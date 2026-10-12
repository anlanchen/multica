import MulticaCore
import SwiftUI

/// Installed plugins of one workspace, loaded once and shared by the issue
/// menus that list manual hook actions.
@MainActor
@Observable
final class ConnectionsPluginCatalog {
    private static var byWorkspace: [String: ConnectionsPluginCatalog] = [:]

    static func shared(_ session: WorkspaceSession) -> ConnectionsPluginCatalog {
        if let hit = byWorkspace[session.workspace.id] { return hit }
        let c = ConnectionsPluginCatalog()
        byWorkspace[session.workspace.id] = c
        return c
    }

    private(set) var installations: [PluginInstallation] = []
    private(set) var running: String?
    /// The `modal` surface an issue menu opened (presented by the page host).
    var openModal: ConnectionsPluginModalTarget?
    @ObservationIgnored private var loaded = false

    func loadIfNeeded(_ session: WorkspaceSession) async {
        guard !loaded else { return }
        loaded = true
        await reload(session)
    }

    func reload(_ session: WorkspaceSession) async {
        if let r = try? await session.api.listPluginInstallations(workspaceId: session.workspace.id) { installations = r.plugins }
    }

    /// Manual hooks of enabled installations (not filtered by whether the
    /// call would succeed: a refusal explains itself).
    var manualActions: [(installation: PluginInstallation, hook: PluginHook)] {
        installations.filter(\.enabled).flatMap { inst in
            inst.hooks.filter { $0.triggers.contains("manual") }.map { (inst, $0) }
        }
    }

    func run(_ installation: PluginInstallation, _ hook: PluginHook, issueID: String?, session: WorkspaceSession, toaster: Toaster) async {
        running = "\(installation.id):\(hook.key)"
        defer { running = nil }
        do {
            let r = try await session.api.invokePluginHook(installationId: installation.id, hookKey: hook.key, trigger: "manual", issueId: issueID)
            switch r.status {
            case "ok": toaster.success(tr("issues", "plugins.hook_succeeded", ["name": hook.name]))
            case "refused": toaster.error([tr("issues", "plugins.hook_refused", ["name": hook.name]), r.error].compactMap { $0 }.joined(separator: " — "))
            default: toaster.error([tr("issues", "plugins.hook_failed", ["name": hook.name]), r.error].compactMap { $0 }.joined(separator: " — "))
            }
        } catch {
            toaster.error("\(tr("issues", "plugins.hook_failed", ["name": hook.name])) — \((error as? APIError)?.message ?? error.localizedDescription)")
        }
    }
}

/// Manual plugin hook actions for an issue's actions / context menu
/// (upstream plugins/plugin-hook-actions.tsx `PluginHookMenuItems`). Place it
/// inside a `Menu` or `.contextMenu`; the host keeps the catalog loaded with
/// `.connectionsPluginCatalog()`.
struct ConnectionsPluginHookMenuItems: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster
    let issueID: String

    var body: some View {
        let catalog = ConnectionsPluginCatalog.shared(session)
        let actions = env.appConfig?.featureFlags?["plugins_v1"] == true ? catalog.manualActions : []
        if !actions.isEmpty {
            Divider()
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                let key = "\(action.installation.id):\(action.hook.key)"
                Button {
                    Task { await catalog.run(action.installation, action.hook, issueID: issueID, session: session, toaster: toaster) }
                } label: {
                    // The plugin's name too: two plugins may both offer "Summarize".
                    Label("\(action.hook.name) — \(action.installation.name)", systemImage: catalog.running == key ? "hourglass" : "powerplug")
                }
                .disabled(catalog.running == key)
            }
        }
    }
}

extension View {
    /// Loads the workspace plugin catalog the hook menu items read.
    func connectionsPluginCatalog() -> some View {
        modifier(ConnectionsPluginCatalogLoader())
    }
}

private struct ConnectionsPluginCatalogLoader: ViewModifier {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        content.task(id: session.revision("plugin")) {
            guard env.appConfig?.featureFlags?["plugins_v1"] == true else { return }
            await ConnectionsPluginCatalog.shared(session).reload(session)
        }
    }
}
