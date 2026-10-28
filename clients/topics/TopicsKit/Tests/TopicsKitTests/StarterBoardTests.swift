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

    func testABoardWithoutASummaryOrAboutsStillDecodes() throws {
        let board = try JSONDecoder().decode(Board.self, from: Data(#"{"columns": 12, "modules": [{"id": "a", "title": "A", "span": 6, "kind": "list"}]}"#.utf8))
        XCTAssertNil(board.summary)
        XCTAssertNil(board.modules[0].about)
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
        let board = try workspace.board()
        // People and the topic's description are background, not cards.
        XCTAssertEqual(board.modules.map(\.kind), ["list", "schedule"])
        XCTAssertEqual(board.summary, "Juniper, our collie")
        XCTAssertTrue(board.modules.allSatisfy { $0.about?.isEmpty == false })
        XCTAssertNoThrow(try board.validate(existingModules: []))
        let rows = try workspace.database.query("SELECT card, title FROM items ORDER BY id")
        XCTAssertEqual(rows.map { $0["card"] }, [.text("on-your-mind"), .text("on-your-mind")])
        XCTAssertEqual(workspace.read("notes/people.md"), "# People\n\n- Maya (Neighbour)\n")
        XCTAssertEqual(try workspace.history().first?.subject, "Starter board")
    }
}
