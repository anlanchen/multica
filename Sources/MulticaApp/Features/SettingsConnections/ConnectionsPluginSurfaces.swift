import AppKit
import MulticaCore
import SwiftUI
import WebKit

/// Every enabled `issue_panel` surface on an issue (upstream
/// plugins/plugin-panel-section.tsx), for the issue detail sidebar.
struct ConnectionsPluginPanelSection: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    let issueID: String

    var body: some View {
        let catalog = ConnectionsPluginCatalog.shared(session)
        let panels = catalog.installations.filter(\.enabled).flatMap { inst in
            inst.surfaces.filter { $0.type == "issue_panel" && (($0.platforms ?? []).isEmpty || ($0.platforms ?? []).contains("desktop")) }
                .map { (installation: inst, surface: $0) }
        }
        if env.appConfig?.featureFlags?["plugins_v1"] == true, !panels.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(tr("issues", "plugins.panels")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(panels, id: \.surface.key) { panel in
                    ConnectionsPluginSurfaceFrame(installation: panel.installation, surface: panel.surface, issueID: issueID)
                        .id("\(panel.installation.id):\(panel.surface.key):\(issueID)")
                }
            }
        }
    }
}

/// Plugin `modal` surfaces offered from an issue's actions menu (upstream
/// `PluginModalMenuItems`); the host presents them with `.connectionsPluginModalHost(issueID:)`.
struct ConnectionsPluginModalMenuItems: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    let issueID: String

    var body: some View {
        let catalog = ConnectionsPluginCatalog.shared(session)
        let targets = catalog.installations.filter(\.enabled).flatMap { inst in
            inst.surfaces.filter { $0.type == "modal" }.map { ConnectionsPluginModalTarget(installation: inst, surface: $0, issueID: issueID) }
        }
        if env.appConfig?.featureFlags?["plugins_v1"] == true {
            ForEach(targets) { target in
                Button { catalog.openModal = target } label: {
                    Label("\(target.surface.name) — \(target.installation.name)", systemImage: "powerplug")
                }
            }
        }
    }
}

struct ConnectionsPluginModalTarget: Identifiable, Equatable {
    var installation: PluginInstallation
    var surface: PluginSurface
    var issueID: String?
    var id: String { "\(installation.id):\(surface.key):\(issueID ?? "")" }
}

extension View {
    /// Presents the plugin modal surface the actions menu opened.
    func connectionsPluginModalHost(issueID: String?) -> some View {
        modifier(ConnectionsPluginModalHost(issueID: issueID))
    }
}

private struct ConnectionsPluginModalHost: ViewModifier {
    @Environment(WorkspaceSession.self) private var session
    let issueID: String?

    func body(content: Content) -> some View {
        let catalog = ConnectionsPluginCatalog.shared(session)
        content.sheet(item: Binding(get: { catalog.openModal }, set: { catalog.openModal = $0 })) { target in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(target.surface.name, systemImage: "powerplug").font(.system(size: 15, weight: .semibold))
                        // Always name the plugin whose UI this is.
                        Text(target.installation.name).font(Theme.Font.body).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { catalog.openModal = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                }
                ConnectionsPluginSurfaceFrame(installation: target.installation, surface: target.surface, issueID: target.issueID ?? issueID)
            }
            .padding(20)
            .frame(width: 640)
            .environment(session)
        }
    }
}

/// Hosts one plugin surface in a WKWebView behind the trusted outer document
/// and serves its bridge requests natively (upstream plugin-surface-frame.tsx
/// + surface-bridge.ts).
struct ConnectionsPluginSurfaceFrame: View {
    @Environment(WorkspaceSession.self) private var session
    let installation: PluginInstallation
    let surface: PluginSurface
    var issueID: String?

    private enum Phase: Equatable { case loading, unavailable, ready(String), failed, navigated }
    @State private var phase = Phase.loading
    @State private var height: CGFloat = 220
    @State private var failedNotice = false

