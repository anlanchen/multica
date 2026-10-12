import Foundation

// Issue surface view state (upstream packages/core/issues/stores/view-store.ts).
// The JSON shape (camelCase keys) is the upstream persisted/saved-view shape,
// so saved view definitions round-trip with the web and desktop clients.

public enum IssueListViewMode: String, Sendable, Hashable, CaseIterable {
    case board, list, table, gantt, swimlane
}

public enum IssueListSwimlaneGrouping: String, Sendable, Hashable, CaseIterable {
    case parent, project, assignee
}

public enum IssueListGanttZoom: String, Sendable, Hashable, CaseIterable {
    case day, week, month
}

public enum IssueListSortDirection: String, Sendable, Hashable {
    case asc, desc
    public var toggled: IssueListSortDirection { self == .asc ? .desc : .asc }
}

public enum IssueListTableCalculation: String, Sendable, Hashable, CaseIterable {
    case none, sum, average, count
}

public struct IssueListActorFilter: Sendable, Hashable {
    public var type: String
    public var id: String

    public init(type: String, id: String) {
        self.type = type
        self.id = id
    }

    public var key: String { "\(type):\(id)" }

    var json: JSONValue { .object(["type": .string(type), "id": .string(id)]) }
}

public struct IssueListDateFilter: Sendable, Hashable {
    /// `created_at` or `updated_at`.
    public var field: String
    /// `YYYY-MM-DD`, inclusive.
    public var from: String
    public var to: String

    public init(field: String, from: String, to: String) {
        self.field = field
        self.from = from
        self.to = to
    }
}

/// One OR-alternative of a custom-property filter: an exact value (or the
/// `__none__` sentinel) or a scalar operator.
public enum IssueListPropertyFilterValue: Sendable, Hashable {
    case equals(String)
    case op(String, String)

    public static let noValue = "__none__"
    public static let knownOps = ["contains", "gt", "gte", "lt", "lte", "before", "after"]

    public static func opsForType(_ type: String) -> [String] {
        switch type {
        case "text", "url": return ["contains"]
        case "number": return ["gt", "gte", "lt", "lte"]
        case "date": return ["before", "after"]
        default: return []
        }
    }

    public static func opSymbol(_ op: String) -> String? {
        ["gt": ">", "gte": "≥", "lt": "<", "lte": "≤"][op]
    }

    /// Canonical membership key (`propertyFilterValueKey`).
    public var key: String {
        switch self {
        case .equals(let s): return s
        case .op(let op, let v): return "\(op)\u{0}\(v)"
        }
    }

    public var isNoValue: Bool { self == .equals(Self.noValue) }

    public var json: JSONValue {
        switch self {
        case .equals(let s): return .string(s)
        case .op(let op, let v): return .object(["op": .string(op), "value": .string(v)])
        }
    }

    /// Drops members this client cannot represent (unknown op, wrong types).
    public init?(json: JSONValue) {
        switch json {
        case .string(let s): self = .equals(s)
        case .object(let o):
            guard case .string(let op)? = o["op"], case .string(let v)? = o["value"],
                  Self.knownOps.contains(op) else { return nil }
            self = .op(op, v)
        default: return nil
        }
    }
}

public struct IssueListCardProperties: Sendable, Hashable {
    public var priority = true
    public var description = false
    public var assignee = true
    public var startDate = false
    public var dueDate = true
    public var project = true
    public var childProgress = true
    public var labels = false

    public init() {}

    /// Upstream CARD_PROPERTY_OPTIONS order.
    public static let keys = ["priority", "description", "assignee", "startDate", "dueDate", "project", "labels", "childProgress"]

    public subscript(key: String) -> Bool {
        get {
            switch key {
            case "priority": return priority
            case "description": return description
            case "assignee": return assignee
            case "startDate": return startDate
            case "dueDate": return dueDate
            case "project": return project
            case "childProgress": return childProgress
            case "labels": return labels
            default: return false
            }
        }
        set {
            switch key {
            case "priority": priority = newValue
            case "description": description = newValue
            case "assignee": assignee = newValue
            case "startDate": startDate = newValue
            case "dueDate": dueDate = newValue
            case "project": project = newValue
            case "childProgress": childProgress = newValue
            case "labels": labels = newValue
            default: break
            }
        }
    }

    var json: JSONValue {
        .object(Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, JSONValue.bool(self[$0])) }))
    }
}

