import Foundation

/// Four lifecycle classifications. Board columns and list sections group by
/// the status key, but presentation resolves the key to its category first.
public struct StatusCategory: OpenEnum, Comparable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let unstarted = StatusCategory(rawValue: "unstarted")
    public static let started = StatusCategory(rawValue: "started")
    public static let done = StatusCategory(rawValue: "done")
    public static let closed = StatusCategory(rawValue: "closed")

    var order: Int {
        switch self {
        case .unstarted: return 0
        case .started: return 1
        case .done: return 2
        case .closed: return 3
        default: return 4
        }
    }

    public static func < (a: StatusCategory, b: StatusCategory) -> Bool { a.order < b.order }
}

/// A status key: one of the seven built-ins or a workspace-defined custom key.
public struct IssueStatusKey: OpenEnum, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public static let backlog: IssueStatusKey = "backlog"
    public static let todo: IssueStatusKey = "todo"
    public static let inProgress: IssueStatusKey = "in_progress"
    public static let inReview: IssueStatusKey = "in_review"
    public static let done: IssueStatusKey = "done"
    public static let blocked: IssueStatusKey = "blocked"
    public static let cancelled: IssueStatusKey = "cancelled"

    public static let builtIns: [IssueStatusKey] = [.backlog, .todo, .inProgress, .inReview, .done, .blocked, .cancelled]

    /// Category of a built-in key; nil for custom keys (resolve via catalog).
    public var builtInCategory: StatusCategory? {
        switch self {
        case .backlog, .todo: return .unstarted
        case .inProgress, .inReview, .blocked: return .started
        case .done: return .done
        case .cancelled: return .closed
        default: return nil
        }
    }

    public var builtInName: String? {
        switch self {
        case .backlog: return "Backlog"
        case .todo: return "Todo"
        case .inProgress: return "In Progress"
        case .inReview: return "In Review"
        case .done: return "Done"
        case .blocked: return "Blocked"
        case .cancelled: return "Cancelled"
        default: return nil
        }
    }
}

public enum IssuePriority: String, Sendable, Hashable, Codable, CaseIterable {
    case urgent, high, medium, low, none

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = IssuePriority(rawValue: raw) ?? .none
    }

    public var sortRank: Int {
        switch self {
        case .urgent: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        case .none: return 4
        }
    }

    public var label: String {
        switch self {
        case .urgent: return "Urgent"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .none: return "No priority"
        }
    }
}

/// Polymorphic actor reference: assignees and creators can be members, agents
/// or squads, and `assignee_id` only means something with its type.
public struct ActorRef: Sendable, Hashable {
    public var type: String
    public var id: String

    public init(type: String, id: String) {
        self.type = type
        self.id = id
    }
}

public struct Label: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var name: String
    public var color: String

    enum CodingKeys: String, CodingKey { case id, name, color }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lossy(String.self, .name, default: "")
        color = c.lossy(String.self, .color, default: "#888888")
    }
}

