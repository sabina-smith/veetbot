import AppKit
import SwiftUI
import TopicsKit
import WebKit

/// Handles calls from a page's JavaScript (`topics` message handler).
typealias PageCallHandler = @MainActor (_ op: String, _ args: [String: Any]) async throws -> Any?

/// A full-screen page (a topic's board, Home, New topic) rendered in one
/// WKWebView. The page has no network access (content security policy)
/// and reaches the app only through the `topics` message handler.
struct PageWebView: NSViewRepresentable {
    let html: String
    let handle: PageCallHandler
    var onLoad: ((WKWebView) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addScriptMessageHandler(context.coordinator.bridge, contentWorld: .page, name: "topics")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.appearance = NSAppearance(named: .aqua)
        #if DEBUG
        webView.isInspectable = true
        #endif
        context.coordinator.bridge.handle = handle
        load(webView, coordinator: context.coordinator)
        onLoad?(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.bridge.handle = handle
        load(webView, coordinator: context.coordinator)
        onLoad?(webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    private func load(_ webView: WKWebView, coordinator: Coordinator) {
        guard coordinator.loadedHTML != html else { return }
        coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedHTML: String?
        let bridge = PageBridge()

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if action.navigationType == .linkActivated {
                Self.openExternally(action.request.url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(action.navigationType == .other ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            Self.openExternally(action.request.url)
            return nil
        }

        static func openExternally(_ url: URL?) {
            guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

final class PageBridge: NSObject, WKScriptMessageHandlerWithReply {
    var handle: PageCallHandler?

    @MainActor
    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String, let handle else {
            return (nil, "malformed call")
        }
        do {
            return (try await handle(op, body["args"] as? [String: Any] ?? [:]), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}

/// Builds the pages. Scripts and styles are inlined from the app bundle.
enum PageHTML {
    static let styles = resource("sdk/topics-sdk.css")
    static let sdk = resource("sdk/topics-sdk.js")
    static let boardScript = resource("sdk/board.js")
    static let spriteScript = resource("sdk/sprite.js")
    static let cardsScript = resource("sdk/cards.js")
    static let homeScript = resource("sdk/home.js")
    static let newTopicScript = resource("sdk/newtopic.js")
    static let onboardingScript = resource("sdk/onboarding.js")

    private static func resource(_ path: String) -> String {
        guard let url = AppModel.bundledResources?.appendingPathComponent(path) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func board(topic: Topic, board: Board?, modules: [String: String]) -> String {
        let columns = max(board?.columns ?? 12, 1)
        let layout: [[String: Any]] = (board?.modules ?? []).map { module in
            [
                "id": module.id, "title": module.title, "span": max(1, min(12, module.span * 12 / columns)),
                "kind": module.kind ?? "custom",
                "columns": module.columns.map { $0.map { ["key": $0.key, "label": $0.label] } } ?? NSNull(),
            ]
        }
        let context: [String: Any] = [
            "topic": [
                "id": topic.id, "name": topic.name, "subtitle": nullable(topic.subtitle), "accent": topic.accentHex,
                "agentName": topic.agentName, "suggestion": nullable(topic.suggestion),
            ],
            "layout": ["modules": layout],
        ]
        var moduleScripts = ""
        for module in board?.modules ?? [] where module.isCustom {
            guard let js = modules[module.id] else { continue }
            moduleScripts += """
            <script type="module">
            \(moduleBody(js).scriptSafe)
            __register(\(jsonString(module.id)), __default__);
            </script>

            """
        }
        return page(
            accent: topic.accentHex,
            head: "<script>(() => { const c = \(json(context)); window.__topic = c.topic; window.__layout = c.layout; })();</script>",
            body: moduleScripts + "<script type=\"module\">\(boardScript.scriptSafe)</script>"
        )
    }

    static func home(data: [String: Any]) -> String {
        page(accent: "#0F0F0E", head: "<script>window.__home = \(json(data));</script>", body: "<script>\(homeScript.scriptSafe)</script>")
    }

    static func newTopic(existingHelpers: [String]) -> String {
        page(accent: "#0E7C86", head: "<script>window.__existingHelpers = \(json(existingHelpers));</script>", body: "<script>\(newTopicScript.scriptSafe)</script>")
    }

    static func onboarding() -> String {
        page(accent: "#0E7C86", head: "", body: "<script>\(onboardingScript.scriptSafe)</script>")
    }

    private static func page(accent: String, head: String, body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:">
        <style>\(styles)
        :root { --topic: \(accent); --topic-soft: \(mix(accent, with: (255, 255, 255), 0.88)); --topic-light: \(mix(accent, with: (255, 255, 255), 0.45)); }</style>
        <script>\(sdk.scriptSafe)</script>
        <script>\(spriteScript.scriptSafe)</script>
        <script>\(cardsScript.scriptSafe)</script>
        \(head)
        </head><body><div id="root"></div>
        \(body)
        </body></html>
        """
    }

    /// Rewrites a module's exports so it runs as an inline module script:
    /// the default export becomes `__default__`, named exports plain
    /// declarations.
    static func moduleBody(_ js: String) -> String {
        var body = js
        if let range = body.range(of: #"export\s+default\s+"#, options: .regularExpression) {
            body.replaceSubrange(range, with: "const __default__ = ")
        } else {
            body += "\nconst __default__ = undefined;"
        }
        return body.replacingOccurrences(
            of: #"(?m)^export\s+(?=(const|let|var|function|class|async)\b)"#, with: "", options: .regularExpression
        )
    }

    /// `hex` blended toward `base` by `amount`, as an opaque CSS colour.
    static func mix(_ hex: String, with base: (Double, Double, Double), _ amount: Double) -> String {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        let rgb = [Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF)]
        let mixed = zip(rgb, [base.0, base.1, base.2]).map { Int(($0 * (1 - amount) + $1 * amount).rounded()) }
        return "rgb(\(mixed[0]), \(mixed[1]), \(mixed[2]))"
    }

    static func nullable(_ value: Any?) -> Any { value ?? NSNull() }

    static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value)
        else { return "null" }
        return String(decoding: data, as: UTF8.self).scriptSafe
    }

    static func jsonString(_ value: String) -> String { json([value]).dropFirst().dropLast().description }
}

extension String {
    var scriptSafe: String { replacingOccurrences(of: "</script", with: "<\\/script") }
}
