import Foundation
import SQLite3

/// A SQL value crossing the module bridge.
public enum DBValue: Codable, Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .real(value) }
        else if let value = try? container.decode(Bool.self) { self = .integer(value ? 1 : 0) }
        else { self = .text(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .integer(let value): try container.encode(value)
        case .real(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        }
    }

    /// Converts a value that came out of `JSONSerialization` or a WebKit
    /// message body.
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .integer(number.boolValue ? 1 : 0) }
            else if CFNumberIsFloatType(number) {
                let double = number.doubleValue
                self = double.rounded() == double && abs(double) < 9e15 ? .integer(Int64(double)) : .real(double)
            } else { self = .integer(number.int64Value) }
        case let string as String: self = .text(string)
        default: self = .text(String(describing: value!))
        }
    }

    /// A Foundation value suitable for a WebKit reply.
    public var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .integer(let value): return NSNumber(value: value)
        case .real(let value): return NSNumber(value: value)
        case .text(let value): return value
        }
    }
}

public typealias DBRow = [String: DBValue]

public struct DBError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// The topic's light database: one SQLite file per topic workspace. Because
/// each topic has its own file, a module can run any SQL it likes and still
/// only ever reach its own topic's data.
public final class TopicDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        guard sqlite3_open_v2(
            path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close(handle)
            throw DBError(message: message)
        }
        try execScript("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")
    }

    deinit { sqlite3_close(handle) }

    /// Runs a multi-statement script without parameters.
    public func execScript(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "SQL failed"
            sqlite3_free(error)
            throw DBError(message: message)
        }
    }

    /// Runs one statement and returns its rows.
    @discardableResult
    public func query(_ sql: String, _ params: [DBValue] = []) throws -> [DBRow] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        var tail: UnsafePointer<CChar>?
        let rows: [DBRow] = try sql.withCString { cSQL in
            guard sqlite3_prepare_v2(handle, cSQL, -1, &statement, &tail) == SQLITE_OK else {
                throw DBError(message: lastError)
            }
            defer { sqlite3_finalize(statement) }
            if let tail, String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ";"))).isEmpty == false {
                throw DBError(message: "query runs one statement; use execScript for several")
            }
            for (index, param) in params.enumerated() {
                let position = Int32(index + 1)
                switch param {
                case .null: sqlite3_bind_null(statement, position)
                case .integer(let value): sqlite3_bind_int64(statement, position, value)
                case .real(let value): sqlite3_bind_double(statement, position, value)
                case .text(let value):
                    sqlite3_bind_text(statement, position, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            }
            var result: [DBRow] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw DBError(message: lastError) }
                var row: DBRow = [:]
                for column in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, column))
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
                    case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                    case SQLITE_NULL: row[name] = .null
                    default: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                    }
                }
                result.append(row)
            }
            return result
        }
        return rows
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    /// Rows changed through this connection since it opened.
    public var totalChanges: Int { Int(sqlite3_total_changes(handle)) }

    /// Runs `body` in a transaction, rolling back if it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execScript("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execScript("COMMIT")
            return value
        } catch {
            try? execScript("ROLLBACK")
            throw error
        }
    }

    /// Each table's `CREATE` statement and row count, for the agent's
    /// check-in context.
    public func schemaSummary(sampleRows: Int = 15) throws -> String {
        let tables = try query(
            "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        var lines: [String] = []
        for table in tables {
            guard case .text(let name) = table["name"], case .text(let sql) = table["sql"] else { continue }
            let count = try query("SELECT COUNT(*) AS n FROM \"\(name)\"").first?["n"]
            lines.append("\(sql);")
            if case .integer(let n) = count {
                lines.append("-- \(name): \(n) rows")
            }
            let sample = try query("SELECT * FROM \"\(name)\" LIMIT \(sampleRows)")
            for row in sample {
                let rendered = row.keys.sorted().map { key -> String in
                    switch row[key]! {
                    case .null: return "\(key)=null"
                    case .integer(let v): return "\(key)=\(v)"
                    case .real(let v): return "\(key)=\(v)"
                    case .text(let v): return "\(key)=\(v.debugDescription)"
                    }
                }.joined(separator: ", ")
                lines.append("--   \(rendered)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }
}
