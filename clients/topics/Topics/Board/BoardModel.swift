import Foundation
import TopicsKit
import WebKit

/// One topic's board: its layout, the built module code, and the bridge
/// every module card calls into.
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
    /// The proposal the owner opened from a row, shown in the sidebar.
    @Published var focusedProposalID: Int64?

    var topic: Topic { workspace.topic }
    private var webViews = NSHashTable<WKWebView>.weakObjects()

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
        }
        history = (try? workspace.history()) ?? []
        refreshProposals()
    }

    func refreshProposals() {
        proposals = (try? ProposalStore.list(workspace.database)) ?? []
        if let focused = focusedProposalID, !proposals.contains(where: { $0.id == focused }) {
            focusedProposalID = nil
        }
    }

    func open(proposal id: Int64) {
        refreshProposals()
        focusedProposalID = id
        app.sidebarTab = .forYou
    }

    func accept(_ proposal: Proposal, option: Int?, note: String?) {
        do {
            try ProposalStore.accept(workspace.database, id: proposal.id, option: option, note: note)
            dataChanged()
            let choice = option.map { proposal.options[$0].label }
            app.showToast(proposal.kind == .purchase ? "Approved. \(topic.agentName) will take it from here." : "Sent to \(topic.agentName)")
            app.agents[topic.id]?.checkIn(
                reason: "You made a decision",
                focus: "The owner accepted proposal #\(proposal.id) (\(proposal.title))" + (choice.map { ", choosing \"\($0)\"" } ?? "")
                    + (note.map { ". Their note: \($0)" } ?? "") + ". Carry on from there."
            )
        } catch {
            app.showToast(error.localizedDescription)
        }
    }

    func decline(_ proposal: Proposal, note: String?) {
        do {
            try ProposalStore.decline(workspace.database, id: proposal.id, note: note)
            dataChanged()
            app.agents[topic.id]?.checkIn(
                reason: "You made a decision",
                focus: "The owner declined proposal #\(proposal.id) (\(proposal.title))" + (note.map { ". Their note: \($0)" } ?? "")
                    + ". Respect that; don't re-propose the same thing."
            )
        } catch {
            app.showToast(error.localizedDescription)
        }
    }

    func register(_ webView: WKWebView) { webViews.add(webView) }

    /// Tells every module card that the topic's data changed.
    func dataChanged() {
        refreshProposals()
        for webView in webViews.allObjects {
            webView.evaluateJavaScript("window.__topicsChanged && window.__topicsChanged()")
        }
    }

    func recordModuleError(_ moduleID: String, _ message: String) {
        moduleErrors[moduleID] = String(message.prefix(1500))
    }

    func clearModuleErrors() { moduleErrors = [:] }

    func revert(_ commit: WorkspaceCommit) {
        do {
            try workspace.revert(commit.sha)
            reload()
            dataChanged()
            app.showToast("Reverted “\(commit.subject)”")
        } catch {
            app.showToast(error.localizedDescription)
        }
    }

    // MARK: Bridge

    /// Handles one call from a module's SDK. Returns a JSON-compatible value.
    func handle(op: String, args: [String: Any], moduleID: String) async throws -> Any? {
        let database = workspace.database
        switch op {
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
            return ["id": stored.id.uuidString]
        case "schedule.remove":
            if let id = (args["id"] as? String).flatMap(UUID.init(uuidString:)) {
                try app.schedule.remove(id: id, owner: topic)
            }
            return nil
        case "schedule.list":
            let days = (args["days"] as? NSNumber)?.doubleValue ?? 14
            return scheduleEntries(days: days).map(Self.json)
        case "proposals.list":
            return proposals.map(Self.json)
        case "proposals.open":
            if let id = (args["id"] as? NSNumber)?.int64Value { open(proposal: id) }
            return nil
        case "agent.ask":
            app.agents[topic.id]?.send(args["text"] as? String ?? "")
            return nil
        case "agent.assign":
            let task = args["task"] as? String ?? ""
            let ref = args["ref"] as? String
            app.agents[topic.id]?.checkIn(reason: "You handed \(topic.agentName) a task", focus: ref.map { "\(task) [\($0)]" } ?? task)
            app.showToast("Handed to \(topic.agentName)")
            return nil
        case "toast":
            app.showToast(args["text"] as? String ?? "")
            return nil
        case "log":
            recordModuleError(moduleID, args["message"] as? String ?? "unknown error")
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
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: string) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = string.count == 16 ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: string)
    }

    static func json(_ proposal: Proposal) -> [String: Any] {
        func n(_ value: Any?) -> Any { value ?? NSNull() }
        return [
            "id": proposal.id, "ref": n(proposal.ref), "kind": proposal.kind.rawValue, "title": proposal.title,
            "summary": n(proposal.summary), "recommended": n(proposal.recommended),
            "options": proposal.options.map { option -> [String: Any] in
                ["label": option.label, "detail": n(option.detail), "url": n(option.url), "price": n(option.price)]
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
