import Foundation

// Agents, agent builder, skills, MCP bindings, tasks, runtimes and runtime
// profiles. Mirrors the upstream ApiClient method for method.

public struct AgentTasksPage: Decodable, Sendable, Hashable {
    public var tasks: [AgentTask]
    public var nextCursor: String?
    enum CodingKeys: String, CodingKey {
        case tasks
        case nextCursor = "next_cursor"
        case nextCursorCamel = "nextCursor"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = c.lossyArray(AgentTask.self, .tasks)
        nextCursor = c.lenient(String.self, .nextCursor) ?? c.lenient(String.self, .nextCursorCamel)
    }
}

public struct RuntimeDeleteResult: Decodable, Sendable, Hashable {
    public var status: String
    public var agentsUnbound: Int?
    public var agentsArchived: Int?
    public var tasksCancelled: Int
    public var autopilotsPaused: Int?
    enum CodingKeys: String, CodingKey {
        case status
        case agentsUnbound = "agents_unbound"
        case agentsArchived = "agents_archived"
        case tasksCancelled = "tasks_cancelled"
        case autopilotsPaused = "autopilots_paused"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.lenient(String.self, .status) ?? ""
        agentsUnbound = c.lenient(Int.self, .agentsUnbound)
        agentsArchived = c.lenient(Int.self, .agentsArchived)
        tasksCancelled = c.lenient(Int.self, .tasksCancelled) ?? 0
        autopilotsPaused = c.lenient(Int.self, .autopilotsPaused)
    }
}

extension APIClient {
    // MARK: Agents

    public nonisolated func listAgents(workspaceId: String? = nil, includeArchived: Bool = false) async throws -> [AgentRecord] {
        try await list("/api/agents", query: MulticaCore.query([
            "workspace_id": workspaceId, "include_archived": includeArchived ? "true" : nil,
        ]))
    }

    public nonisolated func getAgent(_ id: String) async throws -> AgentRecord {
        try await call(.get, "/api/agents/\(id)")
    }

    public nonisolated func createAgent(_ data: CreateAgentRequest) async throws -> AgentRecord {
        try await call(.post, "/api/agents", body: JSONValue(encoding: data))
    }

    public nonisolated func createMikaAgent(runtimeId: String, language: String, model: String? = nil, sessionTitle: String? = nil,
                                            workspaceSlug: String? = nil) async throws -> MikaBootstrapResponse {
        var body: [String: JSONValue] = ["runtime_id": JSONValue(runtimeId), "language": JSONValue(language)]
        if let model { body["model"] = JSONValue(model) }
        if let sessionTitle { body["session_title"] = JSONValue(sessionTitle) }
        return try await call(.post, "/api/agents/mika", body: JSONValue.object(body), slug: workspaceSlug)
    }

    public nonisolated func createAgentBuilderSession(runtimeId: String, model: String? = nil) async throws -> AgentBuilderSession {
        var body: [String: JSONValue] = ["runtime_id": JSONValue(runtimeId)]
        if let model { body["model"] = JSONValue(model) }
        return try await call(.post, "/api/agent-builder/sessions", body: JSONValue.object(body))
    }

    public nonisolated func listAgentBuilderSessions() async throws -> [AgentBuilderSessionSummary] {
        try await list("/api/agent-builder/sessions")
    }

    public nonisolated func saveAgentBuilderDraft(sessionId: String, draft: JSONValue) async throws {
        try await callVoid(.put, "/api/agent-builder/sessions/\(sessionId)/draft", body: ["draft": draft] as JSONValue)
    }

    public nonisolated func switchAgentBuilderRuntime(sessionId: String, runtimeId: String) async throws -> AgentBuilderRuntimeSwitch {
        try await call(.patch, "/api/agent-builder/sessions/\(sessionId)/runtime", body: ["runtime_id": JSONValue(runtimeId)] as JSONValue)
    }

    public nonisolated func updateAgent(_ id: String, _ data: UpdateAgentRequest) async throws -> AgentRecord {
        try await call(.put, "/api/agents/\(id)", body: JSONValue(encoding: data))
    }

    /// Partial update with an explicit JSON body (lets callers send `null`).
    public nonisolated func updateAgent(_ id: String, patch: [String: JSONValue]) async throws -> AgentRecord {
        try await call(.put, "/api/agents/\(id)", body: JSONValue.object(patch))
    }

    public nonisolated func archiveAgent(_ id: String) async throws -> AgentRecord {
        try await call(.post, "/api/agents/\(id)/archive")
    }

    public nonisolated func restoreAgent(_ id: String) async throws -> AgentRecord {
        try await call(.post, "/api/agents/\(id)/restore")
    }

