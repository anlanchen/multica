import AppKit
import MulticaCore
import SwiftUI
import WebKit

/// Draws ```mermaid diagrams and `$$` math with the libraries upstream uses
/// (mermaid with SVG labels, KaTeX → MathML) in one lazily created offscreen
/// web view. Output is a cached bitmap, so no web content lives in the view
/// tree and a diagram is drawn once per source and color scheme.
@MainActor
final class RichBlockRenderer: NSObject, WKNavigationDelegate {
    static let shared = RichBlockRenderer()

    enum Kind: String { case mermaid, math }

    struct RenderError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let webRoot: URL? = {
        let name = "MulticaNative_MulticaApp.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()] {
            if let url = base?.appendingPathComponent(name), let bundle = Bundle(url: url),
               let web = bundle.url(forResource: "Web", withExtension: nil) {
                return web
            }
        }
        return Bundle.module.url(forResource: "Web", withExtension: nil)
    }()

    private static let canvasWidth: CGFloat = 1400
    private static let canvasHeight: CGFloat = 4000

    private var window: NSWindow?
    private var webView: WKWebView?
    private var loaded = false
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var tail: Task<Void, Never>?
    private let cache = NSCache<NSString, NSImage>()
    private var errors: [String: String] = [:]

    private func key(_ kind: Kind, _ source: String, dark: Bool, width: CGFloat) -> String {
        "\(kind.rawValue)|\(dark ? 1 : 0)|\(Int(width))|\(source)"
    }

    func cached(_ kind: Kind, _ source: String, dark: Bool, width: CGFloat) -> NSImage? {
        cache.object(forKey: key(kind, source, dark: dark, width: width) as NSString)
    }

    func cachedError(_ kind: Kind, _ source: String, dark: Bool, width: CGFloat) -> String? {
        errors[key(kind, source, dark: dark, width: width)]
    }

    /// Renders one block; calls are serialized because they share one page.
    func render(_ kind: Kind, source: String, dark: Bool, width: CGFloat) async throws -> NSImage {
        let k = key(kind, source, dark: dark, width: width)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        if let message = errors[k] { throw RenderError(message: message) }
        let previous = tail
        let job = Task { @MainActor () throws -> NSImage in
            await previous?.value
            if let hit = self.cache.object(forKey: k as NSString) { return hit }
            return try await self.perform(kind, source: source, dark: dark, width: width, key: k)
        }
        tail = Task { _ = try? await job.value }
        return try await job.value
    }

    private func perform(_ kind: Kind, source: String, dark: Bool, width: CGFloat, key k: String) async throws -> NSImage {
        try await ensureLoaded()
        guard let webView else { throw RenderError(message: "renderer unavailable") }
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(
                "return await renderBlock(kind, source, colors, maxWidth)",
                arguments: ["kind": kind.rawValue, "source": source, "colors": Self.colors(dark: dark), "maxWidth": Int(width)],
                contentWorld: .page
            )
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            errors[k] = message
            throw RenderError(message: message)
        }
        guard let size = raw as? [String: Any],
              let w = (size["width"] as? NSNumber)?.doubleValue, let h = (size["height"] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { throw RenderError(message: "empty render") }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: min(w, Self.canvasWidth), height: min(h, Self.canvasHeight))
        config.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: config)
        cache.setObject(image, forKey: k as NSString)
        return image
    }

    private func ensureLoaded() async throws {
        if loaded { return }
        if webView == nil {
            guard let root = Self.webRoot else { throw RenderError(message: "missing renderer resources") }
            let config = WKWebViewConfiguration()
            config.suppressesIncrementalRendering = true
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.canvasWidth, height: Self.canvasHeight), configuration: config)
            view.setValue(false, forKey: "drawsBackground")
            view.navigationDelegate = self
            // Offscreen but ordered in, so WebKit paints and can snapshot.
            let w = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: Self.canvasWidth, height: Self.canvasHeight),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.ignoresMouseEvents = true
            w.isExcludedFromWindowsMenu = true
            w.collectionBehavior = [.transient, .ignoresCycle, .stationary]
            w.contentView = view
            w.orderBack(nil)
            window = w
            webView = view
            view.loadFileURL(root.appendingPathComponent("render.html"), allowingReadAccessTo: root)
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            waiters.append(c)
        }
    }

    private func finishLoading(_ error: Error?) {
        loaded = error == nil
        let pending = waiters
        waiters.removeAll()
        for c in pending {
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
        if error != nil {
            webView = nil
            window?.close()
            window = nil
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
    }

    /// The app's palette as CSS colors (upstream feeds mermaid its CSS
    /// variables: --muted, --primary, --foreground, --muted-foreground).
    private static func colors(dark: Bool) -> [String: String] {
        var out: [String: String] = ["scheme": dark ? "dark" : "light"]
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            out["foreground"] = css(.labelColor)
            out["mutedForeground"] = css(.secondaryLabelColor)
            out["muted"] = dark ? "rgb(38, 38, 40)" : "rgb(245, 245, 245)"
            out["primary"] = css(NSColor(Theme.brand))
        }
        return out
    }

    private static func css(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "currentColor" }
        return "rgba(\(Int(c.redComponent * 255)), \(Int(c.greenComponent * 255)), \(Int(c.blueComponent * 255)), \(String(format: "%.3f", c.alphaComponent)))"
    }
}

/// A cached rendering of one diagram or formula, drawn at its natural size.
struct RichRenderedImage: View {
    let kind: RichBlockRenderer.Kind
    let source: String
    var width: CGFloat = 720
    var onError: ((String) -> Void)? = nil
    @Environment(\.colorScheme) private var scheme
    @State private var image: NSImage?

    var body: some View {
        let dark = scheme == .dark
        Group {
            if let image = image ?? RichBlockRenderer.shared.cached(kind, source, dark: dark, width: width) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width)
                    .accessibilityLabel(source)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("editor", "dynamic_block.rendering")).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: kind == .math ? 32 : 96)
            }
        }
        .task(id: "\(dark)|\(source.hashValue)") {
            do {
                image = try await RichBlockRenderer.shared.render(kind, source: source, dark: dark, width: width)
            } catch {
                onError?(error.localizedDescription)
            }
        }
    }
}
