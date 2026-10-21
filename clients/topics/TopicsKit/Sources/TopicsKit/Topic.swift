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

    public init(
        id: String, name: String, icon: String, accentHex: String,
        agentName: String, sealed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.accentHex = accentHex
        self.agentName = agentName
        self.sealed = sealed
    }
}

extension Topic {
    public static let garden = Topic(
        id: "garden", name: "Garden", icon: "leaf", accentHex: "#3F8F4E", agentName: "Fern"
    )
}
