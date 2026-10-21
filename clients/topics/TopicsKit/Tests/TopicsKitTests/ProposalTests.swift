import Foundation
import XCTest
@testable import TopicsKit

final class ProposalTests: XCTestCase {
    var database: TopicDatabase!
    var path: String!

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("proposals-\(UUID()).sqlite").path
        database = try TopicDatabase(path: path)
        try ProposalStore.ensureSchema(database)
        try database.execScript("""
        CREATE TABLE shopping (id INTEGER PRIMARY KEY, item TEXT, status TEXT, source TEXT, price REAL);
        INSERT INTO shopping (id, item, status) VALUES (2, 'Compost', 'researching');
        """)
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    func insertProposal(ref: String = "shopping/2", options: String) throws -> Int64 {
        try database.query(
            "INSERT INTO proposals (ref, kind, title, options, recommended) VALUES (?, 'purchase', 'Compost', ?, 0)",
            [.text(ref), .text(options)]
        )
        return database.lastInsertRowID
    }

    let twoOptions = #"""
    [{"label": "Black Kow, 3 bags", "price": 24, "url": "https://example.com/a",
      "set": {"source": "Lowe's", "price": 24, "status": "in_cart"}},
     {"label": "Cedar Grove", "price": 30, "set": {"source": "Home Depot", "price": 30, "status": "in_cart"}}]
    """#

    func testAcceptingAnOptionWritesItIntoTheRow() throws {
        let id = try insertProposal(options: twoOptions)
        try ProposalStore.accept(database, id: id, option: 1, note: "closer to me")
        let row = try XCTUnwrap(database.query("SELECT * FROM shopping WHERE id = 2").first)
        XCTAssertEqual(row["source"], .text("Home Depot"))
        XCTAssertEqual(row["status"], .text("in_cart"))
        let proposal = try XCTUnwrap(ProposalStore.get(database, id: id))
        XCTAssertEqual(proposal.status, .accepted)
        XCTAssertEqual(proposal.chosen, 1)
        XCTAssertEqual(proposal.ownerNote, "closer to me")
        XCTAssertTrue(try ProposalStore.list(database).isEmpty)
    }

    func testDecodesOptions() throws {
        let id = try insertProposal(options: twoOptions)
        let proposal = try XCTUnwrap(ProposalStore.get(database, id: id))
        XCTAssertEqual(proposal.options.map(\.label), ["Black Kow, 3 bags", "Cedar Grove"])
        XCTAssertEqual(proposal.options[0].price, 24)
        XCTAssertEqual(proposal.recommended, 0)
        XCTAssertEqual(proposal.kind, .purchase)
    }

    func testAnUnknownColumnChangesNothing() throws {
        let id = try insertProposal(options: #"[{"label": "x", "set": {"status": "in_cart", "nope": 1}}]"#)
        XCTAssertThrowsError(try ProposalStore.accept(database, id: id, option: 0, note: nil))
        XCTAssertEqual(try database.query("SELECT status FROM shopping").first?["status"], .text("researching"))
        XCTAssertEqual(try ProposalStore.get(database, id: id)?.status, .open)
    }

    func testCannotTargetTheProposalsTableOrBadRefs() throws {
        for ref in ["proposals/1", "shopping", "shopping/x", "x; DROP TABLE shopping/1", "missing/1"] {
            let id = try insertProposal(ref: ref, options: #"[{"label": "x", "set": {"status": "accepted"}}]"#)
            XCTAssertThrowsError(try ProposalStore.accept(database, id: id, option: 0, note: nil), ref)
        }
        XCTAssertEqual(try database.query("SELECT COUNT(*) AS n FROM shopping").first?["n"], .integer(1))
    }

    func testAMissingRowRollsBack() throws {
        let id = try insertProposal(ref: "shopping/99", options: #"[{"label": "x", "set": {"status": "in_cart"}}]"#)
        XCTAssertThrowsError(try ProposalStore.accept(database, id: id, option: 0, note: nil))
        XCTAssertEqual(try ProposalStore.get(database, id: id)?.status, .open)
    }

    func testAResolvedProposalCannotBeResolvedAgain() throws {
        let id = try insertProposal(options: twoOptions)
        try ProposalStore.decline(database, id: id, note: "not now")
        XCTAssertThrowsError(try ProposalStore.accept(database, id: id, option: 0, note: nil))
        XCTAssertEqual(try ProposalStore.resolved(database, since: nil).map(\.status), [.declined])
    }

    func testAQuestionCanBeAnsweredWithoutAnOption() throws {
        try database.query("INSERT INTO proposals (kind, title) VALUES ('question', 'Which store?')")
        let id = database.lastInsertRowID
        try ProposalStore.accept(database, id: id, option: nil, note: "Lowe's on Main St")
        XCTAssertEqual(try ProposalStore.get(database, id: id)?.ownerNote, "Lowe's on Main St")
    }
}
