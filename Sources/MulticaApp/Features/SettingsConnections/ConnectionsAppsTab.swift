import AppKit
import MulticaCore
import SwiftUI

/// Settings › Connected apps: the user's own Composio toolkit connections
/// (upstream connected-apps-tab.tsx + composio-tab.tsx).
struct ConnectionsAppsTab: View {
    var body: some View {
        ConnectionsSettingsPage(title: tr("settings", "page.tabs.apps"),
                                description: tr("settings", "composio.page_description"),
                                scope: .account) {
            ConnectionsComposioSection()
        }
    }
}

@MainActor
@Observable
final class ConnectionsComposioModel {
    enum Phase { case loading, failed, loaded }
    private(set) var phase = Phase.loading
    private(set) var toolkits: [ComposioToolkit] = []
    private(set) var state = ConnectionsComposio.State([])
    private(set) var connectionsFailed = false
    /// "Composio is not configured on this server" (the page hides upstream).
    private(set) var notConfigured = false

    func load(_ api: APIClient) async {
        async let kits = api.listComposioToolkits()
        async let connections: Void = loadConnections(api)
        do {
            toolkits = try await kits
            phase = .loaded
        } catch {
            let e = error as? APIError
            notConfigured = e?.code == "composio_not_configured" || e?.status == 503
            if toolkits.isEmpty { phase = .failed }
        }
        _ = await connections
    }

    func loadConnections(_ api: APIClient) async {
        do {
            state = ConnectionsComposio.State(try await api.listComposioConnections())
            connectionsFailed = false
        } catch {
            connectionsFailed = true
        }
    }
}

private struct ConnectionsComposioSection: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    @Environment(\.openURL) private var openURL
    @State private var model = ConnectionsComposioModel()
    @State private var query = ""
    @State private var connectingSlug: String?
    @State private var confirm: ConnectionsConfirm?

    var body: some View {
        let filtered = ConnectionsComposio.filter(model.toolkits, query: query)
        VStack(alignment: .leading, spacing: 24) {
            switch model.phase {
            case .loading:
                ConnectionsCard {
                    Text(tr("settings", "composio.loading")).font(Theme.Font.body).foregroundStyle(.secondary).padding(16)
                }
            case .failed:
                ConnectionsCard {
                    Text(tr("settings", "composio.load_failed")).font(Theme.Font.body).foregroundStyle(Theme.destructive).padding(16)
                }
            case .loaded where model.toolkits.isEmpty:
                ConnectionsMessageCard(title: tr("settings", "composio.empty_title"), message: tr("settings", "composio.empty_description"))
            case .loaded:
                VStack(alignment: .leading, spacing: 12) {
                    SearchField(text: $query, prompt: tr("settings", "composio.search_placeholder"))
                        .frame(maxWidth: 320)
                    if model.connectionsFailed {
                        Text(tr("settings", "composio.connections_load_failed"))
                            .font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)], spacing: 8) {
                        ForEach(filtered, id: \.slug) { kit in
                            ConnectionsToolkitCard(
                                toolkit: kit,
                                connectionID: model.state.activeConnectionBySlug[kit.slug],
                                expired: model.state.expiredSlugs.contains(kit.slug),
                                lastUsedAt: model.state.lastUsedBySlug[kit.slug],
                                connecting: connectingSlug == kit.slug,
                                anyConnecting: connectingSlug != nil,
                                onConnect: { connect(kit) },
                                onDisconnect: { id in askDisconnect(id) })
                        }
                    }
                }
            }
        }
        .task { await model.load(session.api) }
        .task(id: callbackKey) { consumeCallback() }
        .connectionsOnAppActive {
            // The hosted consent flow finishes in the browser.
            connectingSlug = nil
            Task { await model.loadConnections(session.api) }
        }
        .connectionsConfirm($confirm)
    }

    private var callbackKey: String {
        "\(nav.query("connected") ?? "")|\(nav.query("error") ?? "")"
    }

    /// `?connected=<slug>` / `?error=composio_connect_failed` from the OAuth
    /// return, consumed once.
    private func consumeCallback() {
        let connected = nav.query("connected")
        let failed = nav.query("error") == "composio_connect_failed"
        guard connected != nil || failed else { return }
        if connected != nil {
            toaster.success(tr("settings", "composio.toast_connected"))
            Task { await model.loadConnections(session.api) }
        } else {
            toaster.error(tr("settings", "composio.toast_connect_failed"))
        }
        nav.setQuery("connected", nil)
        nav.setQuery("error", nil)
        nav.setQuery("integration", nil)
    }

    private func connect(_ kit: ComposioToolkit) {
        guard connectingSlug == nil else { return }
        connectingSlug = kit.slug
        Task {
            do {
                let r = try await session.api.beginComposioConnect(toolkitSlug: kit.slug)
                guard let url = URL(string: r.redirectUrl) else { throw APIError(status: 0, message: tr("settings", "composio.connect_failed")) }
                openURL(url)
            } catch {
                toaster.error((error as? APIError)?.message ?? tr("settings", "composio.connect_failed"))
                connectingSlug = nil
            }
        }
    }

    private func askDisconnect(_ connectionID: String) {
        confirm = ConnectionsConfirm(
            title: tr("settings", "composio.disconnect_confirm_title"),
            message: tr("settings", "composio.disconnect_confirm_description"),
            cancel: tr("settings", "composio.disconnect_confirm_cancel"),
            confirm: tr("settings", "composio.disconnect"),
            pending: tr("settings", "composio.disconnecting")) {
                do {
                    try await session.api.deleteComposioConnection(connectionID)
                    await model.loadConnections(session.api)
                    toaster.success(tr("settings", "composio.toast_disconnected"))
                    return true
                } catch {
                    toaster.error((error as? APIError)?.message ?? tr("settings", "composio.disconnect_failed"))
                    return false
                }
            }
    }
}

