import Foundation

public struct User: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var name: String
    public var email: String
    public var avatarURL: String?
    public var language: String?

    enum CodingKeys: String, CodingKey {
        case id, name, email, language
        case avatarURL = "avatar_url"
    }

    public init(id: String, name: String, email: String, avatarURL: String? = nil, language: String? = nil) {
        self.id = id
        self.name = name
        self.email = email
        self.avatarURL = avatarURL
        self.language = language
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lossy(String.self, .name, default: "")
        email = c.lossy(String.self, .email, default: "")
        avatarURL = c.lossy(String.self, .avatarURL)
        language = c.lossy(String.self, .language)
    }
}

public struct Workspace: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var name: String
    public var slug: String
    public var issuePrefix: String
    public var avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, slug
        case issuePrefix = "issue_prefix"
        case avatarURL = "avatar_url"
    }

    public init(id: String, name: String, slug: String, issuePrefix: String = "", avatarURL: String? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.issuePrefix = issuePrefix
        self.avatarURL = avatarURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lossy(String.self, .name, default: "")
        slug = try c.decode(String.self, forKey: .slug)
        issuePrefix = c.lossy(String.self, .issuePrefix, default: "")
        avatarURL = c.lossy(String.self, .avatarURL)
    }
}

public struct Member: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var workspaceID: String
    public var userID: String
    public var role: String
    public var name: String
    public var email: String
    public var avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id, role, name, email
        case workspaceID = "workspace_id"
        case userID = "user_id"
        case avatarURL = "avatar_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workspaceID = c.lossy(String.self, .workspaceID, default: "")
        userID = try c.decode(String.self, forKey: .userID)
        role = c.lossy(String.self, .role, default: "member")
        name = c.lossy(String.self, .name, default: "")
        email = c.lossy(String.self, .email, default: "")
        avatarURL = c.lossy(String.self, .avatarURL)
    }
}

public struct LoginResponse: Sendable, Decodable {
    public var token: String
    public var user: User
}

/// One workspace's unread inbox count (`GET /api/inbox/unread-summary`). The
/// badge is derived from this instead of downloading the whole inbox
/// (upstream MUL-6967).
public struct InboxWorkspaceUnread: Sendable, Hashable, Decodable {
    public var workspaceID: String
    public var count: Int

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case count
    }
}
