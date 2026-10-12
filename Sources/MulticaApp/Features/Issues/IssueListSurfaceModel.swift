import MulticaCore
import Observation
import SwiftUI

/// One board/list column: a status, assignee, project or select-property
/// option. `branchKeys` are the server branches whose rows it shows.
struct IssueListColumn: Identifiable, Hashable {
    enum Kind: Hashable {
        case status(IssueStatusKey)
        case assignee(ActorRef?)
        case project(String?)
        case property(id: String, optionID: String?, color: String?)
    }

    var id: String
    var title: String
    var kind: Kind
    var branchKeys: [String]
    var total: Int

    var status: IssueStatusKey? {
        if case .status(let s) = kind { return s }
        return nil
    }
}

/// Controller for one issue surface (upstream `useIssueSurfaceController`):
/// view state, the compiled server query, independently paged branches,
/// facets, selection, peek and the surface's writes.
@MainActor
@Observable
final class IssueListSurfaceModel {
    let session: WorkspaceSession
    let modes: [IssueListViewMode]
    private(set) var baseScope: IssueListSurfaceScope
    private(set) var activeView: IssueView?
    private(set) var scope: IssueListSurfaceScope
    private(set) var surfaceKey: String
    private(set) var baseline: IssueListBaseline?

    var state: IssueListViewState {
        didSet { if state != oldValue { stateDidChange(from: oldValue) } }
    }

    /// Server-side membership search (actor panel and table).
    var search = "" {
        didSet { if search != oldValue { scheduleSearch() } }
    }

    private(set) var statusBranches: [IssueStatusKey: IssueListBranch] = [:]
    private(set) var visibleStatuses: [IssueStatusKey] = []
    private(set) var hiddenStatuses: [IssueStatusKey] = []
    private(set) var groupDescriptors: [IssueTableGroupDescriptor] = []
    private(set) var groupBranches: [String: IssueListBranch] = [:]
    private(set) var groupColumns: [IssueListColumn] = []
    private(set) var groupsNextCursor: String?
    private(set) var groupsLoadingMore = false
    private(set) var groupsError = false
    private(set) var groupsTotal = 0
    private(set) var facets: IssueListFacetCounts?
    private(set) var submenuFacets: IssueListFacetCounts?
    private(set) var workingAgents: [IssueListWorkingAgent]?
    private(set) var isLoading = true
    private(set) var isRefreshing = false
    private(set) var workingFilterError = false
    private(set) var statusCatalogError = false
    private(set) var projectsByID: [String: Project] = [:]
    private(set) var activeProperties: [IssueProperty] = []
    private(set) var propertiesLoaded = false

    var selection: Set<String> = []
    var peekID: String?
    var focusedID: String?
    var runConfirm: IssueListRunConfirm?

    @ObservationIgnored let activity = IssueListActivity()
    @ObservationIgnored private var extras: [String: IssueListRowExtras] = [:]
    @ObservationIgnored private var fingerprint = ""
    @ObservationIgnored private var membership = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var workingIssueIDs: [String]?
    @ObservationIgnored private var activeFacet: JSONValue?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var selfInducedRevision = -1
    @ObservationIgnored private var lastPropertiesRevision = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private(set) var debouncedSearch = ""
    @ObservationIgnored var toast: ((String, Bool) -> Void)?

    init(session: WorkspaceSession, scope: IssueListSurfaceScope, modes: [IssueListViewMode], view: IssueView?) {
        self.session = session
        self.modes = modes
        self.baseScope = scope
        self.activeView = view
        let effective = view.map { scope.applyingViewVariant($0.scopeVariant) } ?? scope
        self.scope = effective
        let key = view.map { "view:\($0.id)" } ?? scope.key
        self.surfaceKey = key
        self.baseline = view.map { IssueListBaseline(query: $0.query) }
        var seed: [String: JSONValue]?
        if let view {
            seed = view.query
            for (k, v) in view.display { seed?[k] = v }
        }
        self.state = IssueListPrefs.initialState(workspaceID: session.workspace.id, surface: key, seed: seed)
        if !modes.contains(state.viewMode), let first = modes.first { state.viewMode = first }
    }

    // MARK: Derived

    var viewMode: IssueListViewMode {
        modes.contains(state.viewMode) ? state.viewMode : (modes.first ?? .list)
    }

    var allowGantt: Bool { modes.contains(.gantt) && scope.projectID != nil }

    var activePropertyIDs: Set<String>? {
        propertiesLoaded ? Set(activeProperties.map(\.id)) : nil
    }

    func property(_ id: String) -> IssueProperty? {
        activeProperties.first { $0.id == id }
    }

    /// A `property:<id>` grouping whose definition is gone falls back to status.
    var effectiveGrouping: String {
        guard let pid = IssueListOptions.propertyID(fromKey: state.grouping) else { return state.grouping }
        guard propertiesLoaded else { return state.grouping }
        return activeProperties.contains { $0.id == pid && $0.type == "select" } ? state.grouping : "status"
    }

    var groupingProperty: IssueProperty? {
        IssueListOptions.propertyID(fromKey: effectiveGrouping).flatMap(property)
    }

    var usesStatusSurface: Bool {
        viewMode == .list || (viewMode == .board && effectiveGrouping == "status")
    }

    var usesGroupSurface: Bool {
        (viewMode == .board && effectiveGrouping != "status") || viewMode == .swimlane
    }

    var hasActiveFilters: Bool {
        state.hasActiveFilters(activePropertyIDs: activePropertyIDs, ignoringProjects: scope.projectID != nil)
    }

