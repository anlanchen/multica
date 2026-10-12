import AppKit
import MulticaCore
import SwiftUI

/// The surface toolbar (upstream IssuesHeader / MyIssuesHeader): the view
/// bar on the left, agents-working chip and display controls on the right.
struct IssueListHeaderBar: View {
    @Bindable var model: IssueListSurfaceModel
    let config: IssueListHeaderConfig
    var showRefresh = true
    let onSaveView: (IssueListSaveTarget) -> Void
    @Environment(Navigator.self) private var nav

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let views = config.views, config.saveScope != nil {
                IssueListViewBar(
                    views: views,
                    builtins: config.builtins,
                    activeBuiltin: config.activeBuiltin,
                    activeView: model.activeView,
                    onSelectBuiltin: config.selectBuiltin,
                    onSelectView: { view in nav.setQuery("view", view?.id) },
                    onNewView: { onSaveView(IssueListSaveTarget(view: nil, fromDefinition: false)) },
                    onEditView: { onSaveView(IssueListSaveTarget(view: $0, fromDefinition: true)) }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                if model.state.agentRunningFilter {
                    Text(tr("issues", "agent_activity.filter_active_label"))
                        .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.trailing, 4)
                }
                if config.showWorkingChip {
                    IssueListWorkingChip(model: model)
                }
                IssueListDisplayControls(model: model, showViewToggle: config.showViewToggle, showDate: config.showDateFilter)
                if showRefresh { IssueListRefreshIndicator(active: model.isRefreshing) }
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

/// Fixed-width slot so appearing never shifts the controls; a short delay
/// keeps fast networks indicator-free.
struct IssueListRefreshIndicator: View {
    let active: Bool
    @State private var visible = false

    var body: some View {
        ZStack {
            if visible { ProgressView().controlSize(.mini) }
        }
        .frame(width: 16, height: 16)
        .task(id: active) {
            guard active else {
                visible = false
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { visible = true }
        }
    }
}

/// Bordered toolbar button matching upstream `Button variant=outline size=sm`.
struct IssueListToolbarButtonStyle: ButtonStyle {
    var active = false
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.caption)
            .foregroundStyle(prominent ? Color.white : (active ? Color.primary : Color.secondary))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .fill(prominent ? Theme.brand : (active ? Theme.selected : (configuration.isPressed ? Theme.hover : Color.clear)))
            )
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(prominent ? Color.clear : Theme.border))
            .contentShape(Rectangle())
    }
}

// MARK: - View bar

/// Built-in tabs and saved views as one flat, per-user ordered single row;
/// what does not fit collapses into a "more" popover (upstream view-bar.tsx).
struct IssueListViewBar: View {
    let views: IssueListViewsModel
    let builtins: [IssueListBarItem]
    let activeBuiltin: String?
    let activeView: IssueView?
    let onSelectBuiltin: (String) -> Void
    let onSelectView: (IssueView?) -> Void
    let onNewView: () -> Void
    let onEditView: (IssueView) -> Void

    @Environment(Toaster.self) private var toaster
    @State private var width: CGFloat = 0
    @State private var moreOpen = false
    @State private var manageOpen = false
    @State private var deleting: IssueView?

    private static let maxTab: CGFloat = 160
    private static let reserveMenu: CGFloat = 36
    private static let reserveMore: CGFloat = 36 + 32
    private static let reservePromoted: CGFloat = 36 + 200

    private var items: [IssueListBarItem] { views.items(builtins: builtins) }
    private var anchorID: String { builtins.first?.id ?? "" }

    private var arranged: (ordered: [IssueListBarItem], visible: [IssueListBarItem], hidden: Set<String>) {
        let all = items
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let r = IssueListViewBar_apply(all.map(\.id), views.prefs, anchorID)
        return (r.ordered.compactMap { byID[$0] }, r.visible.compactMap { byID[$0] }, r.hidden)
    }

    private static func tabWidth(_ label: String) -> CGFloat {
        let w = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
        return min(maxTab, ceil(w) + 20)
    }