public struct IssueListTableColumn: Sendable, Hashable, Identifiable {
    public var key: String
    public var width: Double?

    public init(key: String, width: Double? = nil) {
        self.key = key
        self.width = width
    }

    public var id: String { key }

    var json: JSONValue {
        var o: [String: JSONValue] = ["key": .string(key)]
        if let width { o["width"] = .number(width) }
        return .object(o)
    }
}

/// The ten query-defining filter fields (`FilterSnapshot`).
public struct IssueListFilterSnapshot: Sendable, Hashable {
    public var statusFilters: [String] = []
    public var priorityFilters: [String] = []
    public var assigneeFilters: [IssueListActorFilter] = []
    public var includeNoAssignee = false
    public var creatorFilters: [IssueListActorFilter] = []
    public var projectFilters: [String] = []
    public var includeNoProject = false
    public var projectStatusFilters: [String] = []
    public var labelFilters: [String] = []
    public var propertyFilters: [String: [IssueListPropertyFilterValue]] = [:]

    public init() {}
}

public enum IssueListFilterDimension: Sendable, Hashable {
    case status, priority, assignee, creator, project, projectStatus, label
    case property(String)
}

public enum IssueListOptions {
    public static let propertyPrefix = "property:"

    public static func propertyID(fromKey key: String) -> String? {
        key.hasPrefix(propertyPrefix) ? String(key.dropFirst(propertyPrefix.count)) : nil
    }

    /// SORT_OPTIONS values, in menu order.
    public static let sortFields = ["position", "status", "priority", "start_date", "due_date", "created_at", "updated_at", "title"]
    /// GROUPING_OPTIONS values.
    public static let groupings = ["status", "assignee", "project"]
    public static let priorityDisplayOrder = ["none", "urgent", "high", "medium", "low"]
    public static let projectStatusOrder = ["planned", "in_progress", "paused", "completed", "cancelled"]
    public static let defaultHiddenStatuses = ["cancelled"]

    public static let tableSystemColumns = [
        "title", "identifier", "status", "priority", "assignee", "labels", "project",
        "start_date", "due_date", "created_at", "updated_at", "child_progress", "creator",
    ]

    public static let defaultTableColumns = [
        IssueListTableColumn(key: "title", width: 360),
        IssueListTableColumn(key: "status", width: 150),
        IssueListTableColumn(key: "priority", width: 130),
        IssueListTableColumn(key: "assignee", width: 180),
        IssueListTableColumn(key: "due_date", width: 140),
        IssueListTableColumn(key: "labels", width: 220),
    ]

    public static func defaultSortDirection(_ field: String) -> IssueListSortDirection {
        field == "created_at" || field == "updated_at" ? .desc : .asc
    }

    /// `sortOptionsForView`: manual order only means something per status column.
    public static func sortFields(grouping: String) -> [String] {
        grouping == "status" ? sortFields : sortFields.filter { $0 != "position" }
    }

    /// `cardPropertyOptionsForView`.
    public static func cardPropertyKeys(for mode: IssueListViewMode) -> [String] {
        switch mode {
        case .table, .gantt: return []
        case .list: return IssueListCardProperties.keys.filter { $0 != "description" }
        default: return IssueListCardProperties.keys
        }
    }

    /// `sortDirectionLabelKey` — a key under `issues:display.`.
    public static func sortDirectionLabelKey(field: String, direction: IssueListSortDirection) -> String {
        switch field {
        case "created_at", "updated_at": return direction == .desc ? "newest_first" : "oldest_first"
        case "start_date", "due_date": return direction == .asc ? "earliest_first" : "latest_first"
        case "priority": return direction == .asc ? "highest_priority_first" : "lowest_priority_first"
        case "status": return direction == .asc ? "workflow_order" : "reverse_workflow_order"
        case "title": return direction == .asc ? "alphabetical_order" : "reverse_alphabetical_order"
        default: return direction == .asc ? "ascending_title" : "descending_title"
        }
    }

    /// Key under `issues:display.` for a static sort field.
    public static func sortLabelKey(_ field: String) -> String? {
        switch field {
        case "position": return "sort_manual"
        case "status": return "sort_status"
        case "priority": return "sort_priority"
        case "start_date": return "sort_start_date"
        case "due_date": return "sort_due_date"
        case "created_at": return "sort_created"
        case "updated_at": return "sort_updated"
        case "title": return "sort_title"
        default: return nil
        }
    }

