import Foundation

// Projects, squads, autopilots, chat and the usage dashboard.

extension APIClient {
    // MARK: Projects

    public nonisolated func listProjects(status: String? = nil) async throws -> ListProjectsResponse {
        try await call(.get, "/api/projects", query: MulticaCore.query(["status": status]))
    }

    public nonisolated func getProject(_ id: String) async throws -> Project {
        try await call(.get, "/api/projects/\(id)")
    }

    public nonisolated func createProject(_ data: CreateProjectRequest) async throws -> Project {
        try await call(.post, "/api/projects", body: JSONValue(encoding: data))
    }

    public nonisolated func updateProject(_ id: String, _ data: UpdateProjectRequest) async throws -> Project {
        try await call(.put, "/api/projects/\(id)", body: JSONValue(encoding: data))
    }

    /// Partial update that can send explicit nulls (e.g. clear the lead).
    public nonisolated func updateProject(_ id: String, patch: [String: JSONValue]) async throws -> Project {
        try await call(.put, "/api/projects/\(id)", body: JSONValue.object(patch))
    }

    public nonisolated func deleteProject(_ id: String) async throws {
        try await callVoid(.delete, "/api/projects/\(id)")
    }

    public nonisolated func listProjectResources(projectId: String) async throws -> ListProjectResourcesResponse {
        try await call(.get, "/api/projects/\(projectId)/resources")
    }

    public nonisolated func createProjectResource(projectId: String, _ data: CreateProjectResourceRequest) async throws -> ProjectResource {
        try await call(.post, "/api/projects/\(projectId)/resources", body: JSONValue(encoding: data))
    }

    public nonisolated func updateProjectResource(projectId: String, resourceId: String, _ data: UpdateProjectResourceRequest) async throws -> ProjectResource {
        try await call(.put, "/api/projects/\(projectId)/resources/\(resourceId)", body: JSONValue(encoding: data))
    }

    public nonisolated func deleteProjectResource(projectId: String, resourceId: String) async throws {
        try await callVoid(.delete, "/api/projects/\(projectId)/resources/\(resourceId)")
    }

    // MARK: Squads

    public nonisolated func listSquads() async throws -> [Squad] {
        try await list("/api/squads")
    }

    public nonisolated func getSquad(_ id: String) async throws -> Squad {
        try await call(.get, "/api/squads/\(id)")
    }

    public nonisolated func createSquad(name: String, description: String? = nil, leaderId: String, avatarUrl: String? = nil) async throws -> Squad {
        var body: [String: JSONValue] = ["name": JSONValue(name), "leader_id": JSONValue(leaderId)]
        if let description { body["description"] = JSONValue(description) }
        if let avatarUrl { body["avatar_url"] = JSONValue(avatarUrl) }
        return try await call(.post, "/api/squads", body: JSONValue.object(body))
    }

    public nonisolated func updateSquad(_ id: String, name: String? = nil, description: String? = nil, instructions: String? = nil,
                                        leaderId: String? = nil, avatarUrl: String? = nil) async throws -> Squad {
        var body: [String: JSONValue] = [:]
        if let name { body["name"] = JSONValue(name) }
        if let description { body["description"] = JSONValue(description) }
        if let instructions { body["instructions"] = JSONValue(instructions) }
        if let leaderId { body["leader_id"] = JSONValue(leaderId) }
        if let avatarUrl { body["avatar_url"] = JSONValue(avatarUrl) }
        return try await call(.put, "/api/squads/\(id)", body: JSONValue.object(body))
    }

    public nonisolated func deleteSquad(_ id: String) async throws {
        try await callVoid(.delete, "/api/squads/\(id)")
    }

    public nonisolated func listSquadMembers(squadId: String) async throws -> [SquadMember] {
        try await list("/api/squads/\(squadId)/members")
    }

    public nonisolated func addSquadMember(squadId: String, memberType: String, memberId: String, role: String? = nil) async throws -> SquadMember {
        var body: [String: JSONValue] = ["member_type": JSONValue(memberType), "member_id": JSONValue(memberId)]
        if let role { body["role"] = JSONValue(role) }
        return try await call(.post, "/api/squads/\(squadId)/members", body: JSONValue.object(body))
    }

    public nonisolated func removeSquadMember(squadId: String, memberType: String, memberId: String) async throws {
        try await callVoid(.delete, "/api/squads/\(squadId)/members", body: ["member_type": JSONValue(memberType), "member_id": JSONValue(memberId)] as JSONValue)
    }

