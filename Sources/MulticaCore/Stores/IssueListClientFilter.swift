import Foundation

/// Client-side predicates for canvases the server table query cannot express
/// (the project Gantt): upstream utils/filter.ts and utils/sort.ts.
public enum IssueListClientFilter {
    /// One row: the issue plus its custom property bag.
    public struct Item: Sendable, Hashable {
        public var issue: Issue
        public var properties: [String: JSONValue]

        public init(issue: Issue, properties: [String: JSONValue] = [:]) {
            self.issue = issue
            self.properties = properties
        }
    }

    /// `issueValueMatchesOperator`: mirrors the server's operator predicates.
    public static func matchesOperator(_ value: JSONValue, op: String, operand: String) -> Bool {
        switch op {
        case "contains":
            let needle = operand.lowercased()
            guard !needle.isEmpty, case .string(let s) = value else { return false }
            return s.lowercased().contains(needle)
        case "gt", "gte", "lt", "lte":
            guard case .number(let n) = value, let bound = Double(operand), bound.isFinite else { return false }
            switch op {
            case "gt": return n > bound
            case "gte": return n >= bound
            case "lt": return n < bound
            default: return n <= bound
            }
        case "before", "after":
            guard case .string(let s) = value else { return false }
            return op == "before" ? s < operand : s > operand
        default:
            return false
        }
    }

    /// `issueMatchesPropertyFilters`: OR within a definition, AND across.
    public static func matchesProperties(_ bag: [String: JSONValue], _ filters: [String: [IssueListPropertyFilterValue]]) -> Bool {
        for (id, selected) in filters where !selected.isEmpty {
            guard let value = bag[id], !value.isNull else {
                if selected.contains(.equals(IssueListPropertyFilterValue.noValue)) { continue }
                return false
            }
            let matched = selected.contains { member in
                switch member {
                case .equals(let m):
                    if m == IssueListPropertyFilterValue.noValue { return false }
                    switch value {
                    case .string(let s): return s == m
                    case .number(let n): return Double(m) == n
                    case .array(let a): return a.contains(.string(m))
                    case .bool(let b): return m == (b ? "true" : "false")
                    default: return false
                    }
                case .op(let op, let operand):
                    return matchesOperator(value, op: op, operand: operand)
                }
            }
            if !matched { return false }
        }
        return true
    }

    /// `applyIssueFilters`. `projectStatusByID` nil = catalog unknown (the
    /// project-status predicate is then a no-op); `runningIssueIDs` is only
    /// consulted when the agents-working filter is on.
    public static func apply(
        _ items: [Item], state s: IssueListViewState, ignoreProjects: Bool,
        runningIssueIDs: Set<String>?, projectStatusByID: [String: String]?
    ) -> [Item] {
        let hasAssignee = !s.assigneeFilters.isEmpty || s.includeNoAssignee
        let projectFilters = ignoreProjects ? [] : s.projectFilters
        let includeNoProject = ignoreProjects ? false : s.includeNoProject
        let hasProject = !projectFilters.isEmpty || includeNoProject
        let hasProjectStatus = !s.projectStatusFilters.isEmpty && projectStatusByID != nil
        let statuses = Set(s.statusFilters)
        let priorities = Set(s.priorityFilters)
        let labels = Set(s.labelFilters)
        return items.filter { item in
            let issue = item.issue
            if s.agentRunningFilter && !(runningIssueIDs?.contains(issue.id) ?? false) { return false }
            if !s.showSubIssues && issue.parentIssueID != nil { return false }
            if !statuses.isEmpty && !statuses.contains(issue.status.rawValue) { return false }
            if !priorities.isEmpty && !priorities.contains(issue.priority.rawValue) { return false }
            if hasAssignee {
                if let a = issue.assignee {
                    guard s.assigneeFilters.contains(IssueListActorFilter(type: a.type, id: a.id)) else { return false }
                } else if !s.includeNoAssignee {
                    return false
                }
            }
            if !s.creatorFilters.isEmpty {
                guard let c = issue.creator, s.creatorFilters.contains(IssueListActorFilter(type: c.type, id: c.id)) else { return false }
            }
            if hasProject {
                if let p = issue.projectID {
                    guard projectFilters.contains(p) else { return false }
                } else if !includeNoProject {
                    return false
                }
            }
            if hasProjectStatus {
                guard let p = issue.projectID, let st = projectStatusByID?[p], s.projectStatusFilters.contains(st) else { return false }
            }
            if !labels.isEmpty && !issue.labels.contains(where: { labels.contains($0.id) }) { return false }
            return matchesProperties(item.properties, s.propertyFilters)
        }
    }