    public static func cardPropertyLabelKey(_ key: String) -> String {
        switch key {
        case "startDate": return "card_start_date"
        case "dueDate": return "card_due_date"
        case "childProgress": return "card_child_progress"
        default: return "card_\(key)"
        }
    }

    public static func isFilterablePropertyType(_ type: String) -> Bool {
        ["select", "multi_select", "checkbox", "text", "url", "number", "date", "actor", "multi_actor", "multi_text", "multi_url"].contains(type)
    }

    public static func isScalarPropertyType(_ type: String) -> Bool {
        ["text", "url", "number", "date"].contains(type)
    }

    public static func isListPropertyType(_ type: String) -> Bool {
        type == "multi_text" || type == "multi_url"
    }

    public static func isActorPropertyType(_ type: String) -> Bool {
        type == "actor" || type == "multi_actor"
    }
}

public struct IssueListViewState: Sendable, Hashable {
    public var viewMode: IssueListViewMode = .board
    /// `status` | `assignee` | `project` | `property:<id>`.
    public var grouping = "status"
    public var statusFilters: [String] = []
    public var priorityFilters: [String] = []
    public var assigneeFilters: [IssueListActorFilter] = []
    public var includeNoAssignee = false
    public var creatorFilters: [IssueListActorFilter] = []
    public var projectFilters: [String] = []
    public var includeNoProject = false
    public var projectStatusFilters: [String] = []
    public var labelFilters: [String] = []
    public var propertyFilters: [String: [IssueListPropertyFilterValue]] = [:]
    /// Not persisted: relative presets go stale after a day rollover.
    public var dateFilter: IssueListDateFilter?
    /// Not persisted: running state changes second to second.
    public var agentRunningFilter = false
    public var sortBy = "created_at"
    public var sortDirection: IssueListSortDirection = .desc
    public var sortDirections: [String: IssueListSortDirection] = ["created_at": .desc]
    public var cardProperties = IssueListCardProperties()
    public var cardPropertyIds: [String] = []
    public var showSubIssues = true
    public var listCollapsedStatuses: [String] = []
    public var hiddenStatuses: [String] = IssueListOptions.defaultHiddenStatuses
    public var ganttZoom: IssueListGanttZoom = .week
    public var ganttShowCompleted = false
    public var swimlaneGrouping: IssueListSwimlaneGrouping = .assignee
    public var swimlaneOrders: [String: [String]] = ["parent": [], "project": [], "assignee": []]
    public var collapsedSwimlanes: [String: [String]] = ["parent": [], "project": [], "assignee": []]
    public var tableColumns: [IssueListTableColumn] = IssueListOptions.defaultTableColumns
    /// `none` | `status` | `assignee` | `project` | `property:<id>`.
    public var tableGrouping = "none"
    public var tableCollapsedGroups: [String] = []
    public var tableCollapsedParents: [String] = []
    public var tableHierarchy = true
    public var tableCalculation: IssueListTableCalculation = .none

    public init() {}

    /// Defaults for a surface key (project surfaces hide the project chip).
    public static func defaults(surfaceKey: String) -> IssueListViewState {
        var s = IssueListViewState()
        if surfaceKey.hasPrefix("project:") { s.cardProperties.project = false }
        return s
    }

    // MARK: Filters

    public var filterSnapshot: IssueListFilterSnapshot {
        var f = IssueListFilterSnapshot()
        f.statusFilters = statusFilters
        f.priorityFilters = priorityFilters
        f.assigneeFilters = assigneeFilters
        f.includeNoAssignee = includeNoAssignee
        f.creatorFilters = creatorFilters
        f.projectFilters = projectFilters
        f.includeNoProject = includeNoProject
        f.projectStatusFilters = projectStatusFilters
        f.labelFilters = labelFilters
        f.propertyFilters = propertyFilters
        return f
    }

    public mutating func resetFilters(to f: IssueListFilterSnapshot) {
        statusFilters = f.statusFilters
        priorityFilters = f.priorityFilters
        assigneeFilters = f.assigneeFilters
        includeNoAssignee = f.includeNoAssignee
        creatorFilters = f.creatorFilters
        projectFilters = f.projectFilters
        includeNoProject = f.includeNoProject
        projectStatusFilters = f.projectStatusFilters
        labelFilters = f.labelFilters
        propertyFilters = f.propertyFilters
    }

