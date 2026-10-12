import AppKit
import MulticaCore
import SwiftUI

extension Notification.Name {
    /// Palette "Fold / Unfold All Comments" on the open issue; userInfo
    /// `issueID: String`, `fold: Bool`. The issue page owns collapse state.
    static let searchPaletteFoldComments = Notification.Name("multica.searchPalette.foldComments")
}

/// Rows fetched for recently viewed issues that are not in the issue store.
@MainActor
enum SearchPaletteRecentCache {
    static var rows: [String: SearchPaletteIssueRow] = [:]
}

/// ⌘K command palette (upstream search/search-command.tsx): pages,
/// commands, members, workspaces, server search over issues and projects,
/// and recently viewed issues, all keyboard-driven.
struct SearchCommandPalette: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Navigator.self) private var nav
    @Environment(ModalCenter.self) private var modals
    @Environment(ShellState.self) private var shell
    @Environment(Toaster.self) private var toaster
    @State private var model: SearchPaletteModel?
    @State private var currentIssue: Issue?
    @State private var recent: [SearchPaletteIssueRow] = []
    @State private var contentHeight: CGFloat = 0
    @State private var activated = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                SearchPaletteInput(model: model, focused: $focused, onActivate: activate)
                Divider()
                list(model)
            }
        }
        .frame(width: 576)
        .onAppear {
            if model == nil { model = SearchPaletteModel(api: session.api) }
            configure()
            focused = true
        }
        .task {
            await resolveCurrentIssue()
            await loadRecent()
        }
        .onChange(of: env.appearance) { configure() }
        .onChange(of: session.directory.revision) { configure() }
        .onDisappear { model?.cancel() }
        .onExitCommand { close() }
        .accessibilityLabel(tr("search", "title"))
        .accessibilityHint(tr("search", "description"))
    }

    private var maxListHeight: CGFloat {
        min(400, (NSApp.mainWindow?.frame.height ?? 860) * 0.5)
    }

    private func list(_ model: SearchPaletteModel) -> some View {
        let q = model.trimmed
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.groups) { g in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 6) {
                                if let icon = g.icon { Image(systemName: icon).font(.system(size: 10)) }
                                Text(g.heading)
                            }
                            .font(Theme.Font.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            ForEach(g.items) { item in
                                SearchPaletteRow(item: item, selected: model.selected?.id == item.id, onActivate: { activate(item) })
                                    .id(item.id)
                                    .onHover { if $0, !item.disabled { model.selectedID = item.id } }
                            }
                        }
                        .padding(8)
                    }
                    if model.loading && !model.hasResults {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    if !model.loading && !q.isEmpty && !model.hasResults && !model.pageOrCommandMatches {
                        Text(tr("search", "empty.no_results"))
                            .font(Theme.Font.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                    if !model.loading && q.isEmpty && recent.isEmpty {
                        Text(tr("search", "empty.type_to_search"))
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                    }
                }
                .background(GeometryReader { geo in
                    Color.clear.preference(key: SearchPaletteHeightKey.self, value: geo.size.height)
                })
            }
            .frame(height: min(max(contentHeight, 1), maxListHeight))
            .onPreferenceChange(SearchPaletteHeightKey.self) { contentHeight = $0 }
            .onChange(of: model.selectedID) { if let id = model.selectedID { proxy.scrollTo(id) } }
        }
    }

    // MARK: Inputs

    private func commands() -> [SearchPaletteCommand] {
        var items = [
            SearchPaletteCommand(id: "new-issue", label: tr("search", "commands.new_issue"), icon: "plus", keywords: ["new", "issue", "create", "add"]),
            SearchPaletteCommand(id: "new-project", label: tr("search", "commands.new_project"), icon: "plus", keywords: ["new", "project", "create", "add"]),
        ]
        if case .issue = nav.route, let issue = currentIssue {
            let ident = issue.identifier.lowercased()
            items += [
                SearchPaletteCommand(id: "copy-issue-link", label: tr("search", "commands.copy_issue_link"), icon: "link",
                                     keywords: ["copy", "link", "share", "url", ident]),
                SearchPaletteCommand(id: "copy-issue-identifier", label: tr("search", "commands.copy_identifier", ["identifier": issue.identifier]),
                                     icon: "doc.on.doc", keywords: ["copy", "id", "identifier", ident]),
                SearchPaletteCommand(id: "fold-all-comments", label: tr("search", "commands.fold_all_comments"), icon: "arrow.down.right.and.arrow.up.left",
                                     keywords: ["fold", "collapse", "comments", "收起", "折叠", "评论"]),
                SearchPaletteCommand(id: "unfold-all-comments", label: tr("search", "commands.unfold_all_comments"), icon: "arrow.up.left.and.arrow.down.right",
                                     keywords: ["unfold", "expand", "comments", "展开", "评论"]),
            ]
        }
        let theme = env.appearance
        items += [
            SearchPaletteCommand(id: "theme-light", label: tr("search", "commands.switch_to_light"), icon: "sun.max",
                                 keywords: ["light", "theme", "appearance", "mode", "bright"], checked: theme == "light"),
            SearchPaletteCommand(id: "theme-dark", label: tr("search", "commands.switch_to_dark"), icon: "moon",
                                 keywords: ["dark", "theme", "appearance", "mode", "night"], checked: theme == "dark"),
            SearchPaletteCommand(id: "theme-system", label: tr("search", "commands.use_system_theme"), icon: "desktopcomputer",
                                 keywords: ["system", "theme", "appearance", "mode", "auto"], checked: theme != "light" && theme != "dark"),
        ]
        return items
    }

    private func configure() {
        model?.setInputs(SearchPaletteModel.Inputs(
            commands: commands(),
            members: session.directory.members,
            workspaces: env.app.workspaces.filter { $0.id != session.workspace.id },
            recent: recent,
            catalog: session.issues.catalog))
    }

    private func resolveCurrentIssue() async {
        guard case .issue(let id) = nav.route else { return }
        if let m = session.issues.model(id) ?? session.issues.model(identifier: id) {
            currentIssue = m.issue
        } else {
            currentIssue = try? await session.api.issue(id)
        }
        configure()
    }

    /// Recently viewed issues from this workspace's browsing history; rows
    /// come from the live issue store, else are fetched once and cached.
    private func loadRecent() async {
        let ids = SearchPalettePages.recentIssueIDs(env.tabs.activeGroup?.browsingHistory ?? [])
        func resolved() -> [SearchPaletteIssueRow] {
            ids.compactMap { id in session.issues.model(id).map { SearchPaletteIssueRow(issue: $0.issue) } ?? SearchPaletteRecentCache.rows[id] }
        }
        recent = resolved()
        configure()
        let missing = ids.filter { session.issues.model($0) == nil && SearchPaletteRecentCache.rows[$0] == nil }
        guard !missing.isEmpty else { return }
        let api = session.api
        let fetched: [IssueRecord] = await withTaskGroup(of: IssueRecord?.self) { group in
            for id in missing { group.addTask { try? await api.getIssue(id) } }
            var out: [IssueRecord] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
        for r in fetched { SearchPaletteRecentCache.rows[r.id] = SearchPaletteIssueRow(record: r) }
        recent = resolved()
        configure()
    }

    // MARK: Actions

    private func close() {
        shell.searchOpen = false
    }

    /// Runs `action` once the palette sheet is gone, so a dialog it opens
    /// is not presented over a dismissing sheet.
    private func afterClose(_ action: @escaping () -> Void) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: action)
    }

    private func activate(_ item: SearchPaletteItem) {
        guard !item.disabled, !activated else { return }
        activated = true
        switch item.entry {
        case .page(let page):
            close()
            nav.push(page.route)
        case .project(let p):
            close()
            nav.push(.project(p.id), title: p.title)
        case .issue(let i):
            close()
            nav.push(.issue(i.id), title: i.title)
        case .member(let m):
            nav.push(.member(m.userID), title: m.name)
            close()
        case .workspace(let ws):
            close()
            let env = env
            Task { await env.switchWorkspace(ws) }
        case .command(let c):
            run(c)
        }
    }

    private func run(_ c: SearchPaletteCommand) {
        switch c.id {
        case "new-issue":
            let modals = modals
            afterClose { modals.createIssue() }
        case "new-project":
            let modals = modals
            afterClose { modals.present(.createProject) }
        case "copy-issue-link":
            if case .issue = nav.route {
                let url = nav.webURL(nav.route, appURL: env.app.config.appURL)
                copy(url.absoluteString)
                toaster.success(tr("search", "toast.link_copied"))
            }
            close()
        case "copy-issue-identifier":
            if let issue = currentIssue {
                copy(issue.identifier)
                toaster.success(tr("search", "toast.copied_identifier", ["identifier": issue.identifier]))
            }
            close()
        case "fold-all-comments", "unfold-all-comments":
            if let issue = currentIssue {
                NotificationCenter.default.post(name: .searchPaletteFoldComments, object: nil,
                                                userInfo: ["issueID": issue.id, "fold": c.id == "fold-all-comments"])
            }
            close()
        case "theme-light":
            env.appearance = "light"
            close()
        case "theme-dark":
            env.appearance = "dark"
            close()
        case "theme-system":
            env.appearance = "system"
            close()
        default:
            close()
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

private struct SearchPaletteHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The query field: ↑/↓ move, ↩ opens (⌘↩ in a new tab), Esc closes.
private struct SearchPaletteInput: View {
    @Bindable var model: SearchPaletteModel
    var focused: FocusState<Bool>.Binding
    let onActivate: (SearchPaletteItem) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
            TextField(tr("search", "placeholder"), text: $model.query)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .focused(focused)
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.return) {
                    if let item = model.selected { onActivate(item) }
                    return .handled
                }
                .onSubmit { if let item = model.selected { onActivate(item) } }
            KeyCaps("Esc")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct SearchPaletteRow: View {
    @Environment(WorkspaceSession.self) private var session
    let item: SearchPaletteItem
    let selected: Bool
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) { content }
                ForEach(Array(item.snippets.enumerated()), id: \.offset) { _, s in
                    HStack(alignment: .top, spacing: 8) {
                        if !s.icon.isEmpty { Image(systemName: s.icon).font(.system(size: 9)).foregroundStyle(.secondary).padding(.top, 2) }
                        Text(s.text).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.leading, 26)
                }
            }
            .font(Theme.Font.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.disabled)
        .opacity(item.disabled ? 0.5 : 1)
    }

    @ViewBuilder
    private var content: some View {
        switch item.entry {
        case .page(let page):
            Image(systemName: page.icon.systemImage).foregroundStyle(.secondary).frame(width: 16)
            Text(item.title).lineLimit(1)
        case .command(let c):
            Image(systemName: c.icon).foregroundStyle(.secondary).frame(width: 16)
            Text(item.title).lineLimit(1)
            if c.checked {
                Spacer(minLength: 4)
                Image(systemName: "checkmark").foregroundStyle(.secondary).accessibilityLabel(tr("search", "commands.current_theme_aria"))
            }
        case .member(let m):
            AvatarView(name: m.name, url: m.avatarURL, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if let s = item.subtitle { Text(s).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        case .workspace(let ws):
            WorkspaceAvatar(name: ws.name, url: ws.avatarURL, size: 18)
            Text(item.title).lineLimit(1)
        case .project(let p):
            ProjectIconView(icon: p.icon, size: 16)
            Text(item.title).lineLimit(1)
            Spacer(minLength: 4)
            Text(projectStatusLabel(p.status)).font(Theme.Font.caption).foregroundStyle(projectStatusColor(p.status))
        case .issue(let i):
            StatusIcon(status: i.status, entry: session.issues.catalog.entry(for: i.status), size: 16)
            Text(i.identifier).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize()
            Text(item.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if let a = i.assignee { ActorAvatar(type: a.type, id: a.id, size: 18) }
        }
    }

    private func projectStatusLabel(_ s: String) -> String {
        let label = tr("projects", "status.\(s)")
        return label == "status.\(s)" ? s : label
    }

    private func projectStatusColor(_ s: String) -> Color {
        switch s {
        case "in_progress": return Theme.warning
        case "completed": return Theme.info
        case "cancelled": return Theme.destructive
        default: return .secondary
        }
    }
}
