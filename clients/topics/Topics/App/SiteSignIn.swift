import SwiftUI
import TopicsKit
import VeetbotCore

/// Signing in to a booking site once, so the helper can book there after the
/// owner's OK. It is Veetbot's device sign-in (ADR-0128) with Topics' own
/// finish step: the site opens in Veetbot's private sign-in window, and I'm
/// signed in hands only that site's session to Veetbot's isolated browser.
/// The password is typed into the site itself; Topics never sees it and
/// keeps only the profile's id.
///
/// Unlike the Veetbot app, the profile is created before the window opens,
/// for the site and its `www.` twin, so a Veetbot that can't save sign-ins
/// says so before the owner types anything.
@MainActor
final class SiteSignIn: ObservableObject, Identifiable {
    enum Outcome: String { case signedIn = "signed_in", unavailable, cancelled }

    let id = UUID()
    let name: String
    let profileID: UUID
    let session: DeviceSignInWebSession
    @Published private(set) var working = false
    @Published private(set) var message: String?

    private let api: VeetbotAPIClient
    private let origins: [String]
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var openCeremonyID: UUID?
    private var outcome: Outcome?

    /// Creates the site's profile and its window; nil when Veetbot can't save sign-ins.
    static func start(url: String, name: String, api: VeetbotAPIClient) async -> SiteSignIn? {
        guard let site = SiteAccessStore.site(of: url),
            let start = URL(string: url.hasPrefix("https://") ? url : "https://\(site)/")
        else { return nil }
        let origins = ["https://\(site)", "https://www.\(site)"]
        guard let profile = try? await api.createBrowserProfile(allowedOrigins: origins) else { return nil }
        return SiteSignIn(name: name, profileID: profile.id, origins: origins, start: start, api: api)
    }

    private init(name: String, profileID: UUID, origins: [String], start: URL, api: VeetbotAPIClient) {
        self.name = name
        self.profileID = profileID
        self.origins = origins
        self.api = api
        session = DeviceSignInWebSession(
            request: DeviceSignInRequest(startURL: start, allowedOrigins: origins, profileID: profileID, adoptableOrigin: nil)
        )
    }

    /// Waits for the owner to finish or close the window.
    func result() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }

    /// I'm signed in: hand the session over once and wait for Veetbot to confirm it.
    func confirm() async {
        guard !working, outcome == nil else { return }
        working = true
        message = nil
        defer { working = false }
        let body: Data
        let confirmedOrigin: String
        do {
            let handoff = try await session.collect()
            body = try WebsiteSessionScope(allowedOrigins: origins).encode(handoff)
            guard let confirmed = URL(string: handoff.confirmedURL), let origin = WebsiteSessionScope.origin(of: confirmed) else {
                message = DeviceSignInMessage.couldNotStart
                return
            }
            confirmedOrigin = origin
        } catch WebsiteSessionScopeError.tooLarge {
            message = DeviceSignInMessage.tooMuchData
            return
        } catch {
            message = DeviceSignInMessage.couldNotStart
            return
        }
        guard let ceremony = try? await api.beginBrowserAuthentication(
            profileID: profileID, loginURL: confirmedOrigin + "/", mode: .device
        ) else {
            message = DeviceSignInMessage.couldNotStart
            return
        }
        openCeremonyID = ceremony.id
        guard let target = DeviceSignInHandoffTarget(launchURL: ceremony.launchURL) else {
            await cancelCeremony()
            message = DeviceSignInMessage.couldNotStart
            return
        }
        let sent = await DeviceSignInHandoffClient().send(body, to: target)
        let status: BrowserAuthenticationStatus?
        switch sent {
        case .sealed, .transportFailed:
            status = await ceremonyStatus(ceremony.id, polling: true)
        case .capabilityRejected:
            status = await ceremonyStatus(ceremony.id, polling: false)
        case .tooLarge:
            await cancelCeremony()
            message = DeviceSignInMessage.tooMuchData
            return
        case .rejected(let code) where code == "internal_error" || code.hasPrefix("http_5"):
            status = await ceremonyStatus(ceremony.id, polling: false)
        case .rejected(let code):
            // The ceremony is single use; the next I'm signed in begins a new one.
            await cancelCeremony()
            message = Self.message(for: code)
            return
        }
        if status?.isTerminal ?? false { openCeremonyID = nil }
        guard status == .ready else {
            await cancelCeremony()
            message = DeviceSignInMessage.couldNotConfirm
            return
        }
        await finish(.signedIn)
    }

    /// Closing the window: end any open ceremony and remove the unused profile.
    func close() async {
        guard outcome == nil else { return }
        await cancelCeremony()
        try? await api.deleteBrowserProfile(profileID)
        await finish(.cancelled)
    }

    private func finish(_ result: Outcome) async {
        outcome = result
        await session.destroy()
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func cancelCeremony() async {
        if let id = openCeremonyID { _ = try? await api.cancelBrowserAuthentication(id) }
        openCeremonyID = nil
    }

    /// Read every 2 seconds for up to 45 when the handoff's answer is unknown, else once.
    private func ceremonyStatus(_ id: UUID, polling: Bool) async -> BrowserAuthenticationStatus? {
        let timing = DeviceSignInTiming.standard
        let deadline = Date().addingTimeInterval(timing.pollLimit)
        var last: BrowserAuthenticationStatus?
        while true {
            if let view = try? await api.getBrowserAuthentication(id) {
                last = view.status
                if view.status.isTerminal { return view.status }
            }
            guard polling, Date() < deadline, !Task.isCancelled else { return last }
            try? await Task.sleep(for: .seconds(timing.pollInterval))
        }
    }

    private static func message(for code: String) -> String {
        switch code {
        case "session_empty": return DeviceSignInMessage.sessionEmpty
        case "session_signed_out": return DeviceSignInMessage.sessionSignedOut
        case "session_unconfirmed": return DeviceSignInMessage.sessionUnconfirmed
        case "tool.browser.provider_unavailable": return DeviceSignInMessage.couldNotCheck
        default: return DeviceSignInMessage.couldNotFinish
        }
    }
}

/// The window: the site, a line on what happens, and I'm signed in.
struct SiteSignInSheet: View {
    @ObservedObject var model: SiteSignIn
    @ObservedObject private var session: DeviceSignInWebSession

    init(model: SiteSignIn) {
        self.model = model
        session = model.session
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in to \(model.name)").font(.system(size: 20, weight: .semibold))
                Text("Sign in as you normally would, then open a page only members see and press I'm signed in. Your password goes to \(model.name) only; Topics never sees it.")
                    .font(.system(size: 13)).foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Rectangle().fill(Ink.line).frame(height: 1)
            DeviceSignInWebView(webView: session.webView)
                .frame(minWidth: 720, minHeight: 520)
            Rectangle().fill(Ink.line).frame(height: 1)
            HStack(spacing: 12) {
                if let blocked = session.blockedHost {
                    Text("\(blocked) isn't part of \(model.name), so it was blocked.").font(.system(size: 12.5)).foregroundStyle(Ink.muted)
                } else if let message = model.message {
                    Text(message).font(.system(size: 12.5)).foregroundStyle(Ink.attentionText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel") { Task { await model.close() } }
                    .keyboardShortcut(.cancelAction)
                Button(model.working ? "Checking…" : "I'm signed in") { Task { await model.confirm() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.working || !session.canConfirm)
            }
            .padding(16)
        }
        .frame(minWidth: 760, minHeight: 680)
    }
}
