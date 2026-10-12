import AppKit
import MulticaCore
import SwiftUI

/// Native counterpart of packages/views/layout/app-sidebar.tsx.
struct AppSidebar: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(ModalCenter.self) private var modals
    @Environment(ShellState.self) private var shell
    @AppStorage("multica.sidebar.pinsExpanded") private var pinsExpanded = false
    @AppStorage("multica.sidebar.pinnedOpen") private var pinnedOpen = true

    private static let pinnedPreviewLimit = 5

    var body: some View {
        let activePage = nav.route.page
        let activePin = pinForCurrentRoute
        VStack(spacing: 0) {
            SidebarHeader()
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 4)
            List {
                Section {
                    ForEach(WorkspacePage.personal, id: \.self) { page in
                        navRow(page, active: activePage == page && activePin == nil)
                    }
                }
                if !session.pins.items.isEmpty {
                    Section(isExpanded: $pinnedOpen) {
                        let pins = session.pins.items
                        let shown = pinsExpanded ? pins : Array(pins.prefix(Self.pinnedPreviewLimit))
                        ForEach(shown) { pin in
                            PinRow(pin: pin, active: activePin == pin.id)
                        }
                        .onMove { from, to in movePins(from: from, to: to) }
                        if pins.count > Self.pinnedPreviewLimit {
                            Button(pinsExpanded ? tr("layout", "sidebar.show_fewer_pins") : tr("layout", "sidebar.show_more_pins", ["count": pins.count - Self.pinnedPreviewLimit])) {
                                pinsExpanded.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 22)
                        }
                    } header: {
                        Text(tr("layout", "sidebar.pinned_label"))
                    }
                }
                Section(tr("layout", "sidebar.work_group")) {
                    ForEach(WorkspacePage.work, id: \.self) { page in
                        navRow(page, active: activePage == page && activePin == nil)
                    }
                }
                Section(tr("layout", "sidebar.ai_team_group")) {
                    ForEach(WorkspacePage.aiTeam, id: \.self) { page in
                        navRow(page, active: activePage == page)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            SidebarFooter(activePage: activePage)
        }
        .task {
            await session.pins.loadIfNeeded()
            await session.chatSessions.loadIfNeeded()
        }
    }

    private var pinForCurrentRoute: String? {
        let route = nav.route
        return session.pins.items.first { pin in
            switch (pin.itemType, route) {
            case ("issue", .issue(let id)): return id == pin.itemId
            case ("project", .project(let id)): return id == pin.itemId
            case ("view", _): return nav.query("view") == pin.itemId
            default: return false
            }
        }?.id
    }

    @ViewBuilder
    private func navRow(_ page: WorkspacePage, active: Bool) -> some View {
        SidebarNavButton(page: page, active: active, badge: badge(for: page)) {
            nav.push(page.route)
        }
    }

    private func badge(for page: WorkspacePage) -> Int {
        switch page {
        case .inbox: return session.inbox.unread(in: session.workspace.id)
        case .chat:
            let viewing = (nav.route == .chat || shell.chatOpen) && NSApp.isActive ? env.activeChatSessionID : nil
            return session.chatSessions.items.reduce(0) { $0 + ($1.id == viewing ? 0 : ($1.unreadCount ?? 0)) }
        default: return 0
        }
    }

    private func movePins(from: IndexSet, to: Int) {
        var list = session.pins.items
        list.move(fromOffsets: from, toOffset: to)
        let reordered = list.enumerated().map { i, p -> PinnedItem in
            var p = p
            p.position = Double(i + 1)
            return p
        }
        session.pins.setAll(reordered)
        let items = reordered.map { JSONValue.object(["id": .string($0.id), "position": .number($0.position)]) }
        Task {
            do { try await session.api.reorderPins(ReorderPinsRequest(items: items)) }
            catch { await session.pins.load() }
        }
    }
}

/// One nav entry: route icon, localized label, optional count.
struct SidebarNavButton: View {
    let page: WorkspacePage
    let active: Bool
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: page.icon.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(active ? .primary : .secondary)
                Text(page.title)
                    .foregroundStyle(active ? .primary : .secondary)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text(badge > 99 ? tr("layout", "sidebar.unread_overflow") : "\(badge)")
                        .font(Theme.Font.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(Theme.Font.body)
        }
        .buttonStyle(HoverRowButtonStyle(selected: active))
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .contextMenu {
            Button(tr("common", "navigation.open_in_new_tab")) {
                NotificationCenter.default.post(name: .multicaOpenInNewTab, object: page.route.relativePath)
            }
        }
    }
}

extension Notification.Name {
    /// Object: a workspace-relative path to open in a new tab.
    static let multicaOpenInNewTab = Notification.Name("multica.openInNewTab")
}

