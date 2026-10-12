import AppKit
import MulticaCore
import Observation
import SwiftUI

/// Derived rows for the agents list. Presence/activity maps rebuild only when
/// their inputs move; filtering and sorting only when the view state or the
/// maps do — never inside `body`.
@MainActor
@Observable
final class AgentsUIListModel {
    struct DataInputs: Equatable {
        var agents: [AgentRecord]
        var runtimes: [RuntimeDeviceRecord]
        var snapshot: [AgentTaskRecord]
        var activity: [AgentActivityBucket]
        var runCounts: [String: Int]
        var userID: String
        var isAdmin: Bool
        var tick: Int
    }

    struct ViewInputs: Equatable {
        var state: AgentsUI.ViewState
        var search: String
    }

    private(set) var scopeRows: [AgentsUI.ListRow] = []
    private(set) var rows: [AgentsUI.ListRow] = []
    private(set) var scopeCounts = AgentsUI.ScopeCounts()
    private(set) var totalActive = 0

    @ObservationIgnored private var data: DataInputs?
    @ObservationIgnored private var view: ViewInputs?
    @ObservationIgnored private var presence: [String: AgentsUI.Presence] = [:]
    @ObservationIgnored private var activity: [String: AgentsUI.Activity] = [:]

    func update(data newData: DataInputs, view newView: ViewInputs) {
        let dataChanged = newData != data
        let viewChanged = newView != view
        guard dataChanged || viewChanged else { return }
        if dataChanged {
            let now = Date()
            presence = AgentsUI.presenceMap(agents: newData.agents, runtimes: newData.runtimes, snapshot: newData.snapshot, now: now)
            activity = AgentsUI.activityMap(agents: newData.agents, buckets: newData.activity, now: now)
            scopeCounts = AgentsUI.scopeCounts(newData.agents, userID: newData.userID)
            totalActive = newData.agents.filter { $0.archivedAt == nil }.count
        }
        let runtimesByID = Dictionary(newData.runtimes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        scopeRows = newData.agents.filter { AgentsUI.inScope($0, scope: newView.state.scope, userID: newData.userID) }.map { a in
            let act = activity[a.id]
            let mine = a.ownerId == newData.userID
            return AgentsUI.ListRow(agent: a, runtime: runtimesByID[a.runtimeId], presence: presence[a.id], activity: act,
                                    runCount: newData.runCounts[a.id] ?? 0, lastActiveDays: AgentsUI.lastActiveDaysAgo(act),
                                    isOwnedByMe: mine, canManage: newData.isAdmin || mine)
        }
        let filtered = scopeRows.filter {
            AgentsUI.rowMatches($0, filters: newView.state.filters, query: newView.search, latinize: AgentsUILatin.latin)
        }
        rows = AgentsUI.sortRows(filtered, field: newView.state.sortField, direction: newView.state.sortDirection)
        data = newData
        view = newView
    }
}

/// Column widths (upstream COLUMN_WIDTHS); name flexes from 200.
enum AgentsUIColumns {
    static func width(_ c: AgentsUI.Column) -> CGFloat {
        switch c {
        case .status: return 144
        case .owner: return 144
        case .access: return 132
        case .runtime: return 144
        case .lastActive: return 120
        case .runs: return 88
        case .model: return 120
        case .created: return 104
        }
    }

    static func minWidth(_ visible: [AgentsUI.Column]) -> CGFloat {
        268 + 11 * 12 + visible.reduce(0) { $0 + width($1) }
    }
}

struct AgentsUIListPage: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster

    @State private var model = AgentsUIListModel()
    @State private var viewState = AgentsUI.ViewState()
    @State private var loadedState = false
    @State private var search = ""
    @State private var selected: Set<String> = []
    @State private var tick = 0

    private var store: AgentsUIStore { session.agentsUIStore }
    private var stateKey: String { "multica.agents.view.\(session.workspace.id)" }

