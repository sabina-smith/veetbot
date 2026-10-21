import AppKit
import SwiftUI
import TopicsKit
import WebKit

/// One module card's content: a WKWebView running the SDK and the module's
/// built JavaScript. The page has no network access (content security
/// policy) and reaches the app only through the `topics` message handler.
struct ModuleWebView: NSViewRepresentable {
    @ObservedObject var board: BoardModel
    let module: BoardModule
    let script: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let bridge = ModuleBridge(board: board, moduleID: module.id)
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "topics")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        #if DEBUG
        webView.isInspectable = true
        #endif
        board.register(webView)
        load(webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(webView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    private func load(_ webView: WKWebView, coordinator: Coordinator) {
        let html = ModulePage.html(topic: board.topic, module: module, script: script)
        guard coordinator.loadedHTML != html else { return }
        coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedHTML: String?

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            // Only the page itself loads. A clicked web link opens in the
            // browser; nothing navigates the card away.
            if action.navigationType == .other, action.request.url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            if action.navigationType == .linkActivated, let url = action.request.url,
                ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(action.navigationType == .other ? .allow : .cancel)
        }

        /// Links that ask for a new window (target="_blank") open in the browser.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}

/// Receives SDK calls from one module card.
final class ModuleBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var board: BoardModel?
    let moduleID: String

    init(board: BoardModel, moduleID: String) {
        self.board = board
        self.moduleID = moduleID
    }

    @MainActor
    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            return (nil, "malformed call")
        }
        guard let board else { return (nil, "board closed") }
        do {
            return (try await board.handle(op: op, args: body["args"] as? [String: Any] ?? [:], moduleID: moduleID), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}

enum ModulePage {
    static let sdkScript = resource("sdk/topics-sdk.js")
    static let sdkStyles = resource("sdk/topics-sdk.css")

    private static func resource(_ path: String) -> String {
        guard let url = AppModel.bundledResources?.appendingPathComponent(path) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func html(topic: Topic, module: BoardModule, script: String) -> String {
        let context: [String: Any] = [
            "topic": ["id": topic.id, "name": topic.name, "accent": topic.accentHex, "agentName": topic.agentName],
            "module": ["id": module.id, "title": module.title],
        ]
        let contextJSON = (try? JSONSerialization.data(withJSONObject: context))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:">
        <style>:root { --accent: \(topic.accentHex); --accent-soft-light: \(mix(topic.accentHex, with: (255, 255, 255), 0.84)); --accent-soft-dark: \(mix(topic.accentHex, with: (30, 30, 30), 0.72)); }
        \(sdkStyles)</style>
        <script>(() => { const c = \(contextJSON); window.__topic = c.topic; window.__module = c.module; })();</script>
        <script>\(sdkScript.scriptSafe)</script>
        </head><body><div id="root"></div>
        <script type="module">
        \(moduleBody(script).scriptSafe)
        __boot(__default__);
        </script>
        </body></html>
        """
    }

    /// `hex` blended toward `base` by `amount`, as an opaque CSS color.
    static func mix(_ hex: String, with base: (Double, Double, Double), _ amount: Double) -> String {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        let rgb = [Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF)]
        let target = [base.0, base.1, base.2]
        let mixed = zip(rgb, target).map { Int(($0 * (1 - amount) + $1 * amount).rounded()) }
        return "rgb(\(mixed[0]), \(mixed[1]), \(mixed[2]))"
    }

    /// Rewrites the module's exports so it runs as an inline script: the
    /// default export becomes `__default__`, named exports become plain
    /// declarations.
    static func moduleBody(_ js: String) -> String {
        var body = js
        if let range = body.range(of: #"export\s+default\s+"#, options: .regularExpression) {
            body.replaceSubrange(range, with: "const __default__ = ")
        }
        return body.replacingOccurrences(
            of: #"(?m)^export\s+(?=(const|let|var|function|class|async)\b)"#, with: "", options: .regularExpression
        )
    }
}

private extension String {
    var scriptSafe: String { replacingOccurrences(of: "</script", with: "<\\/script") }
}