    var isEmpty: Bool {
        guard !isLoading else { return false }
        if usesStatusSurface { return (facets?.total ?? loadedCount) == 0 }
        if usesGroupSurface { return groupsTotal == 0 && groupDescriptors.isEmpty }
        return false
    }

    var loadedCount: Int {
        statusBranches.values.reduce(0) { $0 + $1.ids.count }
    }

    /// Every row id the surface currently shows, in display order.
    var loadedIDs: [String] {
        if usesStatusSurface {
            return visibleStatuses.flatMap { statusBranches[$0]?.ids ?? [] }
        }
        return groupColumns.flatMap { column in column.branchKeys.flatMap { groupBranches[$0]?.ids ?? [] } }
    }

    /// The authoritative selection: selected ids ∩ the visible rows.
    var selectedIssues: [Issue] {
        guard !selection.isEmpty else { return [] }
        var seen = Set<String>()
        return loadedIDs.compactMap { id in
            guard selection.contains(id), seen.insert(id).inserted else { return nil }
            return session.issues.model(id)?.issue
        }
    }

    var sortLabel: String? {
        guard state.sortBy != "position" else { return nil }
        let field: String
        if let pid = IssueListOptions.propertyID(fromKey: state.sortBy) {
            field = property(pid)?.name ?? ""
        } else {
            field = tr("issues", "display.\(IssueListOptions.sortLabelKey(state.sortBy) ?? "sort_manual")")
        }
        return tr("issues", "board.ordered_by", ["field": field])
    }

    func extras(_ id: String) -> IssueListRowExtras {
        if let e = extras[id] { return e }
        let e = IssueListRowExtras()
        extras[id] = e
        return e
    }

    func project(_ id: String?) -> Project? {
        id.flatMap { projectsByID[$0] }
    }

    func statusBranch(_ key: IssueStatusKey) -> IssueListBranch {
        if let b = statusBranches[key] { return b }
        let b = IssueListBranch(key: key.rawValue)
        statusBranches[key] = b
        return b
    }

    func columnIDs(_ column: IssueListColumn) -> [String] {
        if column.branchKeys.count == 1 { return groupBranches[column.branchKeys[0]]?.ids ?? [] }
        var seen = Set<String>()
        return column.branchKeys.flatMap { groupBranches[$0]?.ids ?? [] }.filter { seen.insert($0).inserted }
    }

    /// The open view was edited: its query (the baseline) follows, the user's
    /// local display state does not.
    func adoptView(_ view: IssueView?) {
        guard let view, view.id == activeView?.id else { return }
        activeView = view
        baseline = IssueListBaseline(query: view.query)
    }

    /// Create-issue defaults for this surface, plus a group's own fields.
    func createDraft(status: IssueStatusKey? = nil, assignee: IssueListField<ActorRef> = .unchanged,
                     projectID: IssueListField<String> = .unchanged) -> CreateIssueDraft {
        var draft = CreateIssueDraft()
        let defaults = scope.createDefaults
        draft.assignee = defaults.assignee
        draft.projectID = defaults.projectID
        if let status { draft.status = status }
        switch assignee {
        case .set(let a): draft.assignee = a
        case .clear: draft.assignee = nil
        case .unchanged: break
        }
        switch projectID {
        case .set(let p): draft.projectID = p
        case .clear: draft.projectID = nil
        case .unchanged: break
        }
        if let pid = scope.projectID { draft.projectID = pid }
        return draft
    }

