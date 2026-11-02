import Foundation

/// Veetbot's Gmail accounts manifest (`GMAIL_ACCOUNTS_FILE`, ADR-0085): a
/// non-secret list of named accounts, each pointing at the three credential
/// files the bootstrap ceremony wrote. Validation mirrors Veetbot's loader
/// so a manifest Topics saves never stops Veetbot from starting.
public struct GmailAccountsManifest: Equatable, Sendable {
    public struct Account: Equatable, Sendable {
        public var accountID: String
        public var readCredentialFile: String
        public var writeCredentialFile: String
        public var sendCredentialFile: String

        public init(accountID: String, read: String, write: String, send: String) {
            self.accountID = accountID
            readCredentialFile = read
            writeCredentialFile = write
            sendCredentialFile = send
        }

        /// The three files `gmail_mcp bootstrap` writes into one folder.
        public init(accountID: String, folder: String) {
            let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
            self.init(
                accountID: accountID, read: "\(base)/gmail-read.json",
                write: "\(base)/gmail-write.json", send: "\(base)/gmail-send.json"
            )
        }

        var files: [String] { [readCredentialFile, writeCredentialFile, sendCredentialFile] }
    }

    public static let limit = 8
    public private(set) var defaultAccount = ""
    public private(set) var accounts: [Account] = []

    public init() {}

    public static func isValidAccountID(_ id: String) -> Bool {
        id.range(of: #"^[a-z][a-z0-9_]{0,31}$"#, options: .regularExpression) != nil
    }

    /// Adds the account, or replaces its files when it's already listed.
    /// The first account becomes the default.
    public mutating func upsert(_ account: Account) throws {
        try Self.check(account)
        if let index = accounts.firstIndex(where: { $0.accountID == account.accountID }) {
            accounts[index] = account
        } else {
            guard accounts.count < Self.limit else { throw ManifestError("Veetbot holds at most \(Self.limit) Gmail accounts.") }
            accounts.append(account)
        }
        if defaultAccount.isEmpty { defaultAccount = account.accountID }
    }

    public mutating func makeDefault(_ id: String) throws {
        guard accounts.contains(where: { $0.accountID == id }) else { throw ManifestError("\(id) isn't connected.") }
        defaultAccount = id
    }

    /// Removing the default promotes the next account; Veetbot needs one.
    public mutating func remove(_ id: String) throws {
        guard accounts.count > 1 else { throw ManifestError("Keep at least one Gmail account connected.") }
        accounts.removeAll { $0.accountID == id }
        if defaultAccount == id { defaultAccount = accounts[0].accountID }
    }

    /// nil when there is no manifest yet.
    public static func load(from url: URL) throws -> GmailAccountsManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(json.keys) == ["version", "default_account", "accounts"],
            json["version"] as? Int == 1,
            let defaultAccount = json["default_account"] as? String,
            let rows = json["accounts"] as? [[String: Any]]
        else { throw ManifestError("The Gmail accounts file isn't one Veetbot accepts.") }
        var manifest = GmailAccountsManifest()
        for row in rows {
            guard Set(row.keys) == ["account_id", "read_credential_file", "write_credential_file", "send_credential_file"],
                let id = row["account_id"] as? String, let read = row["read_credential_file"] as? String,
                let write = row["write_credential_file"] as? String, let send = row["send_credential_file"] as? String,
                !manifest.accounts.contains(where: { $0.accountID == id })
            else { throw ManifestError("The Gmail accounts file has an account Veetbot can't read.") }
            try manifest.upsert(Account(accountID: id, read: read, write: write, send: send))
        }
        guard !manifest.accounts.isEmpty else { throw ManifestError("The Gmail accounts file lists no accounts.") }
        try manifest.makeDefault(defaultAccount)
        return manifest
    }

