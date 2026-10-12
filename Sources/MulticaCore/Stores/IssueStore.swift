import Foundation
import Observation

/// One issue row. Each row observes only its own model, so an
/// `issue:updated` for one issue re-renders one row — not the list. Upstream
/// every row subscribed to the whole workspace task snapshot and re-rendered
/// on any task change (MUL-4474).
@MainActor
@Observable
public final class IssueModel: Identifiable {
    public let id: String
    public private(set) var issue: Issue
    /// Active (non-terminal) agent runs on this issue.
    public internal(set) var activeRuns: Int = 0

    init(issue: Issue) {
        id = issue.id
        self.issue = issue
    }

    /// Replaces the issue if `new` is not older. Returns the fields that
    /// affect list structure, so the store re-sections only when needed.
    func update(_ new: Issue) -> StructuralChange? {
        guard issue.isSuperseded(by: new) else { return nil }
        let change = StructuralChange(
            status: new.status != issue.status || new.statusCategory != issue.statusCategory,
            order: new.position != issue.position,
            assignee: new.assignee != issue.assignee,
            text: new.title != issue.title || new.identifier != issue.identifier
        )
        if new != issue { issue = new }
        return change
    }

    func forceSet(_ new: Issue) {
        issue = new
    }

    struct StructuralChange {
        var status: Bool
        var order: Bool
        var assignee: Bool
        var text: Bool
    }
}

public enum IssueFilter: String, Sendable, Hashable, CaseIterable {
    case all
    case assignedToMe
    case agents
    case running
    case unassigned

    public var label: String {
        switch self {
        case .all: return "All issues"
        case .assignedToMe: return "Assigned to me"
        case .agents: return "Assigned to agents"
        case .running: return "Agents working"
        case .unassigned: return "Unassigned"
        }
    }
}

public struct IssueSection: Identifiable {
    public var id: IssueStatusKey { key }
    public var key: IssueStatusKey
    public var name: String
    public var category: StatusCategory
    public var color: String
    public var items: [IssueModel]
}

/// Normalised issue cache for one workspace plus the derived list/board
/// structure.
@MainActor
@Observable
public final class IssueStore {
    // Identity map. Not observed: views reach models through `sections`, and
    // an insert must not invalidate every row that happens to read the map.
    @ObservationIgnored private var models: [String: IssueModel] = [:]
    @ObservationIgnored private var activeTasks: [String: Set<String>] = [:]
    @ObservationIgnored private var taskIssue: [String: String] = [:]
    @ObservationIgnored private var resectionPending = false
    @ObservationIgnored public var currentUserID: String?

    /// Structure consumed by list and board views.
    public private(set) var sections: [IssueSection] = []
    public private(set) var catalog: StatusCatalog = .builtIn
    public private(set) var totalOnServer = 0
    public private(set) var loadedCount = 0
    /// Number of times `sections` was recomputed (diagnostics).
    @ObservationIgnored public private(set) var resectionCount = 0

    public var filter: IssueFilter = .all {
        didSet { if filter != oldValue { scheduleResection() } }
    }

    public var searchText: String = "" {
        didSet { if searchText != oldValue { scheduleResection() } }
    }

    public var hideEmptySections = false {
        didSet { if hideEmptySections != oldValue { scheduleResection() } }
    }

    public init() {}

    public func model(_ id: String) -> IssueModel? { models[id] }
    public var count: Int { models.count }

    public func model(identifier: String) -> IssueModel? {
        models.values.first { $0.issue.identifier.caseInsensitiveCompare(identifier) == .orderedSame }
    }

    // MARK: Writes

    public func setCatalog(_ entries: [IssueStatusEntry]) {
        catalog = entries.isEmpty ? .builtIn : StatusCatalog(entries)
        scheduleResection()
    }

    /// Merges a page from the server. Existing models are updated in place so
    /// rows keep their identity (no flash, no scroll jump).
    public func merge(page issues: [Issue], total: Int, replacing: Bool) {
        if replacing {
            let keep = Set(issues.map(\.id))
            for id in models.keys where !keep.contains(id) { models[id] = nil }
        }
        for issue in issues {
            if let m = models[issue.id] {
                _ = m.update(issue)
            } else {
                let m = IssueModel(issue: issue)
                m.activeRuns = activeTasks[issue.id]?.count ?? 0
                models[issue.id] = m
            }
        }
        totalOnServer = total
        loadedCount = models.count
        scheduleResection()
    }