    public mutating func clearFilters() {
        resetFilters(to: IssueListFilterSnapshot())
        dateFilter = nil
        agentRunningFilter = false
    }

    private static func toggled(_ list: [String], _ value: String) -> [String] {
        list.contains(value) ? list.filter { $0 != value } : list + [value]
    }

    private static func toggled(_ list: [IssueListActorFilter], _ value: IssueListActorFilter) -> [IssueListActorFilter] {
        list.contains(value) ? list.filter { $0 != value } : list + [value]
    }

    public mutating func toggleStatusFilter(_ key: String) { statusFilters = Self.toggled(statusFilters, key) }
    public mutating func togglePriorityFilter(_ p: String) { priorityFilters = Self.toggled(priorityFilters, p) }
    public mutating func toggleAssigneeFilter(_ a: IssueListActorFilter) { assigneeFilters = Self.toggled(assigneeFilters, a) }
    public mutating func toggleCreatorFilter(_ a: IssueListActorFilter) { creatorFilters = Self.toggled(creatorFilters, a) }
    public mutating func toggleProjectFilter(_ id: String) { projectFilters = Self.toggled(projectFilters, id) }
    public mutating func toggleProjectStatusFilter(_ s: String) { projectStatusFilters = Self.toggled(projectStatusFilters, s) }
    public mutating func toggleLabelFilter(_ id: String) { labelFilters = Self.toggled(labelFilters, id) }

    public mutating func togglePropertyFilter(_ propertyID: String, _ optionID: String) {
        let current = propertyFilters[propertyID] ?? []
        let member = IssueListPropertyFilterValue.equals(optionID)
        let next = current.contains(member) ? current.filter { $0 != member } : current + [member]
        propertyFilters[propertyID] = next.isEmpty ? nil : next
    }

    public mutating func setPropertyFilterValues(_ propertyID: String, _ values: [IssueListPropertyFilterValue]) {
        propertyFilters[propertyID] = values.isEmpty ? nil : values
    }

    public mutating func clearFilterDimension(_ d: IssueListFilterDimension) {
        switch d {
        case .status: statusFilters = []
        case .priority: priorityFilters = []
        case .assignee: assigneeFilters = []; includeNoAssignee = false
        case .creator: creatorFilters = []
        case .project: projectFilters = []; includeNoProject = false
        case .projectStatus: projectStatusFilters = []
        case .label: labelFilters = []
        case .property(let id): propertyFilters[id] = nil
        }
    }

    /// Removing a chip inside a saved view returns that dimension to the
    /// view's own values, never to empty.
    public mutating func clearFilterDimension(_ d: IssueListFilterDimension, baseline: IssueListBaseline?) {
        guard let raw = baseline?.raw else { return clearFilterDimension(d) }
        switch d {
        case .status: statusFilters = raw.statusFilters
        case .priority: priorityFilters = raw.priorityFilters
        case .assignee: assigneeFilters = raw.assigneeFilters; includeNoAssignee = raw.includeNoAssignee
        case .creator: creatorFilters = raw.creatorFilters
        case .project: projectFilters = raw.projectFilters; includeNoProject = raw.includeNoProject
        case .projectStatus: projectStatusFilters = raw.projectStatusFilters
        case .label: labelFilters = raw.labelFilters
        case .property(let id): propertyFilters[id] = raw.propertyFilters[id]
        }
    }

    /// Property filters limited to active definitions; nil `activeIDs` (catalog
    /// not settled) passes them through unchanged.
    public func effectivePropertyFilters(activeIDs: Set<String>?) -> [String: [IssueListPropertyFilterValue]] {
        propertyFilters.filter { id, selected in !selected.isEmpty && (activeIDs?.contains(id) ?? true) }
    }

    /// Exactly what `clearFilters()` resets, so a filtered-empty surface can
    /// always offer a button that fixes it.
    public func hasActiveFilters(activePropertyIDs: Set<String>?, ignoringProjects: Bool = false) -> Bool {
        !statusFilters.isEmpty || !priorityFilters.isEmpty || !assigneeFilters.isEmpty || includeNoAssignee
            || !creatorFilters.isEmpty
            || (!ignoringProjects && (!projectFilters.isEmpty || includeNoProject))
            || !projectStatusFilters.isEmpty || !labelFilters.isEmpty
            || !effectivePropertyFilters(activeIDs: activePropertyIDs).isEmpty
            || dateFilter != nil || agentRunningFilter
    }

