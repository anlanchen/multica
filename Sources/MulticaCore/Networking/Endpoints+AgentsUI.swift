import Foundation

/// A page of agent tasks with the full upstream task shape (trigger summary,
/// kind, attribution, cancelled-by) the Activity tab renders.
public struct AgentsUITaskPage: Decodable, Sendable, Hashable {
    public var tasks: [AgentTaskRecord]
    public var nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case tasks
        case nextCursor = "next_cursor"
        case nextCursorCamel = "nextCursor"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = c.lossyArray(AgentTaskRecord.self, .tasks)
        nextCursor = c.lenient(String.self, .nextCursor) ?? c.lenient(String.self, .nextCursorCamel)
    }
}

// Agent endpoints the shared client does not expose (upstream
// `setAgentSkillEnabled`, `removeAgentSkill`) and full-shape task reads.
extension APIClient {
    public nonisolated func agentsUISetSkillEnabled(agentId: String, skillId: String, enabled: Bool) async throws {
        try await callVoid(.put, "/api/agents/\(agentId)/skills/\(skillId)/enabled", body: ["enabled": JSONValue(enabled)] as JSONValue)
    }

    public nonisolated func agentsUIRemoveSkill(agentId: String, skillId: String) async throws {
        try await callVoid(.delete, "/api/agents/\(agentId)/skills/\(skillId)")
    }

    public nonisolated func agentsUITaskSnapshot() async throws -> [AgentTaskRecord] {
        try await list("/api/agent-task-snapshot")
    }

    public nonisolated func agentsUITasksPage(agentId: String, limit: Int = 200, before: String? = nil) async throws -> AgentsUITaskPage {
        try await call(.get, "/api/agents/\(agentId)/tasks", query: MulticaCore.query([
            "limit": String(limit), "before": before,
        ]))
    }
}
