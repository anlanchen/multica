import MulticaCore
import SwiftUI

/// Derived squads list state, recomputed off `body` when its inputs change.
@MainActor
@Observable
final class SquadsListModel {
    private(set) var scopeCounts: [SquadsScope: Int] = [:]
    private(set) var scopeTotal = 0
    private(set) var rows: [Squad] = []
    private(set) var leaderOptions: [SquadsListQuery.Option] = []
    private(set) var creatorOptions: [SquadsListQuery.Option] = []
    private(set) var canManageAny = false

    func recompute(_ squads: [Squad], view: SquadsViewState, userID: String, isAdmin: Bool, directory: Directory) {
        scopeCounts = SquadsListQuery.scopeCounts(squads, userID: userID)
        let scoped = SquadsListQuery.scopeRows(squads, scope: view.scope, userID: userID)
        scopeTotal = scoped.count
        leaderOptions = SquadsListQuery.options(scoped, key: \.leaderId) { directory.agent($0)?.name }
        creatorOptions = SquadsListQuery.options(scoped, key: \.creatorId) { directory.member(userID: $0)?.name }
        let next = SquadsListQuery.rows(scoped, filters: view.filters, sortField: view.sortField, direction: view.sortDirection)
        if next != rows { rows = next }
        canManageAny = isAdmin || next.contains { $0.creatorId == userID }
    }
}