    /// `getActiveFilterCount`: dimensions with user additions on top of the
    /// open view (the view's own conditions do not count).
    public func activeFilterCount(baseline: IssueListBaseline?, activePropertyIDs: Set<String>?, includeDate: Bool) -> Int {
        func delta(_ values: [String], _ fixed: Set<String>?) -> Int {
            guard let fixed else { return values.count }
            return values.filter { !fixed.contains($0) }.count
        }
        var n = 0
        if delta(statusFilters, baseline?.status) > 0 { n += 1 }
        if delta(priorityFilters, baseline?.priority) > 0 { n += 1 }
        if delta(assigneeFilters.map(\.key), baseline?.assignee) > 0 || (includeNoAssignee && !(baseline?.includeNoAssignee ?? false)) { n += 1 }
        if delta(creatorFilters.map(\.key), baseline?.creator) > 0 { n += 1 }
        if delta(projectFilters, baseline?.project) > 0 || (includeNoProject && !(baseline?.includeNoProject ?? false)) { n += 1 }
        if delta(projectStatusFilters, baseline?.projectStatus) > 0 { n += 1 }
        if delta(labelFilters, baseline?.label) > 0 { n += 1 }
        for (id, selected) in effectivePropertyFilters(activeIDs: activePropertyIDs) {
            if delta(selected.map(\.key), baseline?.property[id]) > 0 { n += 1 }
        }
        if includeDate && dateFilter != nil { n += 1 }
        return n
    }

    // MARK: Display

    /// Manual order is one `issue.position` sequence per status column; it has
    /// no honest meaning under another grouping.
    public mutating func normalizeSortForGrouping() {
        if grouping != "status" && sortBy == "position" {
            sortBy = "created_at"
            sortDirection = .desc
        }
    }

    public mutating func setViewMode(_ mode: IssueListViewMode) {
        viewMode = mode
        normalizeSortForGrouping()
    }

    public mutating func setGrouping(_ g: String) {
        grouping = g
        normalizeSortForGrouping()
    }

    public mutating func setSortBy(_ field: String) {
        sortBy = field
        sortDirection = sortDirections[field] ?? IssueListOptions.defaultSortDirection(field)
        normalizeSortForGrouping()
        sortDirections[sortBy] = sortDirection
    }

    public mutating func setSortDirection(_ d: IssueListSortDirection) {
        sortDirection = d
        sortDirections[sortBy] = d
    }

    public mutating func toggleCardProperty(_ key: String) { cardProperties[key].toggle() }
    public mutating func toggleCardPropertyID(_ id: String) { cardPropertyIds = Self.toggled(cardPropertyIds, id) }
    public mutating func toggleListCollapsed(_ status: String) { listCollapsedStatuses = Self.toggled(listCollapsedStatuses, status) }

    public mutating func hideStatus(_ status: String) {
        if !hiddenStatuses.contains(status) { hiddenStatuses.append(status) }
    }

    public mutating func showStatus(_ status: String) {
        hiddenStatuses.removeAll { $0 == status }
    }

    public mutating func setSwimlaneOrder(_ order: [String]) {
        swimlaneOrders[swimlaneGrouping.rawValue] = order
    }

    public mutating func toggleSwimlaneCollapsed(_ key: String) {
        let g = swimlaneGrouping.rawValue
        collapsedSwimlanes[g] = Self.toggled(collapsedSwimlanes[g] ?? [], key)
    }

    public mutating func toggleTableColumn(_ key: String) {
        guard key != "title" else { return }
        if tableColumns.contains(where: { $0.key == key }) {
            tableColumns.removeAll { $0.key == key }
        } else {
            tableColumns.append(IssueListTableColumn(key: key))
        }
    }

    public mutating func reorderTableColumn(_ active: String, over: String) {
        guard active != "title", over != "title", active != over,
              let from = tableColumns.firstIndex(where: { $0.key == active }),
              let to = tableColumns.firstIndex(where: { $0.key == over }) else { return }
        let moved = tableColumns.remove(at: from)
        tableColumns.insert(moved, at: to)
    }

    public mutating func setTableColumnWidth(_ key: String, _ width: Double?) {
        guard let i = tableColumns.firstIndex(where: { $0.key == key }) else { return }
        tableColumns[i].width = width
    }

    public mutating func toggleTableGroupCollapsed(_ key: String) { tableCollapsedGroups = Self.toggled(tableCollapsedGroups, key) }
    public mutating func toggleTableParentCollapsed(_ id: String) { tableCollapsedParents = Self.toggled(tableCollapsedParents, id) }
}