    var body: some View {
        let agents = session.agentRecords
        VStack(spacing: 0) {
            header
            if let error = agents.error, !agents.isLoaded {
                ErrorStateView(message: tr("agents", "page.list_load_failed") + "\n" + error) {
                    Task { await agents.load() }
                }
            } else if !agents.isLoaded || (!agents.items.isEmpty && !listReady) {
                AgentsUIListSkeleton()
            } else if agents.items.isEmpty {
                EmptyStateView(icon: "cpu", title: tr("agents", "empty.title"), message: tr("agents", "empty.description")) {
                    Button { nav.push(.newAgent) } label: { Label(tr("agents", "page.new_agent"), systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                AgentsUIListToolbar(state: $viewState, search: $search, model: model)
                AgentsUIListGrid(model: model, state: $viewState, selected: $selected, noMatchText: noMatchText)
            }
        }
        .overlay(alignment: .bottom) {
            AgentsUIBatchToolbar(rows: model.rows.filter { selected.contains($0.id) }) { selected.removeAll() }
        }
        .tabTitle(tr("agents", "page.title"))
        .onAppear(perform: restoreState)
        .onChange(of: viewState) { saveState() }
        .task {
            async let a: Void = session.agentRecords.loadIfNeeded()
            async let r: Void = session.runtimeRecords.loadIfNeeded()
            async let p: Void = store.loadProjectionsIfNeeded()
            _ = await (a, r, p)
        }
        .task(id: session.agentsUISyncKey) { session.agentsUISync() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                tick &+= 1
            }
        }
        .onChange(of: dataInputs, initial: true) { model.update(data: dataInputs, view: viewInputs) }
        .onChange(of: viewInputs) { model.update(data: dataInputs, view: viewInputs) }
    }

    private var dataInputs: AgentsUIListModel.DataInputs {
        AgentsUIListModel.DataInputs(agents: session.agentRecords.items, runtimes: session.runtimeRecords.items,
                                     snapshot: store.snapshot, activity: store.activityBuckets, runCounts: store.runCounts,
                                     userID: session.currentUser.id, isAdmin: session.agentsUIIsAdmin, tick: tick)
    }

    private var viewInputs: AgentsUIListModel.ViewInputs {
        AgentsUIListModel.ViewInputs(state: viewState, search: search)
    }

    /// Defers the first paint until the auxiliary data the current sort or
    /// availability filter reads has landed, so rows never visibly re-order.
    private var listReady: Bool {
        let needsRunCounts = viewState.sortField == .lastActive || viewState.sortField == .runs
        let needsActivity = viewState.sortField == .lastActive
        let needsPresence = !viewState.filters.availability.isEmpty
        return (!needsActivity || store.activityLoaded) && (!needsRunCounts || store.runCountsLoaded)
            && (!needsPresence || (store.snapshotLoaded && session.runtimeRecords.isLoaded))
    }

    private var noMatchText: String {
        let q = search.trimmingCharacters(in: .whitespaces)
        let filtered = viewState.filters.activeDimensionCount > 0
        if !q.isEmpty {
            if viewState.scope == .archived { return tr("agents", "no_matches.search_archived", ["query": q]) }
            return filtered ? tr("agents", "no_matches.search_active_filtered", ["query": q]) : tr("agents", "no_matches.search_active", ["query": q])
        }
        if viewState.scope == .archived { return tr("agents", "no_matches.no_archived") }
        return filtered ? tr("agents", "no_matches.no_filter_match") : tr("agents", "no_matches.title")
    }

    private var header: some View {
        PageHeader {
            HStack(spacing: 8) {
                Image(systemName: "cpu").foregroundStyle(.secondary)
                Text(tr("agents", "page.title")).font(Theme.Font.bodyMedium)
                Text("\(model.totalActive)").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(tr("agents", "page.tagline")).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 6)
            }
        } trailing: {
            Link(tr("agents", "page.learn_more"), destination: docsURL)
                .font(Theme.Font.caption)
            Button { nav.push(.newAgent) } label: { Label(tr("agents", "page.new_agent"), systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private var docsURL: URL {
        let lang = L10n.shared.language
        let prefix = ["zh", "ja", "ko", "fr"].first { lang.hasPrefix($0) }.map { "/\($0)" } ?? ""
        return URL(string: "https://multica.ai/docs\(prefix)/agents")!
    }

    private func restoreState() {
        guard !loadedState else { return }
        loadedState = true
        if let data = UserDefaults.standard.data(forKey: stateKey),
           let s = try? JSONDecoder().decode(AgentsUI.ViewState.self, from: data) {
            viewState = s
        }
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(viewState) { UserDefaults.standard.set(data, forKey: stateKey) }
    }
}

// MARK: - Toolbar

struct AgentsUIFilterOption: Identifiable, Hashable {
    var id: String
    var name: String
    var count: Int
}

struct AgentsUIListToolbar: View {
    @Environment(WorkspaceSession.self) private var session
    @Binding var state: AgentsUI.ViewState
    @Binding var search: String
    let model: AgentsUIListModel
    @State private var displayOpen = false

    var body: some View {
        let active = state.filters.activeDimensionCount
        HStack(spacing: 8) {
            SearchField(text: $search, prompt: tr("agents", "page.search_placeholder"))
                .frame(width: 224)
            HStack(spacing: 4) {
                ForEach(AgentsUI.ListScope.allCases, id: \.self) { s in
                    Button { state.setScope(s) } label: {
                        HStack(spacing: 5) {
                            Text(tr("agents", "scope.\(s.rawValue)"))
                            Text("\(model.scopeCounts[s])").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .buttonStyle(PillButtonStyle(active: state.scope == s))
                }
            }
            if active > 0 || !search.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("\(model.rows.count) / \(model.scopeRows.count)")
                    .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help(tr("agents", "toolbar.result_count_title"))
            }
            Spacer(minLength: 8)
            filterMenu(active: active)
            if active > 0 {
                Button { state.clearFilters() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(tr("agents", "toolbar.clear_filters"))
            }
            Button { displayOpen.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: state.sortDirection == .asc ? "arrow.up" : "arrow.down")
                    Text(sortLabel(state.sortField))
                }
            }
            .buttonStyle(PillButtonStyle())
            .help(tr("agents", "toolbar.display"))
            .popover(isPresented: $displayOpen, arrowEdge: .bottom) { displayPanel }
        }
        .padding(.horizontal, Theme.Spacing.page)
        .frame(height: 48)
    }

    private func sortLabel(_ f: AgentsUI.SortField) -> String {
        switch f {
        case .lastActive: return tr("agents", "columns.last_active")
        case .name: return tr("agents", "columns.agent")
        case .runs: return tr("agents", "columns.runs")
        case .created: return tr("agents", "columns.created")
        }
    }

    static func columnLabel(_ c: AgentsUI.Column) -> String {
        switch c {
        case .lastActive: return tr("agents", "columns.last_active")
        default: return tr("agents", "columns.\(c.rawValue)")
        }
    }

    static func accessLabel(_ scope: AgentsUI.AccessScope) -> String {
        switch scope {
        case .workspace: return tr("agents", "access.scope_labels.workspace")
        case .specificPeople: return tr("agents", "access.scope_labels.specific_people")
        case .ownerOnly: return tr("agents", "access.scope_labels.owner_only")
        }
    }

    private func filterMenu(active: Int) -> some View {
        let rows = model.scopeRows
        var availability: [String: Int] = [:]
        var runtimes: [AgentsUIFilterOption] = []
        var access: [String: Int] = [:]
        var owners: [AgentsUIFilterOption] = []
        var models: [AgentsUIFilterOption] = []
        for r in rows {
            if let p = r.presence { availability[p.availability.rawValue, default: 0] += 1 }
            if let rt = r.runtime {
                if let i = runtimes.firstIndex(where: { $0.id == rt.id }) { runtimes[i].count += 1 }
                else { runtimes.append(AgentsUIFilterOption(id: rt.id, name: AgentsUI.runtimeDisplayLabel(rt), count: 1)) }
            }
            access[r.accessScope.rawValue, default: 0] += 1
            if let o = r.agent.ownerId {
                if let i = owners.firstIndex(where: { $0.id == o }) { owners[i].count += 1 } else { owners.append(AgentsUIFilterOption(id: o, name: o, count: 1)) }
            }
            if !r.agent.model.isEmpty {
                if let i = models.firstIndex(where: { $0.id == r.agent.model }) { models[i].count += 1 } else {
                    models.append(AgentsUIFilterOption(id: r.agent.model, name: r.agent.model, count: 1))
                }
            }
        }
        func item(_ key: AgentsUI.FilterKey, _ value: String, _ label: String, _ count: Int) -> some View {
            Toggle(isOn: Binding(get: { state.filters[key].contains(value) }, set: { _ in state.toggleFilter(key, value) })) {
                Text("\(label)    \(count)")
            }
        }
        func section(_ key: AgentsUI.FilterKey, _ titleKey: String) -> String {
            let n = state.filters[key].count
            return tr("agents", titleKey) + (n > 0 ? "  (\(n))" : "")
        }
        return Menu {
            Menu(section(.availability, "toolbar.section_availability")) {
                ForEach(AgentsUI.Availability.filterOrder, id: \.self) { a in
                    item(.availability, a.rawValue, a.label, availability[a.rawValue] ?? 0)
                }
            }
            Menu(section(.access, "toolbar.section_access")) {
                ForEach(AgentsUI.AccessScope.allCases, id: \.self) { s in
                    item(.access, s.rawValue, Self.accessLabel(s), access[s.rawValue] ?? 0)
                }
            }
            Menu(section(.runtimes, "toolbar.section_runtime")) {
                ForEach(runtimes) { r in item(.runtimes, r.id, r.name, r.count) }
            }
            Menu(section(.owners, "toolbar.section_owner")) {
                ForEach(owners) { o in
                    item(.owners, o.id, session.directory.member(userID: o.id)?.name ?? String(o.id.prefix(8)), o.count)
                }
            }
            if !models.isEmpty {
                Menu(section(.models, "toolbar.section_model")) {
                    ForEach(models) { m in item(.models, m.id, m.name, m.count) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(active > 0 ? tr("agents", "toolbar.filter_active_count", ["count": active]) : tr("agents", "toolbar.filter_label"))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(active > 0 ? Theme.brand.opacity(0.15) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(active > 0 ? Theme.brand.opacity(0.5) : Theme.border))
    }

    private var displayPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("agents", "toolbar.sort_by")).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { state.sortField }, set: { state.setSortField($0) })) {
                        ForEach(AgentsUI.SortField.allCases, id: \.self) { f in Text(sortLabel(f)).tag(f) }
                    }
                    .labelsHidden()
                    Button { state.sortDirection = state.sortDirection.toggled } label: {
                        Image(systemName: state.sortDirection == .asc ? "arrow.up" : "arrow.down")
                    }
                    .help(state.sortDirection == .asc ? tr("agents", "toolbar.direction_asc") : tr("agents", "toolbar.direction_desc"))
                }
            }
            .padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("agents", "toolbar.section_columns")).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(AgentsUI.Column.allCases, id: \.self) { c in
                    Toggle(isOn: Binding(get: { state.isVisible(c) }, set: { _ in state.toggleColumn(c) })) {
                        Text(Self.columnLabel(c)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
            .padding(12)
        }
        .frame(width: 256)
    }
}

// MARK: - Grid

struct AgentsUIListGrid: View {
    @Environment(Navigator.self) private var nav
    let model: AgentsUIListModel
    @Binding var state: AgentsUI.ViewState
    @Binding var selected: Set<String>
    let noMatchText: String

    var body: some View {
        let visible = AgentsUI.Column.allCases.filter(state.isVisible)
        let rows = model.rows
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        if rows.isEmpty {
                            Text(noMatchText).font(Theme.Font.body).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 64)
                        }
                        ForEach(rows) { row in
                            AgentsUIListRowView(row: row, selected: selected.contains(row.id), visible: visible) {
                                if selected.contains(row.id) { selected.remove(row.id) } else { selected.insert(row.id) }
                            }
                            .equatable()
                        }
                        Color.clear.frame(height: 80)
                    } header: {
                        headerRow(visible: visible, rows: rows)
                    }
                }
                .frame(width: max(geo.size.width, AgentsUIColumns.minWidth(visible)), alignment: .leading)
            }
        }
    }

    private func headerRow(visible: [AgentsUI.Column], rows: [AgentsUI.ListRow]) -> some View {
        let all = !rows.isEmpty && rows.allSatisfy { selected.contains($0.id) }
        let some = !all && rows.contains { selected.contains($0.id) }
        return HStack(spacing: 12) {
            Button {
                selected = all ? [] : Set(rows.map(\.id))
            } label: {
                Image(systemName: all ? "checkmark.square.fill" : (some ? "minus.square.fill" : "square"))
                    .foregroundStyle(all || some ? Theme.brand : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(all || some ? 1 : 0.5)
            .frame(width: 16)
            headerCell(tr("agents", "columns.agent"), field: .name).frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            ForEach(visible, id: \.self) { c in
                headerCell(AgentsUIListToolbar.columnLabel(c), field: sortField(c), alignTrailing: c == .runs)
                    .frame(width: AgentsUIColumns.width(c), alignment: c == .runs ? .trailing : .leading)
            }
            Color.clear.frame(width: 28)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func sortField(_ c: AgentsUI.Column) -> AgentsUI.SortField? {
        switch c {
        case .lastActive: return .lastActive
        case .runs: return .runs
        case .created: return .created
        default: return nil
        }
    }

    @ViewBuilder
    private func headerCell(_ title: String, field: AgentsUI.SortField?, alignTrailing: Bool = false) -> some View {
        if let field {
            Button { state.toggleSort(field) } label: {
                HStack(spacing: 3) {
                    Text(title)
                    if state.sortField == field {
                        Image(systemName: state.sortDirection == .asc ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                }
            }
            .buttonStyle(.plain)
            .font(Theme.Font.caption.weight(.medium))
            .foregroundStyle(state.sortField == field ? .primary : .secondary)
        } else {
            Text(title).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}

/// One two-line row; equatable so a change re-renders only its row.
struct AgentsUIListRowView: View, Equatable {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let row: AgentsUI.ListRow
    let selected: Bool
    let visible: [AgentsUI.Column]
    let onToggle: () -> Void
    @State private var hovering = false

    static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.selected == b.selected && a.visible == b.visible
    }

    var body: some View {
        let agent = row.agent
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: selected ? "checkmark.square.fill" : "square").foregroundStyle(selected ? Theme.brand : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(selected || hovering ? 1 : 0)
            .frame(width: 16)
            nameCell(agent).frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            ForEach(visible, id: \.self) { c in
                cell(c).frame(width: AgentsUIColumns.width(c), alignment: c == .runs ? .trailing : .leading)
            }
            AgentsUIRowActions(agent: agent, presence: row.presence, canManage: row.canManage)
                .frame(width: 28)
                .opacity(hovering ? 1 : 0.0001)
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
        .background(selected ? Theme.brand.opacity(0.08) : (hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { nav.push(.agent(agent.id), title: agent.name) }
        .contextMenu { AgentsUIRowMenuItems(agent: agent, presence: row.presence, canManage: row.canManage) }
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    private func nameCell(_ agent: AgentRecord) -> some View {
        let archived = agent.archivedAt != nil
        return HStack(spacing: 12) {
            AgentsUIAvatar(name: agent.name, avatarURL: agent.avatarUrl, size: 32, archived: archived)
                .overlay(alignment: .bottomTrailing) {
                    if let p = row.presence, !archived {
                        Circle().fill(p.availability.dotColor).frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }
                }
                .agentsUIProfileHover(agent.id)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name).font(Theme.Font.bodyMedium).foregroundStyle(archived ? .secondary : .primary).lineLimit(1)
                    if agent.visibility == "private" && !archived {
                        Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.tertiary)
                            .help(tr("agents", "visibility.private.tooltip"))
                    }
                    if row.isOwnedByMe {
                        Text(tr("agents", "row.you")).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
                    }
                }
                if !agent.description.isEmpty {
                    Text(agent.description).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ c: AgentsUI.Column) -> some View {
        let agent = row.agent
        switch c {
        case .status: statusCell
        case .owner:
            if let owner = agent.ownerId {
                HStack(spacing: 6) {
                    let m = session.directory.member(userID: owner)
                    AvatarView(name: m?.name ?? owner, url: m?.avatarURL, size: 18)
                    Text(m?.name ?? String(owner.prefix(8))).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("—").font(Theme.Font.caption).foregroundStyle(.tertiary)
            }
        case .access:
            Text(AgentsUIListToolbar.accessLabel(row.accessScope)).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
        case .runtime:
            if !AgentsUI.isRuntimeBound(agent) {
                Text(tr("agents", "row.needs_runtime")).font(Theme.Font.caption).foregroundStyle(Theme.warning).lineLimit(1)
            } else if let rt = row.runtime {
                HStack(spacing: 6) {
                    AgentsUIProviderLogo(provider: rt.provider)
                    Text(AgentsUI.runtimeDisplayLabel(rt)).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("—").font(Theme.Font.caption).foregroundStyle(.tertiary)
            }
        case .lastActive:
            Group {
                if let days = row.lastActiveDays {
                    Text(days == 0 ? tr("agents", "last_active.today") : tr("agents", "last_active.days_ago", ["count": days])).monospacedDigit()
                } else {
                    Text(agent.archivedAt != nil ? "—" : tr("agents", "last_active.none"))
                }
            }
            .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
        case .runs:
            Text(row.runCount.formatted()).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        case .model:
            Text(agent.model.isEmpty ? "—" : agent.model).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
        case .created:
            Text(Formatters.date(agent.createdAt, style: .numeric)).font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusCell: some View {
        let agent = row.agent
        if agent.archivedAt != nil {
            Text(tr("agents", "row.archived")).font(Theme.Font.caption).foregroundStyle(.secondary)
        } else if !AgentsUI.isRuntimeBound(agent) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warning)
                Text(tr("agents", "row.needs_runtime")).foregroundStyle(Theme.warning).lineLimit(1)
            }
            .font(Theme.Font.caption)
        } else if let p = row.presence {
            let active = p.runningCount + p.queuedCount
            HStack(spacing: 5) {
                Circle().fill(p.availability.dotColor).frame(width: 6, height: 6)
                Text(p.availability.label).foregroundStyle(p.availability.textColor)
                if active > 0 {
                    Text("· " + tr("agents", "row.task_count", ["count": active])).foregroundStyle(.secondary)
                }
            }
            .font(Theme.Font.caption)
            .lineLimit(1)
        } else {
            Text("—").font(Theme.Font.caption).foregroundStyle(.tertiary)
        }
    }
}

struct AgentsUIListSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: 12) {
                    Circle().fill(Color.primary.opacity(0.07)).frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: 128, height: 12)
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.05)).frame(width: 192, height: 10)
                    }
                    Spacer()
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)).frame(width: 64, height: 10)
                }
                .padding(.horizontal, 24)
                .frame(height: 64)
            }
            Spacer()
        }
        .padding(.top, 32)
    }
}

