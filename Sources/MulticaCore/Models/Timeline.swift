import Foundation

public struct Reaction: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var commentID: String
    public var actorType: String
    public var actorID: String
    public var emoji: String

    enum CodingKeys: String, CodingKey {
        case id, emoji
        case commentID = "comment_id"
        case actorType = "actor_type"
        case actorID = "actor_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        commentID = c.lossy(String.self, .commentID, default: "")
        actorType = c.lossy(String.self, .actorType, default: "member")
        actorID = c.lossy(String.self, .actorID, default: "")
        emoji = c.lossy(String.self, .emoji, default: "")
    }
}

/// A comment as returned by comment create/update and carried on
/// `comment:*` WebSocket events.
public struct Comment: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var issueID: String
    public var authorType: String
    public var authorID: String
    public var content: String
    public var type: String
    public var parentID: String?
    public var reactions: [Reaction]
    public var createdAt: String
    public var updatedAt: String
    public var revision: Int?
    public var resolvedAt: String?
    public var deletedAt: String?
    public var sourceTaskID: String?
    public var attachments: [Attachment]
    public var resolvedByType: String?
    public var resolvedByID: String?
    public var supplements: [CommentSupplementReceipt]
    public var quickActionID: String?

    enum CodingKeys: String, CodingKey {
        case id, content, type, reactions, revision, attachments, supplements
        case issueID = "issue_id"
        case authorType = "author_type"
        case authorID = "author_id"
        case parentID = "parent_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case resolvedAt = "resolved_at"
        case deletedAt = "deleted_at"
        case sourceTaskID = "source_task_id"
        case resolvedByType = "resolved_by_type"
        case resolvedByID = "resolved_by_id"
        case quickActionID = "quick_action_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        issueID = c.lossy(String.self, .issueID, default: "")
        authorType = c.lossy(String.self, .authorType, default: "member")
        authorID = c.lossy(String.self, .authorID, default: "")
        content = c.lossy(String.self, .content, default: "")
        type = c.lossy(String.self, .type, default: "comment")
        parentID = c.lossy(String.self, .parentID)
        reactions = c.lossyArray(Reaction.self, .reactions)
        createdAt = c.lossy(String.self, .createdAt, default: "")
        updatedAt = c.lossy(String.self, .updatedAt, default: createdAt)
        revision = c.lossy(Int.self, .revision)
        resolvedAt = c.lossy(String.self, .resolvedAt)
        deletedAt = c.lossy(String.self, .deletedAt)
        sourceTaskID = c.lossy(String.self, .sourceTaskID)
        attachments = c.lossyArray(Attachment.self, .attachments)
        resolvedByType = c.lossy(String.self, .resolvedByType)
        resolvedByID = c.lossy(String.self, .resolvedByID)
        supplements = c.lossyArray(CommentSupplementReceipt.self, .supplements)
        quickActionID = c.lossy(String.self, .quickActionID)
    }
}

/// One row of `GET /api/issues/:id/timeline`: either an activity record or a
/// comment, interleaved by creation time.
public struct TimelineEntry: Sendable, Hashable, Identifiable, Decodable {
    public enum Kind: String, Sendable, Hashable {
        case activity, comment
    }

    public var kind: Kind
    public var id: String
    public var actorType: String
    public var actorID: String
    public var actorName: String?
    public var createdAt: String
    public var updatedAt: String?
    public var revision: Int?
    // Activity
    public var action: String?
    public var details: JSONValue?
    // Comment
    public var content: String?
    public var parentID: String?
    public var commentType: String?
    public var reactions: [Reaction]
    public var resolvedAt: String?
    public var deletedAt: String?
    public var sourceTaskID: String?
    public var actorAvatarURL: String?
    public var attachments: [Attachment] = []
    public var coalescedCount: Int?
    public var resolvedByType: String?
    public var resolvedByID: String?
    public var supplements: [CommentSupplementReceipt] = []
    public var quickActionID: String?

    enum CodingKeys: String, CodingKey {
        case type, id, action, details, content, reactions, revision, attachments, supplements
        case actorType = "actor_type"
        case actorID = "actor_id"
        case actorName = "actor_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case parentID = "parent_id"
        case commentType = "comment_type"
        case resolvedAt = "resolved_at"
        case deletedAt = "deleted_at"
        case sourceTaskID = "source_task_id"
        case actorAvatarURL = "actor_avatar_url"
        case coalescedCount = "coalesced_count"
        case resolvedByType = "resolved_by_type"
        case resolvedByID = "resolved_by_id"
        case quickActionID = "quick_action_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.lossy(String.self, .type) == "comment" ? .comment : .activity
        id = try c.decode(String.self, forKey: .id)
        actorType = c.lossy(String.self, .actorType, default: "system")
        actorID = c.lossy(String.self, .actorID, default: "")
        actorName = c.lossy(String.self, .actorName)
        createdAt = c.lossy(String.self, .createdAt, default: "")
        updatedAt = c.lossy(String.self, .updatedAt)
        revision = c.lossy(Int.self, .revision)
        action = c.lossy(String.self, .action)
        details = c.lossy(JSONValue.self, .details)
        content = c.lossy(String.self, .content)
        parentID = c.lossy(String.self, .parentID)
        commentType = c.lossy(String.self, .commentType)
        reactions = c.lossyArray(Reaction.self, .reactions)
        resolvedAt = c.lossy(String.self, .resolvedAt)
        deletedAt = c.lossy(String.self, .deletedAt)
        sourceTaskID = c.lossy(String.self, .sourceTaskID)
        actorAvatarURL = c.lossy(String.self, .actorAvatarURL)
        attachments = c.lossyArray(Attachment.self, .attachments)
        coalescedCount = c.lossy(Int.self, .coalescedCount)
        resolvedByType = c.lossy(String.self, .resolvedByType)
        resolvedByID = c.lossy(String.self, .resolvedByID)
        supplements = c.lossyArray(CommentSupplementReceipt.self, .supplements)
        quickActionID = c.lossy(String.self, .quickActionID)
    }

    /// Projects a live comment event into a timeline row.
    public init(comment: Comment) {
        kind = .comment
        id = comment.id
        actorType = comment.authorType
        actorID = comment.authorID
        createdAt = comment.createdAt
        updatedAt = comment.updatedAt
        revision = comment.revision
        content = comment.content
        parentID = comment.parentID
        commentType = comment.type
        reactions = comment.reactions
        resolvedAt = comment.resolvedAt
        deletedAt = comment.deletedAt
        sourceTaskID = comment.sourceTaskID
        attachments = comment.attachments
        resolvedByType = comment.resolvedByType
        resolvedByID = comment.resolvedByID
        supplements = comment.supplements
        quickActionID = comment.quickActionID
    }

    public var isDeletedComment: Bool { kind == .comment && deletedAt != nil }
}
