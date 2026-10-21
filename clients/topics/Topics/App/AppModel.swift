import Foundation
import SwiftUI
import TopicsKit

/// Owns everything the app holds open: the topics, their workspaces,
/// boards and agents, the shared schedule, and the Veetbot connection.
@MainActor
final class AppModel: ObservableObject {
    /// One example topic for now; more topics follow the same shape.
    let topics: [Topic] = [.garden]

    let connection = VeetbotConnection()
    let schedule: SharedSchedule
    @Published private(set) var boards: [String: BoardModel] = [:]
    @Published private(set) var agents: [String: TopicAgent] = [:]
    @Published var selection: String? = Topic.garden.id
    @Published var startupError: String?
    @Published var toast: String?
    @Published var sidebarTab: SidebarTab = .forYou

    enum SidebarTab: Hashable { case forYou, chat }

    nonisolated static var dataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Topics", isDirectory: true)
    }

    nonisolated static var bundledResources: URL? {
        Bundle.main.url(forResource: "Bundle", withExtension: nil)
    }

    init() {
        schedule = SharedSchedule(fileURL: Self.dataRoot.appendingPathComponent("shared/schedule.json"))
        do {
            let builder = try ModuleBuilder()
            for topic in topics {
                let template = Self.bundledResources?.appendingPathComponent("templates/\(topic.id)")
                let workspace = try TopicWorkspace(
                    topic: topic, base: Self.dataRoot.appendingPathComponent("workspaces"), template: template
                )
                let board = BoardModel(workspace: workspace, builder: builder, app: self)
                boards[topic.id] = board
                agents[topic.id] = TopicAgent(topic: topic, board: board, app: self)
            }
        } catch {
            startupError = error.localizedDescription
        }
    }

    func showToast(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if toast == text { toast = nil }
        }
    }
}
