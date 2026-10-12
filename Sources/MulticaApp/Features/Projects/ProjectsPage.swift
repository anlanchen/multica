import MulticaCore
import SwiftUI

/// Derived list state, recomputed only when the catalog, pins, search or
/// view preferences change — never inside `body`.
@MainActor
@Observable
final class ProjectsListModel {
    private(set) var visible: [Project] = []
    private(set) var leadOptions: [ProjectsListQuery.LeadOption] = []
    private(set) var pinned: Set<String> = []
    private(set) var selected: Set<String> = []
    /// Selected rows among the visible ones (the batch toolbar's subject).
    private(set) var selectedRows: [Project] = []

    func recompute(_ items: [Project], search: String, view: ProjectsViewState) {
        let next = ProjectsListQuery.visible(items, search: search, filters: view.filters,
                                             sortField: view.sortField, direction: view.sortDirection)
        if next != visible { visible = next }
        let leads = ProjectsListQuery.leadOptions(items)
        if leads != leadOptions { leadOptions = leads }
        syncSelection()
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        syncSelection()
    }

    func toggleAll() {
        selected = selectedRows.count == visible.count ? [] : Set(visible.map(\.id))
        syncSelection()
    }

    func clearSelection() {
        selected.removeAll()
        syncSelection()
    }

    private func syncSelection() {
        let rows = visible.filter { selected.contains($0.id) }
        if rows != selectedRows { selectedRows = rows }
    }

    func setPins(_ pins: [PinnedItem]) {
        let next = Set(pins.filter { $0.itemType == "project" }.map(\.itemId))
        if next != pinned { pinned = next }
    }
}

/// Upstream `projects-page.tsx`.
struct ProjectsPage: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(ModalCenter.self) private var modals
    @State private var model = ProjectsListModel()
    @State private var view = ProjectsViewState()
    @State private var prefsSlug: String?
    @State private var search = ""

    private var prefsKey: String { "multica_projects_view:\(session.workspace.slug)" }

    var body: some View {
        let store = session.projects
        VStack(spacing: 0) {
            PageHeader {
                PageTitle(page: .projects, count: store.items.count)
            } trailing: {
                Button { modals.present(.createProject) } label: {
                    Label(tr("projects", "page.new_project"), systemImage: "plus")
                }
                .buttonStyle(PillButtonStyle())
            }
            if store.isLoaded && store.items.isEmpty {
                EmptyStateView(icon: "folder", title: tr("projects", "page.empty")) {
                    Button(tr("projects", "page.create_first")) { modals.present(.createProject) }
                }
            } else {
                ProjectsToolbar(view: $view, search: $search, leadOptions: model.leadOptions,
                                visibleCount: model.visible.count, totalCount: store.items.count)
                content
            }
        }
        .overlay(alignment: .bottom) {
            if !model.selectedRows.isEmpty {
                ProjectsBatchToolbar(rows: model.selectedRows, pinned: model.pinned, canDelete: session.projectsIsWorkspaceAdmin) {
                    model.clearSelection()
                }
                .padding(.bottom, 24)
            }
        }
        .task(id: session.workspace.slug) {
            if prefsSlug != session.workspace.slug {
                view = ProjectsDefaults.load(ProjectsViewState.self, key: prefsKey) ?? ProjectsViewState()
                prefsSlug = session.workspace.slug
            }
            model.recompute(store.items, search: search, view: view)
            model.setPins(session.pins.items)
            async let projects: Void = store.loadIfNeeded()
            async let pins: Void = session.pins.loadIfNeeded()
            _ = await (projects, pins)
        }
        .onChange(of: store.items) { model.recompute(store.items, search: search, view: view) }
        .onChange(of: search) { model.recompute(store.items, search: search, view: view) }
        .onChange(of: view) {
            model.recompute(store.items, search: search, view: view)
            if prefsSlug == session.workspace.slug { ProjectsDefaults.save(view, key: prefsKey) }
        }
        .onChange(of: session.pins.items) { model.setPins(session.pins.items) }
    }

    @ViewBuilder private var content: some View {
        if !session.projects.isLoaded {
            ProjectsLoadingState(compact: view.viewMode == .compact)
        } else if model.visible.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary)
                Text(tr("projects", "page.no_matches")).font(Theme.Font.body).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if view.viewMode == .compact {
            ProjectsTable(model: model, view: $view)
        } else {
            ProjectsCardGrid(rows: model.visible, pinned: model.pinned)
        }
    }
}