public struct Issue: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var workspaceID: String
    public var number: Int
    public var identifier: String
    public var title: String
    public var description: String?
    public var status: IssueStatusKey
    public var statusCategory: StatusCategory?
    public var statusName: String?
    public var priority: IssuePriority
    public var assignee: ActorRef?
    public var creator: ActorRef?
    public var parentIssueID: String?
    public var projectID: String?
    public var position: Double
    public var startDate: String?
    public var dueDate: String?
    public var labels: [Label]
    public var createdAt: String
    public var updatedAt: String
    public var revision: Int?
    public var lastActivityAt: String?

    enum CodingKeys: String, CodingKey {
        case id, number, identifier, title, description, status, priority, position, labels, revision
        case workspaceID = "workspace_id"
        case statusCategory = "status_category"
        case statusName = "status_name"
        case assigneeType = "assignee_type"
        case assigneeID = "assignee_id"
        case creatorType = "creator_type"
        case creatorID = "creator_id"
        case parentIssueID = "parent_issue_id"
        case projectID = "project_id"
        case startDate = "start_date"
        case dueDate = "due_date"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastActivityAt = "last_activity_at"
    }

    public init(
        id: String, workspaceID: String = "", number: Int, identifier: String, title: String,
        description: String? = nil, status: IssueStatusKey = .todo, priority: IssuePriority = .none,
        assignee: ActorRef? = nil, position: Double = 0, createdAt: String = "", updatedAt: String = "",
        revision: Int? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.number = number
        self.identifier = identifier
        self.title = title
        self.description = description
        self.status = status
        self.priority = priority
        self.assignee = assignee
        self.position = position
        self.labels = []
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workspaceID = c.lossy(String.self, .workspaceID, default: "")
        number = c.lossy(Int.self, .number, default: 0)
        identifier = c.lossy(String.self, .identifier, default: "")
        title = c.lossy(String.self, .title, default: "")
        description = c.lossy(String.self, .description)
        status = c.lossy(IssueStatusKey.self, .status, default: .todo)
        statusCategory = c.lossy(StatusCategory.self, .statusCategory)
        statusName = c.lossy(String.self, .statusName)
        priority = c.lossy(IssuePriority.self, .priority, default: .none)
        if let t = c.lossy(String.self, .assigneeType), let i = c.lossy(String.self, .assigneeID), !i.isEmpty {
            assignee = ActorRef(type: t, id: i)
        }
        if let t = c.lossy(String.self, .creatorType), let i = c.lossy(String.self, .creatorID) {
            creator = ActorRef(type: t, id: i)
        }
        parentIssueID = c.lossy(String.self, .parentIssueID)
        projectID = c.lossy(String.self, .projectID)
        position = c.lossy(Double.self, .position, default: 0)
        startDate = c.lossy(String.self, .startDate)
        dueDate = c.lossy(String.self, .dueDate)
        labels = c.lossyArray(Label.self, .labels)
        createdAt = c.lossy(String.self, .createdAt, default: "")
        updatedAt = c.lossy(String.self, .updatedAt, default: "")
        revision = c.lossy(Int.self, .revision)
        lastActivityAt = c.lossy(String.self, .lastActivityAt)
    }

    /// The category this issue belongs to: the server-resolved one when sent,
    /// else the built-in mapping, else the catalog, else `unstarted`.
    public func category(in catalog: StatusCatalog?) -> StatusCategory {
        if let c = statusCategory, !c.rawValue.isEmpty { return c }
        if let c = status.builtInCategory { return c }
        return catalog?.entry(for: status)?.category ?? .unstarted
    }

    /// Whether `other` is a newer or equal server state. Revisions are
    /// monotonic per issue; fall back to `updated_at` for older backends.
    public func isSuperseded(by other: Issue) -> Bool {
        if let a = revision, let b = other.revision { return b >= a }
        return other.updatedAt >= updatedAt
    }
}

public struct ListIssuesResponse: Sendable, Decodable {
    public var issues: [Issue]
    public var total: Int

    enum CodingKeys: String, CodingKey { case issues, total }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issues = c.lossyArray(Issue.self, .issues)
        total = c.lossy(Int.self, .total, default: issues.count)
    }
}

public struct IssueStatusEntry: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var key: IssueStatusKey
    public var name: String
    public var category: StatusCategory
    public var color: String
    public var position: Double
    public var isSystem: Bool
    public var archivedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, key, name, category, color, position
        case isSystem = "is_system"
        case archivedAt = "archived_at"
    }

    public init(id: String, key: IssueStatusKey, name: String, category: StatusCategory, color: String = "#888888", position: Double = 0, isSystem: Bool = true) {
        self.id = id
        self.key = key
        self.name = name
        self.category = category
        self.color = color
        self.position = position
        self.isSystem = isSystem
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lossy(String.self, .id, default: "")
        key = try c.decode(IssueStatusKey.self, forKey: .key)
        name = c.lossy(String.self, .name, default: key.builtInName ?? key.rawValue)
        category = c.lossy(StatusCategory.self, .category, default: key.builtInCategory ?? .unstarted)
        color = c.lossy(String.self, .color, default: "#888888")
        position = c.lossy(Double.self, .position, default: 0)
        isSystem = c.lossy(Bool.self, .isSystem, default: false)
        archivedAt = c.lossy(String.self, .archivedAt)
    }
}

public struct ListIssueStatusesResponse: Sendable, Decodable {
    public var statuses: [IssueStatusEntry]

    enum CodingKeys: String, CodingKey { case statuses }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statuses = c.lossyArray(IssueStatusEntry.self, .statuses)
    }
}

/// The workspace status catalog, indexed once so per-row lookups are O(1).
public struct StatusCatalog: Sendable, Hashable {
    public private(set) var entries: [IssueStatusEntry]
    private var byKey: [IssueStatusKey: Int]

