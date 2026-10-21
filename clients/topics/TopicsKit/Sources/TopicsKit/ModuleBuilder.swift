import Foundation

/// Turns a workspace's TypeScript modules into JavaScript the board can load.
///
/// Modules use erasable TypeScript only (types, interfaces, `import type`),
/// so building is type stripping, done by Node's built-in
/// `module.stripTypeScriptTypes`. Locally that means the owner's Node; in the
/// cloud version the topic's machine does this step instead.
public struct ModuleBuilder: Sendable {
    public let nodePath: String

    public init(nodePath: String? = nil) throws {
        if let nodePath { self.nodePath = nodePath; return }
        let candidates = [
            ProcessInfo.processInfo.environment["TOPICS_NODE"],
            "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node",
        ].compactMap { $0 }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw WorkspaceError.invalid("Node.js 22.6 or newer is needed to build modules; set TOPICS_NODE")
        }
        self.nodePath = found
    }

    /// Strips types from every `sources` entry. Returns JavaScript keyed by
    /// module id, or throws naming the first module that fails.
    public func build(_ sources: [String: String]) throws -> [String: String] {
        let input = try JSONSerialization.data(withJSONObject: sources)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = ["--no-warnings", "-e", Self.script]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WorkspaceError.build(String(decoding: errors, as: UTF8.self))
        }
        guard let result = try JSONSerialization.jsonObject(with: output) as? [String: [String: String]]
        else { throw WorkspaceError.build("unreadable builder output") }
        if let failure = result["errors"], let (id, message) = failure.sorted(by: { $0.key < $1.key }).first {
            throw WorkspaceError.build("modules/\(id).ts: \(message)")
        }
        return result["built"] ?? [:]
    }

    static let script = #"""
    const { stripTypeScriptTypes } = require("node:module");
    let raw = "";
    process.stdin.on("data", (c) => (raw += c));
    process.stdin.on("end", () => {
      const sources = JSON.parse(raw);
      const built = {}, errors = {};
      for (const [id, code] of Object.entries(sources)) {
        try {
          const js = stripTypeScriptTypes(code, { mode: "strip" });
          if (!/export\s+default\s/.test(js)) throw new Error("a module must `export default` its render function");
          built[id] = js;
        } catch (e) {
          errors[id] = String((e && e.message) || e);
        }
      }
      process.stdout.write(JSON.stringify({ built, errors }));
    });
    """#
}
