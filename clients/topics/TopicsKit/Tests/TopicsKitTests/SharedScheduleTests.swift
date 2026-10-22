import Foundation
import XCTest
@testable import TopicsKit

final class SharedScheduleTests: XCTestCase {
    let garden = Topic.garden
    let work = Topic(id: "work", name: "Work", icon: "briefcase", accentHex: "#335599", agentName: "Wren")
    let health = Topic(id: "health", name: "Health", icon: "heart", accentHex: "#AA3355", agentName: "Sage", sealed: true)
    var topics: [Topic] { [garden, work, health] }

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var window: (Date, Date) { (start.addingTimeInterval(-86_400), start.addingTimeInterval(86_400)) }

    func testOtherTopicsSeeOnlyTheSharedLabel() throws {
        let schedule = SharedSchedule(fileURL: nil)
        try schedule.add(
            ScheduleRecord(topicID: "garden", kind: .block, start: start, sharedLabel: "Planting", privateRef: "tasks/7"),
            owner: garden
        )
        let seenByWork = schedule.entries(for: .topic("work"), topics: topics, from: window.0, to: window.1)
        XCTAssertEqual(seenByWork.map(\.label), ["Garden: Planting"])
        XCTAssertNil(seenByWork[0].privateRef)
        XCTAssertFalse(seenByWork[0].isOwn)

        let seenByHome = schedule.entries(for: .home, topics: topics, from: window.0, to: window.1)
        XCTAssertNil(seenByHome[0].privateRef)
    }

    func testOwnerSeesItsPrivateReference() throws {
        let schedule = SharedSchedule(fileURL: nil)
        try schedule.add(
            ScheduleRecord(topicID: "garden", kind: .task, start: start, sharedLabel: "Buy compost", privateRef: "shopping/3"),
            owner: garden
        )
        let own = schedule.entries(for: .topic("garden"), topics: topics, from: window.0, to: window.1)
        XCTAssertEqual(own[0].privateRef, "shopping/3")
        XCTAssertEqual(own[0].label, "Buy compost")
        XCTAssertTrue(own[0].isOwn)
    }

    func testSealedTopicIsNeutralizedOnTheWayIn() throws {
        let schedule = SharedSchedule(fileURL: nil)
        let stored = try schedule.add(
            ScheduleRecord(topicID: "health", kind: .block, start: start, sharedLabel: "Therapy with Dr. Lee", privateRef: "visits/2"),
            owner: health
        )
        XCTAssertEqual(stored.sharedLabel, SharedSchedule.busyLabel)
        XCTAssertEqual(stored.visibility, .busy)
    }

    func testSealedTopicShowsAsBusyWithNoOwner() throws {
        let schedule = SharedSchedule(fileURL: nil)
        try schedule.add(
            ScheduleRecord(topicID: "health", kind: .block, start: start, sharedLabel: "Therapy", privateRef: "visits/2"),
            owner: health
        )
        for viewer in [ScheduleViewer.home, .topic("garden")] {
            let entries = schedule.entries(for: viewer, topics: topics, from: window.0, to: window.1)
            XCTAssertEqual(entries.map(\.label), ["Busy"])
            XCTAssertNil(entries[0].topicID, "a sealed entry must not reveal its topic")
            XCTAssertNil(entries[0].privateRef)
        }
    }

    func testRedactionFailsClosedForARecordWrittenBeforeSealing() {
        // A record stored while the topic was unsealed, read after sealing.
        let record = ScheduleRecord(topicID: "health", kind: .block, start: start, sharedLabel: "Therapy", privateRef: "visits/2")
        let entry = SharedSchedule.redact(record, for: .home, owner: health)
        XCTAssertEqual(entry?.label, "Busy")
        let unknownOwner = SharedSchedule.redact(record, for: .home, owner: nil)
        XCTAssertEqual(unknownOwner?.label, "Busy")
    }

    func testHiddenEntriesAreInvisibleToOthers() throws {
        let schedule = SharedSchedule(fileURL: nil)
        try schedule.add(
            ScheduleRecord(topicID: "work", kind: .block, start: start, sharedLabel: "Offsite prep", visibility: .hidden),
            owner: work
        )
        XCTAssertTrue(schedule.entries(for: .home, topics: topics, from: window.0, to: window.1).isEmpty)
        XCTAssertEqual(schedule.entries(for: .topic("work"), topics: topics, from: window.0, to: window.1).count, 1)
    }

    func testOnlyTheOwnerCanRemove() throws {
        let schedule = SharedSchedule(fileURL: nil)
        let stored = try schedule.add(
            ScheduleRecord(topicID: "garden", kind: .block, start: start, sharedLabel: "Planting"), owner: garden
        )
        try schedule.remove(id: stored.id, owner: work)
        XCTAssertEqual(schedule.entries(for: .home, topics: topics, from: window.0, to: window.1).count, 1)
        try schedule.remove(id: stored.id, owner: garden)
        XCTAssertTrue(schedule.entries(for: .home, topics: topics, from: window.0, to: window.1).isEmpty)
    }

    func testPersistsAcrossInstances() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("schedule-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try SharedSchedule(fileURL: url).add(
            ScheduleRecord(topicID: "garden", kind: .reminder, start: start, sharedLabel: "Water seedlings"), owner: garden
        )
        XCTAssertEqual(SharedSchedule(fileURL: url).entries(for: .home, topics: topics, from: window.0, to: window.1).count, 1)
    }
}
