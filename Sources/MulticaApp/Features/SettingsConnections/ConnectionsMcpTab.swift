import MulticaCore
import SwiftUI

/// Settings › MCP servers: the workspace MCP library (upstream mcp-tab.tsx).
/// Entries are assigned to no agent here, and their configuration is
/// write-only: replacing one means entering a complete new configuration.
struct ConnectionsMcpTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @State private var servers: [WorkspaceMcpServer] = []
    @State private var loading = true
    @State private var editor: ConnectionsMcpEditorTarget?
    @State private var renaming: String?
    @State private var renameDraft = ""
    @State private var renameError = ""
    @State private var renamePending = false
    @State private var confirm: ConnectionsConfirm?

    private var canManage: Bool { session.connectionsIsManager }

    var body: some View {
        ConnectionsSettingsPage(title: tr("settings", "page.tabs.mcp"), description: tr("settings", "mcp.description"), scope: .workspace) {
            if session.connectionsIsMember && !canManage { ConnectionsReadOnlyNotice() }
            ConnectionsToolSourcesOverview()
            ConnectionsSection(title: tr("settings", "mcp.servers_title"), description: tr("settings", "mcp.write_only_note"),
                               action: canManage ? AnyView(addButton) : nil) {
                ConnectionsCard {
                    if loading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 32)
                    } else if servers.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "server.rack").foregroundStyle(.secondary)
                            Text(tr("settings", "mcp.empty_title")).font(Theme.Font.bodyMedium)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else {
                        ForEach(servers, id: \.id) { server in
                            if server.id != servers.first?.id { Divider() }
                            ConnectionsMcpServerRow(
                                name: server.name, transport: server.transport,
                                meta: server.agentCount.map { $0 > 0 ? tr("settings", "mcp_usage.agent_count", ["count": $0]) : tr("settings", "mcp_usage.none") },
                                disabled: server.enabled == false,
                                canManage: canManage,
                                actionsDisabled: renamePending,
                                rename: renaming == server.id ? renameState : nil,
                                onRenameStart: { startRename(server) },
                                onConfigure: {
                                    cancelRename()
                                    editor = ConnectionsMcpEditorTarget(server: server)
                                },
                                onRemove: {
                                    cancelRename()
                                    askDelete(server)
                                })
                        }
                    }
                }
            }
        }
        .task { await load() }
        .sheet(item: $editor) { target in
            ConnectionsMcpServerDialog(replacing: target.server, existingNames: Set(servers.map(\.name))) { name, config in
                await save(target.server, name: name, config: config)
            }
        }
        .connectionsConfirm($confirm)
    }

    private var addButton: some View {
        Button {
            cancelRename()
            editor = ConnectionsMcpEditorTarget(server: nil)
        } label: {
            Label(tr("settings", "mcp.add_server"), systemImage: "plus")
        }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .disabled(renamePending)
    }

    private var renameState: ConnectionsMcpRenameState {
        ConnectionsMcpRenameState(
            draft: Binding(get: { renameDraft }, set: { renameDraft = $0; renameError = "" }),
            error: renameError, pending: renamePending,
            onCancel: cancelRename, onSubmit: { Task { await submitRename() } })
    }

    private func load() async {
        do {
            servers = try await session.api.listWorkspaceMcpServers(workspaceId: session.workspace.id)
        } catch {
            toaster.error(error)
        }
        loading = false
    }

    private func save(_ existing: WorkspaceMcpServer?, name: String, config: [String: JSONValue]) async -> Bool {
        do {
            if let existing {
                _ = try await session.api.updateWorkspaceMcpServer(workspaceId: session.workspace.id, serverId: existing.id, config: config)
                toaster.success(tr("settings", "mcp.updated_toast"))
            } else {
                _ = try await session.api.createWorkspaceMcpServer(workspaceId: session.workspace.id, name: name, config: config)
                toaster.success(tr("settings", "mcp.added_toast"))
            }
            await load()
            return true
        } catch {
            let message = (error as? APIError)?.message
            toaster.error(message?.isEmpty == false ? message! : tr("settings", "mcp.save_failed_toast"))
            return false
        }
    }

    private func startRename(_ s: WorkspaceMcpServer) {
        guard !renamePending else { return }
        renaming = s.id
        renameDraft = s.name
        renameError = ""
    }

    private func cancelRename() {
        guard !renamePending else { return }
        renaming = nil
        renameDraft = ""
        renameError = ""
    }

    private func submitRename() async {
        guard let id = renaming, let current = servers.first(where: { $0.id == id }), !renamePending else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { renameError = tr("settings", "mcp.rename_required"); return }
        if !ConnectionsMcp.isValidName(name) { renameError = tr("settings", "mcp.rename_invalid"); return }
        if name != current.name, servers.contains(where: { $0.name == name }) { renameError = tr("settings", "mcp.rename_duplicate"); return }
        if name == current.name { cancelRename(); return }
        renamePending = true
        defer { renamePending = false }
        do {
            _ = try await session.api.updateWorkspaceMcpServer(workspaceId: session.workspace.id, serverId: id, name: name)
            toaster.success(tr("settings", "mcp.renamed_toast"))
            renaming = nil
            renameDraft = ""
            await load()
        } catch {
            let message = (error as? APIError)?.message
            renameError = message?.isEmpty == false ? message! : tr("settings", "mcp.rename_failed_toast")
            toaster.error(renameError)
        }
    }

    private func askDelete(_ s: WorkspaceMcpServer) {
        confirm = ConnectionsConfirm(
            title: tr("settings", "mcp.delete_title"),
            message: tr("settings", "mcp.delete_description", ["name": s.name]),
            cancel: tr("settings", "mcp.cancel"),
            confirm: tr("settings", "mcp.delete_confirm"),
            destructive: true) {
                do {
                    try await session.api.deleteWorkspaceMcpServer(workspaceId: session.workspace.id, serverId: s.id)
                    toaster.success(tr("settings", "mcp.removed_toast"))
                    await load()
                    return true
                } catch {
                    let message = (error as? APIError)?.message
                    toaster.error(message?.isEmpty == false ? message! : tr("settings", "mcp.remove_failed_toast"))
                    return false
                }
            }
    }
}

