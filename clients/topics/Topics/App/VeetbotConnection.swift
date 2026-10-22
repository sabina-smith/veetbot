import Foundation
import VeetbotCore

/// Where Veetbot lives and how to authenticate. The URL is a preference;
/// the bearer token is kept only in Keychain, as the Veetbot app does.
@MainActor
final class VeetbotConnection: ObservableObject {
    static let defaultURL = "https://localhost:8443"
    private static let urlKey = "veetbotBaseURL"

    @Published var baseURLString: String {
        didSet {
            UserDefaults.standard.set(baseURLString, forKey: Self.urlKey)
            cached = nil
        }
    }
    @Published private(set) var hasToken = false

    let tokenStore: any TokenStore
    private var cached: (url: String, client: VeetbotAPIClient)?

    init() {
        baseURLString = UserDefaults.standard.string(forKey: Self.urlKey) ?? Self.defaultURL
        tokenStore = SessionTokenStore(
            durable: KeychainTokenStore(service: "com.sabina.topics.bearer-token")
        )
        Task { await bootstrapToken() }
    }

    /// Local development ignores the token, so a first launch stores `dev`
    /// rather than asking.
    private func bootstrapToken() async {
        do {
            if try await tokenStore.readToken() == nil {
                try await tokenStore.saveToken("dev")
            }
            hasToken = true
        } catch {
            hasToken = false
        }
    }

    func saveToken(_ token: String) async throws {
        try await tokenStore.saveToken(token)
        hasToken = !token.trimmingCharacters(in: .whitespaces).isEmpty
        cached = nil
    }

    func client() throws -> VeetbotAPIClient {
        if let cached, cached.url == baseURLString { return cached.client }
        let configuration = try ConnectionConfiguration(baseURLString: baseURLString)
        let client = VeetbotAPIClient(
            transport: HTTPTransport(configuration: configuration, tokenStore: tokenStore)
        )
        cached = (baseURLString, client)
        return client
    }
}