    public nonisolated func getAgentEnv(_ id: String) async throws -> AgentEnvResponse {
        try await call(.get, "/api/agents/\(id)/env")
    }

    public nonisolated func updateAgentEnv(_ id: String, _ data: UpdateAgentEnvRequest) async throws -> AgentEnvResponse {
        try await call(.put, "/api/agents/\(id)/env", body: JSONValue(encoding: data))
    }

    public nonisolated func cancelAgentTasks(_ id: String) async throws -> Int {
        try await call(.post, "/api/agents/\(id)/cancel-tasks", as: CountResponse.self).value
    }

    public nonisolated func listAgentTasksPage(agentId: String, limit: Int? = nil, before: String? = nil) async throws -> AgentTasksPage {
        try await call(.get, "/api/agents/\(agentId)/tasks", query: MulticaCore.query([
            "limit": limit.map(String.init), "before": before,
        ]))
    }

    public nonisolated func getWorkspaceWorkingAgents(type: String? = nil, mineRelation: String? = nil, parentIssueId: String? = nil) async throws -> [WorkspaceWorkingAgent] {
        var q: [URLQueryItem] = []
        if let type { q.append(URLQueryItem(name: "type", value: type)) }
        if let mineRelation {
            q.append(URLQueryItem(name: "scope", value: "mine"))
            q.append(URLQueryItem(name: "relation", value: mineRelation))
        } else if let parentIssueId {
            q.append(URLQueryItem(name: "parent", value: parentIssueId))
        }
        return try await list("/api/working-agents", query: q)
    }

    public nonisolated func getWorkspaceAgentActivity30d() async throws -> [AgentActivityBucket] {
        try await list("/api/agent-activity-30d")
    }

    public nonisolated func getWorkspaceAgentRunCounts() async throws -> [AgentRunCount] {
        try await list("/api/agent-run-counts")
    }

    public nonisolated func cancelTaskById(_ taskId: String, queuedAction: String? = nil, sessionId: String? = nil) async throws -> CancelTaskResponse {
        var q: [URLQueryItem] = []
        if let queuedAction, let sessionId {
            q = MulticaCore.query(["expected_status": "queued", "chat_session_id": sessionId, "queue_action": queuedAction])
        }
        return try await call(.post, "/api/tasks/\(taskId)/cancel", query: q, headers: ["X-Client-Capabilities": "chat-draft-restore-v1"])
    }

    // MARK: Agent skills, labels and MCP

    public nonisolated func listAgentSkills(agentId: String) async throws -> [SkillSummary] {
        try await list("/api/agents/\(agentId)/skills")
    }

    public nonisolated func setAgentSkills(agentId: String, _ data: SetAgentSkillsRequest) async throws {
        try await callVoid(.put, "/api/agents/\(agentId)/skills", body: JSONValue(encoding: data))
    }

    public nonisolated func addAgentSkills(agentId: String, _ data: SetAgentSkillsRequest) async throws {
        try await callVoid(.post, "/api/agents/\(agentId)/skills/add", body: JSONValue(encoding: data))
    }

    public nonisolated func setAgentRuntimeSkillEnabled(agentId: String, _ data: SetAgentRuntimeSkillEnabledRequest) async throws {
        try await callVoid(.put, "/api/agents/\(agentId)/runtime-skills/enabled", body: JSONValue(encoding: data))
    }

    public nonisolated func listLabelsForResource(_ resourceType: String, resourceId: String) async throws -> ResourceLabelsResponse {
        try await call(.get, "/api/\(resourceType == "agent" ? "agents" : "skills")/\(resourceId)/labels")
    }

    public nonisolated func attachLabelToResource(_ resourceType: String, resourceId: String, labelId: String) async throws -> ResourceLabelsResponse {
        try await call(.post, "/api/\(resourceType == "agent" ? "agents" : "skills")/\(resourceId)/labels", body: ["label_id": JSONValue(labelId)] as JSONValue)
    }

    public nonisolated func detachLabelFromResource(_ resourceType: String, resourceId: String, labelId: String) async throws -> ResourceLabelsResponse {
        try await call(.delete, "/api/\(resourceType == "agent" ? "agents" : "skills")/\(resourceId)/labels/\(labelId)")
    }

    public nonisolated func listAgentMcpServers(agentId: String) async throws -> [WorkspaceMcpServer] {
        try await list("/api/agents/\(agentId)/mcp-servers")
    }

    public nonisolated func addAgentMcpServer(agentId: String, serverId: String) async throws -> [WorkspaceMcpServer] {
        try await call(.post, "/api/agents/\(agentId)/mcp-servers", body: ["server_id": JSONValue(serverId)] as JSONValue, as: LossyList<WorkspaceMcpServer>.self).items
    }

