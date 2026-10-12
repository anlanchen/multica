import MulticaCore
import SwiftUI

/// The `.settings` route (upstream settings-page.tsx): grouped navigation
/// with search on the left, the selected page on the right. The page is
/// `?tab=`, an in-page anchor `?section=`, a Channels detail `?integration=`.
struct SettingsPage: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var results: [SettingsSearchResult] = []
    @State private var activeResult = 0
    @State private var appsAvailable = false
    @State private var flash: String?

    var body: some View {
        let groups = navGroups
        let entries = groups.flatMap { $0.subgroups.flatMap(\.entries) }
        let location = SettingsLocation.resolve(nav.location.query)
        let candidate = location.tab == "billing" && !env.settingsFeatureEnabled("billing_workspace_subscriptions") ? "workspace" : location.tab
        let active = entries.first { $0.value == candidate } ?? entries[0]
        HStack(spacing: 0) {
            sidebar(groups: groups, entries: entries, active: active)
                .frame(width: 240)
            Divider()
            content(active: active, location: location)
        }
        .tabTitle(tr("settings", "page.title"))
        .task(id: env.settingsFeatureEnabled("composio_mcp_apps")) {
            appsAvailable = env.settingsFeatureEnabled("composio_mcp_apps") ? await session.api.settingsComposioAvailable() : false
        }
        .onChange(of: query) { recomputeResults(entries: entries) }
    }

    // MARK: Navigation model

    private var isMember: Bool { session.settingsMyRole == "member" }

    private var navGroups: [SettingsNavGroup] {
        let user = env.app.user
        let ws = env.settingsWorkspace(session)
        let workspaceName = ws.name.isEmpty ? tr("settings", "page.workspace_fallback") : ws.name
        func e(_ value: String, _ key: String, _ icon: String, wide: Bool = false, adminOnly: Bool = false) -> SettingsNavEntry {
            SettingsNavEntry(value: value, label: tr("settings", "page.tabs.\(key)"), icon: icon, wide: wide, adminOnly: adminOnly)
        }
        var personal = [
            e("profile", "profile", "person"),
            e("preferences", "preferences", "slider.horizontal.3"),
            e("notifications", "notifications", "bell"),
            e("shortcuts", "shortcuts", "keyboard"),
        ]
        if appsAvailable { personal.append(e("apps", "apps", "powerplug")) }
        personal.append(e("tokens", "tokens", "key"))

        var workspace = [
            e("workspace", "general", "gearshape", adminOnly: true),
            e("members", "members", "person.2", adminOnly: true),
        ]
        if env.settingsFeatureEnabled("billing_workspace_subscriptions") { workspace.append(e("billing", "billing", "creditcard")) }

        var connections = [
            e("code", "code", "chevron.left.forwardslash.chevron.right", adminOnly: true),
            e("channels", "channels", "bubble.left.and.bubble.right"),
            e("mcp", "mcp", "server.rack", adminOnly: true),
        ]
        if env.settingsFeatureEnabled("plugins_v1") { connections.append(e("plugins", "plugins", "square.grid.2x2", adminOnly: true)) }

        return [
            SettingsNavGroup(key: "personal", label: tr("settings", "page.groups.personal"),
                             mark: .user(name: user?.name ?? "", avatar: user?.avatarURL), tag: user?.name,
                             subgroups: [SettingsNavSubgroup(key: "personal", label: nil, entries: personal)]),
            SettingsNavGroup(key: "workspace", label: workspaceName, mark: .workspace(name: workspaceName, avatar: ws.avatarURL),
                             tag: tr("settings", "page.groups.workspace"), subgroups: [
                                SettingsNavSubgroup(key: "workspace", label: nil, entries: workspace),
                                SettingsNavSubgroup(key: "issues", label: tr("settings", "page.groups.issues"), entries: [
                                    e("issue-statuses", "issue_statuses", "smallcircle.filled.circle", wide: true, adminOnly: true),
                                    e("wakeups", "wakeups", "alarm", wide: true, adminOnly: true),
                                    e("labels", "labels", "tag", wide: true),
                                    e("properties", "properties", "text.badge.plus", wide: true, adminOnly: true),
                                    e("quick-actions", "quick_actions", "bolt", wide: true),
                                ]),
                                SettingsNavSubgroup(key: "connections", label: tr("settings", "page.groups.connections"), entries: connections),
                             ]),
            SettingsNavGroup(key: "device", label: tr("settings", "page.groups.device"), mark: .device, tag: nil, subgroups: [
                SettingsNavSubgroup(key: "device", label: nil, entries: [
                    SettingsNavEntry(value: "daemon", label: tr("settings", "desktop.daemon.title"), icon: "cpu"),
                    SettingsNavEntry(value: "updates", label: tr("settings", "desktop.tabs.updates"), icon: "arrow.down.circle"),
                    SettingsNavEntry(value: "server", label: trd("settings", "desktop.tabs.server", "Server"), icon: "network"),
                    SettingsNavEntry(value: "diagnostics", label: trd("settings", "desktop.tabs.diagnostics", "Diagnostics"), icon: "waveform.path.ecg"),
                ]),
            ]),
        ]
    }

    private func href(_ tab: String, section: String? = nil, integration: String? = nil) -> [String: String] {
        SettingsLocation.query(from: nav.location.query, tab: tab, section: section, integration: integration)
    }

    private func open(_ tab: String, section: String? = nil, integration: String? = nil) {
        nav.push(.settings, query: href(tab, section: section, integration: integration))
    }

    // MARK: Sidebar

    private func sidebar(groups: [SettingsNavGroup], entries: [SettingsNavEntry], active: SettingsNavEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("settings", "page.title"))
                .font(Theme.Font.title)
                .padding(.horizontal, 20)
                .frame(height: 60, alignment: .leading)

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            ScrollView {
                if query.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.key) { i, group in
                            if i > 0 { Divider().padding(.vertical, 2) }
                            navGroup(group, active: active)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                } else {
                    searchResults(groups: groups, entries: entries)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 24)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).imageScale(.small)
            TextField(tr("settings", "page.search"), text: $query)
                .textFieldStyle(.plain)
                .onSubmit { openResult(activeResult) }
                .onKeyPress(.downArrow) {
                    activeResult = min(activeResult + 1, max(results.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    activeResult = max(activeResult - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.borderless)
                    .help(tr("settings", "page.search_clear"))
            }
        }
        .font(Theme.Font.body)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }

    private func navGroup(_ group: SettingsNavGroup, active: SettingsNavEntry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 10) {
                Group {
                    switch group.mark {
                    case .user(let name, let avatar): AvatarView(name: name, url: avatar, size: 16)
                    case .workspace(let name, let avatar): WorkspaceAvatar(name: name, url: avatar, size: 16)
                    case .device: Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16)
                Text(group.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let tag = group.tag {
                    Text(tag).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            ForEach(group.subgroups, id: \.key) { sub in
                if let label = sub.label {
                    Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                }
                ForEach(sub.entries) { item in navItem(item, active: active) }
            }
        }
        .padding(.vertical, 8)
    }

    private func navItem(_ item: SettingsNavEntry, active: SettingsNavEntry) -> some View {
        let selected = item.value == active.value
        return Button { open(item.value) } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon).frame(width: 16)
                Text(item.label).lineLimit(1)
                Spacer(minLength: 4)
                if isMember && item.adminOnly {
                    Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(.tertiary)
                        .help(tr("settings", "page.admin_only"))
                }
            }
            .font(selected ? Theme.Font.bodyMedium : Theme.Font.body)
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 4)
            .frame(minHeight: 22)
        }
        .buttonStyle(HoverRowButtonStyle(selected: selected))
    }

    private func recomputeResults(entries: [SettingsNavEntry]) {
        activeResult = 0
        guard !SettingsSearch.normalize(query).isEmpty else {
            results = []
            return
        }
        let index = SettingsSearch.index(pages: entries.map { (value: $0.value, label: $0.label) }, rows: SettingsSearchRows.all())
        results = SettingsSearch.search(index, query: query)
    }

    private func searchResults(groups: [SettingsNavGroup], entries: [SettingsNavEntry]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(results.isEmpty ? tr("settings", "page.search_empty") : tr("settings", "page.search_results", ["count": results.count]))
                .font(Theme.Font.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 4)
            ForEach(Array(results.enumerated()), id: \.element.id) { position, result in
                let page = entries.first { $0.value == result.entry.tab }
                let scope = groups.first { $0.subgroups.contains { $0.entries.contains { $0.value == result.entry.tab } } }
                let path = [scope?.label, result.entry.anchor != nil || result.entry.integration != nil ? page?.label : nil]
                    .compactMap { $0 }.joined(separator: " › ")
                Button { openResult(position) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsHighlightedText(text: result.entry.title, query: query).font(Theme.Font.body).lineLimit(1)
                        if let snippet = result.snippet {
                            SettingsHighlightedText(text: snippet, query: query).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(path).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(HoverRowButtonStyle(selected: position == activeResult))
                .onHover { if $0 { activeResult = position } }
            }
        }
    }

    private func openResult(_ position: Int) {
        guard results.indices.contains(position) else { return }
        activeResult = position
        let r = results[position].entry
        open(r.tab, section: r.anchor, integration: r.integration)
    }

    // MARK: Content

    /// Pages owned by other areas; they may scroll themselves, so they get
    /// at least the viewport height instead of collapsing inside ours.
    private static let embeddedTabs: Set<String> = ["apps", "billing", "code", "channels", "mcp", "plugins", "daemon"]

    private func content(active: SettingsNavEntry, location: SettingsLocation) -> some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    tabContent(active.value)
                        .frame(maxWidth: active.wide ? 1024 : 896, alignment: .leading)
                        .frame(minHeight: Self.embeddedTabs.contains(active.value) ? max(0, geo.size.height - 64) : nil, alignment: .top)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 32)
                        .frame(maxWidth: .infinity)
                }
                .id("\(active.value):\(location.integration ?? "")")
                .environment(\.settingsFlashAnchor, flash)
                .task(id: "\(active.value)|\(location.section ?? "")") {
                    guard let section = location.section else { return }
                    for delay in [60, 650] {
                        try? await Task.sleep(for: .milliseconds(delay))
                        guard !Task.isCancelled else { return }
                        withAnimation { proxy.scrollTo(SettingsAnchor.id(section), anchor: .center) }
                        flash = section
                    }
                    try? await Task.sleep(for: .milliseconds(1600))
                    if flash == section { flash = nil }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tabContent(_ value: String) -> some View {
        switch value {
        case "profile": SettingsAccountTab()
        case "preferences": SettingsPreferencesTab()
        case "notifications": SettingsNotificationsTab()
        case "shortcuts": SettingsShortcutsTab()
        case "apps": ConnectedAppsSettingsTab()
        case "tokens": SettingsTokensTab()
        case "workspace": SettingsWorkspaceTab()
        case "members": SettingsMembersTab()
        case "billing": BillingSettingsTab()
        case "issue-statuses": SettingsIssueStatusesTab()
        case "wakeups": SettingsWakeupsTab()
        case "labels": SettingsLabelsTab()
        case "properties": SettingsPropertiesTab()
        case "quick-actions": SettingsQuickActionsTab()
        case "code": CodeSettingsTab()
        case "channels": ChannelsSettingsTab()
        case "mcp": McpSettingsTab()
        case "plugins": PluginsSettingsTab()
        case "daemon": DaemonSettingsTab()
        case "updates": SettingsUpdatesTab()
        case "server": SettingsTabView(title: trd("settings", "desktop.tabs.server", "Server"), scope: .device) { ServerSettings() }
        case "diagnostics": SettingsTabView(title: trd("settings", "desktop.tabs.diagnostics", "Diagnostics"), scope: .device) { DiagnosticsView() }
        default: SettingsAccountTab()
        }
    }
}

