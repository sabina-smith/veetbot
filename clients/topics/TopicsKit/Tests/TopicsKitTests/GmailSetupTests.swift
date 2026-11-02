import Foundation
import XCTest
@testable import TopicsKit

/// Connecting Gmail from Topics: the accounts manifest Veetbot reads, the
/// `.env` lines that point at it, the bootstrap command's output, and the
/// LaunchAgents that let Topics restart Veetbot.
final class GmailAccountsManifestTests: XCTestCase {
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmail-\(UUID())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func account(_ id: String) -> GmailAccountsManifest.Account {
        .init(accountID: id, folder: "/Users/o/.config/veetbot/gmail/\(id)-1")
    }

    func testAccountIDsFollowVeetbotsPattern() {
        XCTAssertTrue(GmailAccountsManifest.isValidAccountID("personal"))
        XCTAssertTrue(GmailAccountsManifest.isValidAccountID("work_2"))
        XCTAssertFalse(GmailAccountsManifest.isValidAccountID("Work"))
        XCTAssertFalse(GmailAccountsManifest.isValidAccountID("2work"))
        XCTAssertFalse(GmailAccountsManifest.isValidAccountID("me@gmail.com"))
        XCTAssertFalse(GmailAccountsManifest.isValidAccountID(String(repeating: "a", count: 33)))
    }

    func testTheFirstAccountBecomesTheDefault() throws {
        var manifest = GmailAccountsManifest()
        try manifest.upsert(account("personal"))
        try manifest.upsert(account("work"))
        XCTAssertEqual(manifest.defaultAccount, "personal")
        XCTAssertEqual(manifest.accounts.map(\.accountID), ["personal", "work"])
    }

    func testReconnectingAnAccountReplacesItsFiles() throws {
        var manifest = GmailAccountsManifest()
        try manifest.upsert(account("personal"))
        try manifest.upsert(.init(accountID: "personal", folder: "/new"))
        XCTAssertEqual(manifest.accounts.count, 1)
        XCTAssertEqual(manifest.accounts[0].readCredentialFile, "/new/gmail-read.json")
    }

    func testAtMostEightAccounts() throws {
        var manifest = GmailAccountsManifest()
        for i in 0..<8 { try manifest.upsert(account("a\(i)")) }
        XCTAssertThrowsError(try manifest.upsert(account("a8")))
    }

    func testRelativePathsAndBadIDsAreRefused() {
        var manifest = GmailAccountsManifest()
        XCTAssertThrowsError(try manifest.upsert(.init(accountID: "personal", folder: "relative")))
        XCTAssertThrowsError(try manifest.upsert(.init(accountID: "Personal", folder: "/x")))
    }

    func testRemovingTheDefaultPromotesTheNextAndTheLastCannotGo() throws {
        var manifest = GmailAccountsManifest()
        try manifest.upsert(account("personal"))
        try manifest.upsert(account("work"))
        try manifest.remove("personal")
        XCTAssertEqual(manifest.defaultAccount, "work")
        XCTAssertThrowsError(try manifest.remove("work"))
    }

    func testMakeDefaultNeedsADeclaredAccount() throws {
        var manifest = GmailAccountsManifest()
        try manifest.upsert(account("personal"))
        try manifest.upsert(account("work"))
        try manifest.makeDefault("work")
        XCTAssertEqual(manifest.defaultAccount, "work")
        XCTAssertThrowsError(try manifest.makeDefault("other"))
    }

    func testSavesTheExactVeetbotShapeOwnerOnly() throws {
        var manifest = GmailAccountsManifest()
        try manifest.upsert(account("personal"))
        let url = directory.appendingPathComponent("gmail-accounts.json")
        try manifest.save(to: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "default_account", "accounts"])
        XCTAssertEqual(json["version"] as? Int, 1)
        let first = try XCTUnwrap((json["accounts"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            Set(first.keys), ["account_id", "read_credential_file", "write_credential_file", "send_credential_file"]
        )
        XCTAssertEqual(first["send_credential_file"] as? String, "/Users/o/.config/veetbot/gmail/personal-1/gmail-send.json")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try GmailAccountsManifest.load(from: url), manifest)
    }

    func testAMissingFileIsAnEmptyManifest() throws {
        XCTAssertEqual(try GmailAccountsManifest.load(from: directory.appendingPathComponent("none.json")), nil)
    }

