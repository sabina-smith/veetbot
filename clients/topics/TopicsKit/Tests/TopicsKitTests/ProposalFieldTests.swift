import Foundation
import XCTest
@testable import TopicsKit

/// Questions answered with pickers instead of typed text: each field's
/// answer is checked against its type and written into the row.
final class ProposalFieldTests: XCTestCase {
    var database: TopicDatabase!
    var path: String!

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("fields-\(UUID()).sqlite").path
        database = try TopicDatabase(path: path)
        try ProposalStore.ensureSchema(database)
        try database.execScript(CardKinds.schema)
        try database.execScript("INSERT INTO items (id, card, title) VALUES (3, 'on-your-mind', 'Costa Rica trip')")
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    func insertQuestion(_ fields: String, ref: String = "items/3") throws -> Int64 {
        try database.query(
            "INSERT INTO proposals (ref, kind, title, fields) VALUES (?, 'question', 'Costa Rica', ?)",
            [.text(ref), .text(fields)]
        )
        return database.lastInsertRowID
    }

    let tripFields = #"""
    [{"key": "dates", "label": "Travel dates", "type": "daterange", "column": "due_on", "end_column": "data.until",
      "value": {"start": "2026-12-19", "end": "2026-12-27"}, "hint": "From your calendar"},
     {"key": "area", "label": "Where", "type": "pick", "options": ["Guanacaste", "Nosara", "Santa Teresa"], "other": true,
      "column": "data.area"},
     {"key": "nights", "label": "Date nights", "type": "number", "min": 0, "max": 7, "column": "data.date_nights"},
     {"key": "likes", "label": "Things you both like", "type": "multi", "options": ["Surf", "Run", "Hike"],
      "column": "detail"},
     {"key": "note", "label": "Anything else", "type": "text", "optional": true}]
    """#

    func testDecodesFieldsWithTheirSuggestedValues() throws {
        let id = try insertQuestion(tripFields)
        let proposal = try XCTUnwrap(ProposalStore.get(database, id: id))
        XCTAssertEqual(proposal.fields.map(\.key), ["dates", "area", "nights", "likes", "note"])
        XCTAssertEqual(proposal.fields[0].type, .daterange)
        XCTAssertEqual(proposal.fields[0].value, .range(start: "2026-12-19", end: "2026-12-27"))
        XCTAssertEqual(proposal.fields[0].hint, "From your calendar")
        XCTAssertEqual(proposal.fields[1].options, ["Guanacaste", "Nosara", "Santa Teresa"])
        XCTAssertTrue(proposal.fields[1].allowsOther)
        XCTAssertEqual(proposal.fields[2].max, 7)
        XCTAssertTrue(proposal.fields[4].optional)
    }

    func testAnswersAreWrittenIntoTheRowAndKept() throws {
        let id = try insertQuestion(tripFields)
        try ProposalStore.accept(database, id: id, option: nil, note: nil, answers: [
            "dates": .range(start: "2026-12-20", end: "2026-12-28"),
            "area": .text("Playa Hermosa"),
            "nights": .number(2),
            "likes": .list(["Surf", "Run"]),
        ])
        let row = try XCTUnwrap(database.query("""
            SELECT due_on, detail, json_extract(data, '$.until') AS until, json_extract(data, '$.area') AS area,
                   json_extract(data, '$.date_nights') AS nights FROM items WHERE id = 3
            """).first)
        XCTAssertEqual(row["due_on"], .text("2026-12-20"))
        XCTAssertEqual(row["until"], .text("2026-12-28"))
        XCTAssertEqual(row["area"], .text("Playa Hermosa"))
        XCTAssertEqual(row["nights"], .integer(2))
        XCTAssertEqual(row["detail"], .text("Surf, Run"))
        let proposal = try XCTUnwrap(ProposalStore.get(database, id: id))
        XCTAssertEqual(proposal.status, .accepted)
        XCTAssertEqual(proposal.answers["area"], .text("Playa Hermosa"))
        XCTAssertEqual(proposal.answers["dates"], .range(start: "2026-12-20", end: "2026-12-28"))
        XCTAssertNil(proposal.answers["note"])
    }

    func testAnswersThatDontFitTheFieldChangeNothing() throws {
        let valid: [String: Proposal.Answer] = [
            "dates": .range(start: "2026-12-20", end: "2026-12-28"), "area": .text("Nosara"),
            "nights": .number(2), "likes": .list(["Surf"]),
        ]
        let bad: [(String, Proposal.Answer?)] = [
            ("dates", .range(start: "next week", end: "2026-12-28")),
            ("dates", .range(start: "2026-12-28", end: "2026-12-20")),
            ("nights", .number(9)),
            ("nights", .text("two")),
            ("likes", .list(["Skydive"])),
            ("area", nil),
        ]
        for (key, answer) in bad {
            let id = try insertQuestion(tripFields)
            var answers = valid
            answers[key] = answer
            XCTAssertThrowsError(try ProposalStore.accept(database, id: id, option: nil, note: nil, answers: answers), key)
            XCTAssertEqual(try ProposalStore.get(database, id: id)?.status, .open, key)
        }
        XCTAssertEqual(try database.query("SELECT due_on FROM items WHERE id = 3").first?["due_on"], .null)
    }

    func testAPickWithoutOtherOnlyTakesItsOptions() throws {
        let id = try insertQuestion(#"[{"key": "size", "label": "Dress size", "type": "pick", "options": ["2", "4", "6"]}]"#)
        XCTAssertThrowsError(try ProposalStore.accept(database, id: id, option: nil, note: nil, answers: ["size": .text("S")]))
        try ProposalStore.accept(database, id: id, option: nil, note: nil, answers: ["size": .text("4")])
        XCTAssertEqual(try ProposalStore.get(database, id: id)?.answers["size"], .text("4"))
    }

    func testAFieldCannotWriteToAMissingColumn() throws {
        let id = try insertQuestion(#"[{"key": "d", "label": "Date", "type": "date", "column": "nope"}]"#)
        XCTAssertThrowsError(try ProposalStore.accept(database, id: id, option: nil, note: nil, answers: ["d": .text("2026-11-05")]))
        XCTAssertEqual(try ProposalStore.get(database, id: id)?.status, .open)
    }

    func testAConnectFieldRecordsTheOutcome() throws {
        let id = try insertQuestion(#"[{"key": "cal", "label": "Calendar", "type": "connect", "integration": "calendar"}]"#, ref: "")
        let field = try XCTUnwrap(ProposalStore.get(database, id: id)?.fields.first)
        XCTAssertEqual(field.integration, "calendar")
        try ProposalStore.accept(database, id: id, option: nil, note: nil, answers: ["cal": .text("connected")])
        XCTAssertEqual(try ProposalStore.get(database, id: id)?.answers["cal"], .text("connected"))
    }

    func testAChosenSlotCanWriteIntoTheRowsData() throws {
        try database.query(
            "INSERT INTO proposals (ref, kind, title, options) VALUES ('items/3', 'choice', 'Nails', ?)",
            [.text(#"[{"label": "Thu Nov 5, 6:30 pm", "set": {"due_on": "2026-11-05", "data.time": "18:30", "data.place": "Olive & June"}}]"#)]
        )
        try ProposalStore.accept(database, id: database.lastInsertRowID, option: 0, note: nil)
        let row = try XCTUnwrap(database.query("""
            SELECT due_on, json_extract(data, '$.time') AS time, json_extract(data, '$.place') AS place FROM items WHERE id = 3
            """).first)
        XCTAssertEqual(row["due_on"], .text("2026-11-05"))
        XCTAssertEqual(row["time"], .text("18:30"))
        XCTAssertEqual(row["place"], .text("Olive & June"))
    }

    func testASignInFieldOffersTheLinkOrSigningIn() throws {
        let fields = #"[{"key": "how", "label": "Booking", "type": "signin", "url": "https://resy.com/cities/sf/lolo", "name": "Resy"}]"#
        let id = try insertQuestion(fields)
        let field = try XCTUnwrap(ProposalStore.get(database, id: id)?.fields.first)
        XCTAssertEqual(field.type, .signin)
        XCTAssertEqual(field.url, "https://resy.com/cities/sf/lolo")
        XCTAssertEqual(field.siteName, "Resy")
        XCTAssertThrowsError(try ProposalStore.accept(database, id: id, option: nil, note: nil, answers: ["how": .text("sure")]))
        try ProposalStore.accept(database, id: id, option: nil, note: nil, answers: ["how": .text("link")])
        for answer in ["signed_in", "unavailable"] {
            let other = try insertQuestion(fields)
            XCTAssertNoThrow(try ProposalStore.accept(database, id: other, option: nil, note: nil, answers: ["how": .text(answer)]))
        }
    }

    func testAnswersDescribeThemselvesForTheAgent() {
        XCTAssertEqual(Proposal.Answer.range(start: "2026-12-20", end: "2026-12-28").description, "2026-12-20 to 2026-12-28")
        XCTAssertEqual(Proposal.Answer.list(["Surf", "Run"]).description, "Surf, Run")
        XCTAssertEqual(Proposal.Answer.number(2).description, "2")
        XCTAssertEqual(Proposal.Answer.number(2.5).description, "2.5")
    }

    func testAnswersFromThePage() {
        XCTAssertEqual(Proposal.Answer(json: "2026-11-05"), .text("2026-11-05"))
        XCTAssertEqual(Proposal.Answer(json: NSNumber(value: 3)), .number(3))
        XCTAssertEqual(Proposal.Answer(json: ["Surf", "Run"]), .list(["Surf", "Run"]))
        XCTAssertEqual(Proposal.Answer(json: ["start": "2026-12-20", "end": "2026-12-28"]), .range(start: "2026-12-20", end: "2026-12-28"))
        XCTAssertNil(Proposal.Answer(json: NSNull()))
    }

    func testOlderWorkspacesGainTheNewColumns() throws {
        let oldPath = FileManager.default.temporaryDirectory.appendingPathComponent("old-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: oldPath) }
        let old = try TopicDatabase(path: oldPath)
        try old.execScript("""
            CREATE TABLE proposals (id INTEGER PRIMARY KEY, ref TEXT, kind TEXT NOT NULL DEFAULT 'choice', title TEXT NOT NULL,
              summary TEXT, options TEXT NOT NULL DEFAULT '[]', recommended INTEGER, status TEXT NOT NULL DEFAULT 'open',
              chosen INTEGER, owner_note TEXT, created_at TEXT NOT NULL DEFAULT (datetime('now')), resolved_at TEXT);
            INSERT INTO proposals (kind, title) VALUES ('question', 'Which store?');
            """)
        try ProposalStore.ensureSchema(old)
        try ProposalStore.ensureSchema(old)
        let columns = try old.query("SELECT name FROM pragma_table_info('proposals')").compactMap { row -> String? in
            if case .text(let name)? = row["name"] { return name }
            return nil
        }
        XCTAssertTrue(columns.contains("fields"))
        XCTAssertTrue(columns.contains("answers"))
        XCTAssertEqual(try ProposalStore.list(old).first?.fields, [])
    }
}
