import Combine
import Foundation
import TopicsKit
import WebKit

/// One topic's board: its layout, the built module code, the proposals
/// waiting on the owner, and the bridge the board page calls into.
@MainActor
final class BoardModel: ObservableObject {
    let workspace: TopicWorkspace
    let builder: ModuleBuilder
    unowned let app: AppModel

    @Published private(set) var board: Board?
    @Published private(set) var builtModules: [String: String] = [:]
    @Published private(set) var buildError: String?
    @Published private(set) var history: [WorkspaceCommit] = []
    /// The latest runtime error each module reported, for the next check-in.
    @Published private(set) var moduleErrors: [String: String] = [:]
    /// Decisions the agent is waiting on, newest first.
    @Published private(set) var proposals: [Proposal] = []

    /// The agent's latest change, shown on the cards it touched.
    private(set) var recentChange: (modules: [String], commit: String?, summary: String, date: Date, added: Bool)?
    private var pendingToast: (id: String, text: String, commit: String?, fromHelper: Bool)?
    private var pendingOpenProposal: Int64?

    /// Follows renames.
    var topic: Topic { app.topic(workspace.topic.id) ?? workspace.topic }
    /// Where server suggestions will come from. Veetbot's per-topic
    /// suggestions API (instructions, schedule and reminder suggestions with
    /// accept/dismiss) isn't wired yet; the page already has a place for them.
    var suggestions: [[String: Any]] { [] }
    private weak var page: WKWebView?
    private var cancellables: Set<AnyCancellable> = []

    init(workspace: TopicWorkspace, builder: ModuleBuilder, app: AppModel) {
        self.workspace = workspace
        self.builder = builder
        self.app = app
        reload()
    }

    /// Re-reads board.json and rebuilds every module.
    func reload() {
        do {
            builtModules = try workspace.build(with: builder)
            board = try workspace.board()
            buildError = nil
        } catch {
            buildError = error.localizedDescription
            board = try? workspace.board()
        }
        history = (try? workspace.history()) ?? []
        refreshProposals()
    }

    func refreshProposals() {
        proposals = (try? ProposalStore.list(workspace.database)) ?? []
    }

    var pageHTML: String { PageHTML.board(topic: topic, board: board, modules: builtModules) }

    // MARK: The page