    // MARK: Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        observeSources()
        activity.refreshSnapshot(session.api)
        activity.startPolling(session.api)
        async let statuses: Void = session.issueStatusEntries.loadIfNeeded()
        async let properties: Void = session.properties.loadIfNeeded()
        _ = await (statuses, properties)
        syncCatalogs()
        if needsProjects { await session.projects.loadIfNeeded() }
        syncCatalogs()
        await reload()
        refreshWorkingAgents()
        loadChildProgress()
    }

    func stop() {
        refreshTask?.cancel()
        searchTask?.cancel()
        activityTask?.cancel()
        activity.stop()
        started = false
        flushSave()
    }

    private var needsProjects: Bool {
        !state.projectStatusFilters.isEmpty || state.cardProperties.project
            || (viewMode == .table && (state.tableColumns.contains { $0.key == "project" } || state.tableGrouping == "project"))
            || (viewMode == .board && effectiveGrouping == "project")
            || (viewMode == .swimlane && state.swimlaneGrouping == .project)
            || !state.projectFilters.isEmpty
    }

    private func syncCatalogs() {
        let props = session.properties.items.filter { !$0.archived && $0.archivedAt == nil }
        if props != activeProperties { activeProperties = props }
        if session.properties.isLoaded || session.properties.error != nil { propertiesLoaded = true }
        let map = Dictionary(session.projects.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if map != projectsByID { projectsByID = map }
        recomputeColumns()
    }

    private func recomputeColumns() {
        let entries = session.issueListStatusEntries
        let visible = IssueListStatusColumns.visible(statusFilters: state.statusFilters, hidden: state.hiddenStatuses, entries: entries)
        let hidden = IssueListStatusColumns.hidden(statusFilters: state.statusFilters, hidden: state.hiddenStatuses, entries: entries)
        if visible != visibleStatuses { visibleStatuses = visible }
        if hidden != hiddenStatuses { hiddenStatuses = hidden }
        let custom = state.statusFilters.contains { IssueStatusKey(rawValue: $0).builtInCategory == nil }
        statusCatalogError = custom && !session.issueStatusEntries.isLoaded && session.issueStatusEntries.error != nil
    }

    /// Re-arms observation of everything that can change membership: issue
    /// writes (realtime and local), custom property values, catalogs.
    private func observeSources() {
        withObservationTracking {
            _ = session.issues.changeRevision
            _ = session.revision("issue_properties")
            _ = session.properties.items
            _ = session.projects.items
            _ = session.issueStatusEntries.items
            _ = session.issues.catalog
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.sourcesChanged() }
        }
        withObservationTracking {
            _ = session.issues.activityRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.activityChanged() }
        }
    }

    private func sourcesChanged() {
        guard started else { return }
        observeSources()
        syncCatalogs()
        refilterBranches()
        let rev = session.issues.changeRevision
        let propsRev = session.revision("issue_properties")
        if rev == selfInducedRevision && propsRev == lastPropertiesRevision { return }
        lastPropertiesRevision = propsRev
        scheduleRefresh()
    }

    private func activityChanged() {
        guard started else { return }
        withObservationTracking {
            _ = session.issues.activityRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.activityChanged() }
        }
        activityTask?.cancel()
        activityTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled else { return }
            self.refreshWorkingAgents()
            self.activity.refreshSnapshot(self.session.api)
            if self.state.agentRunningFilter { await self.reload() }
        }
    }

    func scheduleRefresh(delay: Int = 350) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, !Task.isCancelled else { return }
            await self.reload()
            self.loadChildProgress()
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.debouncedSearch = self.search.trimmingCharacters(in: .whitespacesAndNewlines)
            await self.reload()
        }
    }

    private func stateDidChange(from old: IssueListViewState) {
        scheduleSave()
        recomputeColumns()
        let queryChanged = old.statusFilters != state.statusFilters || old.priorityFilters != state.priorityFilters
            || old.assigneeFilters != state.assigneeFilters || old.includeNoAssignee != state.includeNoAssignee
            || old.creatorFilters != state.creatorFilters || old.projectFilters != state.projectFilters
            || old.includeNoProject != state.includeNoProject || old.projectStatusFilters != state.projectStatusFilters
            || old.labelFilters != state.labelFilters || old.propertyFilters != state.propertyFilters
            || old.dateFilter != state.dateFilter || old.agentRunningFilter != state.agentRunningFilter
            || old.sortBy != state.sortBy || old.sortDirection != state.sortDirection
            || old.showSubIssues != state.showSubIssues
        let shapeChanged = old.viewMode != state.viewMode || old.grouping != state.grouping
            || old.swimlaneGrouping != state.swimlaneGrouping || old.hiddenStatuses != state.hiddenStatuses
            || old.listCollapsedStatuses != state.listCollapsedStatuses
        if old.agentRunningFilter != state.agentRunningFilter && !state.agentRunningFilter { workingIssueIDs = nil }
        if queryChanged || shapeChanged {
            if needsProjects { Task { await session.projects.loadIfNeeded() } }
            Task { await reload() }
            if queryChanged { refreshWorkingAgents() }
        }
        if old.cardProperties.childProgress != state.cardProperties.childProgress { loadChildProgress() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.flushSave()
        }
    }

    private func flushSave() {
        IssueListPrefs.saveState(state.persistedJSON, workspaceID: session.workspace.id, surface: surfaceKey)
    }

    // MARK: Query

    var querySpec: IssueTableQuerySpec {
        IssueListQuery.spec(scope: scope, state: state, search: debouncedSearch,
                            workingIssueIDs: workingIssueIDs, activePropertyIDs: activePropertyIDs)
    }

    private var myRelation: String? {
        if case .my(_, let r) = scope { return r == "all" ? "any" : r }
        return nil
    }

    /// Resolves the running-issue projection behind the agents-working filter.
    private func resolveWorkingIssues() async -> Bool {
        guard state.agentRunningFilter else { return true }
        do {
            let agents = try await session.api.getWorkspaceWorkingAgents(type: "issue", mineRelation: myRelation)
            var ids = Set<String>()
            for a in agents { ids.formUnion(a.issueIds) }
            workingIssueIDs = ids.sorted()
            workingFilterError = false
            return true
        } catch {
            if workingIssueIDs == nil { workingFilterError = true }
            return workingIssueIDs != nil
        }
    }

    // MARK: Loading

    func reload() async {
        guard viewMode != .table && viewMode != .gantt else {
            isLoading = false
            return
        }
        guard await resolveWorkingIssues() else {
            isLoading = false
            return
        }
        recomputeColumns()
        if statusCatalogError {
            isLoading = false
            return
        }
        let spec = querySpec
        let fp = IssueListQuery.fingerprint(spec) + "|\(viewMode.rawValue)|\(effectiveGrouping)|\(state.swimlaneGrouping.rawValue)"
        let reset = fp != fingerprint
        let member = IssueListQuery.membershipKey(spec) + viewMode.rawValue
        if member != membership {
            membership = member
            if !selection.isEmpty { selection = [] }
        }
        if reset {
            fingerprint = fp
            generation += 1
        }
        let gen = generation
        isRefreshing = !isLoading
        if usesStatusSurface {
            await loadStatusSurface(spec, reset: reset, generation: gen)
        } else if usesGroupSurface {
            await loadGroupSurface(spec, reset: reset, generation: gen)
        }
        guard gen == generation else { return }
        isLoading = false
        isRefreshing = false
    }

    private func rowsRequest(_ spec: IssueTableQuerySpec, group: JSONValue, key: String, cursor: String?, limit: Int) -> IssueTableRowsRequest {
        IssueTableRowsRequest(query: spec, group: group, groupKey: key, hierarchy: ["enabled": false],
                              parentId: nil, page: IssueTablePageRequest(limit: limit, cursor: cursor))
    }

    /// Absorbs a server page: rows go into the shared store (one `IssueModel`
    /// per issue) and their extras into the surface.
    private func absorb(_ rows: [IssueListRow]) {
        for row in rows {
            session.issues.upsert(row.issue)
            extras(row.issue.id).set(properties: row.properties, duplicateOf: row.duplicateOfIdentifier, directChildCount: row.directChildCount)
        }
        selfInducedRevision = session.issues.changeRevision
    }

    /// Fetches a branch head, re-walking the cursor chain so a refresh keeps
    /// the window the user already scrolled through.
    private func fetchBranch(_ spec: IssueTableQuerySpec, group: JSONValue, key: String, keepCount: Int) async throws -> (rows: [IssueListRow], next: String?, total: Int) {
        var rows: [IssueListRow] = []
        var cursor: String?
        var total = 0
        let target = max(50, keepCount)
        repeat {
            let limit = min(100, max(50, target - rows.count))
            let page = try await session.api.issueListRows(rowsRequest(spec, group: group, key: key, cursor: cursor, limit: limit))
            rows += page.rows
            cursor = page.nextCursor
            total = page.branchTotal
        } while cursor != nil && rows.count < target && !Task.isCancelled
        return (rows, cursor, total)
    }

    private func loadStatusSurface(_ spec: IssueTableQuerySpec, reset: Bool, generation gen: Int) async {
        let statuses = viewMode == .list
            ? visibleStatuses.filter { !state.listCollapsedStatuses.contains($0.rawValue) }
            : visibleStatuses
        let api = session.api
        var facetKinds: [JSONValue] = [IssueListQuery.facetSpec("status")]
        if let activeFacet, activeFacet["kind"]?.stringValue != "status" { facetKinds.append(activeFacet) }
        let facetRequest = IssueTableFacetsRequest(query: spec, facets: facetKinds, includeTotal: true)
        async let facetResult = try? api.listIssueTableFacets(facetRequest)
        let group: JSONValue = ["kind": "status"]
        for s in statuses {
            let b = statusBranch(s)
            if reset || !b.loaded { b.isLoading = true }
            b.activated = true
        }
        let keep = Dictionary(statuses.map { ($0, reset ? 0 : (statusBranches[$0]?.rawIDs.count ?? 0)) }, uniquingKeysWith: { a, _ in a })
        let results = await withTaskGroup(of: (IssueStatusKey, Result<(rows: [IssueListRow], next: String?, total: Int), Error>).self) { tg in
            for s in statuses {
                let k = keep[s] ?? 0
                tg.addTask { [self] in
                    do {
                        return (s, .success(try await self.fetchBranch(spec, group: group, key: IssueListDrag.statusGroupID(s.rawValue), keepCount: k)))
                    } catch {
                        return (s, .failure(error))
                    }
                }
            }
            var out: [(IssueStatusKey, Result<(rows: [IssueListRow], next: String?, total: Int), Error>)] = []
            for await r in tg { out.append(r) }
            return out
        }
        let facetResponse = await facetResult
        guard gen == generation else { return }
        if let facetResponse {
            let counts = IssueListFacetCounts(facetResponse)
            facets = counts
            if activeFacet != nil { submenuFacets = counts }
        }
        for (s, result) in results {
            let b = statusBranch(s)
            b.isLoading = false
            switch result {
            case .success(let page):
                absorb(page.rows)
                var seen = Set<String>()
                b.rawIDs = page.rows.map(\.issue.id).filter { seen.insert($0).inserted }
                b.nextCursor = page.next
                b.total = page.total
                b.isError = false
                b.loaded = true
            case .failure:
                b.isError = true
            }
        }
        let counts = facets?.statusCounts(selected: state.statusFilters) ?? [:]
        for (key, b) in statusBranches {
            b.total = counts[key.rawValue] ?? (b.loaded ? b.total : 0)
        }
        refilterBranches()
    }

    func loadMore(status: IssueStatusKey) {
        let b = statusBranch(status)
        guard let cursor = b.nextCursor, !b.isLoadingMore else { return }
        b.isLoadingMore = true
        let spec = querySpec
        let gen = generation
        Task {
            defer { b.isLoadingMore = false }
            do {
                let page = try await session.api.issueListRows(rowsRequest(spec, group: ["kind": "status"], key: IssueListDrag.statusGroupID(status.rawValue), cursor: cursor, limit: 50))
                guard gen == generation else { return }
                absorb(page.rows)
                var seen = Set(b.rawIDs)
                b.rawIDs += page.rows.map(\.issue.id).filter { seen.insert($0).inserted }
                b.nextCursor = page.nextCursor
                b.isError = false
                refilterBranches()
            } catch {
                b.isError = true
            }
        }
    }

    func retry(status: IssueStatusKey) {
        statusBranch(status).isError = false
        Task { await reload() }
    }

    // MARK: Group surfaces (non-status board, swimlane)

    var groupSpec: JSONValue {
        if viewMode == .swimlane {
            return .object([
                "kind": "compound", "primary": .string(state.swimlaneGrouping.rawValue),
                "secondary": "status", "secondary_values": JSONValue(visibleStatuses.map(\.rawValue)),
            ])
        }
        let g = effectiveGrouping
        if g == "project" { return ["kind": "project"] }
        if let pid = IssueListOptions.propertyID(fromKey: g) {
            return .object(["kind": "property", "property_id": .string(pid), "include_empty": true])
        }
        return ["kind": "assignee"]
    }

    private var groupQuery: IssueTableQuerySpec {
        var spec = querySpec
        if viewMode == .swimlane { spec.filters?.statuses = nil }
        return spec
    }

    private func loadGroupSurface(_ spec: IssueTableQuerySpec, reset: Bool, generation gen: Int) async {
        let query = groupQuery
        let group = groupSpec
        var descriptors: [IssueTableGroupDescriptor] = []
        var cursor: String?
        var total = 0
        let pagesToKeep = reset ? 1 : max(1, (groupDescriptors.count + 99) / 100)
        do {
            for _ in 0..<pagesToKeep {
                let page = try await session.api.listIssueTableGroups(IssueTableGroupsRequest(query: query, group: group, page: IssueTablePageRequest(limit: 100, cursor: cursor)))
                if descriptors.isEmpty { total = page.total }
                descriptors += page.groups
                cursor = page.nextCursor
                if cursor == nil { break }
            }
        } catch {
            guard gen == generation else { return }
            groupsError = true
            return
        }
        guard gen == generation else { return }
        groupsError = false
        groupDescriptors = descriptors
        groupsNextCursor = cursor
        groupsTotal = total
        if reset {
            groupBranches = [:]
        }
        let leafs = leafDescriptors(descriptors)
        for d in leafs {
            let b = groupBranches[d.key] ?? IssueListBranch(key: d.key)
            b.total = d.count
            groupBranches[d.key] = b
        }
        rebuildGroupColumns()
        let active = leafs.filter { groupBranches[$0.key]?.activated == true }
        await fetchGroupHeads(active.map(\.key), query: query, group: group, generation: gen)
    }

    /// Branch descriptors: compound groups page per lane × status cell.
    private func leafDescriptors(_ descriptors: [IssueTableGroupDescriptor]) -> [IssueTableGroupDescriptor] {
        let allowed = Set(visibleStatuses.map(\.rawValue))
        return descriptors.flatMap { d -> [IssueTableGroupDescriptor] in
            guard let secondary = d.secondaryGroups, !secondary.isEmpty else { return [d] }
            return secondary.filter { s in
                if case .status(let key) = IssueListGroupValue(s.value) { return allowed.contains(key) }
                return true
            }
        }
    }

    private func fetchGroupHeads(_ keys: [String], query: IssueTableQuerySpec, group: JSONValue, generation gen: Int) async {
        guard !keys.isEmpty else { return }
        for k in keys { groupBranches[k]?.isLoading = groupBranches[k]?.loaded != true }
        let keep = Dictionary(keys.map { ($0, groupBranches[$0]?.rawIDs.count ?? 0) }, uniquingKeysWith: { a, _ in a })
        let results = await withTaskGroup(of: (String, Result<(rows: [IssueListRow], next: String?, total: Int), Error>).self) { tg in
            for k in keys {
                let count = keep[k] ?? 0
                tg.addTask { [self] in
                    do { return (k, .success(try await self.fetchBranch(query, group: group, key: k, keepCount: count))) }
                    catch { return (k, .failure(error)) }
                }
            }
            var out: [(String, Result<(rows: [IssueListRow], next: String?, total: Int), Error>)] = []
            for await r in tg { out.append(r) }
            return out
        }
        guard gen == generation else { return }
        for (k, result) in results {
            guard let b = groupBranches[k] else { continue }
            b.isLoading = false
            switch result {
            case .success(let page):
                absorb(page.rows)
                var seen = Set<String>()
                b.rawIDs = page.rows.map(\.issue.id).filter { seen.insert($0).inserted }
                b.nextCursor = page.next
                b.isError = false
                b.loaded = true
            case .failure:
                b.isError = true
            }
        }
        refilterBranches()
    }

    /// Sentinel-driven: the first call activates the head, later calls page.
    func loadMore(group key: String) {
        guard let b = groupBranches[key], !b.isLoadingMore, !b.isLoading else { return }
        let query = groupQuery
        let group = groupSpec
        let gen = generation
        if !b.activated {
            b.activated = true
            guard b.total > 0 || viewMode == .swimlane || groupingProperty != nil else {
                b.loaded = true
                return
            }
            Task { await fetchGroupHeads([key], query: query, group: group, generation: gen) }
            return
        }
        guard let cursor = b.nextCursor else { return }
        b.isLoadingMore = true
        Task {
            defer { b.isLoadingMore = false }
            do {
                let page = try await session.api.issueListRows(rowsRequest(query, group: group, key: key, cursor: cursor, limit: 50))
                guard gen == generation else { return }
                absorb(page.rows)
                var seen = Set(b.rawIDs)
                b.rawIDs += page.rows.map(\.issue.id).filter { seen.insert($0).inserted }
                b.nextCursor = page.nextCursor
                refilterBranches()
            } catch {
                b.isError = true
            }
        }
    }

    func loadMoreGroups() {
        guard let cursor = groupsNextCursor, !groupsLoadingMore else { return }
        groupsLoadingMore = true
        let query = groupQuery
        let group = groupSpec
        let gen = generation
        Task {
            defer { groupsLoadingMore = false }
            guard let page = try? await session.api.listIssueTableGroups(IssueTableGroupsRequest(query: query, group: group, page: IssueTablePageRequest(limit: 100, cursor: cursor))),
                  gen == generation else { return }
            groupDescriptors += page.groups
            groupsNextCursor = page.nextCursor
            for d in leafDescriptors(page.groups) where groupBranches[d.key] == nil {
                let b = IssueListBranch(key: d.key)
                b.total = d.count
                groupBranches[d.key] = b
            }
            rebuildGroupColumns()
        }
    }

    func retryGroups() {
        groupsError = false
        Task { await reload() }
    }

    func retry(group key: String) {
        groupBranches[key]?.isError = false
        let gen = generation
        Task { await fetchGroupHeads([key], query: groupQuery, group: groupSpec, generation: gen) }
    }

    /// Board columns for non-status groupings (`buildGroups` + descriptors).
    private func rebuildGroupColumns() {
        guard viewMode == .board else {
            groupColumns = []
            return
        }
        var columns: [IssueListColumn] = []
        if let prop = groupingProperty {
            var byOption: [String: [String]] = [:]
            var counts: [String: Int] = [:]
            for d in groupDescriptors {
                guard case .property(_, let value, let st) = IssueListGroupValue(d.value) else { continue }
                let option = st == "value" ? value?.stringValue : nil
                let known = option.map { o in prop.config?.options?.contains { $0.id == o } ?? false } ?? false
                let id = known ? option! : "none"
                byOption[id, default: []].append(d.key)
                counts[id, default: 0] += d.count
            }
            for o in prop.config?.options ?? [] {
                columns.append(IssueListColumn(id: IssueListDrag.propertyGroupID(prop.id, o.id), title: o.name,
                                               kind: .property(id: prop.id, optionID: o.id, color: o.color),
                                               branchKeys: byOption[o.id] ?? [], total: counts[o.id] ?? 0))
            }
            columns.append(IssueListColumn(id: IssueListDrag.propertyGroupID(prop.id, nil), title: tr("issues", "board.no_value"),
                                           kind: .property(id: prop.id, optionID: nil, color: nil),
                                           branchKeys: byOption["none"] ?? [], total: counts["none"] ?? 0))
        } else if effectiveGrouping == "project" {
            for d in groupDescriptors {
                guard case .project(let pid) = IssueListGroupValue(d.value) else { continue }
                let title = pid.map { projectsByID[$0]?.title ?? tr("issues", "table.value_unavailable") } ?? tr("issues", "swimlane.no_project")
                columns.append(IssueListColumn(id: d.key, title: title, kind: .project(pid), branchKeys: [d.key], total: d.count))
            }
            if !columns.isEmpty && !columns.contains(where: { $0.kind == .project(nil) }) {
                columns.insert(IssueListColumn(id: IssueListDrag.projectGroupID(nil), title: tr("issues", "swimlane.no_project"),
                                               kind: .project(nil), branchKeys: [], total: 0), at: 0)
            }
        } else {
            for d in groupDescriptors {
                guard case .assignee(let ref) = IssueListGroupValue(d.value) else { continue }
                let title = ref.map { session.actorInfo(type: $0.type, id: $0.id).name } ?? tr("issues", "filters.no_assignee")
                columns.append(IssueListColumn(id: d.key, title: title, kind: .assignee(ref), branchKeys: [d.key], total: d.count))
            }
        }
        if columns != groupColumns { groupColumns = columns }
    }

    /// Drops rows whose live state left their branch (a realtime patch can move
    /// an issue before the refetch lands) and re-reads ordered ids.
    private func refilterBranches() {
        for (key, b) in statusBranches {
            b.setIDs(b.rawIDs.filter { session.issues.model($0)?.issue.status == key })
        }
        guard !groupBranches.isEmpty else { return }
        var owners: [String: IssueTableGroupDescriptor] = [:]
        var leafs: [String: IssueTableGroupDescriptor] = [:]
        for d in groupDescriptors {
            if let secondary = d.secondaryGroups, !secondary.isEmpty {
                for s in secondary { owners[s.key] = d; leafs[s.key] = s }
            } else {
                leafs[d.key] = d
            }
        }
        for (key, b) in groupBranches {
            guard let leaf = leafs[key] else { continue }
            let owner = owners[key] ?? leaf
            b.setIDs(b.rawIDs.filter { id in
                guard let issue = session.issues.model(id)?.issue else { return false }
                return matches(issue, leaf: leaf, owner: owner)
            })
        }
    }

    private func matches(_ issue: Issue, leaf: IssueTableGroupDescriptor, owner: IssueTableGroupDescriptor) -> Bool {
        if leaf.key != owner.key, case .status(let s) = IssueListGroupValue(leaf.value), issue.status.rawValue != s { return false }
        switch IssueListGroupValue(owner.value) {
        case .assignee(let ref): return issue.assignee == ref
        case .project(let pid): return issue.projectID == pid
        case .parent(let pid, _, _, _, _): return issue.parentIssueID == pid
        case .status(let s): return issue.status.rawValue == s
        case .property(let pid, let value, let st):
            let current = extras[issue.id]?.properties[pid]
            if st == "unset" { return current == nil }
            if st == "value" { return current == value }
            return true
        case .unknown: return true
        }
    }

    // MARK: Facets and side data

    /// Loads one server facet while its filter submenu is open.
    func setActiveFacet(_ facet: JSONValue?) {
        activeFacet = facet
        guard let facet else {
            submenuFacets = nil
            return
        }
        let request = IssueTableFacetsRequest(query: querySpec, facets: [facet], includeTotal: false)
        Task {
            guard let r = try? await session.api.listIssueTableFacets(request), activeFacet == facet else { return }
            submenuFacets = IssueListFacetCounts(r)
        }
    }

    /// The header chip's count, on a spec without `working_issue_ids` so the
    /// number does not flicker when the chip itself toggles the filter.
    func refreshWorkingAgents() {
        if case .actor = scope { return }
        var spec = querySpec
        spec.filters?.workingIssueIds = nil
        let request = IssueTableFacetsRequest(query: spec, facets: [IssueListQuery.facetSpec("working_agents")], includeTotal: false)
        Task {
            guard let r = try? await session.api.listIssueTableFacets(request) else { return }
            let next = IssueListFacetCounts(r).workingAgents
            if next != workingAgents { workingAgents = next }
        }
    }

    func loadChildProgress() {
        guard state.cardProperties.childProgress || state.tableColumns.contains(where: { $0.key == "child_progress" }) else { return }
        Task {
            guard let list = try? await session.api.getChildIssueProgress() else { return }
            var byParent: [String: (Int, Int)] = [:]
            for p in list { byParent[p.parentIssueId] = (p.done, p.total) }
            for (id, e) in extras {
                e.setProgress(byParent[id].map { (done: $0.0, total: $0.1) })
            }
            childProgressByParent = byParent
        }
    }

    @ObservationIgnored private var childProgressByParent: [String: (Int, Int)] = [:]

    func progress(_ id: String) -> (done: Int, total: Int)? {
        childProgressByParent[id].map { (done: $0.0, total: $0.1) }
    }

    // MARK: Selection & peek

    func toggleSelection(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func select(_ ids: [String]) { selection.formUnion(ids) }
    func deselect(_ ids: [String]) { selection.subtract(ids) }
    func clearSelection() { if !selection.isEmpty { selection = [] } }

    /// Columns in display order for J/K (within) and H/L (across) stepping.
    var peekColumns: [[String]] {
        if usesStatusSurface {
            if viewMode == .list {
                return [visibleStatuses.filter { !state.listCollapsedStatuses.contains($0.rawValue) }.flatMap { statusBranches[$0]?.ids ?? [] }]
            }
            return visibleStatuses.map { statusBranches[$0]?.ids ?? [] }
        }
        return groupColumns.map(columnIDs)
    }

    func step(_ direction: IssueListStep, from id: String?) -> String? {
        let columns = peekColumns
        guard let id else { return columns.first(where: { !$0.isEmpty })?.first }
        for (c, column) in columns.enumerated() {
            guard let i = column.firstIndex(of: id) else { continue }
            switch direction {
            case .previous: return i > 0 ? column[i - 1] : nil
            case .next: return i < column.count - 1 ? column[i + 1] : nil
            case .left, .right:
                let delta = direction == .left ? -1 : 1
                var n = c + delta
                while n >= 0 && n < columns.count {
                    if !columns[n].isEmpty { return columns[n][min(i, columns[n].count - 1)] }
                    n += delta
                }
                return nil
            }
        }
        return nil
    }

    func peekPosition(_ id: String) -> (index: Int, total: Int)? {
        for column in peekColumns {
            if let i = column.firstIndex(of: id) { return (i + 1, column.count) }
        }
        return nil
    }

    // MARK: Writes

    private func describe(_ error: Error) -> String {
        if let e = error as? APIError {
            if e.status == 409 { return tr("issues", "revision.conflict") }
            return e.message
        }
        return error.localizedDescription
    }

    /// Optimistic single-issue write; rolls back and toasts on failure.
    func update(_ id: String, _ patch: IssueListPatch, errorMessage: String? = nil, onSuccess: (() -> Void)? = nil) {
        let previous = session.issues.patch(id) { patch.applied(to: $0) }
        refilterBranches()
        let fields = patch.json
        Task {
            do {
                let updated = try await session.api.issueListUpdate(id, fields: fields)
                session.issues.upsert(updated)
                onSuccess?()
            } catch {
                if let previous { session.issues.restore(previous) }
                refilterBranches()
                toast?(describe(error).isEmpty ? (errorMessage ?? tr("issues", "detail.update_failed")) : describe(error), true)
            }
        }
    }

    /// Single-issue entry points route agent hand-offs through the run
    /// confirmation (`useIssueActions.updateField`).
    func updateField(_ issue: Issue, _ patch: IssueListPatch) {
        if let intent = runConfirmIntent(issue, patch) {
            runConfirm = intent
            return
        }
        update(issue.id, patch)
    }

    func runConfirmIntent(_ issue: Issue, _ patch: IssueListPatch) -> IssueListRunConfirm? {
        let parked = issue.status == .backlog
        if case .set(let a) = patch.assignee, a.type == "agent" || a.type == "squad", !parked {
            return IssueListRunConfirm(issueIDs: [issue.id], mode: .assign, status: nil, assignee: a)
        }
        if let status = patch.status, status != issue.status, let owner = issue.assignee, owner.type == "agent" || owner.type == "squad" {
            let known = session.issueListStatusEntry(issue.status) != nil || issue.status.builtInCategory != nil
            if parked || !known {
                let target = session.issueListStatusEntry(status)?.category ?? status.builtInCategory
                if status != .backlog && (target == nil || !(target == .done || target == .closed)) {
                    return IssueListRunConfirm(issueIDs: [issue.id], mode: .promote, status: status, assignee: owner)
                }
            }
        }
        return nil
    }

    /// Drag move: positional anchors plus the target column's fields.
    func move(_ id: String, patch: IssueListPatch, before: String?, after: String?, property: (id: String, value: String?)? = nil) {
        let previous = session.issues.patch(id) { patch.applied(to: $0) }
        var fields = patch.json
        fields["position"] = nil
        fields["before_id"] = JSONValue(before)
        fields["after_id"] = JSONValue(after)
        Task {
            do {
                let updated = try await session.api.issueListMove(id, fields: fields)
                session.issues.upsert(updated)
                if let property {
                    if let value = property.value {
                        _ = try await session.api.setIssueProperty(issueId: id, propertyId: property.id, value: .string(value))
                    } else {
                        _ = try await session.api.unsetIssueProperty(issueId: id, propertyId: property.id)
                    }
                }
            } catch {
                if let previous { session.issues.restore(previous) }
                toast?(describe(error).isEmpty ? tr("projects", "detail.toast_move_issue_failed") : describe(error), true)
            }
            scheduleRefresh(delay: 150)
        }
    }

    /// Places a dragged row into a branch immediately (the settle refetch
    /// reconciles with the server).
    func optimisticPlace(_ id: String, inStatus key: IssueStatusKey, order: [String]) {
        for (k, b) in statusBranches where k != key {
            if b.rawIDs.contains(id) { b.rawIDs.removeAll { $0 == id } }
        }
        statusBranch(key).rawIDs = order
        refilterBranches()
    }

    func optimisticPlace(_ id: String, inGroup column: IssueListColumn, order: [String]) {
        for b in groupBranches.values where b.rawIDs.contains(id) { b.rawIDs.removeAll { $0 == id } }
        if let first = column.branchKeys.first { groupBranches[first]?.rawIDs = order }
        refilterBranches()
    }

    static let dragPrefix = "multica-issue:"

    static func draggedID(_ payload: String) -> String? {
        payload.hasPrefix(dragPrefix) ? String(payload.dropFirst(dragPrefix.count)) : nil
    }

    private func positions(_ ids: [String]) -> [String: Double] {
        Dictionary(ids.compactMap { id in session.issues.model(id).map { (id, $0.issue.position) } }, uniquingKeysWith: { a, _ in a })
    }

    /// A row dropped into a status column/section, before `beforeID` (nil =
    /// at the end). Manual order repositions; any other order only changes
    /// the status (and hints when nothing would change).
    func drop(_ id: String, intoStatus key: IssueStatusKey, before beforeID: String?) {
        guard let issue = session.issues.model(id)?.issue else { return }
        if let entry = session.issueListStatusEntry(key), entry.archivedAt != nil, issue.status != key { return }
        let current = statusBranch(key).ids
        if state.sortBy != "position" {
            guard issue.status != key else {
                if beforeID != nil && beforeID != id { toast?(tr("issues", "board.manual_reorder_hint"), false) }
                return
            }
            let order = IssueListDrag.insertByPosition(current, id, position: issue.position, positions: positions(current))
            var patch = IssueListPatch()
            patch.status = key
            let a = IssueListDrag.anchors(of: id, in: order)
            move(id, patch: patch, before: a.before, after: a.after)
            optimisticPlace(id, inStatus: key, order: order)
            return
        }
        let order = IssueListDrag.move(current, id, before: beforeID)
        var map = positions(order)
        map[id] = issue.position
        let position = IssueListDrag.position(of: id, in: order, positions: map)
        if issue.status == key && issue.position == position && order == current { return }
        var patch = IssueListPatch()
        if issue.status != key { patch.status = key }
        patch.position = position
        let a = IssueListDrag.anchors(of: id, in: order)
        move(id, patch: patch, before: a.before, after: a.after)
        optimisticPlace(id, inStatus: key, order: order)
    }

    /// A card dropped into an assignee / project / property column.
    func drop(_ id: String, intoColumn column: IssueListColumn, before beforeID: String?) {
        guard let issue = session.issues.model(id)?.issue else { return }
        if case .status(let key) = column.kind { return drop(id, intoStatus: key, before: beforeID) }
        var patch = IssueListPatch()
        var property: (id: String, value: String?)?
        let matches: Bool
        switch column.kind {
        case .assignee(let ref):
            matches = issue.assignee == ref
            patch.assignee = IssueListField(ref)
        case .project(let pid):
            matches = issue.projectID == pid
            patch.projectID = IssueListField(pid)
        case .property(let pid, let option, _):
            matches = extras[id]?.properties[pid]?.stringValue == option
            property = (pid, option)
        case .status:
            return
        }
        guard !matches else {
            if beforeID != nil && beforeID != id { toast?(tr("issues", "board.manual_reorder_hint"), false) }
            return
        }
        let current = columnIDs(column)
        let order = IssueListDrag.insertByPosition(current, id, position: issue.position, positions: positions(current))
        if let property { extras(id).properties[property.id] = property.value.map(JSONValue.string) }
        let a = IssueListDrag.anchors(of: id, in: order)
        move(id, patch: patch, before: a.before, after: a.after, property: property)
        optimisticPlace(id, inGroup: column, order: order)
    }

    func batchUpdate(_ ids: [String], _ patch: IssueListPatch) async {
        guard !ids.isEmpty else { return }
        var previous: [Issue] = []
        for id in ids {
            if let p = session.issues.patch(id, { patch.applied(to: $0) }) { previous.append(p) }
        }
        refilterBranches()
        do {
            _ = try await session.api.issueListBatchUpdate(ids, updates: patch.json)
            toast?(tr("issues", "batch.update_success", ["count": ids.count]), false)
        } catch {
            for p in previous { session.issues.restore(p) }
            toast?(describe(error).isEmpty ? tr("issues", "batch.update_failed") : describe(error), true)
        }
        scheduleRefresh(delay: 100)
    }

    func batchLabel(_ ids: [String], label: IssueLabel, attach: Bool) async {
        var failed = false
        await withTaskGroup(of: Bool.self) { tg in
            for id in ids {
                tg.addTask { [api = session.api] in
                    do {
                        _ = attach ? try await api.attachLabel(issueId: id, labelId: label.id) : try await api.detachLabel(issueId: id, labelId: label.id)
                        return true
                    } catch { return false }
                }
            }
            for await ok in tg where !ok { failed = true }
        }
        toast?(failed ? tr("issues", "batch.update_failed") : tr("issues", "batch.update_success", ["count": ids.count]), failed)
        scheduleRefresh(delay: 100)
    }
}

enum IssueListStep { case previous, next, left, right }
