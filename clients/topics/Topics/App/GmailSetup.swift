import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers
import TopicsKit
import VeetbotCore

/// Connects a Gmail account to the local Veetbot from Topics. It runs
/// Veetbot's own bootstrap ceremony (three Google consents, each behind the
/// data-use disclosure and a typed CONTINUE that is passed through
/// untouched), records the account in the Gmail accounts manifest, points
/// Veetbot's `.env` at it, restarts Veetbot through its LaunchAgents, and
/// waits for the account to appear in `GET /v1/email/accounts`.
@MainActor
final class GmailSetup: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        /// The disclosure for one consent; the owner types CONTINUE or cancels.
        case disclosure(mode: String, text: String)
        /// Google's consent page is open in the browser.
        case consenting(mode: String)
        /// Veetbot is running by hand; these processes stop before the LaunchAgents take over.
        case confirmTakeover([String])
        case restarting
        case verifying
        case connected(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var presented = false
    @Published private(set) var accounts: [EmailAccountView] = []
    @Published private(set) var manifest: GmailAccountsManifest?
    @Published var repositoryPath: String {
        didSet { UserDefaults.standard.set(repositoryPath, forKey: Self.repositoryKey) }
    }
    @Published var clientFilePath: String {
        didSet { UserDefaults.standard.set(clientFilePath, forKey: Self.clientFileKey) }
    }
    /// A fallback URL when the browser didn't open by itself.
    @Published private(set) var authorizationURL: URL?

    private let connection: VeetbotConnection
    private var process: Process?
    private var input: FileHandle?
    private var transcript = BootstrapTranscript()
    private var saved: [String: String] = [:]
    private var errorTail = ""
    private var pending: (accountID: String, folder: URL)?
    private var onConnected: (() -> Void)?

    private static let repositoryKey = "veetbotRepositoryPath"
    private static let clientFileKey = "gmailOAuthClientFile"
    nonisolated static let home = FileManager.default.homeDirectoryForCurrentUser.path
    nonisolated static var configDirectory: URL { URL(fileURLWithPath: home).appendingPathComponent(".config/veetbot") }
    nonisolated static var manifestURL: URL { configDirectory.appendingPathComponent("gmail-accounts.json") }

    init(connection: VeetbotConnection) {
        self.connection = connection
        repositoryPath = UserDefaults.standard.string(forKey: Self.repositoryKey)
            ?? "\(Self.home)/Documents/CodingProjects/athena/veetbot"
        clientFilePath = UserDefaults.standard.string(forKey: Self.clientFileKey)
            ?? Self.configDirectory.appendingPathComponent("client-secret.json").path
        manifest = try? GmailAccountsManifest.load(from: Self.manifestURL)
    }

    var isBusy: Bool {
        switch phase {
        case .idle, .connected, .failed: false
        default: true
        }
    }

    /// Opens the connect sheet; `then` runs once the account is live.
    func present(then: (() -> Void)? = nil) {
        onConnected = then
        if !isBusy { phase = .idle }
        presented = true
    }

    // MARK: - Settings

    /// Picked from a file panel rather than typed, so the path is always a
    /// real file and the choice is saved the moment it's made.
    func chooseClientFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Desktop app client JSON you downloaded from Google Cloud."
        panel.allowedContentTypes = [.json]
        panel.directoryURL = URL(fileURLWithPath: (clientFilePath as NSString).deletingLastPathComponent)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        clientFilePath = url.path
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.message = "Choose the veetbot folder (the one with .env)."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: repositoryPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        repositoryPath = url.path
    }

    var clientFileProblem: String? { GoogleOAuthClientFile.problem(at: clientFilePath) }

    var repositoryProblem: String? {
        FileManager.default.fileExists(atPath: "\(repositoryPath)/.env") ? nil : "No .env in this folder."
    }

    // MARK: - Bootstrap

    func connect(accountID: String) {
        guard !isBusy else { return }
        if let problem = clientFileProblem {
            phase = .failed("Google OAuth client file: \(problem)")
            return
        }
        guard GmailAccountsManifest.isValidAccountID(accountID) else {
            phase = .failed("Use a short lowercase name like personal or work.")
            return
        }
        guard let uv = Self.uvPath() else {
            phase = .failed("Couldn't find uv. Install it, or check ~/.local/bin/uv.")
            return
        }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let folder = Self.configDirectory.appendingPathComponent("gmail/\(accountID)-\(stamp)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            phase = .failed("Couldn't create \(folder.path): \(error.localizedDescription)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uv)
        process.arguments = [
            "run", "--project", repositoryPath, "python", "-m", "gmail_mcp", "bootstrap",
            "--client-file", clientFilePath, "--output-directory", folder.path, "--account-id", accountID,
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: repositoryPath)
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PATH"] = Self.searchPath
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            Task { @MainActor in self?.received(text) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            Task { @MainActor in self?.errorTail = String(((self?.errorTail ?? "") + text).suffix(2000)) }
        }
        process.terminationHandler = { [weak self] finished in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            Task { @MainActor in
                // Let the last stdout chunk land before deciding.
                try? await Task.sleep(for: .milliseconds(200))
                self?.bootstrapFinished(status: status)
            }
        }

        transcript = BootstrapTranscript()
        saved = [:]
        errorTail = ""
        authorizationURL = nil
        pending = (accountID, folder)
        input = stdin.fileHandleForWriting
        self.process = process
        phase = .starting
        do {
            try process.run()
        } catch {
            phase = .failed("Couldn't start the Gmail setup: \(error.localizedDescription)")
        }
    }

    /// Sends exactly what the owner typed; the command itself decides
    /// whether it is CONTINUE.
    func answerDisclosure(_ typed: String) {
        guard case .disclosure(let mode, _) = phase else { return }
        input?.write(Data((typed + "\n").utf8))
        phase = .consenting(mode: mode)
    }

    func cancel() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        phase = .idle
        presented = false
    }

    private func received(_ text: String) {
        for event in transcript.feed(text) {
            switch event {
            case .disclosure(let mode, let text):
                authorizationURL = nil
                phase = .disclosure(mode: mode, text: text)
            case .openURL(let url):
                authorizationURL = URL(string: url)
            case .saved(let mode, let path):
                saved[mode] = path
            }
        }
    }

    private func bootstrapFinished(status: Int32) {
        process = nil
        input = nil
        guard phase != .idle else { return }
        guard status == 0, let pending, saved.count == 3 else {
            let last = errorTail.split(separator: "\n").last.map(String.init)
            phase = .failed(last ?? "The Gmail setup stopped before finishing.")
            return
        }
        do {
            var manifest = (try GmailAccountsManifest.load(from: Self.manifestURL)) ?? GmailAccountsManifest()
            try manifest.upsert(.init(accountID: pending.accountID, folder: pending.folder.path))
            try apply(manifest)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        Task { await restartAndVerify(expecting: pending.accountID) }
    }

    // MARK: - Manifest and .env

    func makeDefault(_ id: String) {
        mutateManifest { try $0.makeDefault(id) }
    }

    func remove(_ id: String) {
        mutateManifest { try $0.remove(id) }
    }

    private func mutateManifest(_ change: (inout GmailAccountsManifest) throws -> Void) {
        guard !isBusy, var manifest else { return }
        do {
            try change(&manifest)
            try apply(manifest)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        Task { await restartAndVerify(expecting: nil) }
    }

    private func apply(_ manifest: GmailAccountsManifest) throws {
        try manifest.save(to: Self.manifestURL)
        self.manifest = manifest
        let envURL = URL(fileURLWithPath: repositoryPath).appendingPathComponent(".env")
        let original = (try? String(contentsOf: envURL, encoding: .utf8)) ?? ""
        var env = VeetbotEnvFile(text: original)
        env.useAccountsManifest(at: Self.manifestURL.path)
        guard env.text != original else { return }
        let backup = envURL.appendingPathExtension("topics-backup")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: envURL, to: backup)
        let mode = (try? FileManager.default.attributesOfItem(atPath: envURL.path)[.posixPermissions]) as? Int ?? 0o600
        try env.text.write(to: envURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: envURL.path)
    }

    // MARK: - Restart

    private var services: [VeetbotService] {
        guard let uv = Self.uvPath() else { return [] }
        return [
            .api(uv: uv, repository: repositoryPath, home: Self.home),
            .worker(uv: uv, repository: repositoryPath, home: Self.home),
        ]
    }

    private var expected: String?

    private func restartAndVerify(expecting accountID: String?) async {
        expected = accountID
        let services = services
        guard !services.isEmpty else {
            phase = .failed("Couldn't find uv to run Veetbot.")
            return
        }
        if !services.allSatisfy(Self.isLoaded) {
            let manual = Self.manualProcesses()
            if !manual.isEmpty {
                phase = .confirmTakeover(manual.map(\.command))
                return
            }
        }
        await restart()
    }

    /// The owner agreed: stop the hand-started processes, then hand over to launchd.
    func confirmTakeover() {
        guard case .confirmTakeover = phase else { return }
        for process in Self.manualProcesses() { kill(process.pid, SIGTERM) }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await restart()
        }
    }

    private func restart() async {
        phase = .restarting
        do {
            for service in services { try Self.install(service) }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        await verify()
    }

    private func verify() async {
        phase = .verifying
        for _ in 0..<40 {
            try? await Task.sleep(for: .seconds(3))
            guard let page = try? await connection.client().emailAccounts() else { continue }
            accounts = page.items
            if let expected, !page.items.contains(where: { $0.id == expected }) { continue }
            phase = .connected(expected ?? manifest?.defaultAccount ?? "")
            onConnected?()
            onConnected = nil
            return
        }
        phase = .failed("Veetbot didn't come back with the account. See ~/Library/Logs/Veetbot/api.log.")
    }

    func refreshAccounts() async {
        manifest = try? GmailAccountsManifest.load(from: Self.manifestURL)
        accounts = (try? await connection.client().emailAccounts().items) ?? []
    }

    // MARK: - launchd

    private nonisolated static var domain: String { "gui/\(getuid())" }

    private nonisolated static func isLoaded(_ service: VeetbotService) -> Bool {
        run("/bin/launchctl", ["print", "\(domain)/\(service.label)"]).status == 0
    }

    /// Writes the LaunchAgent and (re)starts it: a changed or unloaded agent
    /// is booted in fresh; an unchanged loaded one is kickstarted.
    private nonisolated static func install(_ service: VeetbotService) throws {
        let plist = try service.plist()
        let current = FileManager.default.contents(atPath: service.plistPath)
        try FileManager.default.createDirectory(
            atPath: (service.logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        if current == plist, isLoaded(service) {
            let result = run("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(service.label)"])
            guard result.status == 0 else { throw SetupError("Couldn't restart \(service.label): \(result.output)") }
            return
        }
        if isLoaded(service) { _ = run("/bin/launchctl", ["bootout", "\(domain)/\(service.label)"]) }
        try FileManager.default.createDirectory(
            atPath: (service.plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try plist.write(to: URL(fileURLWithPath: service.plistPath), options: .atomic)
        let result = run("/bin/launchctl", ["bootstrap", domain, service.plistPath])
        guard result.status == 0 else { throw SetupError("Couldn't start \(service.label): \(result.output)") }
    }

    /// Veetbot API and worker processes not started by the LaunchAgents.
    private nonisolated static func manualProcesses() -> [(pid: pid_t, command: String)] {
        let listing = run("/bin/ps", ["-axo", "pid=,ppid=,command="]).output
        return listing.split(separator: "\n").compactMap { row in
            let parts = row.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]) else { return nil }
            let command = String(parts[2])
            let isVeetbot = command.contains("serve_https_api.py") || command.hasSuffix("/agent worker")
                || command.hasSuffix("uv run agent worker")
            return isVeetbot ? (pid, command) : nil
        }
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private nonisolated static var searchPath: String {
        ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
    }

    nonisolated static func uvPath() -> String? {
        searchPath.split(separator: ":").map { "\($0)/uv" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

struct SetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