    public nonisolated func updateSquadMemberRole(squadId: String, memberType: String, memberId: String, role: String) async throws -> SquadMember {
        try await call(.patch, "/api/squads/\(squadId)/members/role",
                       body: ["member_type": JSONValue(memberType), "member_id": JSONValue(memberId), "role": JSONValue(role)] as JSONValue)
    }

    public nonisolated func getSquadMemberStatus(squadId: String) async throws -> SquadMemberStatusListResponse {
        try await call(.get, "/api/squads/\(squadId)/members/status")
    }

    // MARK: Autopilots

    public nonisolated func listAutopilots(status: String? = nil) async throws -> ListAutopilotsResponse {
        try await call(.get, "/api/autopilots", query: MulticaCore.query(["status": status]))
    }

    public nonisolated func getAutopilot(_ id: String) async throws -> GetAutopilotResponse {
        try await call(.get, "/api/autopilots/\(id)")
    }

    public nonisolated func createAutopilot(_ data: CreateAutopilotRequest) async throws -> Autopilot {
        try await call(.post, "/api/autopilots", body: JSONValue(encoding: data))
    }

    public nonisolated func updateAutopilot(_ id: String, _ data: UpdateAutopilotRequest) async throws -> Autopilot {
        try await call(.patch, "/api/autopilots/\(id)", body: JSONValue(encoding: data))
    }

    public nonisolated func updateAutopilot(_ id: String, patch: [String: JSONValue]) async throws -> Autopilot {
        try await call(.patch, "/api/autopilots/\(id)", body: JSONValue.object(patch))
    }

    public nonisolated func deleteAutopilot(_ id: String) async throws {
        try await callVoid(.delete, "/api/autopilots/\(id)")
    }

    public nonisolated func grantAutopilotAccess(_ id: String, userId: String) async throws -> AutopilotCollaboratorsResponse {
        try await call(.post, "/api/autopilots/\(id)/collaborators", body: ["user_id": JSONValue(userId)] as JSONValue)
    }

    public nonisolated func revokeAutopilotAccess(_ id: String, userId: String) async throws -> AutopilotCollaboratorsResponse {
        try await call(.delete, "/api/autopilots/\(id)/collaborators/\(userId)")
    }

    public nonisolated func triggerAutopilot(_ id: String) async throws -> AutopilotRun {
        try await call(.post, "/api/autopilots/\(id)/trigger")
    }

    public nonisolated func getAutopilotQuotaUsage() async throws -> AutopilotQuotaUsage {
        try await call(.get, "/api/autopilots/usage")
    }

    public nonisolated func listAutopilotRuns(_ id: String, limit: Int? = nil, offset: Int? = nil) async throws -> ListAutopilotRunsResponse {
        try await call(.get, "/api/autopilots/\(id)/runs", query: MulticaCore.query(["limit": limit.map(String.init), "offset": offset.map(String.init)]))
    }

    public nonisolated func getAutopilotRun(autopilotId: String, runId: String) async throws -> AutopilotRun {
        try await call(.get, "/api/autopilots/\(autopilotId)/runs/\(runId)")
    }

    public nonisolated func createAutopilotTrigger(autopilotId: String, _ data: CreateAutopilotTriggerRequest) async throws -> AutopilotTrigger {
        try await call(.post, "/api/autopilots/\(autopilotId)/triggers", body: JSONValue(encoding: data))
    }

    public nonisolated func updateAutopilotTrigger(autopilotId: String, triggerId: String, _ data: UpdateAutopilotTriggerRequest) async throws -> AutopilotTrigger {
        try await call(.patch, "/api/autopilots/\(autopilotId)/triggers/\(triggerId)", body: JSONValue(encoding: data))
    }

    public nonisolated func deleteAutopilotTrigger(autopilotId: String, triggerId: String) async throws {
        try await callVoid(.delete, "/api/autopilots/\(autopilotId)/triggers/\(triggerId)")
    }

    public nonisolated func cronPreview(expr: String, tz: String) async throws -> CronPreviewResponse {
        try await call(.get, "/api/autopilots/cron-preview", query: MulticaCore.query(["expr": expr, "tz": tz]))
    }

    public nonisolated func rotateAutopilotTriggerWebhookToken(autopilotId: String, triggerId: String) async throws -> AutopilotTrigger {
        try await call(.post, "/api/autopilots/\(autopilotId)/triggers/\(triggerId)/rotate-webhook-token")
    }

