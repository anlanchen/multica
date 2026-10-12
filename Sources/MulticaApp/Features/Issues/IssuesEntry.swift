import MulticaCore
import SwiftUI

/// The workspace Issues page (upstream issues-page.tsx).
struct IssuesPage: View {
    var body: some View {
        IssueListPageFrame(title: tr("issues", "page.breadcrumb_title")) {
            IssueListHost(kind: .issues)
        }
    }
}

/// My Issues (upstream my-issues-page.tsx).
struct MyIssuesPage: View {
    var body: some View {
        IssueListPageFrame(title: tr("my-issues", "page.breadcrumb")) {
            IssueListHost(kind: .my)
        }
    }
}

/// Which issues a collection shows (upstream IssuesPage / MyIssuesPage /
/// project detail / actor issues panel all share one list surface).
enum IssueListScope: Hashable {
    case workspace
    case mine
    case project(String)
    /// Issues assigned to a member/agent/squad (member, agent, squad pages).
    case actor(type: String, id: String)
}

/// Embeddable issue list/board with its own header (filters, display).
struct IssueCollectionView: View {
    let scope: IssueListScope
    var showHeader = true

    var body: some View {
        switch scope {
        case .workspace: IssueListHost(kind: .issues, showHeader: showHeader)
        case .mine: IssueListHost(kind: .my, showHeader: showHeader)
        case .project(let id): IssueListHost(kind: .project(id), showHeader: showHeader)
        case .actor(let type, let id): IssueListActorPanel(actorType: type, actorID: id, showHeader: showHeader)
        }
    }
}

/// Refresh state the page title reflects (`RefreshablePageIcon`).
@MainActor
@Observable
final class IssueListPageStatus {
    var refreshing = false
}

/// Page header (list icon + title) above a surface.
struct IssueListPageFrame<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @State private var status = IssueListPageStatus()

    var body: some View {
        VStack(spacing: 0) {
            PageHeader {
                HStack(spacing: 8) {
                    ZStack {
                        Image(systemName: "checklist").foregroundStyle(.secondary).opacity(status.refreshing ? 0 : 1)
                        if status.refreshing { ProgressView().controlSize(.mini) }
                    }
                    .frame(width: 16)
                    Text(title).font(Theme.Font.bodyMedium)
                }
            }
            content()
        }
        .environment(status)
        .tabTitle(title)
    }
}

/// Resolves a page's scope tab and open saved view, then mounts the surface
/// keyed by its data window (workspace + effective scope + view).
struct IssueListHost: View {
    enum Kind: Equatable {
        case issues, my
        case project(String)
    }

    let kind: Kind
    var showHeader = true

    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    @State private var views: IssueListViewsModel?
    @State private var tab = ""

    private var page: String {
        if case .project(let id) = kind { return "project:\(id)" }
        return "issues"
    }

    var body: some View {
        Group {
            if let views {
                content(views)
            } else {
                Color.clear
            }
        }
        .task(id: session.workspace.id) {
            let container: (String, String?) = {
                switch kind {
                case .issues: return ("workspace", nil)
                case .my: return ("my", nil)
                case .project(let id): return ("project", id)
                }
            }()
            if views == nil || views?.session !== session {
                tab = kind == .my
                    ? IssueListPrefs.myIssuesScope(workspaceID: session.workspace.id)
                    : IssueListPrefs.scopeTab(workspaceID: session.workspace.id, page: page)
                views = IssueListViewsModel(session: session, scopeType: container.0, scopeID: container.1)
            }
            await views?.start()
        }
    }

    private var baseScope: IssueListSurfaceScope {
        switch kind {
        case .issues: return .workspace(actorKind: tab.isEmpty ? "all" : tab)
        case .my:
            let relation = tab == "agents" ? "involved" : (tab.isEmpty ? "assigned" : tab)
            return .my(userID: session.currentUser.id, relation: relation)
        case .project(let id): return .project(id: id, actorKind: tab.isEmpty ? "all" : tab)
        }
    }

