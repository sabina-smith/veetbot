import SwiftUI
import TopicsKit

/// The topic's board: module cards laid out from board.json.
struct BoardView: View {
    @ObservedObject var board: BoardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = board.buildError {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Part of this board couldn't load. \(board.topic.agentName) will fix it at the next look.", systemImage: "exclamationmark.triangle")
                        #if DEBUG
                        Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        #endif
                    }
                    .foregroundStyle(.orange)
                    .padding(10)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                if let layout = board.board {
                    Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                        ForEach(Array(Self.rows(layout).enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(row) { module in
                                    ModuleCard(board: board, module: module)
                                        .gridCellColumns(min(module.span, layout.columns))
                                }
                                let used = row.reduce(0) { $0 + min($1.span, layout.columns) }
                                if used < layout.columns {
                                    Color.clear.frame(height: 1).gridCellColumns(layout.columns - used)
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Packs modules into rows in order, starting a new row when the next
    /// module would not fit.
    static func rows(_ board: Board) -> [[BoardModule]] {
        var rows: [[BoardModule]] = []
        var current: [BoardModule] = []
        var used = 0
        for module in board.modules {
            let span = min(max(module.span, 1), board.columns)
            if used + span > board.columns, !current.isEmpty {
                rows.append(current)
                current = []
                used = 0
            }
            current.append(module)
            used += span
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}

struct ModuleCard: View {
    @ObservedObject var board: BoardModel
    let module: BoardModule

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(module.title).font(.headline)
                Spacer()
                if board.moduleErrors[module.id] != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Something on this card isn't working. \(board.topic.agentName) will take a look.")
                }
            }
            if let script = board.builtModules[module.id] {
                ModuleWebView(board: board, module: module, script: script)
                    .frame(height: CGFloat(module.height))
            } else {
                Text("This card couldn't load. \(board.topic.agentName) will take a look.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: CGFloat(module.height))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6)))
    }
}
