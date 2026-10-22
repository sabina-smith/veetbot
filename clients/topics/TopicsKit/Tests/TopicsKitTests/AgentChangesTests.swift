import Foundation
import XCTest
@testable import TopicsKit

final class AgentChangeParserTests: XCTestCase {
    func testParsesEveryBlockKind() throws {
        let reply = """
        I added a watering module.

        <<<file modules/watering.ts>>>
        export default function render(root: HTMLElement) {}
        <<<end>>>
        <<<edit board.json>>>
        <<<find>>>
        "modules": [
        <<<replace>>>
        "modules": [ {"id": "watering", "title": "Watering"},
        <<<end>>>
        <<<delete modules/old.ts>>>
        <<<sql>>>
        CREATE TABLE watering (id INTEGER PRIMARY KEY);
        <<<end>>>
        <<<summary>>>
        Added a watering schedule.
        <<<end>>>
        """
        let changes = try XCTUnwrap(try AgentChangeParser.parse(reply))
        XCTAssertEqual(changes.summary, "Added a watering schedule.")
        XCTAssertEqual(changes.ops.count, 4)
        XCTAssertEqual(changes.ops[0], .writeFile(path: "modules/watering.ts", content: "export default function render(root: HTMLElement) {}\n"))
        XCTAssertEqual(changes.ops[2], .deleteFile(path: "modules/old.ts"))
        XCTAssertEqual(AgentChangeParser.strippingBlocks(reply), "I added a watering module.")
    }

    func testFileContentMayContainMarkdownFences() throws {
        let reply = "<<<file notes/howto.md>>>\n```ts\ncode\n```\n<<<end>>>"
        let changes = try XCTUnwrap(try AgentChangeParser.parse(reply))
        XCTAssertEqual(changes.ops, [.writeFile(path: "notes/howto.md", content: "```ts\ncode\n```\n")])
    }

    func testAReplyWithoutBlocksHasNoChanges() throws {
        XCTAssertNil(try AgentChangeParser.parse("Just chatting about tomatoes."))
    }

    func testRefusesPathsOutsideTheAllowlist() {
        for path in ["../escape.ts", "/etc/passwd", "modules/../../x.ts", "data.sqlite", ".git/config", "modules/Upper.ts", "schema.sql"] {
            XCTAssertThrowsError(try AgentChangeParser.validatedPath(path), path)
        }
        for path in ["HANDOFF.md", "board.json", "modules/tool-shed.ts", "log/2026-10-21.md"] {
            XCTAssertNoThrow(try AgentChangeParser.validatedPath(path), path)
        }
    }

    func testRefusesToDeleteTheNotesOrBoard() {
        XCTAssertThrowsError(try AgentChangeParser.parse("<<<delete HANDOFF.md>>>"))
    }

    func testUnterminatedBlockIsAnError() {
        XCTAssertThrowsError(try AgentChangeParser.parse("<<<file modules/a.ts>>>\nexport default 1"))
    }
}