    private func fitCount(_ visible: [IssueListBarItem]) -> Int {
        func fit(reserve: CGFloat) -> Int {
            var used: CGFloat = 0
            for (i, item) in visible.enumerated() {
                used += Self.tabWidth(item.label) + (i > 0 ? 4 : 0)
                if used > width - reserve { return i }
            }
            return visible.count
        }
        guard width > 0 else { return visible.count }
        let all = fit(reserve: Self.reserveMenu)
        if all == visible.count { return all }
        let withMore = fit(reserve: Self.reserveMore)
        if let active = activeView, visible.firstIndex(where: { $0.view?.id == active.id }).map({ $0 >= withMore }) == true {
            return fit(reserve: Self.reservePromoted)
        }
        return withMore
    }

    var body: some View {
        let arranged = arranged
        let visible = arranged.visible
        let n = fitCount(visible)
        let fitting = Array(visible.prefix(n))
        let overflowed = visible.dropFirst(n)
        let activeOverflowed = activeView.map { a in overflowed.contains { $0.view?.id == a.id } } ?? false
        HStack(spacing: 4) {
            ForEach(fitting) { item in
                tab(item)
                    .draggable(item.id)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let from = ids.first, from != item.id else { return false }
                        applyMove(from, over: item.id, arranged: arranged)
                        return true
                    }
            }
            if !overflowed.isEmpty {
                Button {
                    moreOpen.toggle()
                } label: {
                    if activeOverflowed, let active = activeView {
                        HStack(spacing: 4) {
                            Text(active.name).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .frame(maxWidth: Self.maxTab)
                    } else {
                        Image(systemName: "ellipsis")
                    }
                }
                .buttonStyle(IssueListToolbarButtonStyle(active: activeOverflowed))
                .help(tr("issues", "view_bar.more_label"))
                .popover(isPresented: $moreOpen, arrowEdge: .bottom) {
                    IssueListViewListPanel(
                        views: views, items: visible, fitCount: n, activeViewID: activeView?.id,
                        onMove: { from, to in
                            var ids = arranged.ordered.map(\.id)
                            ids.move(fromOffsets: from, toOffset: to)
                            views.savePrefs(hidden: Array(arranged.hidden), order: ids, known: Set(items.map(\.id)))
                        },
                        onSelect: { item in
                            moreOpen = false
                            select(item)
                        },
                        onEdit: { v in moreOpen = false; onEditView(v) },
                        onDelete: { v in moreOpen = false; deleting = v },
                        onHide: { id in moreOpen = false; toggleHidden(id, hidden: true, arranged: arranged) }
                    )
                }
            }
            Menu {
                Button { onNewView() } label: { Label(tr("issues", "view_bar.menu_new"), systemImage: "plus") }
                Button { manageOpen = true } label: { Label(tr("issues", "view_bar.menu_manage"), systemImage: "slider.horizontal.3") }
            } label: {
                Image(systemName: "square.3.layers.3d").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("issues", "view_bar.menu_label"))
            .padding(.leading, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { width = geo.size.width }
                .onChange(of: geo.size.width) { _, w in width = w }
        })
        .sheet(isPresented: $manageOpen) {
            IssueListManageViewsSheet(
                views: views, items: arranged.ordered, hidden: arranged.hidden, anchorID: anchorID,
                onReorder: { ids in views.savePrefs(hidden: Array(arranged.hidden), order: ids, known: Set(items.map(\.id))) },
                onToggleHidden: { id, hidden in toggleHidden(id, hidden: hidden, arranged: arranged) },
                onEdit: { v in
                    manageOpen = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onEditView(v) }
                },
                onDelete: { v in try await confirmDelete(v) }
            )
        }
        .alert(tr("issues", "view_bar.delete_title"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(tr("issues", "save_view.cancel"), role: .cancel) { deleting = nil }
            Button(tr("issues", "view_bar.delete"), role: .destructive) {
                guard let v = deleting else { return }
                deleting = nil
                Task {
                    do {
                        try await confirmDelete(v)
                        toaster.success(tr("issues", "view_bar.toast_deleted"))
                    } catch {
                        toaster.error(tr("issues", "save_view.toast_failed"))
                    }
                }
            }
        } message: {
            Text(tr("issues", "view_bar.delete_description", ["name": deleting?.name ?? ""]))
        }
    }

