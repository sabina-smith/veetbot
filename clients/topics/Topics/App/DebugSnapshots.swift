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
        if defaults.bool(forKey: "autoCheckIn"), let id = app.selection {
            Task {
                try? await Task.sleep(for: .seconds(3))
                app.agents[id]?.checkIn()
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
                    await write(window: window, to: URL(fileURLWithPath: directory).appendingPathComponent(String(format: "window-%03d.png", index)))
                }
            }
        }
    }

    private static func write(window: NSWindow, to url: URL) async {
        guard let content = window.contentView,
            let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(rep)
        for webView in webViews(in: content) where !webView.isHiddenOrHasHiddenAncestor {
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