    /// Writes the manifest owner-only, replacing it atomically. A symlink is
    /// refused because Veetbot refuses one.
    public func save(to url: URL) throws {
        guard !accounts.isEmpty else { throw ManifestError("Connect a Gmail account first.") }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw ManifestError("The Gmail accounts file is a symlink; Veetbot won't read it.")
        }
        let body: [String: Any] = [
            "version": 1,
            "default_account": defaultAccount,
            "accounts": accounts.map {
                [
                    "account_id": $0.accountID, "read_credential_file": $0.readCredentialFile,
                    "write_credential_file": $0.writeCredentialFile, "send_credential_file": $0.sendCredentialFile,
                ]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID())")
        guard FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ManifestError("Couldn't write the Gmail accounts file.")
        }
        guard rename(staging.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: staging)
            throw ManifestError("Couldn't replace the Gmail accounts file.")
        }
    }

    private static func check(_ account: Account) throws {
        guard isValidAccountID(account.accountID) else {
            throw ManifestError("Use a short lowercase name like personal or work.")
        }
        guard account.files.allSatisfy({ $0.hasPrefix("/") }) else {
            throw ManifestError("Credential files need absolute paths.")
        }
    }
}

public struct ManifestError: LocalizedError, Equatable {
    public let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Line-level edits to Veetbot's `.env`. Only the Gmail lines change; every
/// other line, secrets included, is kept byte for byte.
public struct VeetbotEnvFile: Equatable {
    public private(set) var text: String

    static let legacyKeys = ["GMAIL_READ_CREDENTIAL_FILE", "GMAIL_WRITE_CREDENTIAL_FILE", "GMAIL_SEND_CREDENTIAL_FILE"]
    static let disabledPrefix = "# Disabled by Topics (Gmail accounts manifest): "

    public init(text: String) {
        self.text = text
    }

    public func value(for key: String) -> String? {
        lines.lazy.compactMap { Self.assignment($0) }.first { $0.key == key }?.value
    }

    /// Veetbot accepts either the three legacy credential variables or the
    /// manifest, never both, so the legacy lines are commented out.
    public mutating func useAccountsManifest(at path: String) {
        var lines = self.lines
        for (index, line) in lines.enumerated() {
            if let (key, _) = Self.assignment(line), Self.legacyKeys.contains(key) {
                lines[index] = Self.disabledPrefix + line
            }
        }
        Self.set("GMAIL_ACCOUNTS_FILE", to: path, in: &lines)
        Self.set("AGENT_EMAIL_ENABLED", to: "1", in: &lines)
        text = lines.joined(separator: "\n") + "\n"
    }

    private var lines: [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func set(_ key: String, to value: String, in lines: inout [String]) {
        if let index = lines.firstIndex(where: { assignment($0)?.key == key }) {
            lines[index] = "\(key)=\(value)"
        } else {
            lines.append("\(key)=\(value)")
        }
    }

    private static func assignment(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        return (key, String(trimmed[trimmed.index(after: equals)...]))
    }
}

/// Reads `python -m gmail_mcp bootstrap` output as it streams. Only the
/// data-use disclosure, a fallback authorization URL and the saved file
/// paths are surfaced; every other line is dropped.
public struct BootstrapTranscript {
    public enum Event: Equatable {
        /// The disclosure for one mode; the owner must type CONTINUE to go on.
        case disclosure(mode: String, text: String)
        case openURL(String)
        case saved(mode: String, path: String)
    }

    static let heading = "Veetbot Gmail data-use disclosure"
    static let prompt = "Type CONTINUE to open Google's consent screen for this scope:"
    static let fallback = "Open this authorization URL in a browser:"
    static let modes = [
        "https://www.googleapis.com/auth/gmail.readonly": "read",
        "https://www.googleapis.com/auth/gmail.modify": "write",
        "https://www.googleapis.com/auth/gmail.send": "send",
    ]

    private var buffer = ""
    private var disclosure: [String]?
    private var expectingURL = false

    public init() {}

