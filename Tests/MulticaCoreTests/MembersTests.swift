import XCTest
@testable import MulticaCore

final class MembersTests: XCTestCase {
    func testOwnedAgentsSortedByRunsThenName() {
        let agents = [
            AgentRecord(id: "1", name: "zed", ownerId: "u1"),
            AgentRecord(id: "2", name: "Amy", ownerId: "u1"),
            AgentRecord(id: "3", name: "Bob", ownerId: "u1"),
            AgentRecord(id: "4", name: "Gone", ownerId: "u1", archivedAt: "2026-01-01T00:00:00Z"),
            AgentRecord(id: "5", name: "Other", ownerId: "u2"),
        ]
        let runs = [AgentRunCount(agentId: "1", runCount: 9), AgentRunCount(agentId: "3", runCount: 2)]
        XCTAssertEqual(MembersOwnedAgents.sorted(agents, ownerID: "u1", runCounts: runs).map(\.id), ["1", "3", "2"])
    }

    func testRoleKeys() {
        XCTAssertEqual(MembersRole.key("owner"), "owner")
        XCTAssertEqual(MembersRole.key("admin"), "admin")
        XCTAssertEqual(MembersRole.key("guest"), "member")
        XCTAssertTrue(MembersRole.isAdmin("admin"))
        XCTAssertFalse(MembersRole.isAdmin(nil))
    }
}
