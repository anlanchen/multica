import Foundation

public struct InboxItem: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var workspaceID: String
    public var recipientType: String
    public var recipientID: String
    public var actorType: String?
    public var actorID: String?
    public var type: String
    public var severity: String
    public var issueID: String?
    public var title: String
    public var body: String?
    public var issueStatus: IssueStatusKey?
    public var issuePriority: IssuePriority?
    public var read: Bool
    public var archived: Bool
    public var createdAt: String
    /// Type-specific extras (`to`, `comment_id`, `emoji`, ...). Upstream types
    /// them as strings but some arrive as numbers; those are stringified.
    public var details: [String: String]
    /// Whether the server sent `issue_priority` at all (older backends omit
    /// it, which disables the priority filter).
    public var issuePriorityPresent: Bool

    enum CodingKeys: String, CodingKey {
        case id, type, severity, title, body, read, archived, details
        case workspaceID = "workspace_id"
        case recipientType = "recipient_type"
        case recipientID = "recipient_id"
        case actorType = "actor_type"
        case actorID = "actor_id"
        case issueID = "issue_id"
        case issueStatus = "issue_status"
        case issuePriority = "issue_priority"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workspaceID = c.lossy(String.self, .workspaceID, default: "")
        recipientType = c.lossy(String.self, .recipientType, default: "member")
        recipientID = c.lossy(String.self, .recipientID, default: "")
        actorType = c.lossy(String.self, .actorType)
        actorID = c.lossy(String.self, .actorID)
        type = c.lossy(String.self, .type, default: "")
        severity = c.lossy(String.self, .severity, default: "info")
        issueID = c.lossy(String.self, .issueID)
        title = c.lossy(String.self, .title, default: "")
        body = c.lossy(String.self, .body)
        issueStatus = c.lossy(IssueStatusKey.self, .issueStatus)
        issuePriority = c.lossy(IssuePriority.self, .issuePriority)
        read = c.lossy(Bool.self, .read, default: false)
        archived = c.lossy(Bool.self, .archived, default: false)
        createdAt = c.lossy(String.self, .createdAt, default: "")
        issuePriorityPresent = c.contains(.issuePriority)
        var extras: [String: String] = [:]
        for (key, value) in c.lossy([String: JSONValue].self, .details, default: [:]) {
            switch value {
            case .string(let s): extras[key] = s
            case .number(let n): extras[key] = n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n)
            case .bool(let b): extras[key] = b ? "true" : "false"
            default: break
            }
        }
        details = extras
    }
}
