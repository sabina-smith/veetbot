import Foundation

public enum WorkspaceError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String)
    case build(String)
    case git(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .build(let message): return "Module build failed: \(message)"
        case .git(let message): return "git: \(message)"
        }
    }
}

public struct WorkspaceCommit: Hashable, Identifiable, Sendable {
    public let sha: String
    public let author: String
    public let date: Date
    public let subject: String
    public var id: String { sha }
}

/// A topic's durable workspace: a git repository holding the agent's notes
/// (`AGENT.md`, `HANDOFF.md`, `log/`), `board.json`, the module sources under
/// `modules/`, and the topic's database (`data.sqlite`, not tracked).
///
/// Check-ins borrow compute, change files here, and commit; nothing needs to
/// keep running in between. Every change is a commit, so it can be inspected
/// and reverted.
public final class TopicWorkspace: @unchecked Sendable {
    public let topic: Topic
    public let root: URL
    public let database: TopicDatabase

    public static let agentFile = "AGENT.md"
    public static let handoffFile = "HANDOFF.md"
    public static let boardFile = "board.json"
    public static let modulesDirectory = "modules"

    /// Opens the workspace at `base/<topic id>`, seeding it from `template`
    /// on first use.
    public init(topic: Topic, base: URL, template: URL?) throws {
        self.topic = topic
        self.root = base.appendingPathComponent(topic.id, isDirectory: true)
        let fileManager = FileManager.default
        let isNew = !fileManager.fileExists(atPath: root.appendingPathComponent(".git").path)
        if isNew {
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
            if let template {
                if fileManager.fileExists(atPath: root.path) { try fileManager.removeItem(at: root) }
                try fileManager.copyItem(at: template, to: root)
            } else {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            }
            try "data.sqlite*\n.build/\n.topic/\n".write(
                to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8
            )
        }
        database = try TopicDatabase(path: root.appendingPathComponent("data.sqlite").path)
        try ProposalStore.ensureSchema(database)
        if isNew {
            for script in ["schema.sql", "seed.sql"] {
                let url = root.appendingPathComponent(script)
                if let sql = try? String(contentsOf: url, encoding: .utf8) {
                    try database.execScript(sql)
                }
            }
            try git(["init", "-q", "-b", "main"])
            try git(["add", "-A"])
            try commit(message: "Seed \(topic.name) workspace", author: "Topics")
        }
    }

    // MARK: Files

    public func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    public func read(_ relativePath: String) -> String? {
        try? String(contentsOf: url(for: relativePath), encoding: .utf8)
    }

    public func write(_ relativePath: String, _ content: String) throws {
        let target = url(for: relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: target, atomically: true, encoding: .utf8)
    }

    public func delete(_ relativePath: String) throws {
        let target = url(for: relativePath)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    public func board() throws -> Board {
        guard let data = read(Self.boardFile)?.data(using: .utf8) else {
            throw WorkspaceError.invalid("board.json is missing")
        }
        do { return try JSONDecoder().decode(Board.self, from: data) }
        catch { throw WorkspaceError.invalid("board.json: \(error.localizedDescription)") }
    }

    /// Module sources keyed by id (`modules/<id>.ts`).
    public func moduleSources() -> [String: String] {
        let directory = url(for: Self.modulesDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var sources: [String: String] = [:]
        for file in files where file.hasSuffix(".ts") && !file.hasSuffix(".d.ts") {
            sources[String(file.dropLast(3))] = read("\(Self.modulesDirectory)/\(file)")
        }
        return sources
    }

    // MARK: Building

    /// Builds every module and validates the board against them. Returns
    /// JavaScript keyed by module id.
    @discardableResult
    public func build(with builder: ModuleBuilder) throws -> [String: String] {
        let sources = moduleSources()
        let built = try builder.build(sources)
        try board().validate(existingModules: Set(sources.keys))
        let output = url(for: ".build")
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (id, js) in built {
            try js.write(to: output.appendingPathComponent("\(id).js"), atomically: true, encoding: .utf8)
        }
        return built
    }

    // MARK: Git

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WorkspaceError.git(String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Commits everything; returns the new sha, or nil if nothing changed.
    @discardableResult
    public func commit(message: String, author: String) throws -> String? {
        try git(["add", "-A"])
        let status = try git(["status", "--porcelain"])
        guard !status.isEmpty else { return nil }
        let email = "\(author.lowercased().filter(\.isLetter))@topics.local"
        try git([
            "-c", "user.name=\(author)", "-c", "user.email=\(email)",
            "commit", "-q", "-m", message,
        ])
        return try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Discards every uncommitted change to tracked and new files.
    public func discardUncommitted() throws {
        try git(["reset", "-q", "--hard", "HEAD"])
        try git(["clean", "-q", "-fd"])
    }

    /// Reverts one commit's file changes (database changes are not undone).
    public func revert(_ sha: String) throws {
        try git(["-c", "user.name=Owner", "-c", "user.email=owner@topics.local", "revert", "--no-edit", sha])
    }

    public func history(limit: Int = 30) throws -> [WorkspaceCommit] {
        let output = try git(["log", "-n", String(limit), "--format=%H%x1f%an%x1f%aI%x1f%s"])
        let formatter = ISO8601DateFormatter()
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else { return nil }
            return WorkspaceCommit(
                sha: parts[0], author: parts[1], date: formatter.date(from: parts[2]) ?? Date(),
                subject: parts[3]
            )
        }
    }
}