/// Pinned issue / project / view.
private struct PinRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let pin: PinnedItem
    let active: Bool
    @State private var title: String?
    @State private var issue: Issue?
    @State private var project: Project?
    @State private var view: IssueView?
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                icon.frame(width: 18)
                Text(displayTitle).lineLimit(1).foregroundStyle(active ? .primary : .secondary)
                Spacer(minLength: 2)
                if hovering {
                    Button(action: unpin) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(tr("layout", "sidebar.unpin_tooltip"))
                }
            }
            .font(Theme.Font.body)
        }
        .buttonStyle(HoverRowButtonStyle(selected: active))
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .onHover { hovering = $0 }
        .task(id: pin.itemId) { await resolve() }
    }

    private var liveIssue: Issue? { session.issues.model(pin.itemId)?.issue ?? issue }
    private var liveProject: Project? { session.projects.item(pin.itemId) ?? project }

    private var displayTitle: String {
        switch pin.itemType {
        case "issue": return liveIssue?.title ?? title ?? "…"
        case "project": return liveProject?.title ?? "…"
        default: return view?.name ?? "…"
        }
    }

    @ViewBuilder private var icon: some View {
        switch pin.itemType {
        case "issue":
            if let i = liveIssue { session.issues.catalog.icon(for: i.status) } else { StatusIcon(glyph: .circle, color: .secondary) }
        case "project":
            ProjectIconView(icon: liveProject?.icon, size: 14)
        default:
            Image(systemName: "square.3.layers.3d").foregroundStyle(.secondary)
        }
    }

    private func resolve() async {
        do {
            switch pin.itemType {
            case "issue":
                if session.issues.model(pin.itemId) == nil { issue = try await session.api.issue(pin.itemId) }
            case "project":
                if session.projects.item(pin.itemId) == nil { project = try await session.api.getProject(pin.itemId) }
            case "view":
                view = try await session.api.getIssueView(pin.itemId)
            default: break
            }
        } catch let e as APIError where e.status == 404 {
            // Upstream drops pins whose target was deleted.
            unpin()
        } catch {}
    }

    private func open() {
        switch pin.itemType {
        case "issue": nav.push(.issue(pin.itemId), title: liveIssue.map { "\($0.identifier) \($0.title)" })
        case "project": nav.push(.project(pin.itemId), title: liveProject?.title)
        default:
            guard let view else { return }
            let route: AppRoute = view.scopeType == "my" ? .myIssues : (view.scopeType == "project" && view.scopeId != nil ? .project(view.scopeId!) : .issues)
            nav.push(route, query: ["view": view.id])
        }
    }

    private func unpin() {
        session.pins.remove(pin.id)
        Task { try? await session.api.deletePin(itemType: pin.itemType, itemId: pin.itemId) }
    }
}

/// Workspace switcher, search trigger and New Issue.
private struct SidebarHeader: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(WorkspaceSession.self) private var session
    @Environment(ModalCenter.self) private var modals
    @Environment(ShellState.self) private var shell
    @State private var switcherOpen = false

    var body: some View {
        VStack(spacing: 2) {
            Button { switcherOpen.toggle() } label: {
                HStack(spacing: 8) {
                    WorkspaceAvatar(name: session.workspace.name, url: session.workspace.avatarURL, size: 20)
                        .overlay(alignment: .topTrailing) {
                            if !env.myInvitations.isEmpty || env.hasOtherWorkspaceUnread(session.workspace.id, inbox: session.inbox) {
                                Circle().fill(Theme.brand).frame(width: 7, height: 7).offset(x: 2, y: -2)
                            }
                        }
                    Text(session.workspace.name).font(Theme.Font.bodyMedium).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(HoverRowButtonStyle())
            .popover(isPresented: $switcherOpen, arrowEdge: .bottom) {
                WorkspaceSwitcherMenu { switcherOpen = false }
            }

            Button { shell.searchOpen = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").frame(width: 18)
                    Text(tr("search", "trigger.label"))
                    Spacer()
                    if let chord = env.shortcuts.chord(for: .openSearch) { KeyCaps(keys: chord.display) }
                }
                .foregroundStyle(.secondary)
                .font(Theme.Font.body)
            }
            .buttonStyle(HoverRowButtonStyle())

            Button { modals.createIssue() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil").frame(width: 18)
                        .overlay(alignment: .topTrailing) {
                            if env.hasIssueDraft { Circle().fill(Theme.brand).frame(width: 5, height: 5).offset(x: 2, y: -1) }
                        }
                    Text(tr("layout", "sidebar.new_issue"))
                    Spacer()
                    if let chord = env.shortcuts.chord(for: .createIssue) { KeyCaps(keys: chord.display) }
                }
                .foregroundStyle(.secondary)
                .font(Theme.Font.body)
            }
            .buttonStyle(HoverRowButtonStyle())
        }
    }
}

