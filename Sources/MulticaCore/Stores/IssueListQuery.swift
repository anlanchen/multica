import Foundation

/// Which issues a surface shows (upstream `IssueScope`).
public enum IssueListSurfaceScope: Sendable, Hashable {
    /// `actorKind`: `all` | `members` | `agents`.
    case workspace(actorKind: String)
    /// `relation`: `all` | `assigned` | `created` | `involved`.
    case my(userID: String, relation: String)
    case project(id: String, actorKind: String)
    /// `relation`: `assigned` | `created`.
    case actor(type: String, id: String, relation: String)

    /// Surface persistence identity (`issueScopeKey`).
    public var key: String {
        switch self {
        case .workspace(let k): return "workspace:\(k)"
        case .my(let u, let r): return "my:\(u):\(r)"
        case .project(let id, let k): return k == "members" || k == "agents" ? "project:\(id):\(k)" : "project:\(id)"
        case .actor(let t, let id, let r): return "actor:\(t):\(id):\(r)"
        }
    }

    public var projectID: String? {
        if case .project(let id, _) = self { return id }
        return nil
    }

    /// `assigneeTypesForActorKind`.
    public static func assigneeTypes(_ actorKind: String) -> [String]? {
        switch actorKind {
        case "members": return ["member"]
        case "agents": return ["agent", "squad"]
        default: return nil
        }
    }

    /// Saved-view container (`scope_type`, `scope_id`), nil where views do not exist.
    public var viewContainer: (type: String, id: String?)? {
        switch self {
        case .workspace: return ("workspace", nil)
        case .my: return ("my", nil)
        case .project(let id, _): return ("project", id)
        case .actor: return nil
        }
    }

    /// The scope with the axis a saved view captured (`scope_variant`).
    public func applyingViewVariant(_ variant: String?) -> IssueListSurfaceScope {
        switch self {
        case .workspace:
            return .workspace(actorKind: variant == "members" || variant == "agents" ? variant! : "all")
        case .project(let id, _):
            return .project(id: id, actorKind: variant == "members" || variant == "agents" ? variant! : "all")
        case .my(let u, _):
            let r = ["assigned", "created", "involved"].contains(variant ?? "") ? variant! : "all"
            return .my(userID: u, relation: r)
        case .actor:
            return self
        }
    }

    public var tableScope: JSONValue {
        switch self {
        case .workspace(let k):
            var o: [String: JSONValue] = ["kind": "workspace"]
            if let t = Self.assigneeTypes(k) { o["assignee_types"] = JSONValue(t) }
            return .object(o)
        case .project(let id, let k):
            var o: [String: JSONValue] = ["kind": "project", "project_id": .string(id)]
            if let t = Self.assigneeTypes(k) { o["assignee_types"] = JSONValue(t) }
            return .object(o)
        case .my(_, let r):
            return .object(["kind": "my", "relation": .string(r == "all" ? "any" : r)])
        case .actor(let t, let id, let r):
            return .object([
                "kind": .string(r == "assigned" ? "assignee" : "creator"),
                "actor": .object(["type": .string(t), "id": .string(id)]),
            ])
        }
    }

    /// What a new issue created on this surface inherits.
    public var createDefaults: (assignee: ActorRef?, projectID: String?) {
        switch self {
        case .workspace: return (nil, nil)
        case .project(let id, _): return (nil, id)
        case .my(let u, let r): return (r == "assigned" ? ActorRef(type: "member", id: u) : nil, nil)
        case .actor(let t, let id, let r): return (r == "assigned" ? ActorRef(type: t, id: id) : nil, nil)
        }
    }

    /// Legacy list-API filter (Gantt only).
    public func applyListFilter(_ p: inout ListIssuesParams) {
        switch self {
        case .workspace(let k): p.assigneeTypes = Self.assigneeTypes(k)
        case .project(let id, let k):
            p.projectId = id
            p.assigneeTypes = Self.assigneeTypes(k)
        case .my(let u, let r):
            switch r {
            case "assigned": p.assigneeId = u
            case "created": p.creatorId = u
            case "involved": p.involvesUserId = u
            default: break
            }
        case .actor(_, let id, let r):
            if r == "assigned" { p.assigneeId = id } else { p.creatorId = id }
        }
    }
}

