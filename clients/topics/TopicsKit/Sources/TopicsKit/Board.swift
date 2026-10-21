import Foundation

/// `board.json`: which modules a topic's board shows, in order. The agent
/// edits this file to add, remove or rearrange modules.
public struct Board: Codable, Hashable, Sendable {
    public var columns: Int
    public var modules: [BoardModule]

    public init(columns: Int = 3, modules: [BoardModule]) {
        self.columns = columns
        self.modules = modules
    }
}

public struct BoardModule: Codable, Hashable, Identifiable, Sendable {
    /// Matches `modules/<id>.ts`.
    public var id: String
    public var title: String
    /// How many grid columns the card spans.
    public var span: Int
    /// The card's content height in points.
    public var height: Int

    public init(id: String, title: String, span: Int = 1, height: Int = 320) {
        self.id = id
        self.title = title
        self.span = span
        self.height = height
    }
}

extension Board {
    /// Checks the rules a board must satisfy before it is committed.
    public func validate(existingModules: Set<String>) throws {
        guard (1...4).contains(columns) else {
            throw WorkspaceError.invalid("board.json: columns must be 1 to 4")
        }
        var seen = Set<String>()
        for module in modules {
            guard seen.insert(module.id).inserted else {
                throw WorkspaceError.invalid("board.json: module \(module.id) appears twice")
            }
            guard existingModules.contains(module.id) else {
                throw WorkspaceError.invalid("board.json: modules/\(module.id).ts does not exist")
            }
            guard (1...columns).contains(module.span) else {
                throw WorkspaceError.invalid("board.json: \(module.id) span must be 1 to \(columns)")
            }
            guard (120...1200).contains(module.height) else {
                throw WorkspaceError.invalid("board.json: \(module.id) height must be 120 to 1200")
            }
        }
    }
}
