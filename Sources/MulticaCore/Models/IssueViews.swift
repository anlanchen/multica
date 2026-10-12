import Foundation

// Types the upstream client infers from zod schemas (packages/core/api/schemas.ts)
// rather than declaring as interfaces, so the generator cannot see them.

public typealias ResourceLabelsResponse = IssueLabelsResponse

/// A saved issue view (`IssueViewSchema`).
public struct IssueView: Sendable, Hashable, Decodable, Identifiable {
    public var id: String
    public var workspaceId: String
    public var ownerId: String
    public var name: String
    public var scopeType: String
    public var scopeId: String?
    public var scopeVariant: String?
    public var visibility: String
    public var definitionVersion: Int
    public var query: [String: JSONValue]
    public var display: [String: JSONValue]
    public var revision: Int
    public var createdAt: String
    public var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, visibility, query, display, revision
        case workspaceId = "workspace_id"
        case ownerId = "owner_id"
        case scopeType = "scope_type"
        case scopeId = "scope_id"
        case scopeVariant = "scope_variant"
        case definitionVersion = "definition_version"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workspaceId = c.lenient(String.self, .workspaceId) ?? ""
        ownerId = c.lenient(String.self, .ownerId) ?? ""
        name = c.lenient(String.self, .name) ?? ""
        scopeType = c.lenient(String.self, .scopeType) ?? "workspace"
        scopeId = c.lenient(String.self, .scopeId)
        scopeVariant = c.lenient(String.self, .scopeVariant)
        visibility = c.lenient(String.self, .visibility) ?? "private"
        definitionVersion = c.lenient(Int.self, .definitionVersion) ?? 1
        query = c.lenient([String: JSONValue].self, .query) ?? [:]
        display = c.lenient([String: JSONValue].self, .display) ?? [:]
        revision = c.lenient(Int.self, .revision) ?? 1
        createdAt = c.lenient(String.self, .createdAt) ?? ""
        updatedAt = c.lenient(String.self, .updatedAt) ?? ""
    }
}

public struct IssueViewPreference: Sendable, Hashable, Decodable {
    public struct Prefs: Sendable, Hashable, Codable {
        public var hidden: [String]
        public var order: [String]

        public init(hidden: [String] = [], order: [String] = []) {
            self.hidden = hidden
            self.order = order
        }
    }

    public var scopeType: String
    public var scopeId: String?
    public var prefs: Prefs
    public var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case prefs
        case scopeType = "scope_type"
        case scopeId = "scope_id"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scopeType = c.lenient(String.self, .scopeType) ?? "workspace"
        scopeId = c.lenient(String.self, .scopeId)
        prefs = c.lenient(Prefs.self, .prefs) ?? Prefs()
        updatedAt = c.lenient(String.self, .updatedAt) ?? ""
    }
}
