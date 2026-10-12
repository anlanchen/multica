import Foundation

/// Upstream `packages/core/permissions/rules.ts`: who may do what, decided
/// client-side to gate UI (the server enforces the same rules).
public struct PermissionContext: Sendable, Hashable {
    public var userID: String?
    /// `owner` | `admin` | `member`, nil when not a member.
    public var role: String?

    public init(userID: String?, role: String?) {
        self.userID = userID
        self.role = role
    }

    var isAdminLike: Bool { role == "owner" || role == "admin" }
}

public struct PermissionDecision: Sendable, Hashable {
    public var allowed: Bool
    public var reason: String?
    public var message: String?

    public static let allow = PermissionDecision(allowed: true)

    public init(allowed: Bool, reason: String? = nil, message: String? = nil) {
        self.allowed = allowed
        self.reason = reason
        self.message = message
    }

    static func deny(_ reason: String, _ message: String) -> PermissionDecision {
        PermissionDecision(allowed: false, reason: reason, message: message)
    }
}

public enum Permissions {
    public static func canEditAgent(ownerID: String?, _ ctx: PermissionContext) -> PermissionDecision {
        guard let user = ctx.userID else { return .deny("not_authenticated", "Sign in to edit this agent.") }
        if ctx.isAdminLike || ownerID == user { return .allow }
        return .deny("not_resource_owner", "Only the agent owner and workspace admins can edit this agent.")
    }

    /// `invocationTargets`: (target_type, target_id) pairs.
    public static func canAssignAgentToIssue(ownerID: String?, permissionMode: String, invocationTargets: [(type: String, id: String?)],
                                             _ ctx: PermissionContext) -> PermissionDecision {
        guard let user = ctx.userID else { return .deny("not_authenticated", "Sign in to assign agents.") }
        if ownerID == user { return .allow }
        if permissionMode == "private" {
            return .deny("private_visibility", "Personal agent — only the owner can assign work.")
        }
        if invocationTargets.contains(where: { $0.type == "workspace" }) {
            return ctx.role == nil ? .deny("not_member", "Join this workspace to assign agents.") : .allow
        }
        if invocationTargets.contains(where: { $0.type == "member" && $0.id == user }) { return .allow }
        return .deny("private_visibility", "Restricted agent — you don't have access to assign work to it.")
    }

    public static func canEditSkill(createdBy: String?, _ ctx: PermissionContext) -> PermissionDecision {
        guard let user = ctx.userID else { return .deny("not_authenticated", "Sign in to edit this skill.") }
        if ctx.isAdminLike || createdBy == user { return .allow }
        return .deny("not_resource_owner", "Only the creator and workspace admins can edit this skill.")
    }

    public static func canEditComment(authorType: String, authorID: String, _ ctx: PermissionContext) -> PermissionDecision {
        guard let user = ctx.userID else { return .deny("not_authenticated", "Sign in to edit comments.") }
        guard authorType == "member" else { return .deny("not_resource_owner", "Agent-authored comments cannot be edited.") }
        if authorID == user || ctx.isAdminLike { return .allow }
        return .deny("not_resource_owner", "Only the author and workspace admins can edit this comment.")
    }

    public static func canDeleteComment(authorType: String, authorID: String, _ ctx: PermissionContext) -> PermissionDecision {
        guard let user = ctx.userID else { return .deny("not_authenticated", "Sign in to delete comments.") }
        if authorType == "member", authorID == user { return .allow }
        if ctx.isAdminLike { return .allow }
        return .deny("not_resource_owner", "Only the author and workspace admins can delete this comment.")
    }

    public static func canDeleteRuntime(ownerID: String?, _ ctx: PermissionContext) -> PermissionDecision {
        guard let user = ctx.userID else { return .deny("not_authenticated", "Sign in to delete runtimes.") }
        if ctx.isAdminLike || ownerID == user { return .allow }
        return .deny("not_resource_owner", "Only the runtime owner and workspace admins can delete this runtime.")
    }

    public static func canUpdateWorkspaceSettings(_ ctx: PermissionContext) -> PermissionDecision {
        ctx.isAdminLike ? .allow : .deny("not_admin_role", "Only workspace owners and admins can update workspace settings.")
    }

    public static func canDeleteWorkspace(_ ctx: PermissionContext) -> PermissionDecision {
        ctx.role == "owner" ? .allow : .deny("not_owner_role", "Only the workspace owner can delete this workspace.")
    }

    public static func canManageMembers(_ ctx: PermissionContext) -> PermissionDecision {
        ctx.isAdminLike ? .allow : .deny("not_admin_role", "Only workspace owners and admins can manage members.")
    }

    public static func canChangeMemberRole(targetRole: String, ownerCount: Int, _ ctx: PermissionContext) -> PermissionDecision {
        let manage = canManageMembers(ctx)
        guard manage.allowed else { return manage }
        if targetRole == "owner" {
            if ctx.role != "owner" { return .deny("not_owner_role", "Only the workspace owner can change another owner's role.") }
            if ownerCount <= 1 {
                return .deny("last_owner", "Promote another member to owner first — a workspace must keep at least one owner.")
            }
        }
        return .allow
    }
}

extension Permissions {
    public static func canAssignAgentToIssue(_ agent: AgentRecord, _ ctx: PermissionContext) -> PermissionDecision {
        canAssignAgentToIssue(ownerID: agent.ownerId, permissionMode: agent.permissionMode,
                              invocationTargets: agent.invocationTargets.map { ($0.targetType, $0.targetId) }, ctx)
    }

    public static func canEditAgent(_ agent: AgentRecord, _ ctx: PermissionContext) -> PermissionDecision {
        canEditAgent(ownerID: agent.ownerId, ctx)
    }
}
