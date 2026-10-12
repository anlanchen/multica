import MulticaCore
import SwiftUI

/// The full workspace record (settings JSONB, repos) the Code page edits.
@MainActor
@Observable
final class ConnectionsWorkspaceModel {
    private(set) var record: WorkspaceRecord?
    private(set) var savingKey: String?

    func load(_ session: WorkspaceSession) async {
        if let r = try? await session.api.getWorkspace(session.workspace.id) { record = r }
    }

    var settings: [String: JSONValue] { record?.settings ?? [:] }

    /// Merges one key into `settings` and saves; returns false on failure.
    @discardableResult
    func setSetting(_ key: String, _ value: JSONValue, session: WorkspaceSession, toaster: Toaster, failure: String) async -> Bool {
        guard let record, savingKey == nil else { return false }
        savingKey = key
        defer { savingKey = nil }
        var merged = record.settings
        merged[key] = value
        do {
            self.record = try await session.api.updateWorkspace(record.id, patch: ["settings": .object(merged)])
            return true
        } catch {
            let message = (error as? APIError)?.message
            toaster.error(message?.isEmpty == false ? message! : failure)
            return false
        }
    }

    func setRepos(_ repos: [WorkspaceRepo], session: WorkspaceSession, toaster: Toaster) async -> Bool {
        guard let record else { return false }
        let body = JSONValue.array(repos.map { r in
            var o: [String: JSONValue] = ["url": .string(r.url)]
            if let d = r.description, !d.isEmpty { o["description"] = .string(d) }
            return .object(o)
        })
        do {
            self.record = try await session.api.updateWorkspace(record.id, patch: ["repos": body])
            return true
        } catch {
            let message = (error as? APIError)?.message
            toaster.error(message?.isEmpty == false ? message! : tr("settings", "repositories.toast_save_failed"))
            return false
        }
    }
}

/// GitHub installation listing shared by the hosting row and the repository picker.
@MainActor
@Observable
final class ConnectionsGitHubModel {
    private(set) var data: ListGitHubInstallationsResponse?
    private(set) var loading = false

    var installations: [GitHubInstallation] { data?.installations ?? [] }
    var configured: Bool { data?.configured ?? false }
    var browseConfigured: Bool { data?.repositoryBrowseConfigured == true }
    var canManage: Bool { data?.canManage == true }

    func load(_ session: WorkspaceSession) async {
        loading = true
        defer { loading = false }
        if let d = try? await session.api.listGitHubInstallations(workspaceId: session.workspace.id) { data = d }
    }
}