// MARK: - Row actions

/// Kebab menu for one row (upstream AgentRowActions).
struct AgentsUIRowActions: View {
    let agent: AgentRecord
    let presence: AgentsUI.Presence?
    let canManage: Bool

    var body: some View {
        Menu {
            AgentsUIRowMenuItems(agent: agent, presence: presence, canManage: canManage)
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("agents", "row.actions_aria"))
    }
}

/// The row menu items, shared by the kebab and the context menu. Confirmed
/// actions go through `AgentsUIRowConfirm` hosted by the window.
struct AgentsUIRowMenuItems: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let agent: AgentRecord
    let presence: AgentsUI.Presence?
    let canManage: Bool

    var body: some View {
        let archived = agent.archivedAt != nil
        let running = presence?.runningCount ?? 0
        let queued = presence?.queuedCount ?? 0
        Button { nav.openInNewTab(.agent(agent.id), title: agent.name) } label: {
            Label(tr("common", "navigation.open_in_new_tab"), systemImage: "arrow.up.forward.square")
        }
        Divider()
        if canManage && !archived && running + queued > 0 {
            Button { confirmCancel(running: running, queued: queued) } label: {
                Label(tr("agents", "row_actions.cancel_all_tasks"), systemImage: "stop")
            }
        }
        if !archived {
            Button { nav.push(.newAgentManual, query: ["duplicate": agent.id]) } label: {
                Label(tr("agents", "row_actions.duplicate"), systemImage: "doc.on.doc")
            }
        }
        if canManage && archived {
            Button {
                Task { await session.agentsUIRestore(agent.id, toaster: toaster, toast: tr("agents", "row_actions.agent_restored_toast")) }
            } label: {
                Label(tr("agents", "row_actions.restore"), systemImage: "arrow.uturn.backward")
            }
        }
        if canManage && !archived && agent.systemKey == nil {
            Divider()
            Button(role: .destructive) { confirmArchive() } label: {
                Label(tr("agents", "row_actions.archive"), systemImage: "trash")
            }
        }
    }

    private func confirmArchive() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("agents", "row_actions.archive_dialog_title", ["name": agent.name])
        alert.informativeText = tr("agents", "row_actions.archive_dialog_description")
        alert.addButton(withTitle: tr("agents", "row_actions.archive_dialog_confirm")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("agents", "row_actions.archive_dialog_cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await session.agentsUIArchive(agent.id, toaster: toaster, toast: tr("agents", "row_actions.agent_archived_toast")) }
    }

    private func confirmCancel(running: Int, queued: Int) {
        var parts: [String] = []
        if running > 0 { parts.append(tr("agents", "row_actions.cancel_dialog_running", ["count": running])) }
        if queued > 0 { parts.append(tr("agents", "row_actions.cancel_dialog_queued", ["count": queued])) }
        var text = running + queued == 0 ? tr("agents", "row_actions.cancel_dialog_no_tasks")
            : tr("agents", "row_actions.cancel_dialog_impact", ["summary": parts.joined(separator: " + "), "count": running + queued])
        if running > 0 { text += tr("agents", "row_actions.cancel_dialog_running_note") }
        text += tr("agents", "row_actions.cancel_dialog_irreversible")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("agents", "row_actions.cancel_dialog_title", ["name": agent.name])
        alert.informativeText = text
        alert.addButton(withTitle: tr("agents", "row_actions.cancel_dialog_confirm")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("agents", "row_actions.cancel_dialog_keep"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                let n = try await session.api.cancelAgentTasks(agent.id)
                toaster.success(n == 0 ? tr("agents", "row_actions.no_tasks_to_cancel_toast") : tr("agents", "row_actions.cancelled_tasks_toast", ["count": n]))
                await session.agentsUIStore.loadSnapshot()
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("agents", "row_actions.cancel_failed_toast"), kind: .error)
            }
        }
    }
}