// MARK: - JSON (persisted snapshot / saved view definition)

extension IssueListViewState {
    private static func strings(_ v: JSONValue?) -> [String]? {
        guard case .array(let a)? = v else { return nil }
        return a.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    private static func actors(_ v: JSONValue?) -> [IssueListActorFilter]? {
        guard case .array(let a)? = v else { return nil }
        return a.compactMap { item in
            guard case .string(let id)? = item["id"] else { return nil }
            return IssueListActorFilter(type: item["type"]?.stringValue ?? "member", id: id)
        }
    }

    private static func propertyFilters(_ v: JSONValue?) -> [String: [IssueListPropertyFilterValue]]? {
        guard case .object(let o)? = v else { return nil }
        var out: [String: [IssueListPropertyFilterValue]] = [:]
        for (id, members) in o {
            guard case .array(let a) = members else { continue }
            let parsed = a.compactMap(IssueListPropertyFilterValue.init(json:))
            if !parsed.isEmpty { out[id] = parsed }
        }
        return out
    }

    private static func bool(_ v: JSONValue?) -> Bool? {
        if case .bool(let b)? = v { return b }
        return nil
    }

    /// Legacy category names in persisted hidden/collapsed lists.
    private static func statusKeys(_ v: JSONValue?, legacyCategories: Bool) -> [String]? {
        guard let list = strings(v) else { return nil }
        let aliases: [String: [String]] = [
            "unstarted": ["backlog", "todo"], "started": ["in_progress", "in_review", "blocked"],
            "completed": ["done"], "closed": ["cancelled"], "canceled": ["cancelled"],
        ]
        var seen = Set<String>()
        var out: [String] = []
        for k in list.flatMap({ legacyCategories ? aliases[$0] ?? [$0] : [$0] }) where seen.insert(k).inserted {
            out.append(k)
        }
        return out
    }

    /// `mergeViewStatePersisted`: every field read leniently over `defaults`,
    /// so a malformed or older blob degrades field by field.
    public init(json p: [String: JSONValue], defaults: IssueListViewState) {
        self = defaults
        if let m = p["viewMode"]?.stringValue.flatMap(IssueListViewMode.init(rawValue:)) { viewMode = m }
        if case .string(let g)? = p["grouping"], !g.isEmpty { grouping = g }
        if let v = Self.strings(p["statusFilters"]) { statusFilters = v.filter { !$0.isEmpty } }
        if let v = Self.strings(p["priorityFilters"]) { priorityFilters = v.filter { IssueListOptions.priorityDisplayOrder.contains($0) } }
        if let v = Self.actors(p["assigneeFilters"]) { assigneeFilters = v }
        if let v = Self.bool(p["includeNoAssignee"]) { includeNoAssignee = v }
        if let v = Self.actors(p["creatorFilters"]) { creatorFilters = v }
        if let v = Self.strings(p["projectFilters"]) { projectFilters = v }
        if let v = Self.bool(p["includeNoProject"]) { includeNoProject = v }
        if let v = Self.strings(p["projectStatusFilters"]) { projectStatusFilters = v.filter { IssueListOptions.projectStatusOrder.contains($0) } }
        if let v = Self.strings(p["labelFilters"]) { labelFilters = v }
        if let v = Self.propertyFilters(p["propertyFilters"]) { propertyFilters = v }
        if case .string(let s)? = p["sortBy"], !s.isEmpty { sortBy = s }
        if let d = p["sortDirection"]?.stringValue.flatMap(IssueListSortDirection.init(rawValue:)) { sortDirection = d }
        if case .object(let o)? = p["sortDirections"] {
            for (k, v) in o {
                if let d = v.stringValue.flatMap(IssueListSortDirection.init(rawValue:)) { sortDirections[k] = d }
            }
        }
        if case .object(let o)? = p["cardProperties"] {
            for (k, v) in o { if case .bool(let b) = v { cardProperties[k] = b } }
        }
        if let v = Self.strings(p["cardPropertyIds"]) { cardPropertyIds = v }
        if let v = Self.bool(p["showSubIssues"]) { showSubIssues = v }
        let legacy = p["hiddenStatuses"] == nil
        if let v = Self.statusKeys(p["hiddenStatuses"] ?? p["hiddenStatusCategories"], legacyCategories: legacy) { hiddenStatuses = v }
        if let v = Self.statusKeys(p["listCollapsedStatuses"], legacyCategories: legacy) { listCollapsedStatuses = v }
        if let z = p["ganttZoom"]?.stringValue.flatMap(IssueListGanttZoom.init(rawValue:)) { ganttZoom = z }
        if let v = Self.bool(p["ganttShowCompleted"]) { ganttShowCompleted = v }
        if let g = p["swimlaneGrouping"]?.stringValue.flatMap(IssueListSwimlaneGrouping.init(rawValue:)) { swimlaneGrouping = g }
        if case .object(let o)? = p["swimlaneOrders"] {
            for (k, v) in o { if let list = Self.strings(v) { swimlaneOrders[k] = list } }
        }
        if case .object(let o)? = p["collapsedSwimlanes"] {
            for (k, v) in o { if let list = Self.strings(v) { collapsedSwimlanes[k] = list } }
        }
        if case .array(let a)? = p["tableColumns"] {
            var seen = Set<String>()
            var columns: [IssueListTableColumn] = []
            var title: IssueListTableColumn?
            for item in a {
                guard case .string(let key)? = item["key"] else { continue }
                let column = IssueListTableColumn(key: key, width: item["width"]?.doubleValue)
                if key == "title" { title = title ?? column; continue }
                if seen.insert(key).inserted { columns.append(column) }
            }
            tableColumns = [title ?? defaults.tableColumns.first ?? IssueListTableColumn(key: "title")] + columns
        }
        if case .string(let g)? = p["tableGrouping"], !g.isEmpty { tableGrouping = g }
        if let v = Self.strings(p["tableCollapsedGroups"]) { tableCollapsedGroups = v }
        if let v = Self.strings(p["tableCollapsedParents"]) { tableCollapsedParents = v }
        if let v = Self.bool(p["tableHierarchy"]) { tableHierarchy = v }
        if let c = p["tableCalculation"]?.stringValue.flatMap(IssueListTableCalculation.init(rawValue:)) { tableCalculation = c }
        normalizeSortForGrouping()
    }

    /// The saved-view `query` blob.
    public var queryJSON: [String: JSONValue] {
        [
            "statusFilters": JSONValue(statusFilters),
            "priorityFilters": JSONValue(priorityFilters),
            "assigneeFilters": .array(assigneeFilters.map(\.json)),
            "includeNoAssignee": .bool(includeNoAssignee),
            "creatorFilters": .array(creatorFilters.map(\.json)),
            "projectFilters": JSONValue(projectFilters),
            "includeNoProject": .bool(includeNoProject),
            "projectStatusFilters": JSONValue(projectStatusFilters),
            "labelFilters": JSONValue(labelFilters),
            "propertyFilters": .object(propertyFilters.mapValues { .array($0.map(\.json)) }),
        ]
    }

    /// The saved-view `display` blob.
    public var displayJSON: [String: JSONValue] {
        [
            "showSubIssues": .bool(showSubIssues),
            "viewMode": .string(viewMode.rawValue),
            "grouping": .string(grouping),
            "sortBy": .string(sortBy),
            "sortDirection": .string(sortDirection.rawValue),
            "cardProperties": cardProperties.json,
            "cardPropertyIds": JSONValue(cardPropertyIds),
            "tableColumns": .array(tableColumns.map(\.json)),
            "tableGrouping": .string(tableGrouping),
            "tableHierarchy": .bool(tableHierarchy),
            "tableCalculation": .string(tableCalculation.rawValue),
            "swimlaneGrouping": .string(swimlaneGrouping.rawValue),
            "ganttZoom": .string(ganttZoom.rawValue),
            "ganttShowCompleted": .bool(ganttShowCompleted),
        ]
    }

    /// The persisted snapshot (`partialize`): everything but the date filter
    /// and the agents-working toggle.
    public var persistedJSON: [String: JSONValue] {
        var o = queryJSON
        for (k, v) in displayJSON { o[k] = v }
        o["sortDirections"] = .object(sortDirections.mapValues { .string($0.rawValue) })
        o["listCollapsedStatuses"] = JSONValue(listCollapsedStatuses)
        o["hiddenStatuses"] = JSONValue(hiddenStatuses)
        o["swimlaneOrders"] = .object(swimlaneOrders.mapValues { JSONValue($0) })
        o["collapsedSwimlanes"] = .object(collapsedSwimlanes.mapValues { JSONValue($0) })
        o["tableCollapsedGroups"] = JSONValue(tableCollapsedGroups)
        o["tableCollapsedParents"] = JSONValue(tableCollapsedParents)
        return o
    }
}

// MARK: - Saved-view baseline

/// The open saved view's query normalized for membership checks (fixed values
/// render checked-and-disabled) and resets (`raw`).
public struct IssueListBaseline: Sendable, Hashable {
    public var status: Set<String>
    public var priority: Set<String>
    public var assignee: Set<String>
    public var includeNoAssignee: Bool
    public var creator: Set<String>
    public var project: Set<String>
    public var includeNoProject: Bool
    public var projectStatus: Set<String>
    public var label: Set<String>
    public var property: [String: Set<String>]
    public var raw: IssueListFilterSnapshot