struct SettingsNavEntry: Identifiable {
    var value: String
    var label: String
    var icon: String
    var wide = false
    /// Owners and admins manage it; members see a read-only page.
    var adminOnly = false
    var id: String { value }
}

struct SettingsNavSubgroup {
    var key: String
    var label: String?
    var entries: [SettingsNavEntry]
}

struct SettingsNavGroup {
    enum Mark {
        case user(name: String, avatar: String?)
        case workspace(name: String, avatar: String?)
        case device
    }

    var key: String
    var label: String
    var mark: Mark
    var tag: String?
    var subgroups: [SettingsNavSubgroup]
}

/// Text with every case-insensitive occurrence of `query` emphasized
/// (upstream HighlightText).
struct SettingsHighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var out = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return out }
        var searchStart = text.startIndex
        while let r = text.range(of: needle, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            if let lower = AttributedString.Index(r.lowerBound, within: out), let upper = AttributedString.Index(r.upperBound, within: out) {
                out[lower..<upper].backgroundColor = Theme.warning.opacity(0.3)
                out[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            }
            searchStart = r.upperBound
        }
        return out
    }
}

/// The searchable in-page settings (upstream use-settings-search-index.ts);
/// anchors match the `anchor:` of the corresponding rows and sections.
enum SettingsSearchRows {
    static func all() -> [SettingsSearchEntry] {
        func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String { tr("settings", key, args) }
        func row(_ tab: String, _ anchor: String, _ title: String, _ description: String? = nil) -> SettingsSearchEntry {
            SettingsSearchEntry(tab: tab, anchor: anchor, title: title, description: description)
        }
        func page(_ tab: String, _ title: String, _ description: String) -> SettingsSearchEntry {
            SettingsSearchEntry(tab: tab, title: title, description: description)
        }
        var rows: [SettingsSearchEntry] = [
            row("profile", "avatar", t("account.avatar_label")),
            row("profile", "name", t("account.name_label")),
            row("profile", "about", t("account.profile_description_label"), t("account.profile_description_hint")),
            row("preferences", "language", t("preferences.language.title")),
            row("preferences", "timezone", t("preferences.timezone.title"), t("preferences.timezone.hint")),
            row("preferences", "theme", t("preferences.theme.title")),
            row("preferences", "sticky-comment-bar", t("preferences.sticky_comment_bar.title")),
            row("preferences", "running-agent-reply", t("preferences.running_agent_reply.title"), t("preferences.running_agent_reply.hint")),
            row("preferences", "chat", t("chat.floating_label"), t("chat.floating_hint")),
            row("preferences", "issue-opening", t("issue.opening.click"), t("issue.opening.hint")),
            row("preferences", "issue-opening", t("issue.opening.title"), "\(t("issue.opening.page")) · \(t("issue.opening.peek"))"),
            row("preferences", "issue", t("preferences.issue_fields_title"), t("issue.description")),
        ]
        for group in ["assignments", "status_changes", "comments", "mentions", "updates", "agent_activity"] {
            rows.append(row("notifications", group, t("notifications.groups.\(group).label"), t("notifications.groups.\(group).description")))
        }
        rows += [
            row("notifications", "system", t("notifications.system.label"), t("notifications.system.description")),
            page("tokens", t("page.tabs.tokens"), t("tokens.purpose")),
            page("shortcuts", t("page.tabs.shortcuts"), t("shortcuts.description")),
            page("apps", t("page.tabs.apps"), t("composio.page_description")),
            row("workspace", "name", t("workspace.name_label")),
            row("workspace", "description", t("workspace.description_label")),
            row("workspace", "context", t("workspace.context_label"), t("workspace.context_hint")),
            row("workspace", "slug", t("workspace.slug_label")),
            row("workspace", "issue-prefix", t("workspace.issue_prefix_label")),
            row("workspace", "leave", t("workspace.leave_title")),
            row("workspace", "delete", t("workspace.delete_title")),
            row("members", "invitations", t("members.pending_label")),
            row("members", "links", t("members.share_links_label")),
            row("wakeups", "child-done", t("wakeups.child_done_title"), t("wakeups.child_done_description")),
            page("labels", t("page.tabs.labels"), t("labels.description")),
            page("properties", t("page.tabs.properties"), t("properties.description")),
            page("quick-actions", t("page.tabs.quick_actions"), t("quick_actions.description")),
            row("code", "code-hosting", t("code.hosting_title")),
            row("code", "github", t("page.tabs.github")),
            row("code", "vcs", t("vcs.section_title")),
            row("code", "repositories", t("repositories.section_title"), t("repositories.description")),
            row("code", "pr-linking", t("code.pr_linking_title")),
            row("code", "pr-sidebar", t("github.feature_pr_sidebar_label"), t("github.feature_pr_sidebar_description")),
            row("code", "auto-link", t("github.feature_auto_link_label"), t("github.feature_auto_link_description", ["example": "MUL-123"])),
            row("code", "co-author", t("github.feature_co_author_label")),
            row("code", "pr-merge-status", t("pr_merge_status.label"), t("pr_merge_status.description")),
        ]
        for channel in SettingsLocation.channelIntegrations {
            rows.append(SettingsSearchEntry(tab: "channels", integration: channel, title: t("\(channel).section_title"), description: t("\(channel).page_description")))
        }
        rows.append(page("mcp", t("page.tabs.mcp"), t("mcp.description")))
        return rows
    }
}
