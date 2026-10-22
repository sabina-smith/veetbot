import Foundation
import XCTest
@testable import TopicsKit

final class TopicStoreTests: XCTestCase {
    func testSeedsTheDefaultTopicsWithHealthPrivate() {
        let store = TopicStore(fileURL: nil)
        XCTAssertEqual(store.topics.map(\.id), ["garden", "household", "work", "health"])
        XCTAssertEqual(store.topics.last?.sealed, true)
    }

    func testAddingGivesAUniqueSlugAndPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("topics-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TopicStore(fileURL: url)
        let first = try store.add(name: "Kids’ School", accentHex: "#0E7C86", agentName: "Wren", sealed: false)
        let second = try store.add(name: "Kids' school", accentHex: "#0E7C86", agentName: "Juno", sealed: true)
        XCTAssertEqual(first.id, "kids-school")
        XCTAssertEqual(second.id, "kids-school-2")
        XCTAssertEqual(first.template, "blank")
        XCTAssertEqual(TopicStore(fileURL: url).topics.count, 6)
    }
}
