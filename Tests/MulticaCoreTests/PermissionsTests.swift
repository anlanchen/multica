import XCTest
@testable import MulticaCore

final class PermissionsTests: XCTestCase {
    let member = PermissionContext(userID: "u1", role: "member")
    let admin = PermissionContext(userID: "u2", role: "admin")
    let anon = PermissionContext(userID: nil, role: nil)

    func testAssignAgent() {
        var agent = AgentRecord(permissionMode: "private", ownerId: "u1")
        XCTAssertTrue(Permissions.canAssignAgentToIssue(agent, member).allowed)
        XCTAssertEqual(Permissions.canAssignAgentToIssue(agent, admin).reason, "private_visibility")
        agent.permissionMode = "public_to"
        agent.ownerId = "u9"
        agent.invocationTargets = [AgentInvocationTarget(targetType: "workspace", targetId: nil)]
        XCTAssertTrue(Permissions.canAssignAgentToIssue(agent, member).allowed)
        XCTAssertEqual(Permissions.canAssignAgentToIssue(agent, PermissionContext(userID: "x", role: nil)).reason, "not_member")
        agent.invocationTargets = [AgentInvocationTarget(targetType: "member", targetId: "u1"), AgentInvocationTarget(targetType: "team", targetId: "t")]
        XCTAssertTrue(Permissions.canAssignAgentToIssue(agent, member).allowed)
        XCTAssertFalse(Permissions.canAssignAgentToIssue(agent, admin).allowed)
        XCTAssertEqual(Permissions.canAssignAgentToIssue(agent, anon).reason, "not_authenticated")
    }

    func testCommentsAndMembers() {
        XCTAssertFalse(Permissions.canEditComment(authorType: "agent", authorID: "a", admin).allowed)
        XCTAssertTrue(Permissions.canEditComment(authorType: "member", authorID: "u1", member).allowed)
        XCTAssertTrue(Permissions.canDeleteComment(authorType: "agent", authorID: "a", admin).allowed)
        XCTAssertFalse(Permissions.canDeleteComment(authorType: "member", authorID: "u3", member).allowed)
        let owner = PermissionContext(userID: "o", role: "owner")
        XCTAssertEqual(Permissions.canChangeMemberRole(targetRole: "owner", ownerCount: 1, owner).reason, "last_owner")
        XCTAssertEqual(Permissions.canChangeMemberRole(targetRole: "owner", ownerCount: 2, admin).reason, "not_owner_role")
        XCTAssertTrue(Permissions.canChangeMemberRole(targetRole: "member", ownerCount: 1, admin).allowed)
        XCTAssertFalse(Permissions.canDeleteWorkspace(admin).allowed)
    }
}