// MARK: - Toolbar

private struct ProjectsToolbar: View {
    @Environment(WorkspaceSession.self) private var session
    @Binding var view: ProjectsViewState
    @Binding var search: String
    let leadOptions: [ProjectsListQuery.LeadOption]
    let visibleCount: Int
    let totalCount: Int
    @State private var displayOpen = false

    var body: some View {
        let active = view.filters.activeCount
        HStack(spacing: 8) {
            SearchField(text: $search, prompt: tr("projects", "page.search_placeholder"))
                .frame(width: 224)
            if active > 0 || !search.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("\(visibleCount) / \(totalCount)")
                    .font(Theme.Font.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help(tr("projects", "toolbar.result_count_title"))
            }
            Spacer(minLength: 8)
            filterMenu(active: active)
            if active > 0 {
                Button { view.clearFilters() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(tr("projects", "toolbar.clear_filters"))
            }
            Button { displayOpen.toggle() } label: {
                Label(ProjectsLabels.sortField(view.sortField), systemImage: view.sortDirection == .asc ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(PillButtonStyle())
            .help(tr("projects", "toolbar.display"))
            .popover(isPresented: $displayOpen, arrowEdge: .bottom) { displayPanel }
            viewMenu
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func filterMenu(active: Int) -> some View {
        Menu {
            Menu(sectionTitle(tr("projects", "toolbar.section_status"), view.filters.statuses.count)) {
                ForEach(ProjectsConfig.statusOrder, id: \.self) { s in
                    Toggle(ProjectsLabels.status(s), isOn: binding(\.statuses, s))
                }
            }
            Menu(sectionTitle(tr("projects", "toolbar.section_priority"), view.filters.priorities.count)) {
                ForEach(ProjectsConfig.priorityOrder, id: \.self) { p in
                    Toggle(ProjectsLabels.priority(p), isOn: binding(\.priorities, p))
                }
            }
            Menu(sectionTitle(tr("projects", "toolbar.section_lead"), view.filters.leads.count)) {
                ForEach(leadOptions) { o in
                    Toggle("\(session.actorInfo(type: o.type, id: o.id).name)    \(o.count)", isOn: binding(\.leads, o.value))
                }
            }
        } label: {
            Label(active > 0 ? tr("projects", "toolbar.filter_active_count", ["count": active]) : tr("projects", "toolbar.filter_label"),
                  systemImage: "line.3.horizontal.decrease")
                .foregroundStyle(active > 0 ? Theme.brand : .primary)
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle(active: active > 0))
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func sectionTitle(_ title: String, _ n: Int) -> String { n > 0 ? "\(title)  \(n)" : title }

    private func binding(_ key: WritableKeyPath<ProjectsFilters, [String]>, _ value: String) -> Binding<Bool> {
        Binding(get: { view.filters[keyPath: key].contains(value) }, set: { _ in view.toggleFilter(key, value) })
    }

    private var displayPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("projects", "toolbar.sort_by")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { view.sortField }, set: { view.setSortField($0) })) {
                        ForEach(ProjectsSortField.allCases, id: \.self) { f in Text(ProjectsLabels.sortField(f)).tag(f) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    Button { view.sortDirection = view.sortDirection.toggled } label: {
                        Image(systemName: view.sortDirection == .asc ? "arrow.up" : "arrow.down")
                    }
                    .help(view.sortDirection == .asc ? tr("projects", "toolbar.direction_asc") : tr("projects", "toolbar.direction_desc"))
                }
            }
            .padding(12)
            if view.viewMode == .compact {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("projects", "toolbar.section_columns")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(ProjectsColumn.allCases, id: \.self) { c in
                        Toggle(ProjectsLabels.column(c), isOn: Binding(get: { view.isVisible(c) }, set: { _ in view.toggleColumn(c) }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(Theme.Font.body)
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 256)
    }

    private var viewMenu: some View {
        Menu {
            Picker(tr("projects", "toolbar.view"), selection: $view.viewMode) {
                Label(tr("projects", "page.view_table"), systemImage: "list.bullet").tag(ProjectsViewMode.compact)
                Label(tr("projects", "page.view_cards"), systemImage: "square.grid.2x2").tag(ProjectsViewMode.comfortable)
            }
            .pickerStyle(.inline)
        } label: {
            Label(view.viewMode == .compact ? tr("projects", "page.view_table") : tr("projects", "page.view_cards"),
                  systemImage: view.viewMode == .compact ? "list.bullet" : "square.grid.2x2")
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("projects", "toolbar.view"))
    }
}

// MARK: - Table

private enum ProjectsTableLayout {
    static let wideBreakpoint: CGFloat = 672
    static let edge: CGFloat = 12
    static let gap: CGFloat = 12
    static let checkbox: CGFloat = 16
    static let status: CGFloat = 116
    static let kebab: CGFloat = 28

    static func width(_ c: ProjectsColumn) -> CGFloat {
        switch c {
        case .priority: return 116
        case .progress: return 88
        case .lead: return 132
        case .issues: return 80
        case .created: return 104
        }
    }
}

private struct ProjectsTable: View {
    @Environment(WorkspaceSession.self) private var session
    let model: ProjectsListModel
    @Binding var view: ProjectsViewState
    @State private var width: CGFloat = 1000

    var body: some View {
        let wide = width >= ProjectsTableLayout.wideBreakpoint
        let columns = wide ? ProjectsColumn.allCases.filter { view.isVisible($0) } : []
        let canDelete = session.projectsIsWorkspaceAdmin
        let rows = model.visible
        let selectedCount = model.selectedRows.count
        ScrollView([.vertical]) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(rows) { p in
                        ProjectsTableRow(project: p, pinned: model.pinned.contains(p.id), selected: model.selected.contains(p.id),
                                         canDelete: canDelete, columns: columns, wide: wide) {
                            model.toggle(p.id)
                        }
                        .equatable()
                        Divider().padding(.leading, ProjectsTableLayout.edge)
                    }
                } header: {
                    header(columns: columns, wide: wide, allSelected: selectedCount == rows.count && !rows.isEmpty,
                           someSelected: selectedCount > 0)
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

    private func header(columns: [ProjectsColumn], wide: Bool, allSelected: Bool, someSelected: Bool) -> some View {
        HStack(spacing: ProjectsTableLayout.gap) {
            Button {
                model.toggleAll()
            } label: {
                ProjectsCheckbox(state: allSelected ? .on : (someSelected ? .mixed : .off))
            }
            .buttonStyle(.plain)
            .frame(width: ProjectsTableLayout.checkbox)
            .opacity(someSelected ? 1 : 0.35)
            sortHeader(tr("projects", "table.name"), .name).frame(minWidth: wide ? 200 : 120, maxWidth: .infinity, alignment: .leading)
            sortHeader(tr("projects", "table.status"), .status).frame(width: ProjectsTableLayout.status, alignment: .leading)
            ForEach(columns, id: \.self) { c in
                Group {
                    switch c {
                    case .priority: sortHeader(ProjectsLabels.column(c), .priority)
                    case .progress: sortHeader(ProjectsLabels.column(c), .progress)
                    case .created: sortHeader(ProjectsLabels.column(c), .created)
                    case .lead, .issues: Text(ProjectsLabels.column(c))
                    }
                }
                .frame(width: ProjectsTableLayout.width(c), alignment: c == .issues ? .trailing : .leading)
            }
            Color.clear.frame(width: ProjectsTableLayout.kebab)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, ProjectsTableLayout.edge)
        .frame(height: 32)
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func sortHeader(_ title: String, _ field: ProjectsSortField) -> some View {
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

struct ProjectsCheckbox: View {
    enum State { case on, off, mixed }
    let state: State

    var body: some View {
        Image(systemName: state == .on ? "checkmark.square.fill" : (state == .mixed ? "minus.square.fill" : "square"))
            .font(.system(size: 13))
            .foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.brand))
    }
}

private struct ProjectsTableRow: View, Equatable {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let project: Project
    let pinned: Bool
    let selected: Bool
    let canDelete: Bool
    let columns: [ProjectsColumn]
    let wide: Bool
    let onToggleSelect: () -> Void
    @State private var hovering = false

    nonisolated static func == (a: ProjectsTableRow, b: ProjectsTableRow) -> Bool {
        a.project == b.project && a.pinned == b.pinned && a.selected == b.selected
            && a.canDelete == b.canDelete && a.columns == b.columns && a.wide == b.wide
    }

    var body: some View {
        HStack(spacing: ProjectsTableLayout.gap) {
            Button(action: onToggleSelect) { ProjectsCheckbox(state: selected ? .on : .off) }
                .buttonStyle(.plain)
                .frame(width: ProjectsTableLayout.checkbox)
                .opacity(selected || hovering ? 1 : 0)
            HStack(spacing: 8) {
                ProjectIconView(icon: project.icon, size: 14)
                Text(project.title).font(Theme.Font.bodyMedium).lineLimit(1)
            }
            .frame(minWidth: wide ? 200 : 120, maxWidth: .infinity, alignment: .leading)
            ProjectsStatusBadge(status: project.status) { update(ProjectsPatch(status: $0)) }
                .frame(width: ProjectsTableLayout.status, alignment: .leading)
            ForEach(columns, id: \.self) { c in
                cell(c).frame(width: ProjectsTableLayout.width(c), alignment: c == .issues ? .trailing : .leading)
            }
            ProjectsRowActions(project: project, pinned: pinned, canDelete: canDelete)
                .frame(width: ProjectsTableLayout.kebab)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, ProjectsTableLayout.edge)
        .frame(height: 44)
        .background(selected ? Theme.brand.opacity(0.08) : (hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { nav.push(.project(project.id), title: project.title) }
        .contextMenu {
            Button(tr("common", "navigation.open_in_new_tab")) { nav.openInNewTab(.project(project.id), title: project.title) }
        }
    }

    @ViewBuilder private func cell(_ c: ProjectsColumn) -> some View {
        switch c {
        case .priority:
            ProjectsPriorityBadge(priority: project.priority) { update(ProjectsPatch(priority: $0)) }
        case .progress:
            ProjectsProgressRing(project: project)
        case .lead:
            ProjectsLeadPicker(leadType: project.leadType, leadID: project.leadId, onChange: { update(ProjectsPatch(lead: .some($0))) }) { name in
                ProjectsLeadTrigger(leadType: project.leadType, leadID: project.leadId, name: name, emptyLabel: "—")
            }
        case .issues:
            Text("\(project.issueCount)").font(Theme.Font.mono).monospacedDigit().foregroundStyle(.secondary)
        case .created:
            Text(ProjectsLabels.relativeDate(project.createdAt)).font(Theme.Font.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func update(_ patch: ProjectsPatch) {
        let id = project.id
        Task {
            do { try await session.projectsUpdate(id, patch) } catch { toaster.error(error) }
        }
    }
}

// MARK: - Cards

private struct ProjectsCardGrid: View {
    @Environment(WorkspaceSession.self) private var session
    let rows: [Project]
    let pinned: Set<String>

    var body: some View {
        let canDelete = session.projectsIsWorkspaceAdmin
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                ForEach(rows) { p in
                    ProjectsCard(project: p, pinned: pinned.contains(p.id), canDelete: canDelete).equatable()
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.top, 16)
            .padding(.bottom, 96)
        }
    }
}

private struct ProjectsCard: View, Equatable {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let project: Project
    let pinned: Bool
    let canDelete: Bool
    @State private var hovering = false

    nonisolated static func == (a: ProjectsCard, b: ProjectsCard) -> Bool {
        a.project == b.project && a.pinned == b.pinned && a.canDelete == b.canDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button { nav.push(.project(project.id), title: project.title) } label: {
                        HStack(spacing: 8) {
                            ProjectIconView(icon: project.icon, size: 14)
                            Text(project.title).font(Theme.Font.bodyMedium).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    ProjectsRowActions(project: project, pinned: pinned, canDelete: canDelete)
                        .opacity(hovering ? 1 : 0)
                    ProjectsStatusBadge(status: project.status) { update(ProjectsPatch(status: $0)) }
                }
                HStack {
                    Spacer()
                    if project.issueCount > 0 {
                        ProjectsProgressRing(project: project, size: 16, font: Theme.Font.micro)
                    } else {
                        Text(tr("projects", "detail.no_issues_yet")).font(Theme.Font.micro).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            Divider()
            HStack {
                ProjectsLeadPicker(leadType: project.leadType, leadID: project.leadId, onChange: { update(ProjectsPatch(lead: .some($0))) }) { name in
                    ProjectsLeadTrigger(leadType: project.leadType, leadID: project.leadId, name: name,
                                        emptyLabel: tr("projects", "lead.no_lead"), avatarSize: 20, maxNameWidth: 60)
                }
                Spacer()
                ProjectsPriorityBadge(priority: project.priority) { update(ProjectsPatch(priority: $0)) }
                Text(ProjectsLabels.relativeDate(project.createdAt)).font(Theme.Font.micro).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(hovering ? Theme.brand.opacity(0.5) : Theme.border))
        .onHover { hovering = $0 }
        .contextMenu {
            Button(tr("common", "navigation.open_in_new_tab")) { nav.openInNewTab(.project(project.id), title: project.title) }
        }
    }

    private func update(_ patch: ProjectsPatch) {
        let id = project.id
        Task {
            do { try await session.projectsUpdate(id, patch) } catch { toaster.error(error) }
        }
    }
}

// MARK: - Batch toolbar, loading

private struct ProjectsBatchToolbar: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let rows: [Project]
    let pinned: Set<String>
    let canDelete: Bool
    let onClear: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(tr("projects", "page.selected", ["count": rows.count])).font(Theme.Font.bodyMedium)
                Button(action: onClear) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(tr("projects", "page.clear_selection"))
            }
            .padding(.trailing, 8)
            .overlay(alignment: .trailing) { Divider().frame(height: 16) }
            if rows.contains(where: { !pinned.contains($0.id) }) {
                Button {
                    let ids = rows.filter { !pinned.contains($0.id) }.map(\.id)
                    onClear()
                    Task {
                        for id in ids {
                            do { try await session.projectsSetPinned(id, true) } catch { toaster.error(error) }
                        }
                    }
                } label: { Label(tr("projects", "page.pin"), systemImage: "pin") }
                .buttonStyle(.borderless)
                .padding(.horizontal, 6)
            }
            if canDelete {
                Button(role: .destructive) { confirmDelete = true } label: { Label(tr("projects", "page.delete"), systemImage: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.destructive)
                    .padding(.horizontal, 6)
            }
        }
        .font(Theme.Font.body)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .projectsDeleteConfirmation(isPresented: $confirmDelete) {
            let ids = rows.map(\.id)
            onClear()
            Task {
                for id in ids {
                    do { try await session.projectsDelete(id) } catch { toaster.error(error) }
                }
            }
        }
    }
}

private struct ProjectsLoadingState: View {
    let compact: Bool

    var body: some View {
        ScrollView {
            if compact {
                VStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.06)).frame(height: 44)
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.top, 16)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                    ForEach(0..<8, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 4).frame(width: 32, height: 32)
                                RoundedRectangle(cornerRadius: 4).frame(height: 14)
                            }
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 4).frame(width: 64, height: 18)
                                RoundedRectangle(cornerRadius: 4).frame(width: 80, height: 18)
                            }
                        }
                        .foregroundStyle(Color.primary.opacity(0.06))
                        .padding(12)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.top, 16)
            }
        }
    }
}