private struct ConnectionsToolkitCard: View {
    let toolkit: ComposioToolkit
    let connectionID: String?
    let expired: Bool
    let lastUsedAt: String?
    let connecting: Bool
    let anyConnecting: Bool
    let onConnect: () -> Void
    let onDisconnect: (String) -> Void

    var body: some View {
        ConnectionsCard {
            HStack(spacing: 12) {
                ConnectionsToolkitLogo(slug: toolkit.slug, name: toolkit.name, fallback: toolkit.logo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(toolkit.name.isEmpty ? toolkit.slug : toolkit.name).font(Theme.Font.bodyMedium).lineLimit(1)
                    if connectionID != nil {
                        Group {
                            if let lastUsedAt {
                                Text(tr("settings", "composio.last_used", ["when": Formatters.relative(lastUsedAt)]))
                            } else {
                                Text(tr("settings", "composio.last_used_never"))
                            }
                        }
                        .font(Theme.Font.micro).foregroundStyle(.secondary).lineLimit(1)
                    } else if let category = toolkit.category, !category.isEmpty {
                        Text(category.uppercased()).font(Theme.Font.micro).tracking(0.5).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                trailing
            }
            .padding(12)
        }
    }

    @ViewBuilder private var trailing: some View {
        if let connectionID {
            HStack(spacing: 8) {
                Label(tr("settings", "composio.connected"), systemImage: "checkmark")
                    .font(Theme.Font.caption).foregroundStyle(Theme.success).labelStyle(.titleAndIcon)
                Button { onDisconnect(connectionID) } label: { Image(systemName: "trash").font(.system(size: 10)) }
                    .controlSize(.small)
                    .help(tr("settings", "composio.disconnect"))
            }
        } else if expired {
            HStack(spacing: 8) {
                Label(tr("settings", "composio.expired"), systemImage: "exclamationmark.triangle")
                    .font(Theme.Font.caption).foregroundStyle(Theme.warning)
                Button(action: onConnect) {
                    Label(connecting ? tr("settings", "composio.connecting") : tr("settings", "composio.reconnect"),
                          systemImage: connecting ? "hourglass" : "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(anyConnecting)
            }
        } else if toolkit.connectable {
            Button(action: onConnect) {
                Label(connecting ? tr("settings", "composio.connecting") : tr("settings", "composio.connect"),
                      systemImage: connecting ? "hourglass" : "powerplug")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(anyConnecting)
        }
    }
}

/// Toolkit logo with the upstream source fallback chain and an initial.
struct ConnectionsToolkitLogo: View {
    @Environment(\.colorScheme) private var scheme
    let slug: String
    let name: String
    let fallback: String?
    var size: CGFloat = 32
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Text(String((name.isEmpty ? slug : name).prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .task(id: "\(slug)|\(fallback ?? "")|\(scheme == .dark)") {
            image = nil
            for raw in ConnectionsComposio.logoURLs(slug: slug, fallback: fallback, dark: scheme == .dark) {
                guard let url = URL(string: raw) else { continue }
                if let loaded = await ImageLoader.shared.load(url) {
                    image = loaded
                    return
                }
            }
        }
    }
}