    /// `isNew` marks a creation (as opposed to an issue that merely was not
    /// loaded yet), which is the only case that grows the server total.
    public func upsert(_ issue: Issue, isNew: Bool = false) {
        if let m = models[issue.id] {
            guard let change = m.update(issue) else { return }
            if change.status || change.order || (change.assignee && filter != .all) || (change.text && !searchText.isEmpty) {
                scheduleResection()
            }
        } else {
            let m = IssueModel(issue: issue)
            m.activeRuns = activeTasks[issue.id]?.count ?? 0
            models[issue.id] = m
            loadedCount = models.count
            if isNew { totalOnServer += 1 }
            scheduleResection()
        }
    }

    /// Optimistic local patch. Returns the previous value for rollback.
    @discardableResult
    public func patch(_ id: String, _ transform: (Issue) -> Issue) -> Issue? {
        guard let m = models[id] else { return nil }
        let previous = m.issue
        m.forceSet(transform(previous))
        scheduleResection()
        return previous
    }

    public func restore(_ issue: Issue) {
        models[issue.id]?.forceSet(issue)
        scheduleResection()
    }

    public func remove(_ id: String) {
        guard models.removeValue(forKey: id) != nil else { return }
        loadedCount = models.count
        totalOnServer = max(0, totalOnServer - 1)
        scheduleResection()
    }

    public func setLabels(_ issueID: String, _ labels: [IssueLabel]) {
        guard let m = models[issueID] else { return }
        var i = m.issue
        i.labels = labels
        m.forceSet(i)
    }

    // MARK: Agent activity

    /// Seeds the active-run index from `GET /api/agent-task-snapshot`.
    public func applyTaskSnapshot(_ tasks: [AgentTask]) {
        activeTasks.removeAll()
        taskIssue.removeAll()
        for t in tasks where t.status.isActive && !t.issueID.isEmpty {
            activeTasks[t.issueID, default: []].insert(t.id)
            taskIssue[t.id] = t.issueID
        }
        for (id, m) in models {
            let n = activeTasks[id]?.count ?? 0
            if m.activeRuns != n { m.activeRuns = n }
        }
        if filter == .running { scheduleResection() }
    }

    /// Applies one lifecycle transition. Touches exactly one row.
    public func applyTaskLifecycle(_ e: TaskLifecycle) {
        guard !e.issueID.isEmpty else { return }
        if e.status.isActive {
            activeTasks[e.issueID, default: []].insert(e.taskID)
            taskIssue[e.taskID] = e.issueID
        } else {
            activeTasks[e.issueID]?.remove(e.taskID)
            if activeTasks[e.issueID]?.isEmpty == true { activeTasks[e.issueID] = nil }
            taskIssue[e.taskID] = nil
        }
        let n = activeTasks[e.issueID]?.count ?? 0
        if let m = models[e.issueID], m.activeRuns != n {
            m.activeRuns = n
            if filter == .running { scheduleResection() }
        }
    }

    // MARK: Sectioning

    /// Coalesces structural recomputation: a burst of WebSocket events in one
    /// main-actor turn produces a single re-section.
    public func scheduleResection() {
        guard !resectionPending else { return }
        resectionPending = true
        Task { @MainActor [weak self] in self?.resectionIfNeeded() }
    }

    public func resectionIfNeeded() {
        guard resectionPending else { return }
        resectionPending = false
        resection()
    }

    private func matches(_ m: IssueModel, query: String) -> Bool {
        switch filter {
        case .all: break
        case .assignedToMe:
            guard let a = m.issue.assignee, a.type == "member", a.id == currentUserID else { return false }
        case .agents:
            guard m.issue.assignee?.type == "agent" else { return false }
        case .running:
            guard m.activeRuns > 0 else { return false }
        case .unassigned:
            guard m.issue.assignee == nil else { return false }
        }
        if !query.isEmpty {
            return m.issue.title.localizedCaseInsensitiveContains(query)
                || m.issue.identifier.localizedCaseInsensitiveContains(query)
        }
        return true
    }

    private func resection() {
        resectionCount += 1
        let query = searchText.trimmingCharacters(in: .whitespaces)
        var buckets: [IssueStatusKey: [IssueModel]] = [:]
        for m in models.values where matches(m, query: query) {
            buckets[m.issue.status, default: []].append(m)
        }
        let keys = catalog.columns(including: buckets.keys.sorted { $0.rawValue < $1.rawValue })
        var out: [IssueSection] = []
        out.reserveCapacity(keys.count)
        for key in keys {
            var items = buckets[key] ?? []
            if items.isEmpty && hideEmptySections { continue }
            items.sort { a, b in
                if a.issue.position != b.issue.position { return a.issue.position < b.issue.position }
                return a.issue.number > b.issue.number
            }
            let entry = catalog.entry(for: key)
            out.append(IssueSection(
                key: key,
                name: catalog.displayName(for: key),
                category: entry?.category ?? key.builtInCategory ?? .unstarted,
                color: entry?.color ?? "#888888",
                items: items))
        }
        sections = out
    }
}
