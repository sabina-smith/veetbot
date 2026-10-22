import Foundation

/// The board a new topic opens with, built at once from the owner's answers
/// to the helper's first questions, using only ready-made cards. The helper
/// tidies it up afterwards.
public enum StarterBoard {
    public struct Answers: Sendable {
        public var about: String
        public var onYourMind: String
        public var helpers: String

        public init(about: String, onYourMind: String, helpers: String) {
            self.about = about
            self.onYourMind = onYourMind
            self.helpers = helpers
        }
    }

    public static func board(topicName: String) -> Board {
        Board(modules: [
            BoardModule(id: "on-your-mind", title: "On your mind", span: 7, kind: "list"),
            BoardModule(id: "about", title: "About \(topicName)", span: 5, kind: "notes"),
            BoardModule(id: "people", title: "People", span: 6, kind: "table", columns: [
                CardColumn(key: "title", label: "Who"), CardColumn(key: "detail", label: "Role"),
            ]),
            BoardModule(id: "coming-up", title: "Coming up", span: 6, kind: "schedule"),
        ])
    }

    /// Writes the starter board and its rows into `workspace` and commits.
    public static func apply(to workspace: TopicWorkspace, answers: Answers) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(decoding: try encoder.encode(board(topicName: workspace.topic.name)), as: UTF8.self)
        try workspace.write(TopicWorkspace.boardFile, json + "\n")
        let database = workspace.database
        try database.transaction {
            if !answers.about.trimmingCharacters(in: .whitespaces).isEmpty {
                try database.query("INSERT INTO items (card, title) VALUES ('about', ?)", [.text(answers.about.trimmingCharacters(in: .whitespaces))])
            }
            for (index, task) in split(answers.onYourMind).enumerated() {
                try database.query("INSERT INTO items (card, title, position) VALUES ('on-your-mind', ?, ?)", [.text(task), .integer(Int64(index))])
            }
            for person in split(answers.helpers) {
                let (name, role) = nameAndRole(person)
                try database.query("INSERT INTO items (card, title, detail) VALUES ('people', ?, ?)", [.text(name), role.map { .text($0) } ?? .null])
            }
        }
        try workspace.commit(message: "Starter board", author: "Topics")
    }

    /// "vet visits, ordering food and finding a sitter" → three items.
    public static func split(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard !trimmed.isEmpty, !["no", "none", "nobody", "no one", "just me", "-", "n/a"].contains(lowered) else { return [] }
        let parts = trimmed
            .replacingOccurrences(of: #"\s+(and|&)\s+"#, with: ",", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))) }
            .filter { !$0.isEmpty }
        return Array(parts.prefix(8)).map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    /// "Dr. Patel (vet)" → ("Dr. Patel", "Vet").
    static func nameAndRole(_ text: String) -> (String, String?) {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return (text, nil) }
        let name = text[..<open].trimmingCharacters(in: .whitespaces)
        let role = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? text : name, role.isEmpty ? nil : role.prefix(1).uppercased() + role.dropFirst())
    }
}