    public nonisolated func listAutopilotDeliveries(autopilotId: String, limit: Int? = nil, offset: Int? = nil) async throws -> ListWebhookDeliveriesResponse {
        try await call(.get, "/api/autopilots/\(autopilotId)/deliveries", query: MulticaCore.query(["limit": limit.map(String.init), "offset": offset.map(String.init)]))
    }

    public nonisolated func getAutopilotDelivery(autopilotId: String, deliveryId: String) async throws -> WebhookDelivery {
        try await call(.get, "/api/autopilots/\(autopilotId)/deliveries/\(deliveryId)")
    }

    public nonisolated func replayAutopilotDelivery(autopilotId: String, deliveryId: String) async throws -> WebhookDelivery {
        try await call(.post, "/api/autopilots/\(autopilotId)/deliveries/\(deliveryId)/replay")
    }

    // MARK: Chat

    public nonisolated func listChatSessions(status: String? = nil, workspaceSlug: String? = nil) async throws -> [ChatSession] {
        try await list("/api/chat/sessions", query: MulticaCore.query(["status": status]), slug: workspaceSlug)
    }

    public nonisolated func getChatSession(_ id: String) async throws -> ChatSession {
        try await call(.get, "/api/chat/sessions/\(id)")
    }

    public nonisolated func createChatSession(agentId: String, title: String? = nil, projectId: String? = nil, workspaceSlug: String? = nil) async throws -> ChatSession {
        var body: [String: JSONValue] = ["agent_id": JSONValue(agentId)]
        if let title { body["title"] = JSONValue(title) }
        if let projectId { body["project_id"] = JSONValue(projectId) }
        return try await call(.post, "/api/chat/sessions", body: JSONValue.object(body), slug: workspaceSlug)
    }

    public nonisolated func deleteChatSession(_ id: String) async throws {
        try await callVoid(.delete, "/api/chat/sessions/\(id)")
    }

    public nonisolated func regenerateChatQuickActions(sessionId: String, messageId: String) async throws {
        try await callVoid(.post, "/api/chat/sessions/\(sessionId)/quick-actions/regenerate", body: ["message_id": JSONValue(messageId)] as JSONValue)
    }

    public nonisolated func updateChatSession(_ id: String, title: String) async throws -> ChatSession {
        try await call(.patch, "/api/chat/sessions/\(id)", body: ["title": JSONValue(title)] as JSONValue)
    }

    public nonisolated func updateChatSession(_ id: String, projectId: String?) async throws -> ChatSession {
        try await call(.patch, "/api/chat/sessions/\(id)", body: ["project_id": JSONValue(projectId)] as JSONValue)
    }

    public nonisolated func setChatSessionPinned(_ id: String, pinned: Bool) async throws -> ChatSession {
        try await call(.patch, "/api/chat/sessions/\(id)/pin", body: ["pinned": JSONValue(pinned)] as JSONValue)
    }

    public nonisolated func setChatSessionArchived(_ id: String, archived: Bool) async throws -> ChatSession {
        try await call(.patch, "/api/chat/sessions/\(id)/archive", body: ["archived": JSONValue(archived)] as JSONValue)
    }

    public nonisolated func listChatPinnedAgents() async throws -> [ChatPinnedAgent] {
        try await list("/api/chat/pinned-agents")
    }

    public nonisolated func pinChatAgent(_ agentId: String) async throws -> ChatPinnedAgent {
        try await call(.post, "/api/chat/pinned-agents", body: ["agent_id": JSONValue(agentId)] as JSONValue)
    }

    public nonisolated func unpinChatAgent(_ agentId: String) async throws {
        try await callVoid(.delete, "/api/chat/pinned-agents/\(agentId)")
    }

    public nonisolated func listChatMessages(sessionId: String) async throws -> [ChatMessage] {
        try await list("/api/chat/sessions/\(sessionId)/messages")
    }

    /// Falls back to the unpaged list on servers without the page endpoint.
    public nonisolated func listChatMessagesPage(sessionId: String, beforeCreatedAt: String? = nil, beforeId: String? = nil, limit: Int = 50) async throws -> ChatMessagesPage {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let beforeCreatedAt, let beforeId {
            q.append(URLQueryItem(name: "before_created_at", value: beforeCreatedAt))
            q.append(URLQueryItem(name: "before_id", value: beforeId))
        }
        do {
            return try await call(.get, "/api/chat/sessions/\(sessionId)/messages/page", query: q)
        } catch let e as APIError where e.status == 404 && beforeId == nil {
            let messages = try await listChatMessages(sessionId: sessionId)
            return ChatMessagesPage(messages: messages, limit: limit, hasMore: false, nextCursor: nil)
        }
    }

