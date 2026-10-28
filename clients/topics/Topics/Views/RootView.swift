import SwiftUI
import TopicsKit
import WebKit

/// The app shell: the topic rail on the left, and Home, a topic's board or
/// New topic beside it.
struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            TopicRail()
            Rectangle().fill(Ink.line).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.white)
        .preferredColorScheme(.light)
        .sheet(item: $app.siteSignIn, onDismiss: { app.siteSignInClosed() }) { SiteSignInSheet(model: $0) }
        #if DEBUG
        .task { DebugSnapshots.startIfRequested(app: app) }
        #endif
    }

    @ViewBuilder private var content: some View {
        if let error = app.startupError {
            VStack(alignment: .leading, spacing: 8) {
                Text("Topics couldn't start").font(.system(size: 28, weight: .semibold))
                Text(error).foregroundStyle(Ink.muted).textSelection(.enabled)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            switch app.screen {
            case .home:
                HomeScreen()
            case .newTopic:
                PageWebView(html: PageHTML.newTopic(existingHelpers: app.topics.map(\.agentName))) { op, args in
                    try await app.handleHome(op: op, args: args)
                }
            case .onboarding:
                PageWebView(html: PageHTML.onboarding()) { op, args in
                    try await app.handleHome(op: op, args: args)
                }
            case .topic(let id):
                if let board = app.boards[id], let agent = app.agents[id] {
                    BoardScreen(board: board, agent: agent).id(id)
                }
            }
        }
    }
}

struct BoardScreen: View {
    @ObservedObject var board: BoardModel
    let agent: TopicAgent

    var body: some View {
        PageWebView(html: board.pageHTML, handle: { op, args in
            try await board.handle(op: op, args: args)
        }, onLoad: { webView in
            board.attach(webView, agent: agent)
        })
        .onAppear { agent.loadIfNeeded() }
    }
}

struct HomeScreen: View {
    @EnvironmentObject private var app: AppModel
    @State private var html: String?

    var body: some View {
        PageWebView(html: html ?? PageHTML.home(data: app.homeData())) { op, args in
            try await app.handleHome(op: op, args: args)
        }
        .onAppear { html = PageHTML.home(data: app.homeData()) }
    }
}

// MARK: The rail

enum Ink {
    static let ink = Color(hex: "#0F0F0E")
    static let muted = Color(hex: "#6B6B66")
    static let faint = Color(hex: "#9A9A94")
    static let line = Color(hex: "#E7E7E3")
    static let attention = Color(hex: "#FF5A1F")
    static let attentionText = Color(hex: "#C2410C")
}

struct TopicRail: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(selected: app.screen == .home, action: { app.screen = .home }) {
                Text("Home").font(.system(size: 22, weight: .semibold)).tracking(-0.6)
            }
            Text("TOPICS")
                .font(.system(size: 11, weight: .semibold)).tracking(0.9)
                .foregroundStyle(Ink.faint)
                .padding(.leading, 16).padding(.top, 28).padding(.bottom, 8)
            ForEach(app.topics) { topic in
                if let agent = app.agents[topic.id], let board = app.boards[topic.id] {
                    TopicRailRow(topic: topic, agent: agent, board: board)
                }
            }
            row(selected: app.screen == .newTopic, action: { app.screen = .newTopic }) {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    Text("New topic").font(.system(size: 14))
                }
            }
            .padding(.top, 12)
            Spacer()
            if let problem = app.syncProblem {
                Button {
                    Task { await app.syncWithServer() }
                } label: {
                    Text(problem + " Click to retry.")
                        .font(.system(size: 11.5)).foregroundStyle(Color(hex: "#C2410C"))
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
            Text("Each topic has its own helper. Everything is shared.")
                .font(.system(size: 12)).foregroundStyle(Ink.faint)
                .padding(.horizontal, 16).padding(.bottom, 20)
        }
        .padding(.top, 28)
        .frame(width: 208)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.white)
    }

    private func row<Label: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(selected ? Ink.ink : Ink.muted)
                .padding(.vertical, 8).padding(.leading, 16).padding(.trailing, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    if selected { Rectangle().fill(Ink.ink).frame(width: 3).padding(.vertical, 6) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TopicRailRow: View {
    @EnvironmentObject private var app: AppModel
    let topic: Topic
    @State private var renaming: String?
    @ObservedObject var agent: TopicAgent
    @ObservedObject var board: BoardModel

    init(topic: Topic, agent: TopicAgent, board: BoardModel) {
        self.topic = topic
        self.agent = agent
        self.board = board
    }

    var body: some View {
        let selected = app.screen == .topic(topic.id)
        Button {
            app.screen = .topic(topic.id)
        } label: {
            HStack(spacing: 12) {
                Rectangle().fill(Color(hex: topic.accentHex)).frame(width: 10, height: 10)
                Text(topic.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if agent.isWorking {
                    PulsingText(text: topic.agentName, color: Color(hex: topic.accentHex))
                } else if board.proposals.count > 0 {
                    Text("\(board.proposals.count)")
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Ink.ink)
                        .frame(minWidth: 18, minHeight: 18)
                        .padding(.horizontal, 2)
                        .background(Ink.attention)
                }
            }
            .foregroundStyle(selected ? Ink.ink : Ink.muted)
            .padding(.vertical, 8).padding(.leading, 16).padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(Ink.ink).frame(width: 3).padding(.vertical, 6) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") { renaming = topic.name }
        }
        .alert("Rename \(topic.name)", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: Binding(get: { renaming ?? "" }, set: { renaming = $0 }))
            Button("Rename") {
                let name = renaming ?? ""
                Task { await app.rename(topic.id, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .help(agent.isWorking ? "\(topic.agentName) is working" : board.proposals.isEmpty ? topic.name : "\(board.proposals.count) waiting on you")
    }
}

private struct PulsingText: View {
    let text: String
    let color: Color
    @State private var dim = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .opacity(dim ? 0.3 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
            }
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
