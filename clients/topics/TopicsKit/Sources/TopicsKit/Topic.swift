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
    /// A few words under the topic's name, e.g. "Back yard".
    public var subtitle: String?
    /// A suggested first request shown in the ask bar.
    public var suggestion: String?
    /// The workspace template to seed from (`garden`, `household`, or `blank`).
    public var template: String?

    public init(
        id: String, name: String, icon: String, accentHex: String,
        agentName: String, subtitle: String? = nil,
        suggestion: String? = nil, template: String? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.accentHex = accentHex
        self.agentName = agentName
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
        template: "blank"
    )
}

/// What the app knows about each topic beyond the server's id and name:
/// colour, helper name, subtitle and starting template. Persisted as one
/// JSON file. The topic list itself comes from Veetbot (`/v1/topics`);
/// `reconcile` keeps this file in step with it.
public final class TopicStore: @unchecked Sendable {
    private let fileURL: URL?
    public private(set) var topics: [Topic]

    static let palette = ["#157A43", "#B4531A", "#2347C8", "#7A2E6E", "#0E7C86", "#A77A00", "#0F0F0E"]
    static let helpers = ["Wren", "Juno", "Otis", "Mara", "Ezra", "Iris", "Theo", "Nell"]

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        // A first run starts with no topics; the person sets them up.
        if let fileURL, let data = try? Data(contentsOf: fileURL),
            let saved = try? JSONDecoder().decode([Topic].self, from: data)
        {
            topics = saved
        } else {
            topics = []
        }
    }

    /// A new topic's local details, with an id derived from its name that
    /// is unique among `taken` and the topics already here.
    public func draft(name: String, accentHex: String, agentName: String, taken: Set<String> = []) -> Topic {
        let base = Self.slug(name)
        var id = base.isEmpty ? "topic" : base
        var n = 2
        while topics.contains(where: { $0.id == id }) || taken.contains(id) || id == "core" {
            id = "\(base.isEmpty ? "topic" : base)-\(n)"
            n += 1
        }
        return Topic(id: id, name: name, icon: "square.grid.2x2", accentHex: accentHex, agentName: agentName, template: "blank")
    }

    @discardableResult
    public func add(_ topic: Topic) throws -> Topic {
        topics.removeAll { $0.id == topic.id }
        topics.append(topic)
        try persist()
        return topic
    }

    /// Makes the list match the server's: same topics, same names. Topics
    /// keep their order on this Mac; new ones go at the end with a colour
    /// and helper name of their own.
    public func reconcile(with server: [(id: String, name: String)]) throws {
        let order = Dictionary(uniqueKeysWithValues: topics.enumerated().map { ($1.id, $0) })
        let sorted = server.enumerated().sorted { a, b in
            (order[a.element.id] ?? Int.max, a.offset) < (order[b.element.id] ?? Int.max, b.offset)
        }.map(\.element)
        var next: [Topic] = []
        for (index, remote) in sorted.enumerated() {
            if var local = topics.first(where: { $0.id == remote.id }) {
                local.name = remote.name
                next.append(local)
            } else {
                let used = Set(next.map(\.agentName) + topics.map(\.agentName))
                let helper = Self.helpers.first { !used.contains($0) } ?? "Wren"
                next.append(Topic(
                    id: remote.id, name: remote.name, icon: "square.grid.2x2",
                    accentHex: Self.palette[index % Self.palette.count], agentName: helper, template: "blank"
                ))
            }
        }
        guard next != topics else { return }
        topics = next
        try persist()
    }

    public static func slug(_ name: String) -> String {
        let lowered = name.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(mapped).split(separator: "-").joined(separator: "-").prefix(60))
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(topics).write(to: fileURL, options: .atomic)
    }
}