    @ViewBuilder
    private func tab(_ item: IssueListBarItem) -> some View {
        if let view = item.view {
            let active = activeView?.id == view.id
            Button { onSelectView(active ? nil : view) } label: {
                Text(item.label).lineLimit(1).truncationMode(.tail).frame(maxWidth: Self.maxTab - 20)
            }
            .buttonStyle(IssueListToolbarButtonStyle(active: active))
            .contextMenu {
                Button { onEditView(view) } label: { Label(tr("issues", "view_bar.context_edit"), systemImage: "pencil") }
                    .disabled(!item.canManage)
                if item.canManage {
                    Button(role: .destructive) { deleting = view } label: { Label(tr("issues", "view_bar.delete"), systemImage: "trash") }
                }
                Divider()
                let pinned = views.isPinned(view)
                Button { views.togglePin(view) } label: {
                    Label(pinned ? tr("issues", "view_bar.context_unpin") : tr("issues", "view_bar.context_pin"),
                          systemImage: pinned ? "pin.slash" : "pin")
                }
            }
        } else {
            let active = activeBuiltin == item.id
            Button { onSelectBuiltin(item.id) } label: {
                Text(item.label).lineLimit(1).frame(maxWidth: Self.maxTab - 20)
            }
            .buttonStyle(IssueListToolbarButtonStyle(active: active))
            .help(item.description ?? "")
        }
    }

    private func select(_ item: IssueListBarItem) {
        if let v = item.view { onSelectView(v) } else { onSelectBuiltin(item.id) }
    }

    private func applyMove(_ from: String, over: String, arranged: (ordered: [IssueListBarItem], visible: [IssueListBarItem], hidden: Set<String>)) {
        var ids = arranged.ordered.map(\.id)
        guard let a = ids.firstIndex(of: from), let b = ids.firstIndex(of: over) else { return }
        let moved = ids.remove(at: a)
        ids.insert(moved, at: b)
        views.savePrefs(hidden: Array(arranged.hidden), order: ids, known: Set(items.map(\.id)))
    }

    /// Hiding the open view exits it.
    private func toggleHidden(_ id: String, hidden: Bool, arranged: (ordered: [IssueListBarItem], visible: [IssueListBarItem], hidden: Set<String>)) {
        var next = arranged.hidden
        if hidden { next.insert(id) } else { next.remove(id) }
        views.savePrefs(hidden: Array(next), order: arranged.ordered.map(\.id), known: Set(items.map(\.id)))
        if hidden, let active = activeView, id == "view:\(active.id)" { onSelectView(nil) }
    }

    private func confirmDelete(_ view: IssueView) async throws {
        try await views.delete(view)
        if activeView?.id == view.id { onSelectView(nil) }
    }
}

private func IssueListViewBar_apply(_ ids: [String], _ prefs: IssueViewPreference.Prefs, _ anchor: String) -> (ordered: [String], visible: [String], hidden: Set<String>) {
    IssueListBarPrefs.apply(itemIDs: ids, hidden: prefs.hidden, order: prefs.order, anchorID: anchor)
}

/// Every bar item in order, drag to reorder; a separator marks the fold.
private struct IssueListViewListPanel: View {
    let views: IssueListViewsModel
    let items: [IssueListBarItem]
    let fitCount: Int
    let activeViewID: String?
    let onMove: (IndexSet, Int) -> Void
    let onSelect: (IssueListBarItem) -> Void
    let onEdit: (IssueView) -> Void
    let onDelete: (IssueView) -> Void
    let onHide: (String) -> Void