    public mutating func feed(_ chunk: String) -> [Event] {
        buffer += chunk
        var events: [Event] = []
        while true {
            // The prompt has no newline: input() waits on it.
            if disclosure != nil, let range = buffer.range(of: Self.prompt) {
                let before = buffer[..<range.lowerBound]
                if !before.isEmpty { disclosure?.append(contentsOf: before.components(separatedBy: "\n").filter { !$0.isEmpty }) }
                buffer = String(buffer[range.upperBound...])
                if buffer.hasPrefix(" ") { buffer.removeFirst() }
                let lines = disclosure ?? []
                disclosure = nil
                let scope = lines.first { $0.hasPrefix("Scope: ") }.map { String($0.dropFirst(7)) }
                events.append(.disclosure(mode: scope.flatMap { Self.modes[$0] } ?? "unknown", text: lines.joined(separator: "\n")))
                continue
            }
            guard let newline = buffer.firstIndex(of: "\n") else { break }
            let line = String(buffer[..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            if let event = handle(line) { events.append(event) }
        }
        return events
    }

    private mutating func handle(_ line: String) -> Event? {
        if line == Self.heading {
            disclosure = [line]
            return nil
        }
        if disclosure != nil {
            if !line.isEmpty { disclosure?.append(line) }
            return nil
        }
        if expectingURL {
            expectingURL = false
            return line.hasPrefix("https://") ? .openURL(line) : nil
        }
        if line == Self.fallback {
            expectingURL = true
            return nil
        }
        for mode in ["read", "write", "send"] where line.hasPrefix("\(mode): /") {
            let rest = line.dropFirst(mode.count + 2)
            guard let open = rest.range(of: " (https://", options: .backwards) else { return nil }
            return .saved(mode: mode, path: String(rest[..<open.lowerBound]))
        }
        return nil
    }
}

/// A per-user LaunchAgent that runs one Veetbot process from the repository,
/// so Topics can restart it with `launchctl kickstart -k` after Gmail changes.
public struct VeetbotService: Equatable, Sendable {
    public let label: String
    public let arguments: [String]
    public let repository: String
    public let home: String
    let logName: String

    public static func api(uv: String, repository: String, home: String) -> VeetbotService {
        VeetbotService(
            label: "com.sabina.veetbot.api",
            arguments: [uv, "run", "python", "\(home)/.config/veetbot/serve_https_api.py"],
            repository: repository, home: home, logName: "api"
        )
    }

    public static func worker(uv: String, repository: String, home: String) -> VeetbotService {
        VeetbotService(
            label: "com.sabina.veetbot.worker", arguments: [uv, "run", "agent", "worker"],
            repository: repository, home: home, logName: "worker"
        )
    }

    public var plistPath: String { "\(home)/Library/LaunchAgents/\(label).plist" }
    public var logPath: String { "\(home)/Library/Logs/Veetbot/\(logName).log" }

    public func plist() throws -> Data {
        let uvDirectory = (arguments[0] as NSString).deletingLastPathComponent
        let path = [uvDirectory, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let body: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            // Veetbot reads `.env` from its working directory.
            "WorkingDirectory": repository,
            "EnvironmentVariables": ["PATH": path.joined(separator: ":"), "HOME": home, "PYTHONUNBUFFERED": "1"],
            "RunAtLoad": true,
            // Restart after a crash, but not in a tight loop on a bad config.
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        return try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
    }
}

/// The Google OAuth client file `gmail_mcp bootstrap --client-file` reads.
/// Checked the way that command checks it: an absolute, owner-only regular
/// file holding a Desktop app (`installed`) client.
public enum GoogleOAuthClientFile {
    /// Why the command would refuse the file, or nil when it would accept it.
    public static func problem(at path: String) -> String? {
        guard path.hasPrefix("/") else { return "Choose the file again; the path isn't absolute." }
        let manager = FileManager.default
        if (try? manager.destinationOfSymbolicLink(atPath: path)) != nil {
            return "Choose the file itself, not a link to it."
        }
        guard let attributes = try? manager.attributesOfItem(atPath: path) else { return "File not found." }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return "File not found." }
        if let mode = attributes[.posixPermissions] as? Int, mode & 0o077 != 0 {
            return "Only you may read it: run chmod 600 on it."
        }
        guard clientID(at: path) != nil else { return "Not a Desktop app client from Google Cloud." }
        return nil
    }

    /// The `installed` client's id, which names the Google Cloud project it belongs to.
    public static func clientID(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let installed = json["installed"] as? [String: Any],
            let id = installed["client_id"] as? String, !id.isEmpty,
            let secret = installed["client_secret"] as? String, !secret.isEmpty
        else { return nil }
        return id
    }
}