    public init(query: [String: JSONValue]) {
        let parsed = IssueListViewState(json: query, defaults: IssueListViewState())
        var raw = IssueListFilterSnapshot()
        raw.statusFilters = query["statusFilters"] == nil ? [] : parsed.statusFilters
        raw.priorityFilters = query["priorityFilters"] == nil ? [] : parsed.priorityFilters
        raw.assigneeFilters = query["assigneeFilters"] == nil ? [] : parsed.assigneeFilters
        raw.includeNoAssignee = query["includeNoAssignee"] == .bool(true)
        raw.creatorFilters = query["creatorFilters"] == nil ? [] : parsed.creatorFilters
        raw.projectFilters = query["projectFilters"] == nil ? [] : parsed.projectFilters
        raw.includeNoProject = query["includeNoProject"] == .bool(true)
        raw.projectStatusFilters = query["projectStatusFilters"] == nil ? [] : parsed.projectStatusFilters
        raw.labelFilters = query["labelFilters"] == nil ? [] : parsed.labelFilters
        raw.propertyFilters = query["propertyFilters"] == nil ? [:] : parsed.propertyFilters
        self.raw = raw
        status = Set(raw.statusFilters)
        priority = Set(raw.priorityFilters)
        assignee = Set(raw.assigneeFilters.map(\.key))
        includeNoAssignee = raw.includeNoAssignee
        creator = Set(raw.creatorFilters.map(\.key))
        project = Set(raw.projectFilters)
        includeNoProject = raw.includeNoProject
        projectStatus = Set(raw.projectStatusFilters)
        label = Set(raw.labelFilters)
        property = raw.propertyFilters.mapValues { Set($0.map(\.key)) }
    }