    var body: some View {
        Group {
            switch phase {
            case .loading, .unavailable, .navigated:
                Text(notice)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .ready(let document):
                VStack(alignment: .leading, spacing: 0) {
                    if failedNotice {
                        Text(tr("issues", "plugins.surface_failed", ["name": installation.name]))
                            .font(Theme.Font.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    ConnectionsPluginWebView(document: document, installationID: installation.id, issueID: issueID, api: session.api,
                                             onResize: { height = max(0, min(CGFloat(ConnectionsPlugins.maxSurfaceHeight), $0)) },
                                             onStop: { type in
                                                 if type == "multica:plugin-surface-error" { failedNotice = true } else { phase = .navigated }
                                             })
                        .frame(height: height)
                }
            case .failed:
                EmptyView()
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: "\(installation.id)|\(surface.key)|\(installation.packageVersionId)|\(issueID ?? "")") { await launch() }
    }

    private var notice: String {
        switch phase {
        case .loading: return tr("issues", "plugins.surface_loading", ["name": installation.name])
        case .navigated: return tr("issues", "plugins.surface_navigated", ["name": installation.name])
        default: return tr("issues", "plugins.surface_unavailable", ["name": installation.name])
        }
    }

    private func launch() async {
        phase = .loading
        failedNotice = false
        do {
            // Each mount takes a fresh single-use bridge token.
            let l = try await session.api.getPluginSurfaceLaunch(workspaceId: session.workspace.id, installationId: installation.id, surfaceKey: surface.key)
            if let doc = ConnectionsPlugins.surfaceDocument(url: l.url, bridgeToken: l.bridgeToken, theme: ConnectionsPluginTheme.tokens()) {
                phase = .ready(doc)
            } else {
                phase = .unavailable
            }
        } catch {
            phase = .unavailable
        }
    }
}

/// Theme tokens handed to a connected surface (upstream reads the host's CSS
/// variables; here the equivalent native colors as hex).
enum ConnectionsPluginTheme {
    @MainActor static func tokens() -> [String: String] {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        func hex(_ c: NSColor) -> String {
            guard let rgb = c.usingColorSpace(.sRGB) else { return "#000000" }
            return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
        }
        return [
            "--background": dark ? "#18181B" : "#FFFFFF",
            "--foreground": dark ? "#FAFAFA" : "#18181B",
            "--muted": dark ? "#27272A" : "#F4F4F5",
            "--muted-foreground": dark ? "#A1A1AA" : "#71717A",
            "--border": dark ? "#3F3F46" : "#E4E4E7",
            "--primary": hex(NSColor(Theme.brand)),
            "--primary-foreground": "#FFFFFF",
            "--destructive": hex(NSColor(Theme.destructive)),
            "--radius": "0.5rem",
            "--text-caption": "11px",
            "--text-body": "13px",
        ]
    }
}

private struct ConnectionsPluginWebView: NSViewRepresentable {
    let document: String
    let installationID: String
    let issueID: String?
    let api: APIClient
    let onResize: (Double) -> Void
    let onStop: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "multicaPluginBridge")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = view
        view.loadHTMLString(document, baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.closed = true
        view.configuration.userContentController.removeScriptMessageHandler(forName: "multicaPluginBridge")
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: ConnectionsPluginWebView
        weak var webView: WKWebView?
        var closed = false
        private var loadedDocument = false

        init(_ parent: ConnectionsPluginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The outer document loads once; it may never be replaced.
            if action.targetFrame?.isMainFrame ?? true {
                if !loadedDocument, action.request.url?.absoluteString == "about:blank" {
                    loadedDocument = true
                    decisionHandler(.allow)
                } else {
                    decisionHandler(.cancel)
                    if loadedDocument { parent.onStop("multica:plugin-surface-navigated") }
                }
                return
            }
            decisionHandler(.allow)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !closed, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "request", let request = body["request"] as? [String: Any] {
                handle(request)
            } else if type.hasPrefix("multica:plugin-surface-") {
                closed = type != "multica:plugin-surface-error"
                parent.onStop(type)
            }
        }

        private func handle(_ request: [String: Any]) {
            guard let id = request["id"] as? String else { return }
            let kind = request["kind"] as? String
            if kind == "ui.resize", let h = request["height"] as? Double {
                parent.onResize(h)
                return
            }
            guard kind == "action", let method = request["method"] as? String, ConnectionsPlugins.bridgeMethods.contains(method),
                  let path = request["path"] as? String else { return }
            guard ConnectionsPlugins.isAllowedBridgePath(path) else {
                reply(["id": .string(id), "ok": false, "status": 400, "error": .string("unsupported path \(path)")])
                return
            }
            let body: JSONValue? = request["body"].flatMap { value in
                guard JSONSerialization.isValidJSONObject([value]), let data = try? JSONSerialization.data(withJSONObject: [value]),
                      let decoded = try? JSONDecoder().decode([JSONValue].self, from: data) else { return nil }
                return decoded.first
            }
            let api = parent.api, installationID = parent.installationID, issueID = parent.issueID
            let httpMethod = APIClient.Method(rawValue: method) ?? .get
            Task { @MainActor in
                do {
                    let result = try await api.callPluginAction(installationId: installationID, method: httpMethod, path: path, body: body, issueId: issueID)
                    reply(["id": .string(id), "ok": true, "status": 200, "data": result])
                } catch {
                    let e = error as? APIError
                    reply(["id": .string(id), "ok": false, "status": .number(Double(e?.status ?? 500)),
                           "error": .string(e?.message ?? "plugin action failed")])
                }
            }
        }

        private func reply(_ message: JSONValue) {
            guard !closed, let data = try? JSONCoders.encoder.encode(message), let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.__multicaBridgeReply(\(json))")
        }
    }
}