    func testLoadingRefusesWhatVeetbotWouldRefuse() throws {
        let url = directory.appendingPathComponent("bad.json")
        for bad in [
            #"{"version":2,"default_account":"a","accounts":[]}"#,
            #"{"version":1,"default_account":"b","accounts":[{"account_id":"a","read_credential_file":"/r","write_credential_file":"/w","send_credential_file":"/s"}]}"#,
            #"{"version":1,"default_account":"a","accounts":[{"account_id":"a","read_credential_file":"/r","write_credential_file":"/w","send_credential_file":"/s","extra":1}]}"#,
            #"{"version":1,"default_account":"a","accounts":[],"extra":1}"#,
        ] {
            try Data(bad.utf8).write(to: url)
            XCTAssertThrowsError(try GmailAccountsManifest.load(from: url), bad)
        }
    }

    func testSavingRefusesASymlink() throws {
        let target = directory.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        var manifest = GmailAccountsManifest()
        try manifest.upsert(account("personal"))
        XCTAssertThrowsError(try manifest.save(to: link))
    }
}

final class VeetbotEnvFileTests: XCTestCase {
    let original = """
        # Veetbot
        AUTH_SCOPES=session.read,email.read
        AGENT_EMAIL_ENABLED=0
        GMAIL_READ_CREDENTIAL_FILE=/old/gmail-read.json
        GMAIL_WRITE_CREDENTIAL_FILE=/old/gmail-write.json
        GMAIL_SEND_CREDENTIAL_FILE=/old/gmail-send.json
        OPENAI_API_KEY=sk-secret

        """

    func testSwitchingToTheManifestTouchesOnlyGmailLines() {
        var env = VeetbotEnvFile(text: original)
        env.useAccountsManifest(at: "/Users/o/.config/veetbot/gmail-accounts.json")
        let lines = env.text.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("AGENT_EMAIL_ENABLED=1"))
        XCTAssertTrue(lines.contains("GMAIL_ACCOUNTS_FILE=/Users/o/.config/veetbot/gmail-accounts.json"))
        XCTAssertTrue(lines.contains("# Disabled by Topics (Gmail accounts manifest): GMAIL_READ_CREDENTIAL_FILE=/old/gmail-read.json"))
        XCTAssertNil(env.value(for: "GMAIL_READ_CREDENTIAL_FILE"))
        XCTAssertNil(env.value(for: "GMAIL_SEND_CREDENTIAL_FILE"))
        XCTAssertEqual(env.value(for: "OPENAI_API_KEY"), "sk-secret")
        XCTAssertEqual(env.value(for: "AUTH_SCOPES"), "session.read,email.read")
        XCTAssertTrue(env.text.hasPrefix("# Veetbot\n"))
        XCTAssertTrue(env.text.hasSuffix("\n"))
    }

    func testSwitchingTwiceIsStable() {
        var env = VeetbotEnvFile(text: original)
        env.useAccountsManifest(at: "/m.json")
        let once = env.text
        env.useAccountsManifest(at: "/m.json")
        XCTAssertEqual(env.text, once)
    }

    func testAnExistingManifestLineIsReplacedInPlace() {
        var env = VeetbotEnvFile(text: "A=1\nGMAIL_ACCOUNTS_FILE=/x\nB=2\n")
        env.useAccountsManifest(at: "/y")
        XCTAssertEqual(env.text, "A=1\nGMAIL_ACCOUNTS_FILE=/y\nB=2\nAGENT_EMAIL_ENABLED=1\n")
    }

    func testCommentedLinesAreNotValues() {
        let env = VeetbotEnvFile(text: "# GMAIL_ACCOUNTS_FILE=/x\n")
        XCTAssertNil(env.value(for: "GMAIL_ACCOUNTS_FILE"))
    }
}

final class BootstrapTranscriptTests: XCTestCase {
    let disclosure = """

        Veetbot Gmail data-use disclosure
        Scope: https://www.googleapis.com/auth/gmail.readonly
        Data accessed: messages.
        Privacy policy: https://example.test/privacy
        Type CONTINUE to open Google's consent screen for this scope:
        """

    func testTheDisclosureArrivesWithItsModeOnceThePromptAppears() {
        var transcript = BootstrapTranscript()
        let halves = [String(disclosure.prefix(40)), String(disclosure.dropFirst(40))]
        XCTAssertEqual(transcript.feed(halves[0]), [])
        let events = transcript.feed(halves[1])
        XCTAssertEqual(events.count, 1)
        guard case .disclosure(let mode, let text) = events[0] else { return XCTFail() }
        XCTAssertEqual(mode, "read")
        XCTAssertTrue(text.hasPrefix("Veetbot Gmail data-use disclosure\nScope:"))
        XCTAssertTrue(text.hasSuffix("Privacy policy: https://example.test/privacy"))
        XCTAssertFalse(text.contains("Type CONTINUE"))
    }

