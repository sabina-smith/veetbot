import Foundation
import TopicsKit
import VeetbotCore

/// A topic's agent, as the app sees it: one Veetbot session per topic, so
/// chats and check-ins share one history and the owner always talks to the
/// same agent. Only one run is in flight per topic; later requests queue.
@MainActor
final class TopicAgent: ObservableObject {
    enum Kind { case chat, checkIn, retry }

    struct Outcome: Codable {
        let summary: String
        let error: String?
    }

    let topic: Topic
    unowned let board: BoardModel
    unowned let app: AppModel
    let reducer = RunStateReducer()

    @Published private(set) var sessionID: UUID?
    @Published private(set) var isWorking = false
    @Published private(set) var isStopping = false
    @Published private(set) var queuedCount = 0
    @Published private(set) var approvals: [ApprovalView] = []
    /// What each reply did to the board, keyed by timeline item id.
    @Published private(set) var outcomes: [String: Outcome] = [:]
    @Published var lastError: String?
    @Published private(set) var lastCheckIn: Date?

    private var queue: [(kind: Kind, build: () -> String)] = []
    private var retriesLeft = 1
    private var stateSentFingerprint: String?
    private var loadTask: Task<Void, Never>?
    private var currentRunID: UUID?
    private var currentKind: Kind = .chat
    private var stopRequested = false

    private var sessionKey: String { "topics.session.\(topic.id)" }
    private var checkInKey: String { "topics.lastCheckIn.\(topic.id)" }
    private var outcomesKey: String { "topics.outcomes.\(topic.id)" }
    private var handledRunsKey: String { "topics.handledRuns.\(topic.id)" }

    init(topic: Topic, board: BoardModel, app: AppModel) {
        self.topic = topic
        self.board = board
        self.app = app
        let defaults = UserDefaults.standard
        sessionID = defaults.string(forKey: sessionKey).flatMap(UUID.init(uuidString:))
        lastCheckIn = defaults.object(forKey: checkInKey) as? Date
        if let data = defaults.data(forKey: outcomesKey),
            let saved = try? JSONDecoder().decode([String: Outcome].self, from: data)
        {
            outcomes = saved
        }
    }

    struct ThreadItem {
        let fromOwner: Bool
        let text: String
    }

    /// The conversation as the owner sees it: their own words and the
    /// helper's short replies, never the context sent with them.
    var thread: [ThreadItem] {
        reducer.timeline.suffix(12).compactMap { item -> ThreadItem? in
            switch item.role {
            case .user:
                let display = AgentPrompt.displayText(item.text)
                return display.isCheckIn || display.text.isEmpty ? nil : ThreadItem(fromOwner: true, text: display.text)
            case .assistant:
                let text = AgentChangeParser.strippingBlocks(item.text)
                return text.isEmpty ? nil : ThreadItem(fromOwner: false, text: text)
            }
        }
    }

    /// A few words on what the helper is doing right now.
    var doing: String {
        guard isWorking else { return "" }
        if isStopping { return "Stopping…" }
        if let tool = reducer.tools.last(where: { $0.status == .running }) {
            return tool.name.contains("search") || tool.name.contains("fetch") ? "Looking things up" : "Working on it"
        }
        if reducer.runStatus == .waitingForApproval { return "Waiting for your OK" }
        return "Thinking it over"
    }

    // MARK: Public

    func loadIfNeeded() {
        guard loadTask == nil else { return }
        loadTask = Task { await restoreHistory() }
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        enqueue(.chat) { [unowned self] in
            let fingerprint = stateFingerprint()
            let prompt = AgentPrompt.chat(
                trimmed, board: board,
                includeState: fingerprint != stateSentFingerprint,
                firstInSession: sessionID == nil
            )
            stateSentFingerprint = fingerprint
            return prompt
        }
    }

    func checkIn(reason: String? = nil, focus: String? = nil) {
        let reason = reason ?? "You asked \(topic.agentName) to check in"
        enqueue(.checkIn) { [unowned self] in
            stateSentFingerprint = stateFingerprint()
            return AgentPrompt.checkIn(reason: reason, focus: focus, board: board, lastCheckIn: lastCheckIn)
        }
    }