    var body: some View {
        List {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(spacing: 0) {
                    if index == fitCount && index > 0 { Divider().padding(.bottom, 4) }
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.tertiary)
                            .help(tr("issues", "view_bar.drag_handle"))
                        Button { onSelect(item) } label: {
                            HStack(spacing: 6) {
                                Text(item.label).lineLimit(1)
                                    .fontWeight(item.view?.id == activeViewID && activeViewID != nil ? .medium : .regular)
                                if item.isBuiltin {
                                    Text(tr("issues", "view_bar.builtin_tag")).font(Theme.Font.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if let view = item.view {
                            Menu {
                                Button { onEdit(view) } label: { Label(tr("issues", "view_bar.context_edit"), systemImage: "pencil") }
                                    .disabled(!item.canManage)
                                if item.canManage {
                                    Button(role: .destructive) { onDelete(view) } label: { Label(tr("issues", "view_bar.delete"), systemImage: "trash") }
                                }
                                let pinned = views.isPinned(view)
                                Button { views.togglePin(view) } label: {
                                    Label(pinned ? tr("issues", "view_bar.context_unpin") : tr("issues", "view_bar.context_pin"),
                                          systemImage: pinned ? "pin.slash" : "pin")
                                }
                                Divider()
                                Button { onHide(item.id) } label: { Label(tr("issues", "view_bar.row_hide"), systemImage: "eye.slash") }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help(tr("issues", "view_bar.row_menu"))
                        }
                    }
                    .font(Theme.Font.body)
                    .padding(.vertical, 2)
                }
            }
            .onMove(perform: onMove)
        }
        .listStyle(.plain)
        .frame(width: 256, height: min(384, CGFloat(items.count) * 30 + 16))
    }
}

// MARK: - Agents working chip

/// The agents-working filter chip; its count is the surface-scoped
/// `working_agents` facet (nil = not resolved, shown indeterminate).
struct IssueListWorkingChip: View {
    @Bindable var model: IssueListSurfaceModel
    @State private var hoverOpen = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        let agents = model.workingAgents
        let on = model.state.agentRunningFilter
        let label = agents == nil
            ? tr("issues", "agent_activity.chip_agents_working_unknown")
            : tr("issues", "agent_activity.chip_agents_working", ["count": agents!.count])
        Button {
            model.state.agentRunningFilter.toggle()
        } label: {
            HStack(spacing: 5) {
                if let agents, !agents.isEmpty {
                    IssueListAvatarStack(refs: agents.prefix(3).map { ActorRef(type: "agent", id: $0.id) }, size: 14)
                }
                Text(label).monospacedDigit().lineLimit(1)
            }
        }
        .buttonStyle(IssueListChipButtonStyle(on: on, some: (agents?.isEmpty == false), unknown: agents == nil))
        .accessibilityLabel(label)
        .onHover { inside in
            hoverTask?.cancel()
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(inside ? 400 : 200))
                if !Task.isCancelled { hoverOpen = inside }
            }
        }
        .popover(isPresented: $hoverOpen, arrowEdge: .bottom) {
            IssueListWorkingAgentsHover(agents: agents)
                .padding(12)
                .frame(width: 280, alignment: .leading)
        }
    }
}

private struct IssueListChipButtonStyle: ButtonStyle {
    let on: Bool
    let some: Bool
    let unknown: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.caption)
            .foregroundStyle(on ? Color.white : (some ? Theme.brand : (unknown ? Color.primary : Color.secondary)))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .fill(on ? Theme.brand : (some ? Theme.brand.opacity(0.1) : (configuration.isPressed ? Theme.hover : .clear))))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(on || some ? Color.clear : Theme.border))
            .contentShape(Rectangle())
    }
}

/// Hover body for the working-agents projection.
struct IssueListWorkingAgentsHover: View {
    let agents: [IssueListWorkingAgent]?
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        if let agents {
            if agents.isEmpty {
                Text(tr("issues", "agent_activity.empty_hover")).font(Theme.Font.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("issues", "agent_activity.hover_header", ["count": agents.count]))
                        .font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(agents) { a in
                        HStack(spacing: 8) {
                            ActorAvatar(type: "agent", id: a.id, size: 18)
                            Text(session.actorInfo(type: "agent", id: a.id).name).font(Theme.Font.caption.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(tr("issues", "agent_activity.tasks_count", ["count": a.runningTaskCount]))
                                .font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        } else {
            Text(tr("issues", "agent_activity.unknown_hover")).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
    }
}

/// Overlapping avatars with a background ring (`AgentAvatarStack`).
struct IssueListAvatarStack: View {
    let refs: [ActorRef]
    var size: CGFloat = 16
    var dimmed = false

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
                ActorAvatar(type: ref.type, id: ref.id, size: size)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            }
        }
        .opacity(dimmed ? 0.5 : 1)
    }
}

// MARK: - Display controls

/// Filter, table grouping/columns, display settings and the view toggle.
struct IssueListDisplayControls: View {
    @Bindable var model: IssueListSurfaceModel
    var showViewToggle = true
    var showDate = false
    @State private var filterOpen = false
    @State private var displayOpen = false
    @State private var columnsOpen = false