    func attach(_ webView: WKWebView, agent: TopicAgent) {
        guard page !== webView else { return }
        page = webView
        cancellables = []
        agent.objectWillChange.merge(with: agent.reducer.objectWillChange, objectWillChange)
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.pushState() } }
            .store(in: &cancellables)
    }

    /// Tells the page that the topic's data changed; every card re-renders.
    func dataChanged() {
        refreshProposals()
        page?.evaluateJavaScript("window.__topicsChanged && window.__topicsChanged()")
        pushState()
        app.objectWillChange.send()
    }

    func pushState() {
        guard let page, let agent = app.agents[topic.id] else { return }
        var state: [String: Any] = [
            "helper": [
                "working": agent.isWorking, "stopping": agent.isStopping, "doing": agent.doing,
                "thinking": agent.reducer.reasoningTitle ?? NSNull(),
            ] as [String: Any],
            "proposals": proposals.map(Self.json),
            "dueToday": dueToday().map { ["label": $0] },
            "thread": agent.thread.map { ["from": $0.fromOwner ? "you" : "helper", "text": $0.text] },
            "recent": NSNull(),
            "suggestions": suggestions,
            "integrations": ["calendar": CalendarSource.shared.status.rawValue],
            "sites": Dictionary(uniqueKeysWithValues: (app.sites?.all ?? []).map { ($0.site, $0.level.rawValue) }),
        ]
        if let recent = recentChange, Date().timeIntervalSince(recent.date) < 15 * 60 {
            state["recent"] = [
                "modules": recent.modules, "commit": recent.commit ?? NSNull(),
                "label": recent.added ? "Added by \(topic.agentName) just now" : "Changed by \(topic.agentName) just now",
            ] as [String: Any]
        }
        if let toast = pendingToast {
            state["toast"] = ["id": toast.id, "text": toast.text, "commit": toast.commit ?? NSNull(), "fromHelper": toast.fromHelper] as [String: Any]
        }
        if let id = pendingOpenProposal {
            state["openProposal"] = id
            pendingOpenProposal = nil
        }
        page.evaluateJavaScript("window.__topicsState && window.__topicsState(\(PageHTML.json(state)))")
    }

    /// `fromHelper` shows it in the helper's speech bubble instead of a toast.
    func showToast(_ text: String, commit: String? = nil, fromHelper: Bool = false) {
        pendingToast = (UUID().uuidString, text, commit, fromHelper)
        pushState()
    }

    func openProposalWhenShown(_ id: Int64) {
        pendingOpenProposal = id
        pushState()
    }

    private func dueToday() -> [String] {
        let start = Calendar.current.startOfDay(for: Date())
        return app.schedule.entries(for: .topic(topic.id), topics: app.topics, from: start, to: start.addingTimeInterval(86_400))
            .filter { $0.isOwn && $0.kind != .block }
            .map(\.label)
    }

    // MARK: Changes from the agent

    func noteAgentChange(_ applied: AppliedChange, previousModules: Set<String>) {
        let modules = Set(board?.modules.map(\.id) ?? [])
        var touched = Set(applied.filesChanged.compactMap { path -> String? in
            guard path.hasPrefix("modules/"), path.hasSuffix(".ts") else { return nil }
            return String(path.dropFirst("modules/".count).dropLast(3))
        })
        let added = modules.subtracting(previousModules)
        touched.formUnion(added)
        recentChange = (Array(touched.intersection(modules)), applied.commit, applied.summary, Date(), !added.isEmpty)
        showToast(applied.summary, commit: applied.commit, fromHelper: true)
    }

    func recordModuleError(_ moduleID: String, _ message: String) {
        moduleErrors[moduleID] = String(message.prefix(1500))
        #if DEBUG
        if let directory = UserDefaults.standard.string(forKey: "snapshotDir") {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("errors.log")
            let line = "[\(topic.id)/\(moduleID)] \(message)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        #endif
    }

    func clearModuleErrors() { moduleErrors = [:] }

    func revert(sha: String) {
        do {
            try workspace.revert(sha)
            if recentChange?.commit == sha { recentChange = nil }
            reload()
            dataChanged()
            showToast("Undone.")
        } catch {
            showToast("Couldn't undo that change.")
        }
    }

    // MARK: Decisions

    func accept(id: Int64, option: Int?, note: String?, answers: [String: Proposal.Answer] = [:]) {
        guard let proposal = proposals.first(where: { $0.id == id }) else { return }
        do {
            try ProposalStore.accept(workspace.database, id: id, option: option, note: note, answers: answers)
            // "Book it myself" is the owner's choice for that site until they sign in.
            for field in proposal.fields where field.type == .signin && answers[field.key] == .text("link") {
                if let url = field.url { try? app.sites?.record(url, level: .link, name: field.siteName) }
            }
            dataChanged()
            let choice = option.flatMap { proposal.options.indices.contains($0) ? proposal.options[$0].label : nil }
            let answered = proposal.fields.compactMap { field in answers[field.key].map { "\(field.label): \($0)" } }
            showToast(proposal.kind == .purchase ? "\(proposal.title): in your cart." : "Sent to \(topic.agentName).")
            app.agents[topic.id]?.checkIn(
                reason: "You made a decision",
                focus: "The owner accepted proposal #\(proposal.id) (\(proposal.title))" + (choice.map { ", choosing \"\($0)\"" } ?? "")
                    + (answered.isEmpty ? "" : ", answering " + answered.joined(separator: "; "))
                    + (note.map { ". Their note: \($0)" } ?? "") + ". Carry on from there."
            )
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func decline(id: Int64, note: String?) {
        guard let proposal = proposals.first(where: { $0.id == id }) else { return }
        do {
            try ProposalStore.decline(workspace.database, id: id, note: note)
            dataChanged()
            showToast("Declined. \(topic.agentName) will look again if you ask.")
            app.agents[topic.id]?.checkIn(
                reason: "You made a decision",
                focus: "The owner declined proposal #\(proposal.id) (\(proposal.title))" + (note.map { ". Their note: \($0)" } ?? "")
                    + ". Respect that; don't re-propose the same thing."
            )
        } catch {
            showToast(error.localizedDescription)
        }
    }

    // MARK: Bridge

    /// Handles one call from the board page.
    func handle(op: String, args: [String: Any]) async throws -> Any? {
        let database = workspace.database
        let agent = app.agents[topic.id]
        switch op {
        case "ready":
            pushState()
            return nil
        case "db.query":
            let rows = try database.query(args["sql"] as? String ?? "", Self.params(args["params"]))
            return rows.map { row in row.mapValues(\.foundationValue) }
        case "db.exec":
            try database.query(args["sql"] as? String ?? "", Self.params(args["params"]))
            let result: [String: Any] = ["changes": database.changes, "lastInsertRowid": database.lastInsertRowID]
            dataChanged()
            return result
        case "schedule.add":
            guard let start = Self.date(args["start"]), let label = args["label"] as? String, !label.isEmpty else {
                throw BridgeError("schedule.add needs a start date and a label")
            }
            let kind = ScheduleKind(rawValue: args["kind"] as? String ?? "block") ?? .block
            let visibility = ScheduleVisibility(rawValue: args["visibility"] as? String ?? "labeled") ?? .labeled
            let stored = try app.schedule.add(
                ScheduleRecord(
                    topicID: topic.id, kind: kind, start: start, end: Self.date(args["end"]),
                    sharedLabel: label, privateRef: args["ref"] as? String, visibility: visibility
                ),
                owner: topic
            )
            app.objectWillChange.send()
            return ["id": stored.id.uuidString]
        case "schedule.remove":
            if let id = (args["id"] as? String).flatMap(UUID.init(uuidString:)) {
                try app.schedule.remove(id: id, owner: topic)
                app.objectWillChange.send()
            }
            return nil
        case "schedule.list":
            let days = (args["days"] as? NSNumber)?.doubleValue ?? 14
            return scheduleEntries(days: days).map(Self.json)
        case "proposals.list":
            return proposals.map(Self.json)
        case "proposal.accept":
            if let id = (args["id"] as? NSNumber)?.int64Value {
                let answers = (args["answers"] as? [String: Any] ?? [:]).compactMapValues(Proposal.Answer.init(json:))
                accept(id: id, option: (args["option"] as? NSNumber)?.intValue, note: args["note"] as? String, answers: answers)
            }
            return nil
        case "proposal.decline":
            if let id = (args["id"] as? NSNumber)?.int64Value { decline(id: id, note: args["note"] as? String) }
            return nil
        case "site.signin":
            guard let url = args["url"] as? String else { throw BridgeError("site.signin needs a url") }
            let outcome = await app.signIn(url: url, name: args["name"] as? String ?? SiteAccessStore.site(of: url) ?? "this site")
            pushState()
            return outcome
        case "integration.connect":
            guard args["name"] as? String == "calendar" else { return "unavailable" }
            let status = await CalendarSource.shared.connect()
            pushState()
            return status.rawValue
        case "ask", "agent.ask":
            agent?.send(args["text"] as? String ?? "")
            return nil
        case "agent.assign":
            let task = args["task"] as? String ?? ""
            let ref = args["ref"] as? String
            agent?.checkIn(reason: "You handed \(topic.agentName) a task", focus: ref.map { "\(task) [\($0)]" } ?? task)
            return nil
        case "stop":
            agent?.stop()
            return nil
        case "undo":
            if let sha = args["commit"] as? String { revert(sha: sha) }
            return nil
        case "open":
            if let url = (args["url"] as? String).flatMap(URL.init(string:)) {
                PageWebView.Coordinator.openExternally(url)
            }
            return nil
        case "toast":
            showToast(args["text"] as? String ?? "")
            return nil
        case "suggestion.accept", "suggestion.dismiss":
            // Placeholder until Veetbot's suggestions API lands.
            throw BridgeError("Suggestions aren't available yet.")
        case "log":
            recordModuleError(args["module"] as? String ?? "board", args["message"] as? String ?? "unknown error")
            return nil
        default:
            throw BridgeError("unknown call \(op)")
        }
    }

    func scheduleEntries(days: Double) -> [ScheduleEntry] {
        app.schedule.entries(
            for: .topic(topic.id), topics: app.topics,
            from: Date().addingTimeInterval(-86_400), to: Date().addingTimeInterval(days * 86_400)
        )
    }

    private static func params(_ raw: Any?) -> [DBValue] {
        (raw as? [Any] ?? []).map { DBValue(any: $0) }
    }

    /// Accepts `YYYY-MM-DD` (local midnight) or ISO 8601 date-times.
    static func date(_ raw: Any?) -> Date? {
        guard let string = raw as? String, !string.isEmpty else { return nil }
        if string.count == 10 {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: string)
        }
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = string.count == 16 ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: string)
    }

    static func json(_ proposal: Proposal) -> [String: Any] {
        let n = PageHTML.nullable
        return [
            "id": proposal.id, "ref": n(proposal.ref), "kind": proposal.kind.rawValue, "title": proposal.title,
            "summary": n(proposal.summary), "recommended": n(proposal.recommended),
            "options": proposal.options.map { option -> [String: Any] in
                ["label": option.label, "detail": n(option.detail), "url": n(option.url), "price": n(option.price)]
            },
            "fields": proposal.fields.map { field -> [String: Any] in
                [
                    "key": field.key, "label": field.label, "type": field.type.rawValue, "options": field.options,
                    "other": field.allowsOther, "min": n(field.min), "max": n(field.max), "step": n(field.step),
                    "unit": n(field.unit), "value": n(field.value?.jsonValue), "hint": n(field.hint),
                    "optional": field.optional, "integration": n(field.integration),
                    "url": n(field.url), "name": n(field.siteName),
                ]
            },
        ]
    }

    static func json(_ entry: ScheduleEntry) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var value: [String: Any] = [
            "id": entry.id.uuidString, "kind": entry.kind.rawValue, "start": iso.string(from: entry.start),
            "label": entry.label, "isOwn": entry.isOwn,
        ]
        if let end = entry.end { value["end"] = iso.string(from: end) }
        if let ref = entry.privateRef { value["ref"] = ref }
        return value
    }
}

struct BridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
