import Foundation
import XCTest
@testable import TopicsKit

final class TopicStoreTests: XCTestCase {
    func testStartsWithNoTopics() {
        XCTAssertEqual(TopicStore(fileURL: nil).topics, [])
    }

    func testDraftsAUniqueSlug() throws {
        let store = TopicStore(fileURL: nil)
        let first = store.draft(name: "Kids’ School", accentHex: "#0E7C86", agentName: "Wren")
        try store.add(first)
        let second = store.draft(name: "Kids' school", accentHex: "#0E7C86", agentName: "Juno", taken: ["kids-school-2"])
        XCTAssertEqual(first.id, "kids-school")
        XCTAssertEqual(second.id, "kids-school-3")
        XCTAssertEqual(store.draft(name: "Core", accentHex: "#000000", agentName: "X").id, "core-2")
    }

    func testReconcileFollowsTheServer() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("topics-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = TopicStore(fileURL: url)
        try store.add(.garden)
        try store.reconcile(with: [(id: "pets", name: "Pets"), (id: "garden", name: "The Garden")])
        XCTAssertEqual(store.topics.map(\.id), ["garden", "pets"])
        XCTAssertEqual(store.topics[0].name, "The Garden")
        XCTAssertEqual(store.topics[0].agentName, "Fern", "local details survive")
        XCTAssertEqual(store.topics[1].template, "blank")
        XCTAssertFalse(["Fern"].contains(store.topics[1].agentName))
        XCTAssertEqual(TopicStore(fileURL: url).topics.map(\.id), ["garden", "pets"])
    }
}