struct ConnectionsMcpEditorTarget: Identifiable {
    let id = UUID()
    var server: WorkspaceMcpServer?
}

/// The three ways agents get outside tools, linking to the other two pages.
private struct ConnectionsToolSourcesOverview: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Navigator.self) private var nav
    @State private var composioConfigured = true

    private struct Source: Identifiable {
        var id: String
        var icon: String
        var title: String
        var description: String
        var tab: String?
    }

    var body: some View {
        let flags = env.appConfig?.featureFlags ?? [:]
        let appsAvailable = (flags["composio_mcp_apps"] ?? false) && composioConfigured
        var sources = [Source(id: "mcp", icon: "server.rack", title: tr("settings", "page.tabs.mcp"), description: tr("settings", "mcp_sources.mcp"), tab: nil)]
        if appsAvailable {
            sources.append(Source(id: "apps", icon: "powerplug", title: tr("settings", "page.tabs.apps"), description: tr("settings", "mcp_sources.apps"), tab: "apps"))
        }
        if flags["plugins_v1"] ?? false {
            sources.append(Source(id: "plugins", icon: "square.grid.2x2", title: tr("settings", "page.tabs.plugins"), description: tr("settings", "mcp_sources.plugins"), tab: "plugins"))
        }
        return Group {
            if sources.count >= 2 {
                ConnectionsSection(title: tr("settings", "mcp_sources.title")) {
                    HStack(spacing: 0) {
                        ForEach(sources) { source in
                            if source.id != sources.first?.id { Divider() }
                            cell(source)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.02)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .task {
            guard flags["composio_mcp_apps"] ?? false else { return }
            do {
                _ = try await session.api.listComposioToolkits()
            } catch let e as APIError where e.code == "composio_not_configured" || e.status == 503 {
                composioConfigured = false
            } catch {}
        }
    }

    @ViewBuilder private func cell(_ source: Source) -> some View {
        let content = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: source.icon).foregroundStyle(.secondary)
                Text(source.title).font(Theme.Font.bodyMedium)
                Spacer(minLength: 4)
                if source.tab != nil {
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text(tr("settings", "mcp_sources.current"))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
            Text(source.description).font(Theme.Font.caption).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        if let tab = source.tab {
            Button { nav.push(.settings, query: ["tab": tab]) } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 0)
        } else {
            content.background(Color.primary.opacity(0.02))
        }
    }
}

struct ConnectionsMcpRenameState {
    var draft: Binding<String>
    var error: String
    var pending: Bool
    var onCancel: () -> Void
    var onSubmit: () -> Void
}

/// Transport tile: terminal for STDIO, globe for HTTP, server otherwise.
struct ConnectionsMcpTransportIcon: View {
    let transport: String

    var body: some View {
        let icon: String = switch ConnectionsMcp.transportKind(transport) {
        case .stdio: "terminal"
        case .http: "globe"
        case .other: "server.rack"
        }
        Image(systemName: icon)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .help(ConnectionsMcp.transportLabel(transport))
            .accessibilityLabel(ConnectionsMcp.transportLabel(transport))
    }
}

/// Shared MCP inventory row (upstream common/mcp-server-row.tsx).
struct ConnectionsMcpServerRow: View {
    let name: String
    let transport: String
    var meta: String?
    var disabled = false
    let canManage: Bool
    var actionsDisabled = false
    var rename: ConnectionsMcpRenameState?
    let onRenameStart: () -> Void
    let onConfigure: () -> Void
    let onRemove: () -> Void
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            ConnectionsMcpTransportIcon(transport: transport)
            VStack(alignment: .leading, spacing: rename == nil ? 2 : 8) {
                HStack(spacing: 8) {
                    if let rename {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                TextField(tr("settings", "mcp.rename_server"), text: rename.draft)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($renameFocused)
                                    .disabled(rename.pending)
                                    .onSubmit(rename.onSubmit)
                                    .onExitCommand(perform: rename.onCancel)
                                    .frame(maxWidth: 384)
                                if !rename.error.isEmpty {
                                    Text(rename.error).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                                }
                            }
                            Button(action: rename.onSubmit) {
                                if rename.pending { ProgressView().controlSize(.mini) } else { Image(systemName: "checkmark") }
                            }
                            .disabled(rename.pending)
                            .help(tr("settings", "mcp.rename_save"))
                            Button(action: rename.onCancel) { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                                .disabled(rename.pending)
                                .help(tr("settings", "mcp.rename_cancel"))
                        }
                        .onAppear { renameFocused = true }
                    } else {
                        Text(name).font(Theme.Font.bodyMedium).lineLimit(1)
                    }
                    if disabled { Badge(text: tr("settings", "mcp.disabled_badge")) }
                }
                Text(meta.map { "\(ConnectionsMcp.transportLabel(transport)) · \($0)" } ?? ConnectionsMcp.transportLabel(transport))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if canManage && rename == nil {
                HStack(spacing: 2) {
                    Button(action: onRenameStart) { Image(systemName: "pencil") }
                        .help(tr("settings", "mcp.rename_action"))
                        .accessibilityLabel("\(tr("settings", "mcp.rename_server")) \(name)")
                    Button(action: onConfigure) { Image(systemName: "slider.horizontal.3") }
                        .help(tr("settings", "mcp.replace_config"))
                        .accessibilityLabel("\(tr("settings", "mcp.replace_config")) \(name)")
                    Divider().frame(height: 16).padding(.horizontal, 4)
                    Button(action: onRemove) { Image(systemName: "trash") }
                        .help(tr("settings", "mcp.remove_action"))
                        .accessibilityLabel("\(tr("settings", "mcp.remove_server")) \(name)")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(actionsDisabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
        .hoverHighlight(cornerRadius: 0)
    }
}