public enum IssueListQuery {
    /// Resolved sort: a sort on a non-active property definition degrades to
    /// manual order. nil `activePropertyIDs` = catalog not settled.
    public static func effectiveSort(_ state: IssueListViewState, activePropertyIDs: Set<String>?) -> (field: String, direction: IssueListSortDirection) {
        if let pid = IssueListOptions.propertyID(fromKey: state.sortBy) {
            if activePropertyIDs == nil || activePropertyIDs!.contains(pid) {
                return (state.sortBy, state.sortDirection)
            }
            return ("position", .asc)
        }
        return (state.sortBy, state.sortBy == "position" ? .asc : state.sortDirection)
    }

    /// Inclusive local-calendar day range → `[start, end+1day)` instants.
    public static func dateRange(_ filter: IssueListDateFilter?, calendar: Calendar = .current) -> (field: String, start: String, end: String)? {
        guard let filter, let a = parseDay(filter.from, calendar), let b = parseDay(filter.to, calendar) else { return nil }
        let start = min(a, b)
        let endDay = max(a, b)
        guard let end = calendar.date(byAdding: .day, value: 1, to: endDay) else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (filter.field, f.string(from: start), f.string(from: end))
    }

    public static func parseDay(_ s: String, _ calendar: Calendar = .current) -> Date? {
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public static func dayString(_ date: Date, _ calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `todayDateOnly` / `addDaysDateOnly`.
    public static func day(offset: Int, from now: Date = Date(), calendar: Calendar = .current) -> String {
        dayString(calendar.date(byAdding: .day, value: offset, to: now) ?? now, calendar)
    }

    /// The canonical server-owned membership query for every list-shaped mode.
    /// `workingIssueIDs` is only sent while the agents-working filter is on
    /// and its projection has resolved.
    public static func spec(
        scope: IssueListSurfaceScope,
        state: IssueListViewState,
        search: String,
        workingIssueIDs: [String]?,
        activePropertyIDs: Set<String>?
    ) -> IssueTableQuerySpec {
        var f = IssueTableFilters()
        if !state.statusFilters.isEmpty { f.statuses = state.statusFilters }
        if !state.priorityFilters.isEmpty { f.priorities = state.priorityFilters }
        if !state.assigneeFilters.isEmpty { f.assignees = state.assigneeFilters.map { IssueActorRef(type: $0.type, id: $0.id) } }
        if state.includeNoAssignee { f.includeNoAssignee = true }
        if !state.creatorFilters.isEmpty { f.creators = state.creatorFilters.map { IssueActorRef(type: $0.type, id: $0.id) } }
        if scope.projectID == nil {
            if !state.projectFilters.isEmpty { f.projectIds = state.projectFilters }
            if state.includeNoProject { f.includeNoProject = true }
        }
        if !state.projectStatusFilters.isEmpty { f.projectStatuses = state.projectStatusFilters }
        if !state.labelFilters.isEmpty { f.labelIds = state.labelFilters }
        let properties = state.effectivePropertyFilters(activeIDs: activePropertyIDs)
        if !properties.isEmpty { f.properties = properties.mapValues { $0.map(\.json) } }
        if let d = dateRange(state.dateFilter) {
            f.date = .object(["field": .string(d.field), "start": .string(d.start), "end": .string(d.end)])
        }
        if state.agentRunningFilter, let workingIssueIDs { f.workingIssueIds = workingIssueIDs }
        f.includeSubIssues = state.showSubIssues
        let sort = effectiveSort(state, activePropertyIDs: activePropertyIDs)
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return IssueTableQuerySpec(
            scope: scope.tableScope,
            filters: f,
            search: trimmed.isEmpty ? nil : trimmed,
            sort: .object(["field": .string(sort.field), "direction": .string(sort.direction.rawValue)])
        )
    }

    /// Stable identity of a spec (cursor chains and selections reset on change).
    public static func fingerprint(_ spec: IssueTableQuerySpec) -> String {
        String(decoding: (try? JSONCoders.encoder.encode(spec)) ?? Data(), as: UTF8.self)
    }

    /// Membership-affecting inputs only (sort excluded): selection resets when
    /// this changes.
    public static func membershipKey(_ spec: IssueTableQuerySpec) -> String {
        var copy = spec
        copy.sort = .null
        return fingerprint(copy)
    }

    public static func facetSpec(_ kind: String, propertyID: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["kind": .string(kind)]
        if let propertyID { o["property_id"] = .string(propertyID) }
        return .object(o)
    }
}

// MARK: - Status columns

public enum IssueListStatusColumns {
    private static let categoryOrder: [StatusCategory] = [.unstarted, .started, .done, .closed]
    private static let builtInOrder: [IssueStatusKey] = [.backlog, .todo, .inProgress, .inReview, .blocked, .done, .cancelled]

    /// `compareIssueStatusEntries`.
    public static func sorted(_ entries: [IssueStatusEntry]) -> [IssueStatusEntry] {
        func rank(_ c: StatusCategory) -> Int { categoryOrder.firstIndex(of: c) ?? categoryOrder.count }
        return entries.sorted { a, b in
            if rank(a.category) != rank(b.category) { return rank(a.category) < rank(b.category) }
            if a.position != b.position { return a.position < b.position }
            if a.isSystem != b.isSystem { return a.isSystem }
            if a.isSystem {
                let ra = builtInOrder.firstIndex(of: a.key) ?? builtInOrder.count
                let rb = builtInOrder.firstIndex(of: b.key) ?? builtInOrder.count
                if ra != rb { return ra < rb }
            }
            return a.key.rawValue < b.key.rawValue
        }
    }

    /// `statusColumnKeys`: catalog order per category, with built-in fallbacks
    /// for categories the catalog does not cover yet.
    public static func columnKeys(entries: [IssueStatusEntry], includeArchived: Bool) -> [IssueStatusKey] {
        let ordered = sorted(entries)
        let known = Set(ordered.map(\.key))
        return categoryOrder.flatMap { category in
            builtInOrder.filter { $0.builtInCategory == category && !known.contains($0) }
                + ordered.filter { $0.category == category && (includeArchived || $0.archivedAt == nil) }.map(\.key)
        }
    }

    /// `visibleStatusKeys`: exact-key filters override hidden-column
    /// preferences (and re-admit archived keys).
    public static func visible(statusFilters: [String], hidden: [String], entries: [IssueStatusEntry]) -> [IssueStatusKey] {
        if !statusFilters.isEmpty {
            let byKey = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let selected = Set(statusFilters.map(IssueStatusKey.init(rawValue:)).filter { $0.builtInCategory != nil || byKey[$0] != nil })
            return columnKeys(entries: entries, includeArchived: true).filter { selected.contains($0) }
        }
        let hiddenSet = Set(hidden)
        return columnKeys(entries: entries, includeArchived: false).filter { !hiddenSet.contains($0.rawValue) }
    }

    /// Hidden-column panel rows: active columns the user hid (only when no
    /// exact-key status filter is in charge).
    public static func hidden(statusFilters: [String], hidden: [String], entries: [IssueStatusEntry]) -> [IssueStatusKey] {
        guard statusFilters.isEmpty else { return [] }
        let hiddenSet = Set(hidden)
        return columnKeys(entries: entries, includeArchived: false).filter { hiddenSet.contains($0.rawValue) }
    }

    /// `useStatusOptions`: active statuses for pickers and filters, one flat
    /// list in category order.
    public static func options(entries: [IssueStatusEntry]) -> [IssueStatusKey] {
        columnKeys(entries: entries, includeArchived: false)
    }

    public static func isCustom(_ key: IssueStatusKey, entry: IssueStatusEntry?) -> Bool {
        guard let entry else { return false }
        return !entry.isSystem && key.builtInCategory == nil
    }
}

// MARK: - Facets

/// One agent running issue work inside a surface (`WorkingAgentSummary`).
public struct IssueListWorkingAgent: Sendable, Hashable, Identifiable {
    public var id: String
    public var runningTaskCount: Int

    public init(id: String, runningTaskCount: Int) {
        self.id = id
        self.runningTaskCount = runningTaskCount
    }
}

/// Exact disjunctive counts from `/api/issues/table/facets`.
public struct IssueListFacetCounts: Sendable, Hashable {
    public var total: Int = 0
    public var status: [String: Int] = [:]
    public var priority: [String: Int] = [:]
    public var assignee: [String: Int] = [:]
    public var creator: [String: Int] = [:]
    public var project: [String: Int] = [:]
    public var label: [String: Int] = [:]
    public var property: [String: [String: Int]] = [:]
    public var noAssignee = 0
    public var noProject = 0
    /// nil when the backend did not answer the facet (indeterminate).
    public var workingAgents: [IssueListWorkingAgent]?

    public init() {}

    public init(_ r: IssueTableFacetsResponse) {
        total = r.total
        for facet in r.facets {
            let kind = facet.kind.stringValue ?? ""
            if kind == "property", let pid = facet.propertyId {
                property[pid] = Dictionary(facet.values.map { ($0.key, $0.count) }, uniquingKeysWith: { a, _ in a })
                continue
            }
            if kind == "working_agents" {
                workingAgents = facet.values.map { IssueListWorkingAgent(id: $0.key, runningTaskCount: $0.count) }
                continue
            }
            for v in facet.values {
                switch kind {
                case "status": status[v.key] = v.count
                case "priority": priority[v.key] = v.count
                case "assignee":
                    if v.key == IssueListPropertyFilterValue.noValue { noAssignee = v.count } else { assignee[v.key] = v.count }
                case "creator": creator[v.key] = v.count
                case "project":
                    if v.key == IssueListPropertyFilterValue.noValue { noProject = v.count } else { project[v.key] = v.count }
                case "label": label[v.key] = v.count
                default: break
                }
            }
        }
    }

    /// Per-status totals, narrowed to the selected keys under a status filter.
    public func statusCounts(selected: [String]) -> [String: Int] {
        guard !selected.isEmpty else { return status }
        let s = Set(selected)
        return status.filter { s.contains($0.key) }
    }
}

// MARK: - Group descriptors

/// `IssueTableGroupValue`.
public enum IssueListGroupValue: Sendable, Hashable {
    case status(String)
    case assignee(ActorRef?)
    case project(String?)
    case parent(id: String?, identifier: String?, title: String?, status: String?, state: String)
    case property(propertyID: String, value: JSONValue?, state: String)
    case unknown

    public init(_ v: JSONValue) {
        switch v["kind"]?.stringValue {
        case "status": self = .status(v["status"]?.stringValue ?? "")
        case "assignee":
            if let actor = v["actor"], case .object = actor, let t = actor["type"]?.stringValue, let id = actor["id"]?.stringValue {
                self = .assignee(ActorRef(type: t, id: id))
            } else {
                self = .assignee(nil)
            }
        case "project":
            self = .project(v["project_id"].flatMap { $0.isNull ? nil : $0.stringValue })
        case "parent":
            let parent = v["parent"]
            self = .parent(
                id: v["parent_id"].flatMap { $0.isNull ? nil : $0.stringValue },
                identifier: parent?["identifier"]?.stringValue,
                title: parent?["title"]?.stringValue,
                status: parent?["status"]?.stringValue,
                state: v["value_state"]?.stringValue ?? "value"
            )
        case "property":
            let value = v["value"]
            self = .property(propertyID: v["property_id"]?.stringValue ?? "", value: value?.isNull == true ? nil : value, state: v["value_state"]?.stringValue ?? "value")
        default: self = .unknown
        }
    }
}

// MARK: - Drag and drop

public enum IssueListDrag {
    public static func statusGroupID(_ status: String) -> String { "status:\(status)" }
    public static func propertyGroupID(_ propertyID: String, _ optionID: String?) -> String { "property:\(propertyID):\(optionID ?? "none")" }
    public static func assigneeGroupID(_ ref: ActorRef?) -> String { ref.map { "assignee:\($0.type):\($0.id)" } ?? "assignee:unassigned" }
    public static func projectGroupID(_ projectID: String?) -> String { "project:\(projectID ?? "none")" }

    /// `computePosition`: midpoint between neighbours, or one past an edge.
    public static func position(of activeID: String, in ids: [String], positions: [String: Double]) -> Double {
        guard let i = ids.firstIndex(of: activeID) else { return 0 }
        func pos(_ id: String) -> Double { positions[id] ?? 0 }
        if ids.count == 1 { return pos(activeID) }
        if i == 0 { return pos(ids[1]) - 1 }
        if i == ids.count - 1 { return pos(ids[i - 1]) + 1 }
        return (pos(ids[i - 1]) + pos(ids[i + 1])) / 2
    }

    /// `getMoveAnchors`.
    public static func anchors(of activeID: String, in ids: [String]) -> (before: String?, after: String?) {
        guard let i = ids.firstIndex(of: activeID) else { return (nil, nil) }
        return (i > 0 ? ids[i - 1] : nil, i < ids.count - 1 ? ids[i + 1] : nil)
    }

    /// `insertIdByPosition`: slot implied by `position ASC`.
    public static func insertByPosition(_ ids: [String], _ id: String, position: Double, positions: [String: Double]) -> [String] {
        var out = ids.filter { $0 != id }
        if let i = out.firstIndex(where: { (positions[$0] ?? -.infinity) > position }) {
            out.insert(id, at: i)
        } else {
            out.append(id)
        }
        return out
    }

    /// Moves `id` to sit before `beforeID` (or to the end when nil).
    public static func move(_ ids: [String], _ id: String, before beforeID: String?) -> [String] {
        var out = ids.filter { $0 != id }
        if let beforeID, let i = out.firstIndex(of: beforeID) { out.insert(id, at: i) } else { out.append(id) }
        return out
    }
}

// MARK: - Text

public enum IssueListText {
    private static let previewMax = 300

    private static func replace(_ s: String, _ pattern: String, _ template: String, options: NSRegularExpression.Options = []) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// `descriptionPreview`: Markdown flattened to one plain-text line.
    public static func descriptionPreview(_ markdown: String) -> String {
        var s = replace(markdown, #"<!-- multica:channel-media:[0-9a-fA-F-]{36} -->"#, "")
        s = replace(s, ##"\\([!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])"##, "$1")
        s = replace(s, #"!file\[[^\]]*\]\((?:[^()]|\([^()]*\))*\)"#, "")
        s = replace(s, #"!\[[^\]]*\]\((?:[^()]|\([^()]*\))*\)"#, "")
        s = replace(s, #"\[([^\]]+)\]\((?:[^()]|\([^()]*\))*\)"#, "$1")
        s = replace(s, #"[*_`~]+"#, "")
        s = replace(s, #"^[\s>#]+"#, "", options: [.anchorsMatchLines])
        s = replace(s, #"\s+"#, " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > previewMax else { return s }
        return String(s.prefix(previewMax - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Case-insensitive substring or pinyin-free match for filter menus.
    public static func matches(_ text: String, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || text.localizedCaseInsensitiveContains(q)
    }
}

// MARK: - Rows with custom property bags

/// One `/api/issues/table/rows` row. The hand-tuned `Issue` drops the custom
/// property bag and the duplicate marker, which cards render.
public struct IssueListRow: Sendable, Hashable, Decodable {
    public var issue: Issue
    public var properties: [String: JSONValue]
    public var duplicateOfIdentifier: String?
    public var directChildCount: Int

    private struct Extras: Decodable {
        var properties: [String: JSONValue]?
        var duplicateOf: JSONValue?
        enum CodingKeys: String, CodingKey {
            case properties
            case duplicateOf = "duplicate_of"
        }
    }

    enum CodingKeys: String, CodingKey {
        case issue
        case directChildCount = "direct_child_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issue = try c.decode(Issue.self, forKey: .issue)
        let extras = try? c.decode(Extras.self, forKey: .issue)
        properties = extras?.properties ?? [:]
        duplicateOfIdentifier = extras?.duplicateOf?["identifier"]?.stringValue
        directChildCount = c.lossy(Int.self, .directChildCount, default: 0)
    }
}

public struct IssueListRowsPage: Sendable, Hashable, Decodable {
    public var queryFingerprint: String
    public var groupKey: String?
    public var parentID: String?
    public var total: Int
    public var branchTotal: Int
    public var rows: [IssueListRow]
    public var nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case total, rows
        case queryFingerprint = "query_fingerprint"
        case groupKey = "group_key"
        case parentID = "parent_id"
        case branchTotal = "branch_total"
        case nextCursor = "next_cursor"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queryFingerprint = c.lossy(String.self, .queryFingerprint, default: "")
        groupKey = c.lossy(String.self, .groupKey)
        parentID = c.lossy(String.self, .parentID)
        total = c.lossy(Int.self, .total, default: 0)
        branchTotal = c.lossy(Int.self, .branchTotal, default: 0)
        rows = c.lossyArray(IssueListRow.self, .rows)
        nextCursor = c.lossy(String.self, .nextCursor)
    }
}