/// Settings › Code: code hosts, repositories and PR ↔ issue rules (upstream code-tab.tsx).
struct ConnectionsCodeTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster
    @Environment(\.openURL) private var openURL
    @State private var workspace = ConnectionsWorkspaceModel()
    @State private var github = ConnectionsGitHubModel()
    @State private var connecting = false
    @State private var confirm: ConnectionsConfirm?

    private var isManager: Bool { session.connectionsIsManager }

    var body: some View {
        ConnectionsSettingsPage(title: tr("settings", "page.tabs.code"), scope: .workspace) {
            if session.connectionsIsMember && !isManager { ConnectionsReadOnlyNotice() }
            ConnectionsSection(title: tr("settings", "code.hosting_title"), anchor: "code-hosting") {
                ConnectionsCard {
                    githubRow
                    if env.appConfig?.vcsIntegrationAvailable == true {
                        ConnectionsVCSRows()
                    }
                }
            }
            ConnectionsRepositoriesSection(workspace: workspace, github: github)
            prSection
        }
        .task { await workspace.load(session) }
        .task(id: session.revision("github_installation")) { await github.load(session) }
        .connectionsOnAppActive { Task { await github.load(session) } }
        .connectionsConfirm($confirm)
    }

    private var flags: ConnectionsGitHubSettings { ConnectionsGitHubSettings(settings: workspace.settings) }

    private var githubRow: some View {
        let connected = !github.installations.isEmpty
        let primary = github.installations.first
        let flags = self.flags
        let status: (Bool, String) = !connected
            ? (false, tr("settings", "integrations.status_not_connected"))
            : flags.enabled ? (true, tr("settings", "integrations.status_connected")) : (false, tr("settings", "github.status_paused"))
        return ConnectionsRow(label: {
            HStack(spacing: 12) {
                ConnectionsHostMark { ConnectionsBrandMark(brand: .github, size: 16) }
                HStack(spacing: 8) {
                    Text(tr("settings", "page.tabs.github"))
                    ConnectionsHostStatus(connected: status.0, label: status.1)
                }
            }
        }, descriptionView: githubDetail(connected: connected, primary: primary, flags: flags).map { AnyView($0.padding(.leading, 48)) },
           anchor: "github") {
            if github.canManage {
                HStack(spacing: 4) {
                    if !connected {
                        Button(connecting ? tr("settings", "github.connect_opening") : tr("settings", "github.connect_github")) { connect() }
                            .controlSize(.small)
                            .disabled(connecting || !github.configured)
                    }
                    if connected || !flags.enabled {
                        Menu {
                            Button {
                                Task { await setFlag("github_enabled", !flags.enabled) }
                            } label: {
                                Label(flags.enabled ? tr("settings", "github.pause") : tr("settings", "github.resume"),
                                      systemImage: flags.enabled ? "pause" : "play")
                            }
                            .disabled(workspace.savingKey == "github_enabled")
                            if let primary {
                                Divider()
                                Button(role: .destructive) { askDisconnect(primary.id) } label: {
                                    Label(tr("settings", "github.disconnect"), systemImage: "powerplug")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(tr("settings", "code.github_actions"))
                    }
                }
            }
        }
    }

    private func githubDetail(connected: Bool, primary: GitHubInstallation?, flags: ConnectionsGitHubSettings) -> AnyView? {
        let paused = flags.enabled ? nil : tr("settings", "github.master_description_off")
        var lines: [Text] = []
        if connected {
            var line = tr("settings", "github.connected_to", ["login": github.installations.map(\.accountLogin).joined(separator: ", ")])
            if let by = primary?.connectedBy, !by.isEmpty { line += " · " + tr("settings", "github.connected_by", ["name": by]) }
            lines.append(Text(line))
        } else if !github.canManage {
            lines.append(Text(tr("settings", "github.contact_admin_to_connect")))
        } else if !github.configured {
            lines.append(Text(tr("settings", "github.not_configured")) + Text(" ") + connectionsCode("GITHUB_APP_SLUG")
                         + Text(" \(tr("settings", "github.not_configured_and")) ") + connectionsCode("GITHUB_WEBHOOK_SECRET"))
        }
        if let paused { lines.append(Text(paused)) }
        guard !lines.isEmpty else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: 2) {
            ForEach(lines.indices, id: \.self) { lines[$0] }
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true))
    }

    private var prSection: some View {
        let flags = self.flags
        let featureDisabled = { (key: String) in !github.canManage || !flags.enabled || workspace.savingKey == key }
        return ConnectionsSection(title: tr("settings", "code.pr_linking_title"), anchor: "pr-linking") {
            ConnectionsCard {
                ConnectionsRow(tr("settings", "github.feature_pr_sidebar_label"), description: tr("settings", "github.feature_pr_sidebar_description"), anchor: "pr-sidebar") {
                    toggle(flags.prSidebar, key: "github_pr_sidebar_enabled", disabled: featureDisabled("github_pr_sidebar_enabled"))
                }
                Divider()
                ConnectionsRow(tr("settings", "github.feature_auto_link_label"),
                               description: tr("settings", "github.feature_auto_link_description",
                                               ["example": "\(session.workspace.issuePrefix.isEmpty ? "MUL" : session.workspace.issuePrefix)-123"]),
                               anchor: "auto-link") {
                    toggle(flags.autoLinkPRs, key: "github_auto_link_prs_enabled", disabled: featureDisabled("github_auto_link_prs_enabled"))
                }
                Divider()
                ConnectionsRow(tr("settings", "github.feature_co_author_label"), descriptionView: AnyView(
                    (Text(tr("settings", "github.feature_co_author_description_prefix")) + Text(" ")
                     + Text("Co-authored-by: multica-agent <github@multica.ai>").font(.system(size: 11, design: .monospaced))
                     + Text(tr("settings", "github.feature_co_author_description_suffix")))
                        .font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)), anchor: "co-author") {
                    toggle(flags.coAuthor, key: "co_authored_by_enabled", disabled: featureDisabled("co_authored_by_enabled"))
                }
                Divider()
                ConnectionsPRMergeStatusRow(workspace: workspace, canManage: isManager)
            }
        }
    }

    private func toggle(_ on: Bool, key: String, disabled: Bool) -> some View {
        Toggle("", isOn: Binding(get: { on }, set: { v in Task { await setFlag(key, v) } }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(disabled)
    }

    private func setFlag(_ key: String, _ value: Bool) async {
        await workspace.setSetting(key, .bool(value), session: session, toaster: toaster, failure: tr("settings", "github.toast_failed"))
    }

    private func connect() {
        connecting = true
        Task {
            defer { connecting = false }
            do {
                let r = try await session.api.getGitHubConnectURL(workspaceId: session.workspace.id)
                guard r.configured, let raw = r.url, let url = URL(string: raw) else {
                    toaster.error(tr("settings", "github.toast_not_configured"))
                    return
                }
                openURL(url)
            } catch {
                toaster.error((error as? APIError)?.message ?? tr("settings", "github.toast_open_failed"))
            }
        }
    }

    private func askDisconnect(_ installationID: String) {
        confirm = ConnectionsConfirm(
            title: tr("settings", "github.disconnect_confirm_title"),
            message: tr("settings", "github.disconnect_confirm_description"),
            cancel: tr("settings", "github.disconnect_confirm_cancel"),
            confirm: tr("settings", "github.disconnect_confirm_action"),
            pending: tr("settings", "github.disconnecting")) {
                do {
                    try await session.api.deleteGitHubInstallation(workspaceId: session.workspace.id, installationId: installationID)
                    await github.load(session)
                    toaster.success(tr("settings", "github.toast_disconnected"))
                    return true
                } catch {
                    toaster.error((error as? APIError)?.message ?? tr("settings", "github.toast_disconnect_failed"))
                    return false
                }
            }
    }
}

/// "After PRs merge, move the issue to" (upstream pr-merge-status-row.tsx).
private struct ConnectionsPRMergeStatusRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let workspace: ConnectionsWorkspaceModel
    let canManage: Bool

    var body: some View {
        let catalog = session.issues.catalog
        let groups = ConnectionsPRMergeStatus.groups(entries: catalog.entries)
        let stored = ConnectionsPRMergeStatus.derive(settings: workspace.settings)
        let offered = groups.contains { $0.keys.contains(stored) }
        let value = offered ? stored : ConnectionsPRMergeStatus.none
        ConnectionsRow(tr("settings", "pr_merge_status.label"), description: tr("settings", "pr_merge_status.description"), anchor: "pr-merge-status") {
            Menu {
                Button { persist(ConnectionsPRMergeStatus.none, current: value) } label: {
                    Label(tr("settings", "pr_merge_status.none"), systemImage: "circle.slash")
                }
                ForEach(groups, id: \.category) { group in
                    Section(tr("settings", "issue_statuses.category_labels.\(group.category.rawValue)")) {
                        ForEach(group.keys, id: \.self) { key in
                            Button { persist(key, current: value) } label: {
                                Text(catalog.localizedName(for: IssueStatusKey(rawValue: key)))
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if value == ConnectionsPRMergeStatus.none {
                        Image(systemName: "circle.slash").foregroundStyle(.secondary)
                        Text(tr("settings", "pr_merge_status.none"))
                    } else {
                        catalog.icon(for: IssueStatusKey(rawValue: value), size: 13)
                        Text(catalog.localizedName(for: IssueStatusKey(rawValue: value)))
                    }
                }
            }
            .menuStyle(.button)
            .frame(width: 192)
            .disabled(!canManage || workspace.savingKey == "pr_merge_status")
        }
    }

    private func persist(_ next: String, current: String) {
        guard next != current else { return }
        Task {
            await workspace.setSetting("pr_merge_status", .string(next), session: session, toaster: toaster,
                                       failure: tr("settings", "auto_save.failed"))
        }
    }
}
