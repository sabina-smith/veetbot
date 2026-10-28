import Foundation

/// The board a new topic opens with, built at once from the owner's answers
/// to the helper's first questions, using only ready-made cards. What the
/// topic is becomes the board's summary and the people who help go in the
/// helper's notes; neither gets a card. The helper tidies it up afterwards.
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

    public static func board(topicName: String, summary: String? = nil) -> Board {
        Board(summary: summary, modules: [
            BoardModule(id: "on-your-mind", title: "On your mind", span: 7, kind: "list",
                        about: "The open things you want off your mind, and who's handling each."),
            BoardModule(id: "coming-up", title: "Coming up", span: 5, kind: "schedule",
                        about: "This topic's time on your schedule over the next two weeks."),
        ])
    }

    /// Writes the starter board and its rows into `workspace` and commits.
    public static func apply(to workspace: TopicWorkspace, answers: Answers) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let about = answers.about.trimmingCharacters(in: .whitespaces)
        let json = String(decoding: try encoder.encode(board(topicName: workspace.topic.name, summary: about.isEmpty ? nil : about)), as: UTF8.self)
        try workspace.write(TopicWorkspace.boardFile, json + "\n")
        let people = split(answers.helpers).map { person -> String in
            let (name, role) = nameAndRole(person)
            return "- \(name)" + (role.map { " (\($0))" } ?? "")
        }
        if !people.isEmpty { try workspace.write("notes/people.md", "# People\n\n" + people.joined(separator: "\n") + "\n") }
        let database = workspace.database
        try database.transaction {
            for (index, task) in split(answers.onYourMind).enumerated() {
                try database.query("INSERT INTO items (card, title, position) VALUES ('on-your-mind', ?, ?)", [.text(task), .integer(Int64(index))])
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