    public init(_ entries: [IssueStatusEntry]) {
        let active = entries.filter { $0.archivedAt == nil }
        self.entries = active.sorted {
            $0.category == $1.category ? $0.position < $1.position : $0.category < $1.category
        }
        var index: [IssueStatusKey: Int] = [:]
        for (i, e) in self.entries.enumerated() { index[e.key] = i }
        byKey = index
    }

    public static let builtIn = StatusCatalog(IssueStatusKey.builtIns.enumerated().map { i, k in
        IssueStatusEntry(id: k.rawValue, key: k, name: k.builtInName ?? k.rawValue,
                         category: k.builtInCategory ?? .unstarted, position: Double(i))
    })

    public func entry(for key: IssueStatusKey) -> IssueStatusEntry? {
        byKey[key].map { entries[$0] }
    }

    public func displayName(for key: IssueStatusKey) -> String {
        entry(for: key)?.name ?? key.builtInName ?? key.rawValue
    }

    /// Board column order: the catalog order, plus any key seen on an issue
    /// but missing from the catalog, so no issue is ever dropped from view.
    public func columns(including keys: some Sequence<IssueStatusKey>) -> [IssueStatusKey] {
        var out = entries.map(\.key)
        var seen = Set(out)
        for k in keys where !seen.contains(k) {
            seen.insert(k)
            out.append(k)
        }
        return out
    }
}

/// Explicit three-state field for PUT bodies: leave alone, set, or clear
/// (send JSON null). Clearing an assignee requires the explicit null.
public enum Patch<Value: Encodable & Sendable>: Sendable {
    case unchanged
    case set(Value)
    case clear
}

public struct UpdateIssueRequest: Encodable, Sendable {
    public var title: String?
    public var description: String?
    public var status: IssueStatusKey?
    public var priority: IssuePriority?
    public var assigneeType: Patch<String> = .unchanged
    public var assigneeID: Patch<String> = .unchanged
    public var dueDate: Patch<String> = .unchanged
    public var position: Double?
    public var expectedRevision: Int?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case title, description, status, priority, position
        case assigneeType = "assignee_type"
        case assigneeID = "assignee_id"
        case dueDate = "due_date"
        case expectedRevision = "expected_revision"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(priority, forKey: .priority)
        try c.encodeIfPresent(position, forKey: .position)
        try c.encodeIfPresent(expectedRevision, forKey: .expectedRevision)
        try encodePatch(assigneeType, .assigneeType, &c)
        try encodePatch(assigneeID, .assigneeID, &c)
        try encodePatch(dueDate, .dueDate, &c)
    }

    private func encodePatch<V>(_ p: Patch<V>, _ key: CodingKeys, _ c: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch p {
        case .unchanged: break
        case .set(let v): try c.encode(v, forKey: key)
        case .clear: try c.encodeNil(forKey: key)
        }
    }

    /// Applies the request to a local copy for optimistic UI. Only fields
    /// with a predictable result are patched; the server response replaces it.
    public func applied(to issue: Issue) -> Issue {
        var out = issue
        if let title { out.title = title }
        if let description { out.description = description }
        if let status {
            out.status = status
            out.statusCategory = status.builtInCategory
        }
        if let priority { out.priority = priority }
        if let position { out.position = position }
        switch (assigneeType, assigneeID) {
        case (.set(let t), .set(let i)): out.assignee = ActorRef(type: t, id: i)
        case (.clear, _), (_, .clear): out.assignee = nil
        default: break
        }
        switch dueDate {
        case .set(let d): out.dueDate = d
        case .clear: out.dueDate = nil
        case .unchanged: break
        }
        return out
    }
}

public struct CreateIssueRequest: Encodable, Sendable {
    public var title: String
    public var description: String?
    public var status: IssueStatusKey?
    public var priority: IssuePriority?
    public var assigneeType: String?
    public var assigneeID: String?
    public var parentIssueID: String?
    public var projectID: String?

    public init(title: String, description: String? = nil, status: IssueStatusKey? = nil, priority: IssuePriority? = nil,
                assignee: ActorRef? = nil, parentIssueID: String? = nil, projectID: String? = nil) {
        self.title = title
        self.description = description
        self.status = status
        self.priority = priority
        self.assigneeType = assignee?.type
        self.assigneeID = assignee?.id
        self.parentIssueID = parentIssueID
        self.projectID = projectID
    }

    enum CodingKeys: String, CodingKey {
        case title, description, status, priority
        case assigneeType = "assignee_type"
        case assigneeID = "assignee_id"
        case parentIssueID = "parent_issue_id"
        case projectID = "project_id"
    }
}