/// Upstream `squads-page.tsx`.
struct SquadsPage: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(ModalCenter.self) private var modals
    @State private var model = SquadsListModel()
    @State private var view = SquadsViewState()
    @State private var prefsSlug: String?

    private var prefsKey: String { "multica_squads_view:\(session.workspace.slug)" }

    var body: some View {
        let store = session.squads
        VStack(spacing: 0) {
            PageHeader {
                PageTitle(page: .squads, count: store.items.count)
            } trailing: {
                Button { modals.present(.createSquad) } label: { Label(tr("squads", "page.new_button"), systemImage: "plus") }
                    .buttonStyle(PillButtonStyle())
            }
            if !store.isLoaded {
                SquadsLoadingRows()
            } else if store.items.isEmpty {
                EmptyStateView(icon: "person.3", title: tr("squads", "page.empty_no_squads")) {
                    Button { modals.present(.createSquad) } label: { Label(tr("squads", "page.new_button"), systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            } else {
                SquadsToolbar(view: $view, model: model)
                SquadsTable(model: model, view: $view)
            }
        }
        .task(id: session.workspace.slug) {
            if prefsSlug != session.workspace.slug {
                view = ProjectsDefaults.load(SquadsViewState.self, key: prefsKey) ?? SquadsViewState()
                prefsSlug = session.workspace.slug
            }
            recompute()
            await store.loadIfNeeded()
        }
        .onChange(of: store.items) { recompute() }
        .onChange(of: session.directory.revision) { recompute() }
        .onChange(of: view) {
            recompute()
            if prefsSlug == session.workspace.slug { ProjectsDefaults.save(view, key: prefsKey) }
        }
    }

    private func recompute() {
        model.recompute(session.squads.items, view: view, userID: session.currentUser.id,
                        isAdmin: session.projectsIsWorkspaceAdmin, directory: session.directory)
    }
}

private struct SquadsToolbar: View {
    @Binding var view: SquadsViewState
    let model: SquadsListModel
    @State private var displayOpen = false

    var body: some View {
        let active = view.filters.activeCount
        HStack(spacing: 8) {
            ForEach(SquadsScope.allCases, id: \.self) { s in
                Button { view.scope = s } label: {
                    HStack(spacing: 6) {
                        Text(tr("squads", "scope.\(s.rawValue)"))
                        Text("\(model.scopeCounts[s] ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(PillButtonStyle(active: view.scope == s))
            }
            if active > 0 {
                Text("\(model.rows.count) / \(model.scopeTotal)")
                    .font(Theme.Font.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help(tr("squads", "toolbar.result_count_title"))
            }
            Spacer(minLength: 8)
            Menu {
                Menu(title(tr("squads", "page.table.leader"), view.filters.leaders.count)) {
                    ForEach(model.leaderOptions) { o in
                        Toggle("\(o.name)    \(o.count)", isOn: binding(\.leaders, o.id))
                    }
                }
                Menu(title(tr("squads", "page.table.creator"), view.filters.creators.count)) {
                    ForEach(model.creatorOptions) { o in
                        Toggle("\(o.name)    \(o.count)", isOn: binding(\.creators, o.id))
                    }
                }
            } label: {
                Label(active > 0 ? tr("squads", "toolbar.filter_active_count", ["count": active]) : tr("squads", "toolbar.filter_label"),
                      systemImage: "line.3.horizontal.decrease")
                    .foregroundStyle(active > 0 ? Theme.brand : .primary)
            }
            .menuStyle(.button)
            .buttonStyle(PillButtonStyle(active: active > 0))
            .menuIndicator(.hidden)
            .fixedSize()
            if active > 0 {
                Button { view.clearFilters() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(tr("squads", "toolbar.clear_filters"))
            }
            Button { displayOpen.toggle() } label: {
                Label(sortLabel(view.sortField), systemImage: view.sortDirection == .asc ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(PillButtonStyle())
            .help(tr("squads", "toolbar.display"))
            .popover(isPresented: $displayOpen, arrowEdge: .bottom) { displayPanel }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func title(_ t: String, _ n: Int) -> String { n > 0 ? "\(t)  \(n)" : t }

    private func binding(_ key: WritableKeyPath<SquadsFilters, [String]>, _ value: String) -> Binding<Bool> {
        Binding(get: { view.filters[keyPath: key].contains(value) }, set: { _ in view.toggleFilter(key, value) })
    }

    private func sortLabel(_ f: SquadsSortField) -> String { tr("squads", "page.table.\(f.rawValue)") }

    private var displayPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("squads", "toolbar.sort_by")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { view.sortField }, set: { view.setSortField($0) })) {
                        ForEach(SquadsSortField.allCases, id: \.self) { f in Text(sortLabel(f)).tag(f) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    Button { view.sortDirection = view.sortDirection.toggled } label: {
                        Image(systemName: view.sortDirection == .asc ? "arrow.up" : "arrow.down")
                    }
                    .help(view.sortDirection == .asc ? tr("squads", "toolbar.direction_asc") : tr("squads", "toolbar.direction_desc"))
                }
            }
            .padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("squads", "toolbar.section_columns")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(SquadsColumn.allCases, id: \.self) { c in
                    Toggle(tr("squads", "page.table.\(c.rawValue)"), isOn: Binding(get: { view.isVisible(c) }, set: { _ in view.toggleColumn(c) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(Theme.Font.body)
                }
            }
            .padding(12)
        }
        .frame(width: 256)
    }
}

private enum SquadsTableLayout {
    static let wideBreakpoint: CGFloat = 672
    static let leader: CGFloat = 160
    static let kebab: CGFloat = 28

    static func width(_ c: SquadsColumn) -> CGFloat {
        switch c {
        case .members: return 120
        case .creator: return 144
        case .created: return 104
        }
    }
}

private struct SquadsTable: View {
    @Environment(WorkspaceSession.self) private var session
    let model: SquadsListModel
    @Binding var view: SquadsViewState
    @State private var width: CGFloat = 1000

    var body: some View {
        let wide = width >= SquadsTableLayout.wideBreakpoint
        let columns = wide ? SquadsColumn.allCases.filter { view.isVisible($0) } : []
        let isAdmin = session.projectsIsWorkspaceAdmin
        let userID = session.currentUser.id
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    if model.rows.isEmpty {
                        Text(tr("squads", "page.no_matches"))
                            .font(Theme.Font.body).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 64)
                    }
                    ForEach(model.rows) { s in
                        SquadsRow(squad: s, columns: columns, wide: wide, showActions: model.canManageAny,
                                  canManage: SquadsListQuery.canManage(s, userID: userID, isWorkspaceAdmin: isAdmin))
                            .equatable()
                        Divider().padding(.leading, 12)
                    }
                } header: {
                    header(columns: columns, wide: wide)
                }
            }
            .padding(.bottom, 96)
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { width = g.size.width }
                .onChange(of: g.size.width) { width = g.size.width }
        })
    }

    private func header(columns: [SquadsColumn], wide: Bool) -> some View {
        HStack(spacing: 12) {
            sortHeader(tr("squads", "page.table.name"), .name).frame(minWidth: wide ? 200 : 120, maxWidth: .infinity, alignment: .leading)
            Text(tr("squads", "page.table.leader")).frame(width: SquadsTableLayout.leader, alignment: .leading)
            ForEach(columns, id: \.self) { c in
                Group {
                    switch c {
                    case .members: sortHeader(tr("squads", "page.table.members"), .members)
                    case .created: sortHeader(tr("squads", "page.table.created"), .created)
                    case .creator: Text(tr("squads", "page.table.creator"))
                    }
                }
                .frame(width: SquadsTableLayout.width(c), alignment: .leading)
            }
            Color.clear.frame(width: model.canManageAny ? SquadsTableLayout.kebab : 0)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func sortHeader(_ title: String, _ field: SquadsSortField) -> some View {
        Button { view.toggleSort(field) } label: {
            HStack(spacing: 3) {
                Text(title)
                if view.sortField == field {
                    Image(systemName: view.sortDirection == .asc ? "arrow.up" : "arrow.down").font(.system(size: 9, weight: .semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SquadsRow: View, Equatable {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let squad: Squad
    let columns: [SquadsColumn]
    let wide: Bool
    let showActions: Bool
    let canManage: Bool
    @State private var hovering = false

    nonisolated static func == (a: SquadsRow, b: SquadsRow) -> Bool {
        a.squad == b.squad && a.columns == b.columns && a.wide == b.wide && a.showActions == b.showActions && a.canManage == b.canManage
    }

    var body: some View {
        let _ = session.directory.revision
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                AvatarView(name: squad.name, url: squad.avatarUrl, kind: .squad, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(squad.name).font(Theme.Font.bodyMedium).lineLimit(1)
                    if !squad.description.isEmpty {
                        Text(squad.description).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(minWidth: wide ? 200 : 120, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                ActorAvatar(type: "agent", id: squad.leaderId, size: 18)
                Text(session.directory.agent(squad.leaderId)?.name ?? String(squad.leaderId.prefix(8)))
                    .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: SquadsTableLayout.leader, alignment: .leading)
            ForEach(columns, id: \.self) { c in
                cell(c).frame(width: SquadsTableLayout.width(c), alignment: .leading)
            }
            Group {
                if canManage {
                    SquadsRowActions(squad: squad).opacity(hovering ? 1 : 0)
                } else {
                    Color.clear
                }
            }
            .frame(width: showActions ? SquadsTableLayout.kebab : 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
        .background(hovering ? Theme.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { nav.push(.squad(squad.id), title: squad.name) }
        .contextMenu {
            Button(tr("common", "navigation.open_in_new_tab")) { nav.openInNewTab(.squad(squad.id), title: squad.name) }
        }
    }

    @ViewBuilder private func cell(_ c: SquadsColumn) -> some View {
        switch c {
        case .members:
            SquadsMemberStack(squad: squad)
        case .creator:
            HStack(spacing: 6) {
                ActorAvatar(type: "member", id: squad.creatorId, size: 18)
                Text(session.directory.member(userID: squad.creatorId)?.name ?? String(squad.creatorId.prefix(8)))
                    .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        case .created:
            Text(Formatters.date(squad.createdAt, style: .numeric))
                .font(Theme.Font.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// Up to three overlapping member avatars and a `+N` overflow chip.
struct SquadsMemberStack: View {
    let squad: Squad

    var body: some View {
        let preview = squad.memberPreview ?? []
        let count = SquadsListQuery.memberCount(squad)
        if count == 0 {
            Text("—").font(Theme.Font.caption).foregroundStyle(.tertiary)
        } else {
            let visible = Array(preview.prefix(3))
            HStack(spacing: -6) {
                ForEach(visible, id: \.memberId) { m in
                    ActorAvatar(type: m.memberType, id: m.memberId, size: 24)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                }
                if count - visible.count > 0 {
                    Text("+\(count - visible.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                }
            }
        }
    }
}

private struct SquadsRowActions: View {
    @Environment(Navigator.self) private var nav
    let squad: Squad
    @State private var confirmArchive = false

    var body: some View {
        Menu {
            Button { nav.openInNewTab(.squad(squad.id), title: squad.name) } label: {
                Label(tr("common", "navigation.open_in_new_tab"), systemImage: "arrow.up.right.square")
            }
            Divider()
            Button(role: .destructive) { confirmArchive = true } label: {
                Label(tr("squads", "page.archive_action"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("squads", "page.row_menu"))
        .squadsArchiveConfirmation(squad: squad, isPresented: $confirmArchive)
    }
}

extension View {
    /// Upstream archive (= delete) dialog; workspace admin or creator only.
    func squadsArchiveConfirmation(squad: Squad, isPresented: Binding<Bool>, onArchived: (() -> Void)? = nil) -> some View {
        modifier(SquadsArchiveConfirmation(squad: squad, isPresented: isPresented, onArchived: onArchived))
    }
}

private struct SquadsArchiveConfirmation: ViewModifier {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let squad: Squad
    @Binding var isPresented: Bool
    let onArchived: (() -> Void)?

    func body(content: Content) -> some View {
        content.alert(tr("squads", "archive_dialog.title"), isPresented: $isPresented) {
            Button(tr("squads", "archive_dialog.cancel"), role: .cancel) {}
            Button(tr("squads", "archive_dialog.confirm"), role: .destructive) {
                let id = squad.id
                Task {
                    do {
                        try await session.api.deleteSquad(id)
                        session.squads.remove(id)
                        toaster.success(tr("squads", "archive_dialog.success"))
                        onArchived?()
                    } catch {
                        let m = (error as? APIError)?.message ?? error.localizedDescription
                        toaster.error(m.isEmpty ? tr("squads", "toasts.archive_failed") : m)
                    }
                }
            }
        } message: {
            Text(tr("squads", "archive_dialog.description", ["name": squad.name]))
        }
    }
}

private struct SquadsLoadingRows: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 12) {
                    Circle().frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).frame(width: 128, height: 12)
                        RoundedRectangle(cornerRadius: 3).frame(width: 192, height: 10)
                    }
                    Spacer()
                    Circle().frame(width: 20, height: 20)
                    RoundedRectangle(cornerRadius: 3).frame(width: 64, height: 10)
                }
                .foregroundStyle(Color.primary.opacity(0.06))
                .padding(.horizontal, 12)
                .frame(height: 64)
                Divider()
            }
            Spacer()
        }
    }
}