// MARK: - Batch toolbar

/// Floating bulk actions for the selected rows: restore, access scope
/// (owner-only), archive.
struct AgentsUIBatchToolbar: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let rows: [AgentsUI.ListRow]
    let onClear: () -> Void

    @State private var busy = false
    @State private var confirmArchive = false
    @State private var accessOpen = false
    @State private var accessChange: AgentsUIAccessChange?

    var body: some View {
        let allManageable = rows.allSatisfy(\.canManage)
        let owned = rows.filter(\.isOwnedByMe)
        let anyActive = rows.contains { $0.agent.archivedAt == nil }
        let anyArchived = rows.contains { $0.agent.archivedAt != nil }
        Group {
            if !rows.isEmpty {
                HStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text(tr("agents", "actions.selected", ["count": rows.count])).font(Theme.Font.bodyMedium)
                        Button(action: onClear) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(tr("agents", "actions.clear_selection"))
                    }
                    .padding(.trailing, 8)
                    .overlay(alignment: .trailing) { Divider().frame(height: 16) }
                    if anyArchived {
                        Button {
                            run(rows.filter { $0.agent.archivedAt != nil }) { try await session.api.restoreAgent($0) }
                        } label: { Label(tr("agents", "row_actions.restore"), systemImage: "arrow.uturn.backward") }
                            .disabled(!allManageable || busy)
                    }
                    if anyActive {
                        Button(tr("agents", "row_actions.set_access")) {
                            accessChange = nil
                            accessOpen = true
                        }
                        .disabled(owned.isEmpty || busy)
                        Button { confirmArchive = true } label: { Label(tr("agents", "row_actions.archive"), systemImage: "archivebox") }
                            .disabled(!allManageable || busy)
                    }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: rows.isEmpty)
        .alert(tr("agents", "row_actions.archive_dialog_title", ["name": rows.count == 1 ? rows[0].agent.name : String(rows.count)]),
               isPresented: $confirmArchive) {
            Button(tr("agents", "row_actions.archive_dialog_cancel"), role: .cancel) {}
            Button(tr("agents", "row_actions.archive_dialog_confirm"), role: .destructive) {
                run(rows.filter { $0.agent.archivedAt == nil }) { try await session.api.archiveAgent($0) }
            }
        } message: {
            Text(tr("agents", "row_actions.archive_dialog_description"))
        }
        .sheet(isPresented: $accessOpen) { accessSheet(owned: owned) }
    }

    private func accessSheet(owned: [AgentsUI.ListRow]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("agents", "row_actions.set_access_dialog_title")).font(Theme.Font.title)
            Text(tr("agents", "row_actions.set_access_applies_to", ["count": owned.count])
                 + (rows.count > owned.count ? " " + tr("agents", "row_actions.set_access_skipped", ["count": rows.count - owned.count]) : ""))
                .font(Theme.Font.caption).foregroundStyle(.secondary)
            AgentsUISettingsCard {
                AgentsUIAccessPicker(permissionMode: "private", targets: [], members: session.directory.members,
                                     ownerID: session.currentUser.id, canEdit: true, hideFooter: true,
                                     onReadyChange: { accessChange = $0 })
            }
            HStack {
                Spacer()
                Button(tr("agents", "row_actions.archive_dialog_cancel")) { accessOpen = false }
                    .keyboardShortcut(.cancelAction)
                Button(tr("agents", "row_actions.set_access_dialog_confirm")) {
                    guard let change = accessChange else { return }
                    accessOpen = false
                    applyAccess(change, to: owned)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || accessChange == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func applyAccess(_ change: AgentsUIAccessChange, to targets: [AgentsUI.ListRow]) {
        run(targets) { id in _ = try await session.api.updateAgent(id, patch: change.patch) } completion: { ok, failed in
            if failed > 0 {
                toaster.error(tr("agents", "row_actions.set_access_bulk_partial", ["succeeded": ok, "failed": failed]))
            }
        }
    }

    private func run(_ targets: [AgentsUI.ListRow], _ op: @escaping (String) async throws -> Any,
                     completion: ((Int, Int) -> Void)? = nil) {
        busy = true
        Task {
            var failures: [Error] = []
            await withTaskGroup(of: Error?.self) { group in
                for row in targets {
                    group.addTask { @MainActor in
                        do { _ = try await op(row.agent.id); return nil } catch { return error }
                    }
                }
                for await e in group { if let e { failures.append(e) } }
            }
            await session.agentRecords.load()
            onClear()
            busy = false
            if let first = failures.first { toaster.error(first) }
            completion?(targets.count - failures.count, failures.count)
        }
    }
}