    /// Dimensions the view fixes (locked chips/sections).
    public var lockedDimensions: Set<IssueListFilterDimension> {
        var out: Set<IssueListFilterDimension> = []
        if !status.isEmpty { out.insert(.status) }
        if !priority.isEmpty { out.insert(.priority) }
        if !assignee.isEmpty || includeNoAssignee { out.insert(.assignee) }
        if !creator.isEmpty { out.insert(.creator) }
        if !project.isEmpty || includeNoProject { out.insert(.project) }
        if !projectStatus.isEmpty { out.insert(.projectStatus) }
        if !label.isEmpty { out.insert(.label) }
        for (id, members) in property where !members.isEmpty { out.insert(.property(id)) }
        return out
    }
}

// MARK: - View bar preferences

public enum IssueListBarPrefs {
    /// `applyViewBarPrefs`: the user's order first, unknown ids ignored, items
    /// absent from `order` appended in natural order; the anchor built-in is
    /// never hidden.
    public static func apply(itemIDs: [String], hidden: [String], order: [String], anchorID: String) -> (ordered: [String], visible: [String], hidden: Set<String>) {
        var hiddenSet = Set(hidden)
        hiddenSet.remove(anchorID)
        var remaining = Set(itemIDs)
        var ordered: [String] = []
        for id in order where remaining.contains(id) {
            ordered.append(id)
            remaining.remove(id)
        }
        for id in itemIDs where remaining.contains(id) { ordered.append(id) }
        return (ordered, ordered.filter { !hiddenSet.contains($0) }, hiddenSet)
    }

    /// Client mirror of the server's `canManageIssueView`.
    public static func canManage(ownerID: String, visibility: String, userID: String?, role: String?) -> Bool {
        guard let userID else { return false }
        if ownerID == userID { return true }
        return visibility == "workspace" && (role == "owner" || role == "admin")
    }
}