    public nonisolated func setAgentMcpServerEnabled(agentId: String, serverId: String, enabled: Bool) async throws -> [WorkspaceMcpServer] {
        try await call(.put, "/api/agents/\(agentId)/mcp-servers/\(serverId.pathEscaped)/enabled", body: ["enabled": JSONValue(enabled)] as JSONValue,
                       as: LossyList<WorkspaceMcpServer>.self).items
    }

    public nonisolated func removeAgentMcpServer(agentId: String, serverId: String) async throws -> [WorkspaceMcpServer] {
        try await call(.delete, "/api/agents/\(agentId)/mcp-servers/\(serverId.pathEscaped)", as: LossyList<WorkspaceMcpServer>.self).items
    }

    // MARK: Skills

    public nonisolated func listSkills() async throws -> [SkillSummary] {
        try await list("/api/skills")
    }

    public nonisolated func getSkill(_ id: String) async throws -> Skill {
        try await call(.get, "/api/skills/\(id)")
    }

    public nonisolated func createSkill(_ data: CreateSkillRequest) async throws -> Skill {
        try await call(.post, "/api/skills", body: JSONValue(encoding: data))
    }

    public nonisolated func updateSkill(_ id: String, _ data: UpdateSkillRequest) async throws -> Skill {
        try await call(.put, "/api/skills/\(id)", body: JSONValue(encoding: data))
    }

    public nonisolated func deleteSkill(_ id: String) async throws {
        try await callVoid(.delete, "/api/skills/\(id)")
    }

    public nonisolated func importSkill(url: String) async throws -> Skill {
        try await call(.post, "/api/skills/import", body: ["url": JSONValue(url)] as JSONValue)
    }

    public func importSkillArchive(fileName: String, data: Data, onConflict: String? = nil) async throws -> Skill {
        var fields: [String: String] = [:]
        if let onConflict { fields["on_conflict"] = onConflict }
        let raw: JSONValue = try await upload("/api/skills/import", fileName: fileName.isEmpty ? "skill.zip" : fileName,
                                              mimeType: "application/zip", fileData: data, fields: fields)
        let skill = raw["skill"] ?? raw
        return try JSONCoders.decoder.decode(Skill.self, from: JSONCoders.encoder.encode(skill))
    }

    public nonisolated func refreshSkill(_ id: String) async throws -> Skill {
        try await call(.post, "/api/skills/\(id)/refresh")
    }

    // MARK: Runtimes

    public nonisolated func listRuntimes(workspaceId: String? = nil, owner: String? = nil, workspaceSlug: String? = nil) async throws -> [RuntimeDeviceRecord] {
        try await list("/api/runtimes", query: MulticaCore.query(["workspace_id": workspaceId, "owner": owner]), slug: workspaceSlug)
    }

    public nonisolated func deleteRuntime(_ runtimeId: String) async throws {
        try await callVoid(.delete, "/api/runtimes/\(runtimeId)")
    }

    public nonisolated func unbindAgentsAndDeleteRuntime(_ runtimeId: String, expectedActiveAgentIds: [String]) async throws -> RuntimeDeleteResult {
        try await call(.post, "/api/runtimes/\(runtimeId)/unbind-agents-and-delete",
                       body: ["expected_active_agent_ids": JSONValue(expectedActiveAgentIds)] as JSONValue)
    }

    public nonisolated func updateRuntime(_ runtimeId: String, visibility: String? = nil, customName: String? = nil, applyToMachine: Bool? = nil) async throws -> RuntimeDeviceRecord {
        var body: [String: JSONValue] = [:]
        if let visibility { body["visibility"] = JSONValue(visibility) }
        if let customName { body["custom_name"] = JSONValue(customName) }
        if let applyToMachine { body["apply_to_machine"] = JSONValue(applyToMachine) }
        return try await call(.patch, "/api/runtimes/\(runtimeId)", body: JSONValue.object(body))
    }

    public nonisolated func listRuntimeProfiles(workspaceId: String) async throws -> [RuntimeProfile] {
        try await list("/api/workspaces/\(workspaceId)/runtime-profiles")
    }

    public nonisolated func getRuntimeProfile(workspaceId: String, profileId: String) async throws -> RuntimeProfile {
        try await call(.get, "/api/workspaces/\(workspaceId)/runtime-profiles/\(profileId)")
    }

    public nonisolated func createRuntimeProfile(workspaceId: String, _ body: CreateRuntimeProfileRequest) async throws -> RuntimeProfile {
        try await call(.post, "/api/workspaces/\(workspaceId)/runtime-profiles", body: JSONValue(encoding: body))
    }

