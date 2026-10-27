import Foundation
import SwiftUI
import TopicsKit

/// Owns everything the app holds open: the topics, their workspaces,
/// boards and helpers, the shared schedule, and the Veetbot connection.
@MainActor
final class AppModel: ObservableObject {
    enum Screen: Hashable {
        case home
        case topic(String)
        case newTopic
    }

    let connection = VeetbotConnection()
    let schedule: SharedSchedule
    let topicStore: TopicStore
    @Published private(set) var topics: [Topic] = []
    @Published private(set) var boards: [String: BoardModel] = [:]
    @Published private(set) var agents: [String: TopicAgent] = [:]
    @Published var screen: Screen = .home
    @Published var startupError: String?
    /// Nil once the topic list matches Veetbot's; otherwise why it doesn't.
    @Published private(set) var syncProblem: String?

    private var builder: ModuleBuilder?
    /// Finishes once the topic list has been synced with Veetbot (or the
    /// attempt failed). Helpers wait for it before creating sessions, since
    /// a session can only be bound to a topic the server knows.
    private(set) var serverSync: Task<Void, Never>?
    private static let migratedKey = "topics.migratedToServer"

    nonisolated static var dataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Topics", isDirectory: true)
    }

    nonisolated static var bundledResources: URL? {
        Bundle.main.url(forResource: "Bundle", withExtension: nil)
    }

    init() {
        schedule = SharedSchedule(fileURL: Self.dataRoot.appendingPathComponent("shared/schedule.json"))
        topicStore = TopicStore(fileURL: Self.dataRoot.appendingPathComponent("topics.json"))
        topics = topicStore.topics
        if topics.isEmpty { screen = .newTopic }
        do {
            builder = try ModuleBuilder()
            for topic in topics { try open(topic) }
        } catch {
            startupError = error.localizedDescription
        }
        serverSync = Task { await syncWithServer() }
    }

    func api() throws -> TopicsAPI { TopicsAPI(client: try connection.client()) }

    /// Makes Veetbot the source of truth for the topic list. The first time,
    /// topics that exist only on this Mac are created on the server.
    func syncWithServer() async {
        do {
            let api = try api()
            var server = try await api.list()
            if !UserDefaults.standard.bool(forKey: Self.migratedKey) {
                let known = Set(server.map(\.id))
                for topic in topicStore.topics where !known.contains(topic.id) {
                    server.append(try await api.create(id: topic.id, name: topic.name))
                }
                UserDefaults.standard.set(true, forKey: Self.migratedKey)
            }
            try topicStore.reconcile(with: server.map { (id: $0.id, name: $0.name) })
            topics = topicStore.topics
            for topic in topics where boards[topic.id] == nil { try open(topic) }
            let current = Set(topics.map(\.id))
            for id in Array(boards.keys) where !current.contains(id) {
                boards[id] = nil
                agents[id] = nil
            }
            if case .topic(let id) = screen, !current.contains(id) { screen = .home }
            syncProblem = nil
        } catch {
            syncProblem = "Couldn't reach Veetbot to load your topics: \(error.localizedDescription)"
        }
    }

    /// Renames a topic on the server, then here.
    func rename(_ topicID: String, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await api().rename(id: topicID, name: trimmed)
            try topicStore.reconcile(with: topicStore.topics.map { (id: $0.id, name: $0.id == topicID ? trimmed : $0.name) })
            topics = topicStore.topics
            boards[topicID]?.objectWillChange.send()
        } catch {
            syncProblem = "Couldn't rename the topic: \(error.localizedDescription)"
        }
    }

    private func open(_ topic: Topic) throws {
        guard let builder else { return }
        let template = Self.bundledResources?.appendingPathComponent("templates/\(topic.template ?? "blank")")
        let workspace = try TopicWorkspace(
            topic: topic, base: Self.dataRoot.appendingPathComponent("workspaces"), template: template,
            substitutions: ["name": topic.name, "helper": topic.agentName]
        )
        let board = BoardModel(workspace: workspace, builder: builder, app: self)
        boards[topic.id] = board
        agents[topic.id] = TopicAgent(topic: topic, board: board, app: self)
    }

    func topic(_ id: String) -> Topic? { topics.first { $0.id == id } }

    // MARK: New topic

    func createTopic(name: String, colour: String, helper: String, answers: [(q: String, a: String)]) async throws {
        await serverSync?.value
        let api = try api()
        let taken = Set(try await api.list().map(\.id))
        let draft = topicStore.draft(name: name, accentHex: colour, agentName: helper, taken: taken)
        let created = try await api.create(id: draft.id, name: draft.name)
        var topic = draft
        topic.name = created.name
        try topicStore.add(topic)
        topics = topicStore.topics
        try open(topic)
        // The starter board is on screen at once; the helper tidies it after.
        if let board = boards[topic.id] {
            let answer = { (i: Int) in answers.indices.contains(i) ? answers[i].a : "" }
            try StarterBoard.apply(to: board.workspace, answers: .init(about: answer(0), onYourMind: answer(1), helpers: answer(2)))
            board.reload()
        }
        screen = .topic(topic.id)
        let told = answers.filter { !$0.a.isEmpty }.map { "\($0.q)\n\($0.a)" }.joined(separator: "\n\n")
        agents[topic.id]?.checkIn(
            reason: "You set up \(topic.name)",
            focus: """
            The owner just created this topic and answered your first questions:

            \(told)

            A starter board is already on screen, built from those answers with ready-made cards: \
            "On your mind" (list), "About \(topic.name)" (notes), "People" (table) and "Coming up" (schedule). \
            Tidy it quickly: fix rows that were split badly, add a due date or detail where they implied one, \
            and add at most one more ready-made card if it clearly helps. Keep this visit short.
            """
        )
    }

    // MARK: Home

    func homeData() -> [String: Any] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE"
        let days: [[String: Any]] = (0..<5).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: today)!
            return ["short": dayFormatter.string(from: date), "date": calendar.component(.day, from: date), "today": offset == 0]
        }
        let entries = schedule.entries(for: .home, topics: topics, from: today, to: today.addingTimeInterval(5 * 86_400))
        let slots: [[String: Any]] = entries.map { entry in
            let day = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: entry.start)).day ?? 0
            let parts = calendar.dateComponents([.hour, .minute], from: entry.start)
            var start = Double(parts.hour ?? 9) + Double(parts.minute ?? 0) / 60
            if start == 0 { start = 9 }
            let length = entry.end.map { max(0.5, $0.timeIntervalSince(entry.start) / 3600) } ?? 1
            return [
                "id": entry.id.uuidString, "topicId": PageHTML.nullable(entry.topicID),
                "label": entry.topicID == nil ? entry.label : Self.shortLabel(entry.label),
                "day": day, "start": start, "len": length, "kind": entry.kind.rawValue,
            ]
        }
        let asks: [[String: Any]] = topics.flatMap { topic in
            (boards[topic.id]?.proposals ?? []).map { proposal -> [String: Any] in
                ["topicId": topic.id, "name": topic.name, "tint": topic.accentHex, "helper": topic.agentName, "proposal": BoardModel.json(proposal)]
            }
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE d MMMM"
        let now = calendar.dateComponents([.hour, .minute], from: Date())
        return [
            "date": dateFormatter.string(from: Date()),
            "asks": asks,
            "topics": topics.map { topic -> [String: Any] in
                ["id": topic.id, "name": topic.name, "tint": topic.accentHex, "soft": PageHTML.mix(topic.accentHex, with: (255, 255, 255), 0.88)]
            },
            "days": days,
            "slots": slots,
            "nowHour": Double(now.hour ?? 12) + Double(now.minute ?? 0) / 60,
        ]
    }

    /// Home shows "Garden: Plant garlic" as "Plant garlic" in the Garden colour.
    private static func shortLabel(_ label: String) -> String {
        guard let colon = label.firstIndex(of: ":") else { return label }
        return label[label.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    /// Calls from the Home and New topic pages.
    func handleHome(op: String, args: [String: Any]) async throws -> Any? {
        let topicID = args["topicId"] as? String ?? ""
        let proposalID = (args["id"] as? NSNumber)?.int64Value
        switch op {
        case "home.accept":
            if let proposalID { boards[topicID]?.accept(id: proposalID, option: (args["option"] as? NSNumber)?.intValue, note: nil) }
            objectWillChange.send()
        case "home.compare":
            screen = .topic(topicID)
            if let proposalID { boards[topicID]?.openProposalWhenShown(proposalID) }
        case "home.openTopic":
            screen = .topic(topicID)
        case "newtopic.create":
            let answers = (args["answers"] as? [[String: Any]] ?? []).map { (q: $0["q"] as? String ?? "", a: $0["a"] as? String ?? "") }
            try await createTopic(
                name: args["name"] as? String ?? "New topic", colour: args["colour"] as? String ?? "#0E7C86",
                helper: args["helper"] as? String ?? "Wren", answers: answers
            )
        default:
            break
        }
        return nil
    }
}
