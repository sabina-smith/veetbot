import Foundation

/// How a schedule entry appears to topics other than its owner.
public enum ScheduleVisibility: String, Codable, Sendable {
    /// Others see the shared label.
    case labeled
    /// Others see only that the time is taken (the owner's choice).
    case busy
    /// Others do not see it at all.
    case hidden
}

public enum ScheduleKind: String, Codable, Sendable {
    case block, task, reminder
}

/// One claim on time. The shared store holds only the label and a pointer
/// (`privateRef`) into the owning topic's own records; the detail itself
/// never leaves the topic.
public struct ScheduleRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var topicID: String
    public var kind: ScheduleKind
    public var start: Date
    public var end: Date?
    public var sharedLabel: String
    public var privateRef: String?
    public var visibility: ScheduleVisibility

    public init(
        id: UUID = UUID(), topicID: String, kind: ScheduleKind, start: Date, end: Date? = nil,
        sharedLabel: String, privateRef: String? = nil, visibility: ScheduleVisibility = .labeled
    ) {
        self.id = id
        self.topicID = topicID
        self.kind = kind
        self.start = start
        self.end = end
        self.sharedLabel = sharedLabel
        self.privateRef = privateRef
        self.visibility = visibility
    }
}

/// What a viewer receives. `privateRef` is set only when the viewer owns
/// the entry.
public struct ScheduleEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    /// Nil only for an entry its owner chose to show as just "Busy".
    public let topicID: String?
    public let kind: ScheduleKind
    public let start: Date
    public let end: Date?
    public let label: String
    public let privateRef: String?
    public let isOwn: Bool
}

public enum ScheduleViewer: Sendable {
    /// Home: every topic's entries, as labels only.
    case home
    /// A topic's own board: its entries in full, others as labels.
    case topic(String)
}

/// The cross-topic plane: time blocks, tasks and reminders, persisted as one
/// JSON file. Every topic sees every entry by its label; only the owning
/// topic gets the pointer back into its own records.
public final class SharedSchedule: @unchecked Sendable {
    public static let busyLabel = "Busy"

    private let fileURL: URL?
    private let lock = NSLock()
    private var records: [ScheduleRecord]

    /// `fileURL` nil keeps the schedule in memory (tests).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder.schedule.decode([ScheduleRecord].self, from: data)
        {
            records = decoded
        } else {
            records = []
        }
    }

    /// Adds `record` on behalf of `owner`.
    @discardableResult
    public func add(_ record: ScheduleRecord, owner: Topic) throws -> ScheduleRecord {
        var stored = record
        stored.topicID = owner.id
        lock.lock()
        records.append(stored)
        let snapshot = records
        lock.unlock()
        try persist(snapshot)
        return stored
    }

    /// Removes an entry. Only its owner may remove it.
    public func remove(id: UUID, owner: Topic) throws {
        lock.lock()
        records.removeAll { $0.id == id && $0.topicID == owner.id }
        let snapshot = records
        lock.unlock()
        try persist(snapshot)
    }

    /// Entries overlapping `[from, to)`, redacted for `viewer`.
    /// `topics` supplies display names.
    public func entries(
        for viewer: ScheduleViewer, topics: [Topic], from: Date, to: Date
    ) -> [ScheduleEntry] {
        lock.lock()
        let snapshot = records
        lock.unlock()
        let byID = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0) })
        return snapshot
            .filter { $0.start < to && ($0.end ?? $0.start) >= from }
            .compactMap { Self.redact($0, for: viewer, owner: byID[$0.topicID]) }
            .sorted { $0.start < $1.start }
    }

    /// The one place a record becomes visible to someone. Exposed for tests.
    public static func redact(
        _ record: ScheduleRecord, for viewer: ScheduleViewer, owner: Topic?
    ) -> ScheduleEntry? {
        if case .topic(let viewerID) = viewer, viewerID == record.topicID {
            return ScheduleEntry(
                id: record.id, topicID: record.topicID, kind: record.kind, start: record.start,
                end: record.end, label: record.sharedLabel, privateRef: record.privateRef,
                isOwn: true
            )
        }
        switch record.visibility {
        case .hidden:
            return nil
        case .busy:
            return ScheduleEntry(
                id: record.id, topicID: nil, kind: record.kind, start: record.start,
                end: record.end, label: busyLabel, privateRef: nil, isOwn: false
            )
        case .labeled:
            return ScheduleEntry(
                id: record.id, topicID: record.topicID, kind: record.kind, start: record.start,
                end: record.end, label: "\(owner?.name ?? record.topicID): \(record.sharedLabel)",
                privateRef: nil, isOwn: false
            )
        }
    }

    private func persist(_ snapshot: [ScheduleRecord]) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder.schedule.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}

extension JSONEncoder {
    static let schedule: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let schedule: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
