import SwiftUI
import TopicsKit

/// Presents the connect sheet whenever `GmailSetup` asks for it.
struct GmailSheetHost: ViewModifier {
    @ObservedObject var setup: GmailSetup

    func body(content: Content) -> some View {
        content.sheet(isPresented: $setup.presented) { GmailConnectSheet(setup: setup) }
    }
}

/// Walks the owner through Veetbot's Gmail ceremony: name the account, read
/// each disclosure and type CONTINUE, approve Google in the browser, then
/// wait while Topics restarts Veetbot.
struct GmailConnectSheet: View {
    @ObservedObject var setup: GmailSetup
    @State private var accountID = ""
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Gmail").font(.system(size: 22, weight: .semibold))
            content
        }
        .padding(28)
        .frame(width: 560)
        .onAppear { if accountID.isEmpty { accountID = setup.manifest == nil ? "personal" : "" } }
    }

    @ViewBuilder private var content: some View {
        switch setup.phase {
        case .idle, .failed:
            start
        case .starting:
            progress("Starting Veetbot’s Gmail setup…")
        case .disclosure(let mode, let text):
            disclosure(mode: mode, text: text)
        case .consenting(let mode):
            consenting(mode: mode)
        case .confirmTakeover(let commands):
            takeover(commands)
        case .restarting:
            progress("Restarting Veetbot…")
        case .verifying:
            progress("Waiting for Veetbot to pick up the account…")
        case .connected(let id):
            Text("\(id) is connected. Your helpers can read it now.").foregroundStyle(Ink.muted)
            HStack { Spacer(); Button("Done") { setup.presented = false }.keyboardShortcut(.defaultAction) }
        }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .failed(let message) = setup.phase {
                Text(message).foregroundStyle(Ink.attentionText).textSelection(.enabled)
            }
            Text("Give this account a short name. Connecting the same name again replaces its sign-in.")
                .foregroundStyle(Ink.muted)
            TextField("personal, work…", text: $accountID)
                .textFieldStyle(.roundedBorder)
            if !accountID.isEmpty, !GmailAccountsManifest.isValidAccountID(accountID) {
                Text("Lowercase letters, numbers and _ only, starting with a letter.")
                    .font(.caption).foregroundStyle(Ink.attentionText)
            }
            Text("You’ll approve three Google prompts in your browser: read, change and send. Pick the same Google account each time.")
                .font(.caption).foregroundStyle(Ink.muted)
            // The client decides which Google accounts may sign in, so show it before starting.
            PathRow(
                title: "Google OAuth client", path: setup.clientFilePath,
                problem: setup.clientFileProblem, choose: setup.chooseClientFile
            )
            HStack {
                Spacer()
                Button("Cancel") { setup.cancel() }
                Button("Continue") { setup.connect(accountID: accountID) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!GmailAccountsManifest.isValidAccountID(accountID) || setup.clientFileProblem != nil)
            }
        }
    }

    private func disclosure(mode: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Google prompt \(Self.step(mode)) of 3 — \(Self.label(mode))").font(.headline)
            ScrollView {
                Text(text).font(.system(size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 240)
            .padding(10)
            .background(Color(hex: "#F6F6F3"))
            Text("Type CONTINUE to open Google’s consent screen for this scope.")
            TextField("CONTINUE", text: $typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            HStack {
                Spacer()
                Button("Cancel") { setup.cancel() }
                Button("Open Google", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(typed.isEmpty)
            }
        }
    }

    private func send() {
        guard !typed.isEmpty else { return }
        setup.answerDisclosure(typed)
        typed = ""
    }

    private func consenting(mode: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            progress("Approve the \(Self.label(mode)) prompt in your browser. You have five minutes.")
            if let url = setup.authorizationURL {
                Link("The browser didn’t open? Open Google’s page", destination: url)
            }
            HStack { Spacer(); Button("Cancel") { setup.cancel() } }
        }
    }

    private func takeover(_ commands: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Veetbot is running from a terminal. To restart it, Topics will stop these and run them as login items instead:")
                .foregroundStyle(Ink.muted)
            ForEach(commands, id: \.self) { command in
                Text(command).font(.system(size: 11, design: .monospaced)).lineLimit(2).truncationMode(.middle)
            }
            Text("Logs go to ~/Library/Logs/Veetbot.").font(.caption).foregroundStyle(Ink.muted)
            HStack {
                Spacer()
                Button("Not now") { setup.cancel() }
                Button("Stop and restart") { setup.confirmTakeover() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func progress(_ message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(message).foregroundStyle(Ink.muted)
        }
    }

    private static func step(_ mode: String) -> Int {
        ["read": 1, "write": 2, "send": 3][mode] ?? 1
    }

    private static func label(_ mode: String) -> String {
        ["read": "read", "write": "change", "send": "send"][mode] ?? mode
    }
}

/// Settings: the Gmail accounts Veetbot reads, and where Veetbot lives.
struct GmailAccountsSection: View {
    @ObservedObject var setup: GmailSetup

    var body: some View {
        Section("Gmail") {
            if let manifest = setup.manifest {
                ForEach(manifest.accounts, id: \.accountID) { account in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.accountID + (account.accountID == manifest.defaultAccount ? " (default)" : ""))
                            Text(status(for: account.accountID)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if account.accountID != manifest.defaultAccount {
                            Button("Make default") { setup.makeDefault(account.accountID) }
                        }
                        if manifest.accounts.count > 1 {
                            Button("Remove") { setup.remove(account.accountID) }
                        }
                    }
                    .disabled(setup.isBusy)
                }
            } else {
                Text("No Gmail accounts connected through Topics yet.").foregroundStyle(.secondary)
            }
            HStack {
                if case .failed(let message) = setup.phase {
                    Text(message).font(.caption).foregroundStyle(.red)
                } else if setup.isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Connect an account…") { setup.present() }
            }
            PathRow(
                title: "Veetbot folder", path: setup.repositoryPath,
                problem: setup.repositoryProblem, choose: setup.chooseRepository
            )
            PathRow(
                title: "Google OAuth client file", path: setup.clientFilePath,
                problem: setup.clientFileProblem, choose: setup.chooseClientFile
            )
            Text("Removing an account here stops Veetbot using it. To revoke access, remove Veetbot under Third-party connections in your Google Account.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await setup.refreshAccounts() }
    }

    private func status(for id: String) -> String {
        guard let account = setup.accounts.first(where: { $0.id == id }) else { return "Not loaded by Veetbot" }
        return [account.emailAddress, account.status, account.error].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A chosen file or folder: its name, its full path, what's wrong with it,
/// and a Choose… button.
struct PathRow: View {
    let title: String
    let path: String
    let problem: String?
    let choose: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(path).textSelection(.enabled)
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(Ink.attentionText)
                }
            }
            Spacer()
            Button("Choose…", action: choose)
        }
    }
}