    public nonisolated func updateRuntimeProfile(workspaceId: String, profileId: String, _ patch: UpdateRuntimeProfileRequest) async throws -> RuntimeProfile {
        try await call(.patch, "/api/workspaces/\(workspaceId)/runtime-profiles/\(profileId)", body: JSONValue(encoding: patch))
    }

    public nonisolated func deleteRuntimeProfile(workspaceId: String, profileId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/runtime-profiles/\(profileId)")
    }

    public nonisolated func getRuntimeUsage(_ runtimeId: String, days: Int? = nil, tz: String? = nil) async throws -> [RuntimeUsage] {
        try await list("/api/runtimes/\(runtimeId)/usage", query: MulticaCore.query(["days": days.map(String.init), "tz": tz]))
    }

    public nonisolated func getRuntimeTaskActivity(_ runtimeId: String, tz: String? = nil) async throws -> [RuntimeHourlyActivity] {
        try await list("/api/runtimes/\(runtimeId)/activity", query: MulticaCore.query(["tz": tz]))
    }

    public nonisolated func getRuntimeUsageByAgent(_ runtimeId: String, days: Int? = nil, tz: String? = nil) async throws -> [RuntimeUsageByAgent] {
        try await list("/api/runtimes/\(runtimeId)/usage/by-agent", query: MulticaCore.query(["days": days.map(String.init), "tz": tz]))
    }

    public nonisolated func getRuntimeUsageByHour(_ runtimeId: String, days: Int? = nil, tz: String? = nil) async throws -> [RuntimeUsageByHour] {
        try await list("/api/runtimes/\(runtimeId)/usage/by-hour", query: MulticaCore.query(["days": days.map(String.init), "tz": tz]))
    }

    public nonisolated func initiateUpdate(_ runtimeId: String, targetVersion: String) async throws -> RuntimeUpdate {
        try await call(.post, "/api/runtimes/\(runtimeId)/update", body: ["target_version": JSONValue(targetVersion)] as JSONValue)
    }

    public nonisolated func getUpdateResult(_ runtimeId: String, updateId: String) async throws -> RuntimeUpdate {
        try await call(.get, "/api/runtimes/\(runtimeId)/update/\(updateId)")
    }

    public nonisolated func initiateListModels(_ runtimeId: String, force: Bool = false) async throws -> RuntimeModelListRequest {
        try await call(.post, "/api/runtimes/\(runtimeId)/models", query: force ? [URLQueryItem(name: "force", value: "true")] : [])
    }

    public nonisolated func getListModelsResult(_ runtimeId: String, requestId: String) async throws -> RuntimeModelListRequest {
        try await call(.get, "/api/runtimes/\(runtimeId)/models/\(requestId)")
    }

    public nonisolated func initiateListLocalSkills(_ runtimeId: String) async throws -> RuntimeLocalSkillListRequest {
        try await call(.post, "/api/runtimes/\(runtimeId)/local-skills")
    }

    public nonisolated func getListLocalSkillsResult(_ runtimeId: String, requestId: String) async throws -> RuntimeLocalSkillListRequest {
        try await call(.get, "/api/runtimes/\(runtimeId)/local-skills/\(requestId)")
    }

    public nonisolated func initiateImportLocalSkill(_ runtimeId: String, _ data: CreateRuntimeLocalSkillImportRequest) async throws -> RuntimeLocalSkillImportRequest {
        try await call(.post, "/api/runtimes/\(runtimeId)/local-skills/import", body: JSONValue(encoding: data))
    }

    public nonisolated func getImportLocalSkillResult(_ runtimeId: String, requestId: String) async throws -> RuntimeLocalSkillImportRequest {
        try await call(.get, "/api/runtimes/\(runtimeId)/local-skills/import/\(requestId)")
    }

    // MARK: Cloud runtime nodes

    public nonisolated func listCloudRuntimeNodes(limit: Int? = nil, offset: Int? = nil) async throws -> [CloudRuntimeNode] {
        try await list("/api/cloud-runtime/nodes", query: MulticaCore.query(["limit": limit.map(String.init), "offset": offset.map(String.init)]))
    }

    public nonisolated func createCloudRuntimeNode(_ data: CreateCloudRuntimeNodeRequest) async throws -> CloudRuntimeNode {
        try await call(.post, "/api/cloud-runtime/nodes", body: JSONValue(encoding: data))
    }

    public nonisolated func deleteCloudRuntimeNode(instanceId: String) async throws {
        try await callVoid(.delete, "/api/cloud-runtime/nodes", body: ["instance_id": JSONValue(instanceId)] as JSONValue)
    }
}