final class AgentChangeApplierTests: XCTestCase {
    var base: URL!
    var template: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("topics-\(UUID())")
        template = base.appendingPathComponent("template")
        try FileManager.default.createDirectory(at: template.appendingPathComponent("modules"), withIntermediateDirectories: true)
        try "# Agent\n".write(to: template.appendingPathComponent("AGENT.md"), atomically: true, encoding: .utf8)
        try "# Handoff\n".write(to: template.appendingPathComponent("HANDOFF.md"), atomically: true, encoding: .utf8)
        try #"{"columns": 3, "modules": [{"id": "todo", "title": "To-do", "span": 1, "height": 300}]}"#
            .write(to: template.appendingPathComponent("board.json"), atomically: true, encoding: .utf8)
        try "export default function render(root: HTMLElement): void {}\n"
            .write(to: template.appendingPathComponent("modules/todo.ts"), atomically: true, encoding: .utf8)
        try "CREATE TABLE tasks (id INTEGER PRIMARY KEY, title TEXT NOT NULL);"
            .write(to: template.appendingPathComponent("schema.sql"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func workspace() throws -> TopicWorkspace {
        try TopicWorkspace(topic: .garden, base: base.appendingPathComponent("workspaces"), template: template)
    }

    func testAppliesFilesAndSQLAndCommits() throws {
        let ws = try workspace()
        let applier = AgentChangeApplier(builder: try ModuleBuilder())
        let changes = AgentChangeSet(summary: "Added a task", ops: [
            .writeFile(path: "HANDOFF.md", content: "# Handoff\nDid a thing.\n"),
            .sql("INSERT INTO tasks (title) VALUES ('Plant garlic');"),
        ])
        let applied = try applier.apply(changes, to: ws, author: "Fern")
        XCTAssertNotNil(applied.commit)
        XCTAssertEqual(try ws.history().first?.author, "Fern")
        XCTAssertEqual(try ws.database.query("SELECT COUNT(*) AS n FROM tasks").first?["n"], .integer(1))
    }

    func testABrokenModuleRollsBackEverything() throws {
        let ws = try workspace()
        let applier = AgentChangeApplier(builder: try ModuleBuilder())
        let changes = AgentChangeSet(summary: "Broken", ops: [
            .writeFile(path: "HANDOFF.md", content: "changed\n"),
            .writeFile(path: "modules/todo.ts", content: "export default function (( {\n"),
            .sql("INSERT INTO tasks (title) VALUES ('should not land');"),
        ])
        XCTAssertThrowsError(try applier.apply(changes, to: ws, author: "Fern"))
        XCTAssertEqual(ws.read("HANDOFF.md"), "# Handoff\n")
        XCTAssertEqual(try ws.database.query("SELECT COUNT(*) AS n FROM tasks").first?["n"], .integer(0))
        XCTAssertEqual(try ws.history().count, 1)
    }

    func testFailingSQLRollsBackFilesToo() throws {
        let ws = try workspace()
        let applier = AgentChangeApplier(builder: try ModuleBuilder())
        let changes = AgentChangeSet(summary: "Bad SQL", ops: [
            .writeFile(path: "HANDOFF.md", content: "changed\n"),
            .sql("INSERT INTO tasks (title) VALUES ('first'); INSERT INTO nowhere VALUES (1);"),
        ])
        XCTAssertThrowsError(try applier.apply(changes, to: ws, author: "Fern"))
        XCTAssertEqual(ws.read("HANDOFF.md"), "# Handoff\n")
        XCTAssertEqual(try ws.database.query("SELECT COUNT(*) AS n FROM tasks").first?["n"], .integer(0))
    }

    func testBoardMustReferenceExistingModules() throws {
        let ws = try workspace()
        let applier = AgentChangeApplier(builder: try ModuleBuilder())
        let changes = AgentChangeSet(summary: "Dangling", ops: [
            .writeFile(path: "board.json", content: #"{"columns": 3, "modules": [{"id": "ghost", "title": "Ghost", "span": 1, "height": 300}]}"#),
        ])
        XCTAssertThrowsError(try applier.apply(changes, to: ws, author: "Fern"))
        XCTAssertEqual(try ws.board().modules.map(\.id), ["todo"])
    }

    func testEditMustMatchExactlyOnce() throws {
        let ws = try workspace()
        let applier = AgentChangeApplier(builder: try ModuleBuilder())
        let changes = AgentChangeSet(summary: "Ambiguous", ops: [
            .editFile(path: "modules/todo.ts", find: "not in the file", replace: "x"),
        ])
        XCTAssertThrowsError(try applier.apply(changes, to: ws, author: "Fern"))
    }
}

final class BoardKindsTests: XCTestCase {
    func testBuiltInCardsNeedNoModuleFile() throws {
        let board = Board(modules: [
            BoardModule(id: "todo", title: "To do", span: 6, kind: "list"),
            BoardModule(id: "people", title: "People", span: 6, kind: "table", columns: [CardColumn(key: "title", label: "Who")]),
        ])
        XCTAssertNoThrow(try board.validate(existingModules: []))
    }

    func testUnknownKindsAndMissingCustomFilesAreRefused() {
        XCTAssertThrowsError(try Board(modules: [BoardModule(id: "x", title: "X", kind: "gallery")]).validate(existingModules: []))
        XCTAssertThrowsError(try Board(modules: [BoardModule(id: "x", title: "X", kind: "custom")]).validate(existingModules: []))
        XCTAssertNoThrow(try Board(modules: [BoardModule(id: "x", title: "X", kind: "custom")]).validate(existingModules: ["x"]))
    }

    func testDecodesBoardJSONWithKinds() throws {
        let json = #"{"columns": 12, "modules": [{"id": "seeds", "title": "Seeds", "span": 4, "kind": "table", "columns": [{"key": "title", "label": "Seed"}, {"key": "sow", "label": "Sow"}]}]}"#
        let board = try JSONDecoder().decode(Board.self, from: Data(json.utf8))
        XCTAssertEqual(board.modules[0].columns?.map(\.key), ["title", "sow"])
        XCTAssertFalse(board.modules[0].isCustom)
    }
}
