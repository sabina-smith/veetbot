import Foundation

/// One change a topic agent asks to make to its workspace.
public enum WorkspaceOp: Hashable, Sendable {
    case writeFile(path: String, content: String)
    case editFile(path: String, find: String, replace: String)
    case deleteFile(path: String)
    case sql(String)
}

/// The changes carried by one agent reply.
public struct AgentChangeSet: Hashable, Sendable {
    public var summary: String
    public var ops: [WorkspaceOp]
}

/// Parses the change blocks out of an agent reply.
///
/// The agent cannot touch the workspace directly (Veetbot's sandboxes are
/// per-run and the workspace lives with the app), so it writes its changes
/// as blocks the app applies:
///
///     <<<file modules/watering.ts>>>
///     ...full file content...
///     <<<end>>>
///     <<<edit modules/todo.ts>>>
///     <<<find>>>
///     ...exact text...
///     <<<replace>>>
///     ...new text...
///     <<<end>>>
///     <<<delete modules/old.ts>>>
///     <<<sql>>>
///     UPDATE shopping SET status = 'ordered' WHERE id = 3;
///     <<<end>>>
///     <<<summary>>>
///     One line for the owner.
///     <<<end>>>
///
/// The markers are not Markdown fences, so code inside a file can contain
/// fences freely.
public enum AgentChangeParser {
    public static func parse(_ text: String) throws -> AgentChangeSet? {
        let lines = text.components(separatedBy: "\n")
        var ops: [WorkspaceOp] = []
        var summary: String?
        var index = 0

        func marker(_ line: String) -> (String, String)? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("<<<"), trimmed.hasSuffix(">>>"), trimmed.count >= 6 else { return nil }
            let inner = trimmed.dropFirst(3).dropLast(3).trimmingCharacters(in: .whitespaces)
            let parts = inner.split(separator: " ", maxSplits: 1).map(String.init)
            return (parts.first ?? "", parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
        }

        func body(until stops: Set<String>) throws -> (String, String) {
            var collected: [String] = []
            while index < lines.count {
                if let (keyword, _) = marker(lines[index]), stops.contains(keyword) {
                    let stop = keyword
                    index += 1
                    return (collected.joined(separator: "\n"), stop)
                }
                collected.append(lines[index])
                index += 1
            }
            throw WorkspaceError.invalid("a change block is missing its <<<end>>> marker")
        }

        while index < lines.count {
            guard let (keyword, argument) = marker(lines[index]) else { index += 1; continue }
            index += 1
            switch keyword {
            case "file":
                let (content, _) = try body(until: ["end"])
                ops.append(.writeFile(path: try validatedPath(argument), content: content.hasSuffix("\n") ? content : content + "\n"))
            case "edit":
                let path = try validatedPath(argument)
                guard index < lines.count, marker(lines[index])?.0 == "find" else {
                    throw WorkspaceError.invalid("edit \(path): expected <<<find>>>")
                }
                index += 1
                let (find, _) = try body(until: ["replace"])
                let (replace, _) = try body(until: ["end"])
                guard !find.isEmpty else { throw WorkspaceError.invalid("edit \(path): empty find text") }
                ops.append(.editFile(path: path, find: find, replace: replace))
            case "delete":
                let path = try validatedPath(argument)
                guard path != TopicWorkspace.boardFile, path != TopicWorkspace.agentFile, path != TopicWorkspace.handoffFile else {
                    throw WorkspaceError.invalid("\(path) cannot be deleted")
                }
                ops.append(.deleteFile(path: path))
            case "sql":
                let (sql, _) = try body(until: ["end"])
                if !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ops.append(.sql(sql)) }
            case "summary":
                let (text, _) = try body(until: ["end"])
                summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                continue
            }
        }
        guard !ops.isEmpty || summary != nil else { return nil }
        return AgentChangeSet(summary: summary ?? "Updated the workspace", ops: ops)
    }

    /// The reply with every change block removed, for display.
    public static func strippingBlocks(_ text: String) -> String {
        var output: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isMarker = trimmed.hasPrefix("<<<") && trimmed.hasSuffix(">>>")
            if isMarker {
                let keyword = trimmed.dropFirst(3).split(separator: " ").first.map(String.init) ?? ""
                switch keyword.replacingOccurrences(of: ">>>", with: "") {
                case "file", "edit", "sql", "summary": skipping = true
                case "end": skipping = false
                default: break
                }
                continue
            }
            if !skipping { output.append(line) }
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The paths an agent may write. Anything else, including anything that
    /// escapes the workspace, is refused.
    public static func validatedPath(_ raw: String) throws -> String {
        let path = raw.trimmingCharacters(in: .whitespaces)
        let segment = "[a-z0-9][a-z0-9-]{0,47}"
        let allowed = [
            "^AGENT\\.md$", "^HANDOFF\\.md$", "^board\\.json$",
            "^modules/\(segment)\\.ts$", "^log/\(segment)\\.md$", "^notes/\(segment)\\.md$",
        ]
        guard allowed.contains(where: { path.range(of: $0, options: .regularExpression) != nil }) else {
            throw WorkspaceError.invalid("the agent may not write \(path.isEmpty ? "an empty path" : path)")
        }
        return path
    }
}

public struct AppliedChange: Hashable, Sendable {
    public let summary: String
    public let commit: String?
    public let filesChanged: [String]
    public let sqlStatements: Int
}

/// Applies an agent's change set to a workspace, all or nothing: files are
/// written and every module rebuilt, then SQL runs in one transaction. Any
/// failure discards the file changes and rolls the database back.
public struct AgentChangeApplier: Sendable {
    public let builder: ModuleBuilder

    public init(builder: ModuleBuilder) { self.builder = builder }

    @discardableResult
    public func apply(_ changes: AgentChangeSet, to workspace: TopicWorkspace, author: String) throws -> AppliedChange {
        var files: [String] = []
        let statements = changes.ops.compactMap { op -> String? in
            if case .sql(let sql) = op { return sql }
            return nil
        }
        do {
            for op in changes.ops {
                switch op {
                case .writeFile(let path, let content):
                    try workspace.write(path, content)
                    files.append(path)
                case .editFile(let path, let find, let replace):
                    guard let current = workspace.read(path) else {
                        throw WorkspaceError.invalid("edit \(path): the file does not exist")
                    }
                    let occurrences = current.components(separatedBy: find).count - 1
                    guard occurrences == 1 else {
                        throw WorkspaceError.invalid("edit \(path): find text matched \(occurrences) times, expected once")
                    }
                    try workspace.write(path, current.replacingOccurrences(of: find, with: replace))
                    files.append(path)
                case .deleteFile(let path):
                    try workspace.delete(path)
                    files.append(path)
                case .sql:
                    break
                }
            }
            if !files.isEmpty { try workspace.build(with: builder) }
            if !statements.isEmpty {
                try workspace.database.transaction {
                    for sql in statements { try workspace.database.execScript(sql) }
                }
            }
        } catch {
            try? workspace.discardUncommitted()
            if !files.isEmpty { try? workspace.build(with: builder) }
            throw error
        }
        let message = statements.isEmpty
            ? changes.summary
            : "\(changes.summary)\n\nDatabase:\n\(statements.joined(separator: "\n"))"
        let sha = try workspace.commit(message: message, author: author)
        return AppliedChange(summary: changes.summary, commit: sha, filesChanged: files, sqlStatements: statements.count)
    }
}
