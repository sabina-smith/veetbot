import Foundation

/// `board.json`: which modules a topic's board shows, in order. The agent
/// edits this file to add, remove or rearrange modules.
public struct Board: Codable, Hashable, Sendable {
    public var columns: Int
    /// One sentence on what the topic is, shown under the board's title.
    public var summary: String?
    public var modules: [BoardModule]

    public init(columns: Int = 12, summary: String? = nil, modules: [BoardModule]) {
        self.columns = columns
        self.summary = summary
        self.modules = modules
    }
}

public struct BoardModule: Codable, Hashable, Identifiable, Sendable {
    /// The card's id. For a custom card it matches `modules/<id>.ts`; for a
    /// built-in kind it is the `card` value of its rows in `items`.
    public var id: String
    public var title: String
    /// How many of the board's columns (12 by default) the card spans.
    public var span: Int
    /// Unused on the 12-column board, where cards size to their content.
    public var height: Int?
    /// A built-in card kind (see `CardKinds`), or nil / "custom" for a
    /// TypeScript module.
    public var kind: String?
    /// For `table` cards: the columns to show.
    public var columns: [CardColumn]?
    /// What the card is for, shown in the board's About panel.
    public var about: String?

    public init(
        id: String, title: String, span: Int = 4, height: Int? = nil, kind: String? = nil, columns: [CardColumn]? = nil,
        about: String? = nil
    ) {
        self.id = id
        self.title = title
        self.span = span
        self.height = height
        self.kind = kind
        self.columns = columns
        self.about = about
    }

    public var isCustom: Bool { kind == nil || kind == "custom" }
}

public struct CardColumn: Codable, Hashable, Sendable {
    /// `title`, `detail`, or a key in the row's `data` object.
    public var key: String
    public var label: String

    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}

/// Cards the app ships ready-made. The agent adds one with a line in
/// board.json and rows in `items`, instead of writing a module.
public enum CardKinds {
    public static let all: Set<String> = ["list", "table", "recurring", "shopping", "notes", "schedule"]

    /// One table for every built-in card's rows, keyed by card id.
    public static let schema = """
    CREATE TABLE IF NOT EXISTS items (
      id INTEGER PRIMARY KEY,
      card TEXT NOT NULL,
      title TEXT NOT NULL,
      detail TEXT,
      done INTEGER NOT NULL DEFAULT 0,
      due_on TEXT,
      assignee TEXT NOT NULL DEFAULT 'me' CHECK (assignee IN ('me', 'agent')),
      status TEXT,
      qty TEXT,
      source TEXT,
      url TEXT,
      price REAL,
      every_days INTEGER,
      last_done TEXT,
      data TEXT,
      position INTEGER,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS items_card ON items (card);
    """
}

extension Board {
    /// Checks the rules a board must satisfy before it is committed.
    public func validate(existingModules: Set<String>) throws {
        guard (1...12).contains(columns) else {
            throw WorkspaceError.invalid("board.json: columns must be 1 to 12")
        }
        var seen = Set<String>()
        for module in modules {
            guard seen.insert(module.id).inserted else {
                throw WorkspaceError.invalid("board.json: module \(module.id) appears twice")
            }
            if module.isCustom {
                guard existingModules.contains(module.id) else {
                    throw WorkspaceError.invalid("board.json: modules/\(module.id).ts does not exist")
                }
            } else if let kind = module.kind, !CardKinds.all.contains(kind) {
                throw WorkspaceError.invalid("board.json: \(module.id) has unknown kind \(kind)")
            }
            guard (1...columns).contains(module.span) else {
                throw WorkspaceError.invalid("board.json: \(module.id) span must be 1 to \(columns)")
            }
        }
    }
}