    /// Stops the run in progress and drops anything queued behind it.
    func stop() {
        queue.removeAll()
        queuedCount = 0
        guard isWorking, let runID = currentRunID ?? reducer.activeRunID else { return }
        stopRequested = true
        isStopping = true
        Task {
            do {
                _ = try await app.connection.client().cancelRun(runID)
            } catch {
                lastError = "Couldn't stop: \(error.localizedDescription)"
                isStopping = false
            }
        }
    }

    func resolve(_ approval: ApprovalView, decision: ApprovalDecision) async {
        do {
            _ = try await app.connection.client().resolveApproval(approval.id, decision: decision)
            approvals.removeAll { $0.id == approval.id }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func answer(_ question: ClarifyingQuestionPrompt, _ text: String) async {
        do {
            _ = try await app.connection.client().deliverInput(
                runID: question.runID, content: [.text(text)], questionID: question.questionID
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startNewConversation() {
        guard !isWorking else { return }
        UserDefaults.standard.removeObject(forKey: sessionKey)
        sessionID = nil
        stateSentFingerprint = nil
        outcomes = [:]
        saveOutcomes()
        reducer.reset()
    }

    // MARK: Running

    private func enqueue(_ kind: Kind, _ build: @escaping () -> String) {
        queue.append((kind, build))
        queuedCount = queue.count
        Task { await drain() }
    }

    private func drain() async {
        await loadTask?.value
        guard !isWorking else { return }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            queuedCount = queue.count
            isWorking = true
            lastError = nil
            stopRequested = false
            await run(next.kind, next.build())
            currentRunID = nil
            isWorking = false
            isStopping = false
        }
    }

    private func run(_ kind: Kind, _ text: String) async {
        do {
            let client = try app.connection.client()
            let session = try await ensureSession(client)
            let submitted = try await client.submitMessage(sessionID: session, content: [.text(text)])
            currentRunID = submitted.runID
            currentKind = kind
            reducer.begin(runID: submitted.runID, status: submitted.status)
            try? await follow(runID: submitted.runID, client: client)
            await finish(runID: submitted.runID, kind: kind, client: client)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Streams a run's events into the timeline. The stream can end before
    /// the terminal event arrives, so `finish` confirms with the server.
    private func follow(runID: UUID, client: VeetbotAPIClient) async throws {
        let stream = ReconnectingEventStream(reader: SSEReader(transport: client.transport)).frames(runID: runID)
        for try await frame in stream {
            reducer.reduce(frame)
            if frame.event == "approval.requested" || frame.event == "run.waiting_for_approval" {
                await refreshApprovals(client: client)
            }
            if frame.event == "approval.resolved" {
                approvals.removeAll { !reducer.needsApprovalIDs.contains($0.id) }
            }
            if reducer.runStatus?.isTerminal == true { break }
        }
        approvals = []
    }

    /// Waits until the server reports the run finished, reloads the
    /// authoritative transcript, and applies the final reply's changes once.
    private func finish(runID: UUID, kind: Kind, client: VeetbotAPIClient) async {
        var status = reducer.runStatus
        var failure: RunFailureView?
        for attempt in 0..<120 where status?.isTerminal != true {
            if let run = try? await client.getRun(runID) {
                status = run.status
                failure = run.failure
                if run.status.isTerminal { break }
                if !isWorking { break }
            }
            try? await Task.sleep(for: .seconds(attempt < 10 ? 1 : 3))
        }
        let messages = await allMessages(client: client)
        if !messages.isEmpty { reducer.restore(messages: messages) }
        switch status {
        case .completed?:
            if kind == .checkIn || kind == .retry {
                lastCheckIn = Date()
                UserDefaults.standard.set(lastCheckIn, forKey: checkInKey)
            }
            guard markHandled(runID) else { return }
            if let reply = messages.last(where: { $0.role == .assistant }) {
                let text = reply.content.compactMap(\.text).joined(separator: "\n")
                handleReply(itemID: "event-\(reply.sequence)", text: text, kind: kind)
            }
        case .failed?:
            lastError = failure?.message ?? reducer.failure?.message ?? "\(topic.agentName) ran into a problem."
            board.showToast("\(topic.agentName) ran into a problem and stopped.")
        case .cancelled?:
            if !stopRequested { lastError = "\(topic.agentName) stopped before finishing." }
            board.showToast(stopRequested ? "Stopped. Nothing on the board changed." : "\(topic.agentName) stopped before finishing.")
        default:
            lastError = "\(topic.agentName) is taking a long time. The answer will show up when it's ready."
        }
    }

    private func allMessages(client: VeetbotAPIClient) async -> [SessionMessageView] {
        guard let sessionID else { return [] }
        var items: [SessionMessageView] = []
        var cursor: String?
        repeat {
            guard let page = try? await client.listSessionMessages(sessionID: sessionID, cursor: cursor) else { return items }
            items += page.items
            cursor = page.nextCursor
        } while cursor != nil
        return items
    }

    /// Records that a run's reply was handled; false if it already was.
    private func markHandled(_ runID: UUID) -> Bool {
        var handled = UserDefaults.standard.stringArray(forKey: handledRunsKey) ?? []
        guard !handled.contains(runID.uuidString) else { return false }
        handled.append(runID.uuidString)
        UserDefaults.standard.set(Array(handled.suffix(100)), forKey: handledRunsKey)
        return true
    }

    private func refreshApprovals(client: VeetbotAPIClient) async {
        var fetched: [ApprovalView] = []
        for id in reducer.needsApprovalIDs {
            if let approval = try? await client.getApproval(id), approval.status.isPending {
                fetched.append(approval)
            }
        }
        approvals = fetched
    }

    private func ensureSession(_ client: VeetbotAPIClient) async throws -> UUID {
        if let sessionID { return sessionID }
        let session = try await client.createSession(
            metadata: ["topics.topic_id": .string(topic.id), "topics.agent": .string(topic.agentName)]
        )
        sessionID = session.id
        UserDefaults.standard.set(session.id.uuidString, forKey: sessionKey)
        return session.id
    }

    private func restoreHistory() async {
        guard let sessionID else { return }
        do {
            let client = try app.connection.client()
            let messages = await allMessages(client: client)
            reducer.restore(messages: messages)
            let session = try await client.getSession(sessionID)
            // A run still going (the app was quit mid-run) is followed and
            // its reply applied when it finishes.
            if let active = session.activeRunID {
                isWorking = true
                currentRunID = active
                reducer.begin(runID: active, status: .running)
                try? await follow(runID: active, client: client)
                await finish(runID: active, kind: .checkIn, client: client)
                currentRunID = nil
                isWorking = false
            }
        } catch {
            if (error as? APIError)?.code == .notFound {
                startNewConversation()
            } else {
                lastError = "Couldn't reach \(topic.agentName): \(error.localizedDescription)"
            }
        }
    }

    // MARK: Changes

    private func handleReply(itemID: String, text: String, kind: Kind) {
        let changes: AgentChangeSet?
        do {
            changes = try AgentChangeParser.parse(text)
        } catch {
            fail(itemID: itemID, error: error.localizedDescription)
            return
        }
        guard let changes, !changes.ops.isEmpty else { return }
        do {
            let previousModules = Set(board.board?.modules.map(\.id) ?? [])
            let applied = try AgentChangeApplier(builder: board.builder)
                .apply(changes, to: board.workspace, author: topic.agentName)
            outcomes[itemID] = Outcome(summary: applied.summary, error: nil)
            saveOutcomes()
            board.reload()
            board.dataChanged()
            board.noteAgentChange(applied, previousModules: previousModules)
            if kind != .chat { board.clearModuleErrors() }
            retriesLeft = 1
        } catch {
            fail(itemID: itemID, error: error.localizedDescription)
        }
    }

    private func fail(itemID: String, error: String) {
        outcomes[itemID] = Outcome(summary: "Couldn't update the board", error: error)
        saveOutcomes()
        guard retriesLeft > 0 else { retriesLeft = 1; return }
        retriesLeft -= 1
        enqueue(.retry) { AgentPrompt.retryAfterFailure(error) }
    }

    private func saveOutcomes() {
        if let data = try? JSONEncoder().encode(outcomes) {
            UserDefaults.standard.set(data, forKey: outcomesKey)
        }
    }

    private func stateFingerprint() -> String {
        let head = board.history.first?.sha ?? ""
        return "\(head)/\(board.workspace.database.totalChanges)/\(board.moduleErrors.count)"
    }
}
