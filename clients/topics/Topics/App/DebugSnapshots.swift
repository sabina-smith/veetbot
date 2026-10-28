#if DEBUG
import AppKit
import WebKit

/// Development aid: launched with `-snapshotDir <path>`, the app writes a
/// PNG of its window every few seconds (module cards composited in from
/// WKWebView snapshots), so the board can be checked without screen
/// recording permission. `-autoCheckIn YES` also starts a check-in.
@MainActor
enum DebugSnapshots {
    static func startIfRequested(app: AppModel) {
        let defaults = UserDefaults.standard
        if let screen = defaults.string(forKey: "screen") {
            app.screen = screen == "home" ? .home : screen == "new" ? .newTopic : screen == "onboarding" ? .onboarding : .topic(screen)
        }
        if defaults.bool(forKey: "autoCheckIn"), case .topic(let id) = app.screen {
            Task {
                try? await Task.sleep(for: .seconds(3))
                app.agents[id]?.checkIn()
            }
        }
        // `-onboardingAutoplay YES` runs onboarding with sample answers;
        // `-onboardingAutoCreate YES` also keeps the first proposed topic.
        if defaults.bool(forKey: "onboardingAutoplay"), app.screen == .onboarding {
            app.onboarding.start()
            app.onboarding.answer([
                (q: "What do you do for work?", a: "Investor at a venture firm"),
                (q: "What would you most like off your plate?", a: "Founder follow-ups, home admin"),
            ])
            if defaults.bool(forKey: "onboardingAutoCreate") {
                Task {
                    while app.onboarding.phase != .proposed { try? await Task.sleep(for: .seconds(2)) }
                    let first = app.onboarding.core[0].name
                    _ = try? await app.handleHome(op: "onboarding.create", args: [
                        "topics": [["source": first, "name": first, "colour": "#0E7C86", "helper": "Wren"]],
                    ])
                }
            }
        }
        guard let directory = defaults.string(forKey: "snapshotDir") else { return }
        let interval = max(defaults.double(forKey: "snapshotInterval"), 5)
        Task {
            var index = 0
            while true {
                try? await Task.sleep(for: .seconds(index == 0 ? 4 : interval))
                index += 1
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                    await write(window: window, index: index, to: URL(fileURLWithPath: directory).appendingPathComponent(String(format: "window-%03d.png", index)))
                }
            }
        }
    }

    private static func write(window: NSWindow, index: Int, to url: URL) async {
        guard let content = window.contentView,
            let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(rep)
        for webView in webViews(in: content) where !webView.isHiddenOrHasHiddenAncestor {
            if index == 1, let script = UserDefaults.standard.string(forKey: "debugScript") {
                _ = try? await webView.evaluateJavaScript(script)
                try? await Task.sleep(for: .milliseconds(600))
            }
            // Animations don't advance while the window is hidden behind others.
            _ = try? await webView.evaluateJavaScript("document.getElementById('tp-debug-still') || document.head.append(Object.assign(document.createElement('style'), { id: 'tp-debug-still', textContent: '*, *::before, *::after { animation: none !important; }' }))")
            guard let shot = try? await webView.takeSnapshot(configuration: nil) else { continue }
            var frame = webView.convert(webView.bounds, to: content)
            if content.isFlipped { frame.origin.y = content.bounds.height - frame.maxY }
            let visible = frame.intersection(content.bounds)
            guard !visible.isEmpty else { continue }
            image.lockFocus()
            shot.draw(in: frame)
            image.unlockFocus()
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url)
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        if let webView = view as? WKWebView { return [webView] }
        return view.subviews.flatMap(webViews(in:))
    }
}
#endif