    var body: some View {
        let count = model.state.activeFilterCount(baseline: model.baseline, activePropertyIDs: model.activePropertyIDs, includeDate: showDate)
        HStack(spacing: 4) {
            Button { filterOpen.toggle() } label: {
                Label(count > 0 ? tr("issues", "filters.active_count", ["count": count]) : tr("issues", "filters.tooltip"),
                      systemImage: "line.3.horizontal.decrease")
            }
            .buttonStyle(IssueListToolbarButtonStyle(prominent: count > 0))
            .help(tr("issues", "filters.tooltip"))
            .popover(isPresented: $filterOpen, arrowEdge: .bottom) {
                IssueListFilterMenu(state: $model.state, model: model, baseline: model.baseline,
                                    showCounts: model.viewMode != .gantt, showDate: showDate, onFacet: { model.setActiveFacet($0) })
            }
            .onChange(of: filterOpen) { _, open in if !open { model.setActiveFacet(nil) } }

            if model.viewMode == .table {
                Menu {
                    Picker("", selection: $model.state.tableGrouping) {
                        Text(tr("issues", "table.group_none")).tag("none")
                        Text(tr("issues", "table.columns.status")).tag("status")
                        Text(tr("issues", "table.columns.assignee")).tag("assignee")
                        Text(tr("issues", "table.columns.project")).tag("project")
                        ForEach(model.activeProperties.filter { ["select", "checkbox"].contains($0.type) }) { p in
                            Text(p.name).tag("property:\(p.id)")
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label(tableGroupLabel, systemImage: "rectangle.grid.1x2")
                }
                .menuStyle(.button)
                .buttonStyle(IssueListToolbarButtonStyle())
                .fixedSize()

                Button { columnsOpen.toggle() } label: {
                    Label(tr("issues", "table.columns.section"), systemImage: "rectangle.split.3x1")
                }
                .buttonStyle(IssueListToolbarButtonStyle())
                .popover(isPresented: $columnsOpen, arrowEdge: .bottom) {
                    IssueListColumnPicker(model: model)
                }
            }

            Button { displayOpen.toggle() } label: {
                Label(tr("issues", "display.button"), systemImage: "slider.horizontal.3")
            }
            .buttonStyle(IssueListToolbarButtonStyle())
            .help(tr("issues", "display.tooltip"))
            .popover(isPresented: $displayOpen, arrowEdge: .bottom) {
                IssueListDisplayPopover(state: $model.state, model: model, mode: model.viewMode)
                    .padding(12)
                    .frame(width: 288)
            }

            if showViewToggle {
                Menu {
                    Section(tr("issues", "view.section")) {
                        ForEach(model.modes.filter { $0 != .gantt || model.allowGantt }, id: \.self) { mode in
                            Button {
                                model.state.setViewMode(mode)
                            } label: {
                                Label(Self.title(mode), systemImage: Self.icon(mode))
                                if model.viewMode == mode { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Label(Self.title(model.viewMode), systemImage: Self.icon(model.viewMode))
                }
                .menuStyle(.button)
                .buttonStyle(IssueListToolbarButtonStyle())
                .fixedSize()
                .help(tr("issues", "view.tooltip_\(model.viewMode.rawValue)"))
            }
        }
        .labelStyle(.titleAndIcon)
    }

    private var tableGroupLabel: String {
        let g = model.state.tableGrouping
        if let pid = IssueListOptions.propertyID(fromKey: g) {
            guard let p = model.property(pid) else { return tr("issues", "table.group_label") }
            return tr("issues", "table.group_active", ["group": p.name])
        }
        switch g {
        case "status", "assignee", "project": return tr("issues", "table.group_active", ["group": tr("issues", "table.columns.\(g)")])
        default: return tr("issues", "table.group_label")
        }
    }

    static func title(_ mode: IssueListViewMode) -> String { tr("issues", "view.\(mode.rawValue)") }

    static func icon(_ mode: IssueListViewMode) -> String {
        switch mode {
        case .board: return "rectangle.split.3x1"
        case .list: return "list.bullet"
        case .table: return "tablecells"
        case .swimlane: return "water.waves"
        case .gantt: return "chart.bar.xaxis"
        }
    }
}