    /// `ganttCanvasRows`: dated rows, completed work hidden unless shown.
    public static func ganttRows(_ items: [Item], showCompleted: Bool, catalog: StatusCatalog?) -> [Item] {
        items.filter { item in
            guard item.issue.startDate != nil || item.issue.dueDate != nil else { return false }
            if showCompleted { return true }
            let category = item.issue.category(in: catalog)
            return category != .done && category != .closed
        }
    }

    private static let priorityRank: [String: Int] = ["urgent": 0, "high": 1, "medium": 2, "low": 3, "none": 4]

    /// `sortIssues`. `statusOrder` is the catalog's column order (archived
    /// included); without it built-ins rank in board order.
    public static func sort(_ items: [Item], field: String, direction: IssueListSortDirection, statusOrder: [IssueStatusKey]?) -> [Item] {
        let dir: Double = direction == .desc ? -1 : 1
        if let pid = IssueListOptions.propertyID(fromKey: field) {
            return items.issueListStableSorted { a, b in
                let av = a.properties[pid], bv = b.properties[pid]
                let aMissing = av == nil || av?.arrayValue != nil || av?.isNull == true
                let bMissing = bv == nil || bv?.arrayValue != nil || bv?.isNull == true
                if aMissing || bMissing { return !aMissing && bMissing }
                if case .number(let x)? = av, case .number(let y)? = bv { return dir * (x - y) < 0 }
                let cmp = (av?.stringValue ?? "").localizedCompare(bv?.stringValue ?? "")
                return direction == .desc ? cmp == .orderedDescending : cmp == .orderedAscending
            }
        }
        let builtIns: [IssueStatusKey] = [.backlog, .todo, .inProgress, .inReview, .blocked, .done, .cancelled]
        let order = statusOrder ?? builtIns
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        func optionalDate(_ a: String?, _ b: String?) -> Bool? {
            switch (a, b) {
            case (nil, nil): return nil
            case (nil, _): return false
            case (_, nil): return true
            case (let x?, let y?):
                if x == y { return nil }
                return direction == .desc ? x > y : x < y
            }
        }
        return items.issueListStableSorted { a, b in
            let x = a.issue, y = b.issue
            switch field {
            case "priority":
                let d = Double((priorityRank[x.priority.rawValue] ?? 99) - (priorityRank[y.priority.rawValue] ?? 99))
                return dir * d < 0
            case "status":
                let d = Double((rank[x.status] ?? order.count) - (rank[y.status] ?? order.count))
                return dir * d < 0
            case "start_date": return optionalDate(x.startDate, y.startDate) ?? false
            case "due_date": return optionalDate(x.dueDate, y.dueDate) ?? false
            case "created_at":
                let (p, q) = (Timestamp.parse(x.createdAt) ?? .distantPast, Timestamp.parse(y.createdAt) ?? .distantPast)
                return dir * p.timeIntervalSince(q) < 0
            case "updated_at":
                let (p, q) = (Timestamp.parse(x.updatedAt) ?? .distantPast, Timestamp.parse(y.updatedAt) ?? .distantPast)
                return dir * p.timeIntervalSince(q) < 0
            case "title":
                let cmp = x.title.localizedCompare(y.title)
                return direction == .desc ? cmp == .orderedDescending : cmp == .orderedAscending
            default:
                return x.position < y.position
            }
        }
    }
}

extension Array {
    /// Stable sort (JavaScript `toSorted` is stable; Swift's `sorted` is not
    /// guaranteed to be).
    fileprivate func issueListStableSorted(by less: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}