    public nonisolated func sendChatMessage(sessionId: String, content: String, attachmentIds: [String]? = nil) async throws -> SendChatMessageResponse {
        var body: [String: JSONValue] = ["content": JSONValue(content)]
        if let attachmentIds, !attachmentIds.isEmpty { body["attachment_ids"] = JSONValue(attachmentIds) }
        return try await call(.post, "/api/chat/sessions/\(sessionId)/messages", body: JSONValue.object(body))
    }

    public nonisolated func startMikaOnboarding(sessionId: String, language: String, workspaceSlug: String? = nil) async throws -> StartMikaOnboardingResponse {
        try await call(.post, "/api/chat/sessions/\(sessionId)/onboarding", body: ["language": JSONValue(language)] as JSONValue, slug: workspaceSlug)
    }

    public nonisolated func getPendingChatTask(sessionId: String) async throws -> ChatPendingTask {
        try await call(.get, "/api/chat/sessions/\(sessionId)/pending-task")
    }

    public nonisolated func prioritizeQueuedChatTask(sessionId: String, taskId: String) async throws -> PrioritizeQueuedChatTaskResponse {
        try await call(.post, "/api/chat/sessions/\(sessionId)/queued-tasks/\(taskId)/prioritize")
    }

    public nonisolated func clearQueuedChatTasks(sessionId: String) async throws {
        try await callVoid(.delete, "/api/chat/sessions/\(sessionId)/queued-tasks")
    }

    public nonisolated func listChatDraftRestores(sessionId: String) async throws -> ChatDraftRestoresResponse {
        try await call(.get, "/api/chat/sessions/\(sessionId)/draft-restores")
    }

    public nonisolated func consumeChatDraftRestore(sessionId: String, restoreId: String) async throws {
        try await callVoid(.delete, "/api/chat/sessions/\(sessionId)/draft-restores/\(restoreId)")
    }

    public nonisolated func listPendingChatTasks() async throws -> PendingChatTasksResponse {
        try await call(.get, "/api/chat/pending-tasks")
    }

    public nonisolated func hasAnyPendingChatTasks() async throws -> HasPendingChatTasksResponse {
        try await call(.get, "/api/chat/pending-tasks/has-any")
    }

    public nonisolated func markChatSessionRead(sessionId: String) async throws {
        try await callVoid(.post, "/api/chat/sessions/\(sessionId)/read")
    }

    // MARK: Usage dashboard

    private nonisolated func dashboardQuery(days: Int?, projectId: String?, tz: String?) -> [URLQueryItem] {
        MulticaCore.query(["days": days.map(String.init), "project_id": projectId, "tz": tz])
    }

    public nonisolated func getDashboardUsageDaily(days: Int? = nil, projectId: String? = nil, tz: String? = nil) async throws -> [DashboardUsageDaily] {
        try await list("/api/dashboard/usage/daily", query: dashboardQuery(days: days, projectId: projectId, tz: tz))
    }

    public nonisolated func getDashboardUsageByAgent(days: Int? = nil, projectId: String? = nil, tz: String? = nil) async throws -> [DashboardUsageByAgent] {
        try await list("/api/dashboard/usage/by-agent", query: dashboardQuery(days: days, projectId: projectId, tz: tz))
    }

    public nonisolated func getDashboardAgentRunTime(days: Int? = nil, projectId: String? = nil, tz: String? = nil) async throws -> [DashboardAgentRunTime] {
        try await list("/api/dashboard/agent-runtime", query: dashboardQuery(days: days, projectId: projectId, tz: tz))
    }

    public nonisolated func getDashboardRunTimeDaily(days: Int? = nil, projectId: String? = nil, tz: String? = nil) async throws -> [DashboardRunTimeDaily] {
        try await list("/api/dashboard/runtime/daily", query: dashboardQuery(days: days, projectId: projectId, tz: tz))
    }

    public nonisolated func getDashboardFailuresDaily(days: Int? = nil, projectId: String? = nil, tz: String? = nil) async throws -> [DashboardFailureDaily] {
        try await list("/api/dashboard/failures/daily", query: dashboardQuery(days: days, projectId: projectId, tz: tz))
    }

    public nonisolated func getDashboardFailuresByAgent(days: Int? = nil, projectId: String? = nil, tz: String? = nil) async throws -> [DashboardFailureByAgent] {
        try await list("/api/dashboard/failures/by-agent", query: dashboardQuery(days: days, projectId: projectId, tz: tz))
    }
}