    @ViewBuilder
    private func content(_ views: IssueListViewsModel) -> some View {
        let activeID = nav.query("view")
        let active = views.view(activeID)
        if activeID != nil && active == nil && !views.ready {
            IssueListSkeleton(mode: .list)
        } else {
            let scope = baseScope
            let effective = active.map { scope.applyingViewVariant($0.scopeVariant) } ?? scope
            IssueListSurfaceView(
                session: session,
                scope: scope,
                view: active,
                modes: kind == .issues || kind == .my ? [.board, .list, .table, .swimlane] : [.board, .list, .table, .swimlane, .gantt],
                header: headerConfig(views, active: active),
                showHeader: showHeader,
                empty: kind == .my ? .my : (kind == .issues ? .issues : .project)
            )
            .id("\(session.workspace.id)|\(effective.key)|\(active?.id ?? "default")")
            .onChange(of: views.ready) { checkMissing(views) }
            .onChange(of: views.views) { checkMissing(views) }
            .onAppear { checkMissing(views) }
        }
    }

    /// The open view vanished (deleted / access revoked): fall back to the
    /// built-in default and say so.
    private func checkMissing(_ views: IssueListViewsModel) {
        guard let id = nav.query("view"), views.ready, !views.fetching, views.view(id) == nil else { return }
        nav.setQuery("view", nil)
        toaster.show(tr("issues", "view_selector.unavailable"))
    }

    private func selectTab(_ value: String) {
        if nav.query("view") != nil { nav.setQuery("view", nil) }
        tab = value
        if kind == .my {
            IssueListPrefs.setMyIssuesScope(value, workspaceID: session.workspace.id)
        } else {
            IssueListPrefs.setScopeTab(value, workspaceID: session.workspace.id, page: page)
        }
    }

    private func headerConfig(_ views: IssueListViewsModel, active: IssueView?) -> IssueListHeaderConfig {
        let builtins: [IssueListBarItem]
        let saveScope: IssueListSaveScope
        switch kind {
        case .my:
            builtins = ["all", "assigned", "created", "agents"].map {
                IssueListBarItem(id: "builtin:\($0)", label: tr("my-issues", "header.scope.\($0)_label"),
                                 description: tr("my-issues", "header.scope.\($0)_description"))
            }
            let variant = ["all": "any", "assigned": "assigned", "created": "created", "agents": "involved"][tab] ?? "assigned"
            saveScope = .my(variant: active.flatMap { v in ["any", "assigned", "created", "involved"].contains(v.scopeVariant ?? "") ? v.scopeVariant : nil } ?? variant)
        case .issues, .project:
            builtins = ["all", "members", "agents"].map {
                IssueListBarItem(id: "builtin:\($0)", label: tr("issues", "scope.\($0)_label"),
                                 description: tr("issues", "scope.\($0)_description"))
            }
            let actorKind = active.map { v in v.scopeVariant == "members" || v.scopeVariant == "agents" ? v.scopeVariant! : "all" } ?? (tab.isEmpty ? "all" : tab)
            if case .project(let id) = kind {
                saveScope = .project(id: id, actorKind: actorKind)
            } else {
                saveScope = .workspace(actorKind: actorKind)
            }
        }
        let activeTab = kind == .my ? (tab.isEmpty ? "assigned" : tab) : (tab.isEmpty ? "all" : tab)
        return IssueListHeaderConfig(
            views: views,
            builtins: builtins,
            activeBuiltin: active == nil ? "builtin:\(activeTab)" : nil,
            selectBuiltin: { id in selectTab(String(id.dropFirst("builtin:".count))) },
            saveScope: saveScope,
            showDateFilter: kind == .issues
        )
    }
}

/// Header inputs that differ per page.
struct IssueListHeaderConfig {
    var views: IssueListViewsModel?
    var builtins: [IssueListBarItem]
    var activeBuiltin: String?
    var selectBuiltin: (String) -> Void
    var saveScope: IssueListSaveScope?
    var showViewToggle = true
    var showWorkingChip = true
    var showDateFilter = false
}

enum IssueListEmptyKind {
    case issues, my, project, actor(String)
}
