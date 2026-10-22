import Foundation

/// One area of the owner's life, with its own agent, board and workspace.
/// See topics/ARCHITECTURE.md, "Data model".
public struct Topic: Codable, Hashable, Identifiable, Sendable {
    /// A stable slug, also the workspace folder name.
    public var id: String
    public var name: String
    /// An SF Symbol name.
    public var icon: String
    /// `#RRGGBB`.
    public var accentHex: String
    /// The name the topic's agent goes by, the same in every check-in.
    public var agentName: String
    /// A sealed topic writes nothing out: its schedule entries reach others
    /// only as `Busy`.
    public var sealed: Bool
    /// A few words under the topic's name, e.g. "Back yard".
    public var subtitle: String?
    /// A suggested first request shown in the ask bar.
    public var suggestion: String?
    /// The workspace template to seed from (`garden`, `household`, or `blank`).
    public var template: String?

    public init(
        id: String, name: String, icon: String, accentHex: String,
        agentName: String, sealed: Bool = false, subtitle: String? = nil,
        suggestion: String? = nil, template: String? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.accentHex = accentHex
        self.agentName = agentName
        self.sealed = sealed
        self.subtitle = subtitle
        self.suggestion = suggestion
        self.template = template
    }
}

extension Topic {
    public static let garden = Topic(
        id: "garden", name: "Garden", icon: "leaf", accentHex: "#157A43", agentName: "Fern",
        subtitle: "Back yard", suggestion: "Keep track of my seeds", template: "garden"
    )
    public static let household = Topic(
        id: "household", name: "Household", icon: "house", accentHex: "#B4531A", agentName: "Hollis",
        subtitle: "Home", suggestion: "Who fixes the dishwasher?", template: "household"
    )
    public static let work = Topic(
        id: "work", name: "Work", icon: "briefcase", accentHex: "#2347C8", agentName: "Ada",
        template: "blank"
    )
    public static let health = Topic(
        id: "health", name: "Health", icon: "heart", accentHex: "#0F0F0E", agentName: "Sage",
        sealed: true, template: "blank"
    )

    public static let defaults: [Topic] = [.garden, .household, .work, .health]
}

/// The owner's topics, persisted as one JSON file.
public final class TopicStore: @unchecked Sendable {
    private let fileURL: URL?
    public private(set) var topics: [Topic]

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
            let saved = try? JSONDecoder().decode([Topic].self, from: data), !saved.isEmpty
        {
            topics = saved
        } else {
            topics = Topic.defaults
            try? persist()
        }
    }

    /// Adds a topic with a unique id derived from its name.
    @discardableResult
    public func add(
        name: String, accentHex: String, agentName: String, sealed: Bool, subtitle: String? = nil
    ) throws -> Topic {
        let base = Self.slug(name)
        var id = base.isEmpty ? "topic" : base
        var n = 2
        while topics.contains(where: { $0.id == id }) {
            id = "\(base)-\(n)"
            n += 1
        }
        let topic = Topic(
            id: id, name: name, icon: "square.grid.2x2", accentHex: accentHex, agentName: agentName,
            sealed: sealed, subtitle: subtitle, template: "blank"
        )
        topics.append(topic)
        try persist()
        return topic
    }

    public static func slug(_ name: String) -> String {
        let lowered = name.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-").prefix(40).description
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(topics).write(to: fileURL, options: .atomic)
    }
}