/// The workspace dropdown: account, workspaces, invitations, log out.
private struct WorkspaceSwitcherMenu: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(WorkspaceSession.self) private var session
    @Environment(ModalCenter.self) private var modals
    let dismiss: () -> Void
    @State private var busyInvitation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                AvatarView(name: session.currentUser.name, url: session.currentUser.avatarURL, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.currentUser.name).font(Theme.Font.bodyMedium).lineLimit(1)
                    Text(session.currentUser.email).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(8)
            Divider()
            Text(tr("layout", "sidebar.workspaces_label")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 6)
            ForEach(env.app.workspaces) { ws in
                Button {
                    dismiss()
                    Task { await env.switchWorkspace(ws) }
                } label: {
                    HStack(spacing: 8) {
                        WorkspaceAvatar(name: ws.name, url: ws.avatarURL, size: 18)
                        Text(ws.name).lineLimit(1)
                        Spacer()
                        if ws.id != session.workspace.id && session.inbox.unread(in: ws.id) > 0 {
                            Circle().fill(Theme.brand).frame(width: 7, height: 7)
                        }
                        if ws.id == session.workspace.id {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.brand)
                        }
                    }
                    .font(Theme.Font.body)
                }
                .buttonStyle(HoverRowButtonStyle())
            }
            if !env.workspaceCreationDisabled {
                Button {
                    dismiss()
                    modals.present(.createWorkspace)
                } label: {
                    Label(tr("layout", "sidebar.create_workspace"), systemImage: "plus").font(Theme.Font.body)
                }
                .buttonStyle(HoverRowButtonStyle())
            }
            if !env.myInvitations.isEmpty {
                Divider().padding(.vertical, 2)
                Text(tr("layout", "sidebar.pending_invitations_label")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                ForEach(env.myInvitations) { inv in
                    HStack(spacing: 8) {
                        WorkspaceAvatar(name: inv.workspaceName ?? "W", size: 18)
                        Text(inv.workspaceName ?? tr("layout", "sidebar.invitation_workspace_fallback")).lineLimit(1)
                        Spacer()
                        Button(tr("layout", "sidebar.invitation_join")) {
                            busyInvitation = inv.id
                            Task {
                                await env.acceptInvitation(inv)
                                busyInvitation = nil
                                dismiss()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        Button(tr("layout", "sidebar.invitation_decline")) {
                            busyInvitation = inv.id
                            Task {
                                await env.declineInvitation(inv)
                                busyInvitation = nil
                            }
                        }
                        .controlSize(.mini)
                    }
                    .font(Theme.Font.body)
                    .disabled(busyInvitation == inv.id)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            Divider().padding(.vertical, 2)
            Button(role: .destructive) {
                dismiss()
                Task { await env.signOut() }
            } label: {
                Label(tr("layout", "sidebar.log_out"), systemImage: "rectangle.portrait.and.arrow.right")
                    .foregroundStyle(Theme.destructive)
                    .font(Theme.Font.body)
            }
            .buttonStyle(HoverRowButtonStyle())
        }
        .padding(6)
        .frame(minWidth: 260)
    }
}

/// Usage + Settings, Discord card and Help.
private struct SidebarFooter: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Navigator.self) private var nav
    @Environment(WorkspaceSession.self) private var session
    @Environment(ModalCenter.self) private var modals
    let activePage: WorkspacePage?
    @AppStorage("multica.discordCardDismissed") private var discordDismissed = false

    var body: some View {
        VStack(spacing: 2) {
            ForEach(WorkspacePage.utility, id: \.self) { page in
                SidebarNavButton(page: page, active: activePage == page) { nav.push(page.route) }
            }
            HStack(spacing: 4) {
                if !discordDismissed {
                    HStack(spacing: 6) {
                        Link(destination: URL(string: "https://discord.gg/W8gYBn226t")!) {
                            Label(tr("layout", "sidebar.discord_card.title"), systemImage: "bubble.left.and.bubble.right")
                                .font(Theme.Font.caption)
                        }
                        Spacer()
                        Button { discordDismissed = true } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(tr("layout", "sidebar.discord_card.dismiss"))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.04)))
                } else {
                    Spacer()
                }
                Menu {
                    Link(tr("layout", "help.download_desktop"), destination: URL(string: "https://multica.ai/download")!)
                    Link(tr("layout", "help.docs"), destination: URL(string: "https://multica.ai/docs" + docsPrefix)!)
                    Link(tr("layout", "help.changelog"), destination: URL(string: "https://multica.ai/changelog")!)
                    Link(tr("layout", "help.discord"), destination: URL(string: "https://discord.gg/W8gYBn226t")!)
                    Button(tr("layout", "help.feedback")) { modals.present(.feedback) }
                    if let v = env.serverVersion {
                        Divider()
                        Text(tr("layout", "help.server_version", ["version": v]))
                    }
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("layout", "help.trigger"))
            }
            .padding(.top, 4)
            ConnectionFooter(state: session.connection)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private var docsPrefix: String {
        switch L10n.shared.language {
        case "zh-Hans": return "/zh"
        case "ja": return "/ja"
        case "ko": return "/ko"
        case "fr": return "/fr"
        default: return ""
        }
    }
}

/// Realtime connection indicator.
struct ConnectionFooter: View {
    let state: ConnectionState

    var body: some View {
        if case .connected = state {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(Theme.Font.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
    }

    private var color: Color {
        switch state {
        case .connected: return Theme.success
        case .connecting: return Theme.warning
        case .disconnected: return .orange
        case .stopped: return .gray
        }
    }

    private var label: String {
        switch state {
        case .connected: return "Live"
        case .connecting: return "Connecting…"
        case .disconnected(let retry): return "Reconnecting in \(Int(retry.rounded()))s"
        case .stopped: return "Offline"
        }
    }
}
