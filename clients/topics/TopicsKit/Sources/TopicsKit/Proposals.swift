import Foundation

/// Something the agent needs the owner to decide, attached to a row on the
/// board: a purchase to approve, a choice between options, a question.
/// The agent creates proposals with SQL; the owner resolves them in the
/// app's sidebar, which applies the chosen option to the row.
public struct Proposal: Hashable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case purchase, choice, question, change }
    public enum Status: String, Sendable { case open, accepted, declined, withdrawn }

    public struct Option: Hashable, Sendable {
        public var label: String
        public var detail: String?
        public var url: String?
        public var price: Double?
        /// Column values written to the proposal's row when this option is chosen.
        public var set: [String: DBValue]
    }

    public let id: Int64
    /// `"<table>/<row id>"`, e.g. `"shopping/2"`; nil for a proposal not tied to a row.
    public let ref: String?
    public let kind: Kind
    public let title: String
    public let summary: String?
    public let options: [Option]
    public let recommended: Int?
    public let status: Status
    public let chosen: Int?
    public let ownerNote: String?
    public let createdAt: String
    public let resolvedAt: String?
}

public struct ProposalError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// The `proposals` table, owned by the app: created in every workspace and
/// documented to the agent.
public enum ProposalStore {
    public static let schema = """
    CREATE TABLE IF NOT EXISTS proposals (
      id INTEGER PRIMARY KEY,
      ref TEXT,
      kind TEXT NOT NULL DEFAULT 'choice' CHECK (kind IN ('purchase', 'choice', 'question', 'change')),
      title TEXT NOT NULL,
      summary TEXT,
      options TEXT NOT NULL DEFAULT '[]',
      recommended INTEGER,
      status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'accepted', 'declined', 'withdrawn')),
      chosen INTEGER,
      owner_note TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      resolved_at TEXT
    );
    """

    public static func ensureSchema(_ database: TopicDatabase) throws {
        try database.execScript(schema)
    }

    public static func list(_ database: TopicDatabase, status: Proposal.Status? = .open) throws -> [Proposal] {
        let rows: [DBRow]
        if let status {
            rows = try database.query("SELECT * FROM proposals WHERE status = ? ORDER BY id DESC", [.text(status.rawValue)])
        } else {
            rows = try database.query("SELECT * FROM proposals ORDER BY id DESC LIMIT 100")
        }
        return rows.compactMap(decode)
    }

    public static func get(_ database: TopicDatabase, id: Int64) throws -> Proposal? {
        try database.query("SELECT * FROM proposals WHERE id = ?", [.integer(id)]).first.flatMap(decode)
    }

    /// Proposals the owner resolved after `since` (SQLite datetime text).
    public static func resolved(_ database: TopicDatabase, since: String?) throws -> [Proposal] {
        try database.query(
            "SELECT * FROM proposals WHERE status IN ('accepted', 'declined') AND resolved_at > ? ORDER BY resolved_at",
            [.text(since ?? "")]
        ).compactMap(decode)
    }

    /// Accepts `proposal`, writing the chosen option's values into its row.
    /// All in one transaction: if the row update fails, nothing changes.
    public static func accept(_ database: TopicDatabase, id: Int64, option index: Int?, note: String?) throws {
        guard let proposal = try get(database, id: id) else { throw ProposalError(message: "That proposal no longer exists.") }
        guard proposal.status == .open else { throw ProposalError(message: "That proposal was already \(proposal.status.rawValue).") }
        let option: Proposal.Option?
        if let index {
            guard proposal.options.indices.contains(index) else { throw ProposalError(message: "No such option.") }
            option = proposal.options[index]
        } else {
            option = nil
        }
        try database.transaction {
            if let option, !option.set.isEmpty {
                guard let ref = proposal.ref else { throw ProposalError(message: "This proposal isn't tied to a row.") }
                try applySet(option.set, ref: ref, database: database)
            }
            try database.query(
                "UPDATE proposals SET status = 'accepted', chosen = ?, owner_note = ?, resolved_at = datetime('now') WHERE id = ?",
                [index.map { .integer(Int64($0)) } ?? .null, note.map { .text($0) } ?? .null, .integer(id)]
            )
        }
    }

    public static func decline(_ database: TopicDatabase, id: Int64, note: String?) throws {
        try database.query(
            "UPDATE proposals SET status = 'declined', owner_note = ?, resolved_at = datetime('now') WHERE id = ? AND status = 'open'",
            [note.map { .text($0) } ?? .null, .integer(id)]
        )
    }

    /// Updates `<table>/<id>` with `values`, after checking the table and
    /// every column exist. The proposals table itself is off limits.
    static func applySet(_ values: [String: DBValue], ref: String, database: TopicDatabase) throws {
        let parts = ref.split(separator: "/").map(String.init)
        let identifier = "^[A-Za-z_][A-Za-z0-9_]*$"
        guard parts.count == 2, parts[0].range(of: identifier, options: .regularExpression) != nil,
            let rowID = Int64(parts[1]), parts[0] != "proposals"
        else { throw ProposalError(message: "The proposal points at \(ref), which isn't a row.") }
        let table = parts[0]
        let columns = Set(try database.query("SELECT name FROM pragma_table_info(?)", [.text(table)]).compactMap { row -> String? in
            if case .text(let name)? = row["name"] { return name }
            return nil
        })
        guard !columns.isEmpty else { throw ProposalError(message: "There is no \(table) table.") }
        let keys = values.keys.sorted()
        for key in keys where !columns.contains(key) || key == "id" {
            throw ProposalError(message: "\(table) has no column \(key) to set.")
        }
        let assignments = keys.map { "\"\($0)\" = ?" }.joined(separator: ", ")
        try database.query(
            "UPDATE \"\(table)\" SET \(assignments) WHERE id = ?", keys.map { values[$0]! } + [.integer(rowID)]
        )
        guard database.changes == 1 else { throw ProposalError(message: "\(ref) no longer exists.") }
    }

    static func decode(_ row: DBRow) -> Proposal? {
        func text(_ key: String) -> String? { if case .text(let v)? = row[key] { return v }; return nil }
        func int(_ key: String) -> Int64? { if case .integer(let v)? = row[key] { return v }; return nil }
        guard let id = int("id"), let title = text("title") else { return nil }
        var options: [Proposal.Option] = []
        if let raw = text("options")?.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]]
        {
            options = array.map { item in
                Proposal.Option(
                    label: item["label"] as? String ?? "Option",
                    detail: item["detail"] as? String,
                    url: item["url"] as? String,
                    price: (item["price"] as? NSNumber)?.doubleValue,
                    set: (item["set"] as? [String: Any] ?? [:]).mapValues { DBValue(any: $0) }
                )
            }
        }
        return Proposal(
            id: id, ref: text("ref"), kind: Proposal.Kind(rawValue: text("kind") ?? "") ?? .choice, title: title,
            summary: text("summary"), options: options, recommended: int("recommended").map(Int.init),
            status: Proposal.Status(rawValue: text("status") ?? "") ?? .open, chosen: int("chosen").map(Int.init),
            ownerNote: text("owner_note"), createdAt: text("created_at") ?? "", resolvedAt: text("resolved_at")
        )
    }
}
