import SwiftUI
import TopicsKit

struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $app.selection) {
                Section("Topics") {
                    ForEach(app.topics) { topic in
                        Label {
                            Text(topic.name)
                        } icon: {
                            Image(systemName: topic.icon).foregroundStyle(Color(hex: topic.accentHex))
                        }
                        .badge(topic.sealed ? Text(Image(systemName: "lock.fill")) : nil)
                        .tag(topic.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if let error = app.startupError {
                ContentUnavailableView("Topics couldn't start", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let id = app.selection, let board = app.boards[id], let agent = app.agents[id] {
                TopicScreen(board: board, agent: agent)
                    .id(id)
            } else {
                ContentUnavailableView("Pick a topic", systemImage: "square.grid.2x2")
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                Text(toast)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: app.toast)
        #if DEBUG
        .task { DebugSnapshots.startIfRequested(app: app) }
        #endif
    }
}

struct TopicScreen: View {
    @ObservedObject var board: BoardModel
    @ObservedObject var agent: TopicAgent

    var body: some View {
        HStack(spacing: 0) {
            BoardView(board: board)
            Divider()
            AgentPanel(agent: agent, reducer: agent.reducer, board: board)
                .frame(width: 380)
        }
        .navigationTitle(board.topic.name)
        .navigationSubtitle("with \(board.topic.agentName)")
        #if DEBUG
        .toolbar {
            ToolbarItem {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([board.workspace.root])
                } label: {
                    Label("Show workspace (debug)", systemImage: "folder")
                }
                .help("Developer only: reveal this topic's workspace in Finder")
            }
        }
        #endif
        .onAppear { agent.loadIfNeeded() }
    }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