    func testSavedFilesAreReportedByMode() {
        var transcript = BootstrapTranscript()
        let events = transcript.feed(
            "read: /d/gmail-read.json (https://www.googleapis.com/auth/gmail.readonly)\n"
                + "write: /d/gmail-write.json (https://www.googleapis.com/auth/gmail.modify)\n"
        )
        XCTAssertEqual(events, [.saved(mode: "read", path: "/d/gmail-read.json"), .saved(mode: "write", path: "/d/gmail-write.json")])
    }

    func testAFallbackAuthorizationURLIsSurfaced() {
        var transcript = BootstrapTranscript()
        let events = transcript.feed("Open this authorization URL in a browser:\nhttps://accounts.google.com/o/oauth2/auth?x=1\n")
        XCTAssertEqual(events, [.openURL("https://accounts.google.com/o/oauth2/auth?x=1")])
    }

    func testOtherLinesAreDropped() {
        var transcript = BootstrapTranscript()
        XCTAssertEqual(transcript.feed("something unexpected\nrefresh_token=abc\n"), [])
    }
}

/// The OAuth client file is checked the way `gmail_mcp bootstrap` checks it,
/// so a wrong pick is caught in Settings instead of mid-ceremony.
final class GoogleOAuthClientFileTests: XCTestCase {
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("client-\(UUID())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ json: String, mode: Int = 0o600) throws -> URL {
        let url = directory.appendingPathComponent("client.json")
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    let desktop = #"{"installed":{"client_id":"1-abc.apps.googleusercontent.com","client_secret":"s"}}"#

    func testAnOwnerOnlyDesktopClientIsAccepted() throws {
        let url = try write(desktop)
        XCTAssertNil(GoogleOAuthClientFile.problem(at: url.path))
        XCTAssertEqual(GoogleOAuthClientFile.clientID(at: url.path), "1-abc.apps.googleusercontent.com")
    }

    func testAMissingFileIsReported() {
        XCTAssertEqual(GoogleOAuthClientFile.problem(at: directory.appendingPathComponent("none.json").path), "File not found.")
    }

    func testAFileOthersCanReadIsReported() throws {
        let url = try write(desktop, mode: 0o644)
        XCTAssertEqual(GoogleOAuthClientFile.problem(at: url.path), "Only you may read it: run chmod 600 on it.")
    }

    func testAWebClientIsReported() throws {
        let url = try write(#"{"web":{"client_id":"x","client_secret":"s"}}"#)
        XCTAssertEqual(GoogleOAuthClientFile.problem(at: url.path), "Not a Desktop app client from Google Cloud.")
    }

    func testARelativePathIsReported() {
        XCTAssertEqual(GoogleOAuthClientFile.problem(at: "client.json"), "Choose the file again; the path isn't absolute.")
    }

    func testASymlinkIsReported() throws {
        let target = try write(desktop)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(GoogleOAuthClientFile.problem(at: link.path), "Choose the file itself, not a link to it.")
    }
}

final class VeetbotServiceTests: XCTestCase {
    func testTheAPIAgentRunsTheHTTPSLauncherFromTheRepository() throws {
        let service = VeetbotService.api(
            uv: "/Users/o/.local/bin/uv", repository: "/Users/o/veetbot", home: "/Users/o"
        )
        XCTAssertEqual(service.label, "com.sabina.veetbot.api")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: service.plist(), format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["Label"] as? String, "com.sabina.veetbot.api")
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            ["/Users/o/.local/bin/uv", "run", "python", "/Users/o/.config/veetbot/serve_https_api.py"]
        )
        XCTAssertEqual(plist["WorkingDirectory"] as? String, "/Users/o/veetbot")
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, "/Users/o/Library/Logs/Veetbot/api.log")
        let path = try XCTUnwrap((plist["EnvironmentVariables"] as? [String: String])?["PATH"])
        XCTAssertTrue(path.hasPrefix("/Users/o/.local/bin:"))
    }

    func testTheWorkerAgentRunsAgentWorker() throws {
        let service = VeetbotService.worker(uv: "/u", repository: "/r", home: "/h")
        XCTAssertEqual(service.label, "com.sabina.veetbot.worker")
        XCTAssertEqual(service.arguments, ["/u", "run", "agent", "worker"])
        XCTAssertEqual(service.plistPath, "/h/Library/LaunchAgents/com.sabina.veetbot.worker.plist")
    }
}
