import Foundation
import XCTest
@testable import TopicsKit

final class StarterBoardTests: XCTestCase {
    func testSplitsAnswersIntoRows() {
        XCTAssertEqual(StarterBoard.split("vet visits, monthly heartworm pill and ordering food; finding a sitter."),
                       ["Vet visits", "Monthly heartworm pill", "Ordering food", "Finding a sitter"])
        XCTAssertEqual(StarterBoard.split("nobody"), [])
        XCTAssertEqual(StarterBoard.split("  "), [])
    }

    func testReadsRolesInParentheses() {
        XCTAssertEqual(StarterBoard.nameAndRole("Dr. Patel (vet)").0, "Dr. Patel")
        XCTAssertEqual(StarterBoard.nameAndRole("Dr. Patel (vet)").1, "Vet")
        XCTAssertNil(StarterBoard.nameAndRole("Maya").1)
    }

    func testAppliesABoardOfReadyMadeCardsWithRows() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("starter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let topic = Topic(id: "pets", name: "Pets", icon: "pawprint", accentHex: "#0E7C86", agentName: "Wren")
        let workspace = try TopicWorkspace(topic: topic, base: base, template: nil)
        try workspace.write(TopicWorkspace.boardFile, #"{"columns": 12, "modules": []}"#)
        try StarterBoard.apply(to: workspace, answers: .init(about: "Juniper, our collie", onYourMind: "vet visits, food", helpers: "Maya (neighbour)"))
        XCTAssertEqual(try workspace.board().modules.map(\.kind), ["list", "notes", "table", "schedule"])
        XCTAssertNoThrow(try workspace.board().validate(existingModules: []))
        let rows = try workspace.database.query("SELECT card, title, detail FROM items ORDER BY id")
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.last?["detail"], .text("Neighbour"))
        XCTAssertEqual(try workspace.history().first?.subject, "Starter board")
    }
}
