import SwiftUI
import TopicsKit
import VeetbotCore

/// The agent's side of the board: what it needs from the owner ("For you")
/// and the conversation ("Chat"). Nothing here shows how the agent works
/// internally; it reads like a colleague, not a system.
struct AgentPanel: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var agent: TopicAgent
    @ObservedObject var reducer: RunStateReducer
    @ObservedObject var board: BoardModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $app.sidebarTab) {
                Text(board.proposals.isEmpty ? "For you" : "For you (\(board.proposals.count))").tag(AppModel.SidebarTab.forYou)
                Text("Chat").tag(AppModel.SidebarTab.chat)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14).padding(.bottom, 10)
            Divider()
            switch app.sidebarTab {
            case .forYou: ForYouView(agent: agent, board: board)
            case .chat: ChatView(agent: agent, reducer: reducer)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color(hex: agent.topic.accentHex))
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.topic.agentName).font(.headline)
                Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if agent.isWorking {
                Button {
                    agent.stop()
                } label: {
                    Label(agent.isStopping ? "Stopping…" : "Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(agent.isStopping)
                .help("Stop \(agent.topic.agentName) and cancel anything queued")
            } else {
                Button {
                    agent.checkIn()
                } label: {
                    Label("Check in", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .help("Ask \(agent.topic.agentName) to look over the board now")
            }
            Menu {
                Button("Start a new conversation") { agent.startNewConversation() }
                    .disabled(agent.isWorking)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var statusLine: String {
        if agent.isStopping { return "Stopping…" }
        if agent.isWorking { return agent.queuedCount > 0 ? "Working · \(agent.queuedCount) more after this" : "Working on the board…" }
        if let date = agent.lastCheckIn { return "Last looked \(date.formatted(.relative(presentation: .named)))" }
        return "Hasn't looked at the board yet"
    }
}

// MARK: For you

private struct ForYouView: View {
    @ObservedObject var agent: TopicAgent
    @ObservedObject var board: BoardModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if agent.isWorking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("\(agent.topic.agentName) is working on the board…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(agent.approvals) { approval in
                        ApprovalRow(approval: approval, agent: agent)
                    }
                    if let error = agent.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Text("Needs you").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    if board.proposals.isEmpty {
                        Text("Nothing right now. When \(agent.topic.agentName) finds something to buy or needs an answer, it shows up here and on the board.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(board.proposals) { proposal in
                        ProposalCard(
                            proposal: proposal, board: board, agentName: agent.topic.agentName,
                            expanded: board.focusedProposalID == proposal.id || board.proposals.count == 1
                        )
                        .id(proposal.id)
                    }
                    ActivityList(board: board, agentName: agent.topic.agentName)
                        .padding(.top, 8)
                }
                .padding(14)
            }
            .onChange(of: board.focusedProposalID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } }
            }
        }
    }
}

private struct ProposalCard: View {
    let proposal: Proposal
    @ObservedObject var board: BoardModel
    let agentName: String
    let expanded: Bool
    @State private var choice: Int?
    @State private var note = ""
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { isOpen.toggle() }
                if isOpen { board.focusedProposalID = proposal.id }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: icon).foregroundStyle(Color(hex: board.topic.accentHex))
                    Text(proposal.title).font(.callout.weight(.semibold)).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showing ? 0 : -90)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showing {
                if let summary = proposal.summary, !summary.isEmpty {
                    Text(MessageText.markdown(summary)).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(proposal.options.enumerated()), id: \.offset) { index, option in
                    optionRow(index, option)
                }
                TextField(proposal.kind == .question ? "Your answer" : "Anything \(agentName) should know? (optional)", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                HStack {
                    Button(primaryLabel) {
                        board.accept(proposal, option: proposal.options.isEmpty ? nil : selected, note: note.isEmpty ? nil : note)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: board.topic.accentHex))
                    .disabled(proposal.kind == .question && proposal.options.isEmpty && note.isEmpty)
                    Button("Decline") { board.decline(proposal, note: note.isEmpty ? nil : note) }
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(board.focusedProposalID == proposal.id ? Color(hex: board.topic.accentHex) : Color.secondary.opacity(0.25))
        )
        .onAppear { isOpen = expanded }
        .onChange(of: expanded) { _, value in if value { isOpen = true } }
    }

    private var showing: Bool { isOpen || expanded }
    private var selected: Int { choice ?? proposal.recommended ?? 0 }

    private var icon: String {
        switch proposal.kind {
        case .purchase: return "cart"
        case .choice: return "list.bullet"
        case .question: return "questionmark.bubble"
        case .change: return "square.grid.2x2"
        }
    }

    private var primaryLabel: String {
        switch proposal.kind {
        case .purchase: return "Approve"
        case .choice: return "Choose"
        case .question: return proposal.options.isEmpty ? "Send answer" : "Choose"
        case .change: return "Accept"
        }
    }

    private func optionRow(_ index: Int, _ option: Proposal.Option) -> some View {
        Button {
            choice = index
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected == index ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected == index ? Color(hex: board.topic.accentHex) : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(option.label).fontWeight(.medium)
                        if proposal.recommended == index {
                            Text("\(agentName)'s pick").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color(hex: board.topic.accentHex).opacity(0.15), in: Capsule())
                                .foregroundStyle(Color(hex: board.topic.accentHex))
                        }
                        Spacer()
                        if let price = option.price {
                            Text(price, format: .currency(code: "USD")).monospacedDigit()
                        }
                    }
                    if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    if let url = option.url.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true {
                        Link(destination: url) {
                            Label(url.host?.replacingOccurrences(of: "www.", with: "") ?? "Open", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                    }
                }
            }
            .padding(8)
            .background(selected == index ? Color(hex: board.topic.accentHex).opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What the agent changed, in its own plain words, with undo.
private struct ActivityList: View {
    @ObservedObject var board: BoardModel
    let agentName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What \(agentName) did").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            let items = board.history.filter { $0.author == agentName }.prefix(10)
            if items.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(items)) { commit in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(commit.subject).font(.callout)
                        Text(commit.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Undo") { board.revert(commit) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Undo this change to the board")
                }
            }
        }
    }
}

