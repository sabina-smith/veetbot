import Foundation

/// Something the agent needs the owner to decide, attached to a row on the
/// board: a purchase to approve, a choice between options, a question.
/// The agent creates proposals with SQL; the owner resolves them in the
/// app's sidebar, which applies the chosen option (and any answered fields)
/// to the row.
public struct Proposal: Hashable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case purchase, choice, question, change }
    public enum Status: String, Sendable { case open, accepted, declined, withdrawn }

    public struct Option: Hashable, Sendable {
        public var label: String
        public var detail: String?
        public var url: String?
        public var price: Double?
        /// Column values written to the proposal's row when this option is chosen;
        /// `data.<key>` writes into the row's `data` JSON.
        public var set: [String: DBValue]
    }

    /// One thing a question asks for, answered with a picker rather than
    /// typed text: a calendar for a date, chips for a pick, a stepper for a
    /// number, or a button that connects a data source.
    public struct Field: Hashable, Sendable {
        public enum FieldType: String, Sendable { case date, daterange, number, pick, multi, text, connect, signin }

        public var key: String
        public var label: String
        public var type: FieldType
        /// For pick and multi.
        public var options: [String]
        /// Pick and multi also accept values not in `options`.
        public var allowsOther: Bool
        public var min: Double?
        public var max: Double?
        public var step: Double?
        public var unit: String?
        /// What the agent already found, so the owner only confirms it.
        public var value: Answer?
        /// Where `value` came from, e.g. "From your Amtrak email".
        public var hint: String?
        public var optional: Bool
        /// Row column the answer is written to; `data.<key>` writes into the row's `data` JSON.
        public var column: String?
        /// For daterange: where the end date goes (`column` gets the start).
        public var endColumn: String?
        /// For connect: which data source, e.g. "calendar".
        public var integration: String?
        /// For signin: the booking link the owner can use themselves; its site is the one to sign in to.
        public var url: String?
        /// For signin: the site's name, e.g. "Resy".
        public var siteName: String?
    }

    public enum Answer: Hashable, Sendable, CustomStringConvertible {
        case text(String)
        case number(Double)
        case list([String])
        case range(start: String, end: String)

        /// From the page or from JSON: a string, number, array of strings or {start, end}.
        public init?(json: Any) {
            switch json {
            case let string as String: self = .text(string)
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): self = .number(number.doubleValue)
            case let array as [Any]:
                let strings = array.compactMap { $0 as? String }
                guard strings.count == array.count else { return nil }
                self = .list(strings)
            case let object as [String: Any]:
                guard let start = object["start"] as? String, let end = object["end"] as? String else { return nil }
                self = .range(start: start, end: end)
            default: return nil
            }
        }

        public var jsonValue: Any {
            switch self {
            case .text(let value): return value
            case .number(let value): return value
            case .list(let values): return values
            case .range(let start, let end): return ["start": start, "end": end]
            }
        }

        public var description: String {
            switch self {
            case .text(let value): return value
            case .number(let value): return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
            case .list(let values): return values.joined(separator: ", ")
            case .range(let start, let end): return "\(start) to \(end)"
            }
        }
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
    public let fields: [Field]
    public let answers: [String: Answer]
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
      fields TEXT NOT NULL DEFAULT '[]',
      answers TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      resolved_at TEXT
    );
    """

    public static func ensureSchema(_ database: TopicDatabase) throws {
        try database.execScript(schema)
        // Workspaces made before questions had fields.
        let columns = Set(try database.query("SELECT name FROM pragma_table_info('proposals')").compactMap { row -> String? in
            if case .text(let name)? = row["name"] { return name }
            return nil
        })
        if !columns.contains("fields") { try database.execScript("ALTER TABLE proposals ADD COLUMN fields TEXT NOT NULL DEFAULT '[]';") }
        if !columns.contains("answers") { try database.execScript("ALTER TABLE proposals ADD COLUMN answers TEXT;") }
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

    /// Accepts `proposal`, writing the chosen option's values and the
    /// answered fields into its row. All in one transaction: if an answer
    /// doesn't fit its field or the row update fails, nothing changes.
    public static func accept(
        _ database: TopicDatabase, id: Int64, option index: Int?, note: String?, answers: [String: Proposal.Answer] = [:]
    ) throws {
        guard let proposal = try get(database, id: id) else { throw ProposalError(message: "That proposal no longer exists.") }
        guard proposal.status == .open else { throw ProposalError(message: "That proposal was already \(proposal.status.rawValue).") }
        let option: Proposal.Option?
        if let index {
            guard proposal.options.indices.contains(index) else { throw ProposalError(message: "No such option.") }
            option = proposal.options[index]
        } else {
            option = nil
        }
        try validate(answers, for: proposal.fields)
        var columns: [String: DBValue] = [:]
        var dataKeys: [String: DBValue] = [:]
        for (key, value) in option?.set ?? [:] {
            if key.hasPrefix("data.") { dataKeys[String(key.dropFirst(5))] = value } else { columns[key] = value }
        }
        for field in proposal.fields {
            guard let answer = answers[field.key] else { continue }
            var writes: [(String?, DBValue)] = []
            if case .range(let start, let end) = answer {
                writes = [(field.column, .text(start)), (field.endColumn, .text(end))]
            } else {
                writes = [(field.column, dbValue(answer))]
            }
            for case let (column?, value) in writes {
                if column.hasPrefix("data.") { dataKeys[String(column.dropFirst(5))] = value } else { columns[column] = value }
            }
        }
        let storedAnswers: DBValue = answers.isEmpty ? .null : .text(String(
            decoding: try JSONSerialization.data(withJSONObject: answers.mapValues(\.jsonValue), options: [.sortedKeys]), as: UTF8.self
        ))
        try database.transaction {
            if !columns.isEmpty || !dataKeys.isEmpty {
                guard let ref = proposal.ref else { throw ProposalError(message: "This proposal isn't tied to a row.") }
                if !columns.isEmpty { try applySet(columns, ref: ref, database: database) }
                if !dataKeys.isEmpty { try applyData(dataKeys, ref: ref, database: database) }
            }
            try database.query(
                "UPDATE proposals SET status = 'accepted', chosen = ?, owner_note = ?, answers = ?, resolved_at = datetime('now') WHERE id = ?",
                [index.map { .integer(Int64($0)) } ?? .null, note.map { .text($0) } ?? .null, storedAnswers, .integer(id)]
            )
        }
    }

    /// Every required field answered, each answer the right shape for its field.
    static func validate(_ answers: [String: Proposal.Answer], for fields: [Proposal.Field]) throws {
        let keys = Set(fields.map(\.key))
        if let unknown = answers.keys.first(where: { !keys.contains($0) }) {
            throw ProposalError(message: "This question has nothing called \(unknown).")
        }
        for field in fields {
            guard let answer = answers[field.key] else {
                if field.optional { continue }
                throw ProposalError(message: "\(field.label) needs an answer.")
            }
            let fits: Bool
            switch (field.type, answer) {
            case (.date, .text(let date)):
                fits = isDate(date)
            case (.daterange, .range(let start, let end)):
                fits = isDate(start) && isDate(end) && start <= end
            case (.number, .number(let n)):
                fits = n.isFinite && field.min.map { n >= $0 } ?? true && field.max.map { n <= $0 } ?? true
            case (.pick, .text(let value)):
                fits = !value.trimmingCharacters(in: .whitespaces).isEmpty && (field.allowsOther || field.options.contains(value))
            case (.multi, .list(let values)):
                fits = (field.optional || !values.isEmpty) && (field.allowsOther || values.allSatisfy(field.options.contains))
            case (.signin, .text(let value)):
                // Book from the link, signed in for the helper, or sign-in isn't available here.
                fits = ["link", "signed_in", "unavailable"].contains(value)
            case (.text, .text(let value)), (.connect, .text(let value)):
                fits = !value.trimmingCharacters(in: .whitespaces).isEmpty
            default:
                fits = false
            }
            guard fits else { throw ProposalError(message: "That doesn't fit \(field.label).") }
        }
    }

    private static func isDate(_ text: String) -> Bool {
        guard text.count == 10 else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text) != nil
    }

    private static func dbValue(_ answer: Proposal.Answer) -> DBValue {
        switch answer {
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? .integer(Int64(n)) : .real(n)
        default: return .text(answer.description)
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
    static func applySet(_ values: [String: DBValue], ref: String, database: TopicDatabase, mustHave: [String] = []) throws {
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
        for key in keys + mustHave where !columns.contains(key) || key == "id" {
            throw ProposalError(message: "\(table) has no column \(key) to set.")
        }
        if keys.isEmpty {
            guard try !database.query("SELECT 1 FROM \"\(table)\" WHERE id = ?", [.integer(rowID)]).isEmpty else {
                throw ProposalError(message: "\(ref) no longer exists.")
            }
            return
        }
        let assignments = keys.map { "\"\($0)\" = ?" }.joined(separator: ", ")
        try database.query(
            "UPDATE \"\(table)\" SET \(assignments) WHERE id = ?", keys.map { values[$0]! } + [.integer(rowID)]
        )
        guard database.changes == 1 else { throw ProposalError(message: "\(ref) no longer exists.") }
    }

    /// Sets keys inside `<table>/<id>`'s `data` JSON object, keeping the rest.
    static func applyData(_ values: [String: DBValue], ref: String, database: TopicDatabase) throws {
        try applySet([:], ref: ref, database: database, mustHave: ["data"])
        let table = String(ref.split(separator: "/")[0])
        let rowID = Int64(ref.split(separator: "/")[1])!
        for key in values.keys.sorted() {
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
                throw ProposalError(message: "data.\(key) isn't a field name.")
            }
            try database.query(
                "UPDATE \"\(table)\" SET data = json_set(coalesce(data, '{}'), ?, ?) WHERE id = ?",
                [.text("$.\(key)"), values[key]!, .integer(rowID)]
            )
        }
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
        var fields: [Proposal.Field] = []
        if let raw = text("fields")?.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]]
        {
            fields = array.compactMap { item in
                guard let key = item["key"] as? String else { return nil }
                func number(_ name: String) -> Double? { (item[name] as? NSNumber)?.doubleValue }
                return Proposal.Field(
                    key: key, label: item["label"] as? String ?? key,
                    type: Proposal.Field.FieldType(rawValue: item["type"] as? String ?? "") ?? .text,
                    options: (item["options"] as? [Any] ?? []).map { "\($0)" },
                    allowsOther: item["other"] as? Bool ?? false,
                    min: number("min"), max: number("max"), step: number("step"), unit: item["unit"] as? String,
                    value: item["value"].flatMap(Proposal.Answer.init(json:)), hint: item["hint"] as? String,
                    optional: item["optional"] as? Bool ?? false,
                    column: item["column"] as? String, endColumn: item["end_column"] as? String,
                    integration: item["integration"] as? String,
                    url: item["url"] as? String, siteName: item["name"] as? String
                )
            }
        }
        var answers: [String: Proposal.Answer] = [:]
        if let raw = text("answers")?.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            answers = object.compactMapValues(Proposal.Answer.init(json:))
        }
        return Proposal(
            id: id, ref: text("ref"), kind: Proposal.Kind(rawValue: text("kind") ?? "") ?? .choice, title: title,
            summary: text("summary"), options: options, recommended: int("recommended").map(Int.init),
            status: Proposal.Status(rawValue: text("status") ?? "") ?? .open, chosen: int("chosen").map(Int.init),
            ownerNote: text("owner_note"), fields: fields, answers: answers, createdAt: text("created_at") ?? "", resolvedAt: text("resolved_at")
        )
    }
}