// MARK: Chat

private struct ChatView: View {
    @ObservedObject var agent: TopicAgent
    @ObservedObject var reducer: RunStateReducer
    @State private var draft = ""
    @State private var answer = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if reducer.timeline.isEmpty {
                            Text("Ask \(agent.topic.agentName) anything about the garden, or ask for a change to the board.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(reducer.timeline) { item in
                            MessageRow(item: item, outcome: agent.outcomes[item.id], agentName: agent.topic.agentName)
                                .id(item.id)
                        }
                        if agent.isWorking {
                            WorkingRow(reducer: reducer, agentName: agent.topic.agentName).id("working")
                        }
                        ForEach(agent.approvals) { approval in
                            ApprovalRow(approval: approval, agent: agent)
                        }
                        if let question = reducer.clarifyingQuestion {
                            questionRow(question)
                        }
                        if let error = agent.lastError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: reducer.timeline.last?.text) { _, _ in
                    proxy.scrollTo(agent.isWorking ? "working" : reducer.timeline.last?.id, anchor: .bottom)
                }
                .onAppear { proxy.scrollTo(reducer.timeline.last?.id, anchor: .bottom) }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(agent.topic.agentName)…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(hex: agent.topic.accentHex))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
    }

    private func send() {
        let text = draft
        draft = ""
        agent.send(text)
    }

    private func questionRow(_ question: ClarifyingQuestionPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(question.question, systemImage: "questionmark.bubble")
            HStack {
                TextField("Answer", text: $answer).textFieldStyle(.roundedBorder)
                Button("Send") {
                    let text = answer
                    answer = ""
                    Task { await agent.answer(question, text) }
                }
                .disabled(answer.isEmpty)
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

enum MessageText {
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct MessageRow: View {
    let item: TimelineItem
    let outcome: TopicAgent.Outcome?
    let agentName: String

    var body: some View {
        switch item.role {
        case .user:
            let display = AgentPrompt.displayText(item.text)
            if display.isCheckIn {
                if !display.text.isEmpty {
                    Label(display.text, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                Text(display.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                let visible = AgentChangeParser.strippingBlocks(item.text)
                if !visible.isEmpty {
                    Text(MessageText.markdown(visible)).textSelection(.enabled)
                }
                if let outcome {
                    OutcomeChip(outcome: outcome, agentName: agentName)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OutcomeChip: View {
    let outcome: TopicAgent.Outcome
    let agentName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = outcome.error {
                Label("\(agentName) couldn't update the board and is trying again", systemImage: "arrow.clockwise")
                    .foregroundStyle(.orange)
                DisclosureGroup("Details") {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .font(.caption)
            } else {
                Label(outcome.summary, systemImage: "checkmark.circle").foregroundStyle(.green)
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct WorkingRow: View {
    @ObservedObject var reducer: RunStateReducer
    let agentName: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var status: String {
        if let tool = reducer.tools.last(where: { $0.status == .running }) {
            return tool.name.contains("search") || tool.name.contains("fetch") ? "\(agentName) is looking things up…" : "\(agentName) is working…"
        }
        if reducer.runStatus == .waitingForApproval { return "Waiting for your OK" }
        return "\(agentName) is thinking…"
    }
}

private struct ApprovalRow: View {
    let approval: ApprovalView
    @ObservedObject var agent: TopicAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(agent.topic.agentName) needs your OK", systemImage: "hand.raised").font(.callout.weight(.semibold))
            Text(approval.actionSummary).textSelection(.enabled)
            HStack {
                Button("Allow") { Task { await agent.resolve(approval, decision: .approveOnce) } }
                    .buttonStyle(.borderedProminent)
                Button("Don't allow", role: .destructive) { Task { await agent.resolve(approval, decision: .deny) } }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
