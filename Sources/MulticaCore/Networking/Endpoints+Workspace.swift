import Foundation

// Account, workspace administration and workspace-level catalogs.

public struct ShareLinkJoinResult: Decodable, Sendable, Hashable {
    public var workspaceId: String
    public var workspaceSlug: String
    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case workspaceSlug = "workspace_slug"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = c.lenient(String.self, .workspaceId) ?? ""
        workspaceSlug = c.lenient(String.self, .workspaceSlug) ?? ""
    }
}

/// Filters of the archived inbox (`InboxFilters` in inbox/filter-store.ts).
public struct InboxFilters: Sendable, Hashable {
    public var statuses: [String] = []
    public var priorities: [String] = []
    public var actors: [String] = []
    public var unreadOnly = false

    public init(statuses: [String] = [], priorities: [String] = [], actors: [String] = [], unreadOnly: Bool = false) {
        self.statuses = statuses
        self.priorities = priorities
        self.actors = actors
        self.unreadOnly = unreadOnly
    }

    var queryItems: [URLQueryItem] {
        query([
            "statuses": statuses.isEmpty ? nil : statuses.sorted().joined(separator: ","),
            "priorities": priorities.isEmpty ? nil : priorities.sorted().joined(separator: ","),
            "actors": actors.isEmpty ? nil : actors.sorted().joined(separator: ","),
            "unread_only": unreadOnly ? "true" : nil,
        ])
    }
}

extension APIClient {
    // MARK: Auth & account

    public nonisolated func googleLogin(code: String, redirectUri: String) async throws -> LoginResponse {
        try await call(.post, "/auth/google", body: ["code": JSONValue(code), "redirect_uri": JSONValue(redirectUri)] as JSONValue)
    }

    public nonisolated func logout() async throws {
        try await callVoid(.post, "/auth/logout")
    }

    public nonisolated func issueCliToken() async throws -> String {
        let v: JSONValue = try await call(.post, "/api/cli-token")
        return v["token"]?.stringValue ?? ""
    }

    public nonisolated func refreshSession() async throws -> RefreshSessionResponse {
        try await call(.post, "/api/auth/refresh")
    }

    public nonisolated func getMe() async throws -> UserRecord {
        try await call(.get, "/api/me")
    }

    public nonisolated func markOnboardingComplete(completionPath: String? = nil, workspaceId: String? = nil) async throws -> UserRecord {
        var body: [String: JSONValue] = [:]
        if let completionPath { body["completion_path"] = JSONValue(completionPath) }
        if let workspaceId { body["workspace_id"] = JSONValue(workspaceId) }
        return try await call(.post, "/api/me/onboarding/complete", body: body.isEmpty ? nil : JSONValue.object(body))
    }

    public nonisolated func joinCloudWaitlist(email: String, reason: String? = nil) async throws -> UserRecord {
        try await call(.post, "/api/me/onboarding/cloud-waitlist", body: ["email": JSONValue(email), "reason": JSONValue(reason)] as JSONValue)
    }

    public nonisolated func patchOnboarding(questionnaire: [String: JSONValue]) async throws -> UserRecord {
        try await call(.patch, "/api/me/onboarding", body: ["questionnaire": JSONValue.object(questionnaire)] as JSONValue)
    }

    public nonisolated func updateMe(_ data: UpdateMeRequest) async throws -> UserRecord {
        try await call(.patch, "/api/me", body: JSONValue(encoding: data))
    }

    public nonisolated func updateMe(patch: [String: JSONValue]) async throws -> UserRecord {
        try await call(.patch, "/api/me", body: JSONValue.object(patch))
    }

    public nonisolated func getConfig() async throws -> AppConfigResponse {
        try await call(.get, "/api/config")
    }

    public nonisolated func createFeedback(message: String, url: String? = nil, workspaceId: String? = nil, kind: String? = nil) async throws -> CreateFeedbackResponse {
        var body: [String: JSONValue] = ["message": JSONValue(message)]
        if let url { body["url"] = JSONValue(url) }
        if let workspaceId { body["workspace_id"] = JSONValue(workspaceId) }
        if let kind { body["kind"] = JSONValue(kind) }
        return try await call(.post, "/api/feedback", body: JSONValue.object(body))
    }

    public nonisolated func upsertClientUsage(_ data: ClientUsageRequest) async throws {
        try await callVoid(.post, "/api/client-usage", body: JSONValue(encoding: data))
    }

    // MARK: Workspaces

    public nonisolated func getWorkspace(_ id: String) async throws -> WorkspaceRecord {
        try await call(.get, "/api/workspaces/\(id)")
    }

    public nonisolated func listWorkspaceRecords() async throws -> [WorkspaceRecord] {
        try await list("/api/workspaces")
    }

    public nonisolated func createWorkspace(name: String, slug: String, description: String? = nil, context: String? = nil,
                                            issuePrefix: String? = nil) async throws -> Workspace {
        var body: [String: JSONValue] = ["name": JSONValue(name), "slug": JSONValue(slug)]
        if let description { body["description"] = JSONValue(description) }
        if let context { body["context"] = JSONValue(context) }
        if let issuePrefix { body["issue_prefix"] = JSONValue(issuePrefix) }
        return try await call(.post, "/api/workspaces", body: JSONValue.object(body))
    }

    public nonisolated func updateWorkspace(_ id: String, patch: [String: JSONValue]) async throws -> WorkspaceRecord {
        try await call(.patch, "/api/workspaces/\(id)", body: JSONValue.object(patch))
    }

    public nonisolated func deleteWorkspace(_ id: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(id)")
    }

    public nonisolated func leaveWorkspace(_ id: String) async throws {
        try await callVoid(.post, "/api/workspaces/\(id)/leave")
    }

    // MARK: Members & invitations

    public nonisolated func listMembers(workspaceId: String) async throws -> [MemberWithUserRecord] {
        try await list("/api/workspaces/\(workspaceId)/members")
    }

    public nonisolated func createMember(workspaceId: String, _ data: CreateMemberRequest) async throws -> Invitation {
        try await call(.post, "/api/workspaces/\(workspaceId)/members", body: JSONValue(encoding: data))
    }

    public nonisolated func updateMember(workspaceId: String, memberId: String, _ data: UpdateMemberRequest) async throws -> MemberWithUserRecord {
        try await call(.patch, "/api/workspaces/\(workspaceId)/members/\(memberId)", body: JSONValue(encoding: data))
    }

    public nonisolated func deleteMember(workspaceId: String, memberId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/members/\(memberId)")
    }

    public nonisolated func listWorkspaceInvitations(workspaceId: String) async throws -> [Invitation] {
        try await list("/api/workspaces/\(workspaceId)/invitations")
    }

    public nonisolated func revokeInvitation(workspaceId: String, invitationId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/invitations/\(invitationId)")
    }

    public nonisolated func listMyInvitations() async throws -> [Invitation] {
        try await list("/api/invitations")
    }

    public nonisolated func getInvitation(_ invitationId: String) async throws -> Invitation {
        try await call(.get, "/api/invitations/\(invitationId)")
    }

    public nonisolated func acceptInvitation(_ invitationId: String) async throws -> MemberWithUserRecord {
        try await call(.post, "/api/invitations/\(invitationId)/accept")
    }

    public nonisolated func declineInvitation(_ invitationId: String) async throws {
        try await callVoid(.post, "/api/invitations/\(invitationId)/decline")
    }

    public nonisolated func createShareLink(workspaceId: String, role: String? = nil, expiresIn: Int? = nil, maxUses: Int? = nil) async throws -> ShareLink {
        var body: [String: JSONValue] = [:]
        if let role { body["role"] = JSONValue(role) }
        if let expiresIn { body["expires_in"] = JSONValue(expiresIn) }
        if let maxUses { body["max_uses"] = JSONValue(maxUses) }
        return try await call(.post, "/api/workspaces/\(workspaceId)/share-links", body: JSONValue.object(body))
    }

    public nonisolated func listShareLinks(workspaceId: String) async throws -> [ShareLink] {
        try await list("/api/workspaces/\(workspaceId)/share-links")
    }

    public nonisolated func revokeShareLink(workspaceId: String, linkId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/share-links/\(linkId)")
    }

    public nonisolated func joinByShareLink(code: String) async throws -> ShareLinkJoinResult {
        try await call(.post, "/api/share-links/join", body: ["code": JSONValue(code)] as JSONValue)
    }

    public nonisolated func getShareLinkInfo(code: String) async throws -> ShareLinkInfo {
        try await call(.get, "/api/share-links/\(code.pathEscaped)")
    }

    // MARK: Personal access tokens

    public nonisolated func listPersonalAccessTokens() async throws -> [PersonalAccessToken] {
        try await list("/api/tokens")
    }

    public nonisolated func createPersonalAccessToken(_ data: CreatePersonalAccessTokenRequest) async throws -> CreatePersonalAccessTokenResponse {
        try await call(.post, "/api/tokens", body: JSONValue(encoding: data))
    }

    public nonisolated func revokePersonalAccessToken(_ id: String) async throws {
        try await callVoid(.delete, "/api/tokens/\(id)")
    }

    // MARK: Notification preferences

    public nonisolated func getNotificationPreferences(workspaceSlug: String? = nil) async throws -> NotificationPreferenceResponse {
        try await call(.get, "/api/notification-preferences", slug: workspaceSlug)
    }

    public nonisolated func updateNotificationPreferences(_ preferences: [String: JSONValue], workspaceSlug: String? = nil) async throws -> NotificationPreferenceResponse {
        try await call(.patch, "/api/notification-preferences", body: ["preferences": JSONValue.object(preferences)] as JSONValue, slug: workspaceSlug)
    }

    // MARK: Labels

    public nonisolated func listLabels(resourceType: String = "issue") async throws -> ListLabelsResponse {
        try await call(.get, "/api/labels", query: [URLQueryItem(name: "resource_type", value: resourceType)])
    }

    public nonisolated func getLabel(_ id: String) async throws -> IssueLabel {
        try await call(.get, "/api/labels/\(id)")
    }

    public nonisolated func createLabel(_ data: CreateLabelRequest) async throws -> IssueLabel {
        try await call(.post, "/api/labels", body: JSONValue(encoding: data))
    }

    public nonisolated func updateLabel(_ id: String, _ data: UpdateLabelRequest) async throws -> IssueLabel {
        try await call(.put, "/api/labels/\(id)", body: JSONValue(encoding: data))
    }

    public nonisolated func deleteLabel(_ id: String) async throws {
        try await callVoid(.delete, "/api/labels/\(id)")
    }

    // MARK: Issue statuses

    public nonisolated func listIssueStatuses(includeArchived: Bool) async throws -> ListIssueStatusesResponse {
        try await call(.get, "/api/issue-statuses", query: includeArchived ? [URLQueryItem(name: "include_archived", value: "true")] : [])
    }

    public nonisolated func createIssueStatus(_ data: CreateIssueStatusRequest) async throws -> IssueStatusEntry {
        try await call(.post, "/api/issue-statuses", body: JSONValue(encoding: data))
    }

    public nonisolated func updateIssueStatus(_ id: String, _ data: UpdateIssueStatusRequest) async throws -> IssueStatusEntry {
        try await call(.patch, "/api/issue-statuses/\(id)", body: JSONValue(encoding: data))
    }

    public nonisolated func reorderIssueStatuses(category: String, ids: [String], includeSystem: Bool = false) async throws -> ListIssueStatusesResponse {
        try await call(.patch, "/api/issue-statuses/reorder",
                       body: ["category": JSONValue(category), "ids": JSONValue(ids), "include_system": JSONValue(includeSystem)] as JSONValue)
    }

    public nonisolated func archiveIssueStatus(_ id: String) async throws -> IssueStatusEntry {
        try await call(.delete, "/api/issue-statuses/\(id)")
    }

    // MARK: Custom properties

    /// Older servers 404 here; that reads as "no properties".
    public nonisolated func listProperties(includeArchived: Bool = false) async throws -> ListPropertiesResponse {
        do {
            return try await call(.get, "/api/properties", query: includeArchived ? [URLQueryItem(name: "include_archived", value: "true")] : [])
        } catch let e as APIError where e.status == 404 {
            return ListPropertiesResponse()
        }
    }

    public nonisolated func createProperty(_ data: CreatePropertyRequest) async throws -> IssueProperty {
        try await call(.post, "/api/properties", body: JSONValue(encoding: data))
    }

    public nonisolated func updateProperty(_ id: String, _ data: UpdatePropertyRequest) async throws -> IssueProperty {
        try await call(.patch, "/api/properties/\(id)", body: JSONValue(encoding: data))
    }

    // MARK: Quick actions

    public nonisolated func listQuickActions(includeArchived: Bool = false) async throws -> ListQuickActionsResponse {
        do {
            return try await call(.get, "/api/quick-actions", query: includeArchived ? [URLQueryItem(name: "include_archived", value: "true")] : [])
        } catch let e as APIError where e.status == 404 {
            return ListQuickActionsResponse()
        }
    }

    public nonisolated func createQuickAction(_ data: CreateQuickActionRequest) async throws -> QuickAction {
        try await call(.post, "/api/quick-actions", body: JSONValue(encoding: data))
    }

    public nonisolated func updateQuickAction(_ id: String, _ data: UpdateQuickActionRequest) async throws -> QuickAction {
        try await call(.patch, "/api/quick-actions/\(id)", body: JSONValue(encoding: data))
    }

    public nonisolated func deleteQuickAction(_ id: String) async throws {
        try await callVoid(.delete, "/api/quick-actions/\(id)")
    }

    // MARK: Pins

    public nonisolated func listPins() async throws -> [PinnedItem] {
        try await list("/api/pins", query: [URLQueryItem(name: "include", value: "view")])
    }

    public nonisolated func createPin(_ data: CreatePinRequest) async throws -> PinnedItem {
        try await call(.post, "/api/pins", body: JSONValue(encoding: data))
    }

    public nonisolated func deletePin(itemType: String, itemId: String) async throws {
        try await callVoid(.delete, "/api/pins/\(itemType)/\(itemId)")
    }

    public nonisolated func reorderPins(_ data: ReorderPinsRequest) async throws {
        try await callVoid(.put, "/api/pins/reorder", body: JSONValue(encoding: data))
    }

    // MARK: Inbox (full surface)

    public nonisolated func listInboxItems() async throws -> [InboxItem] {
        try await list("/api/inbox")
    }

    public nonisolated func markInboxUnread(_ id: String) async throws {
        try await callVoid(.post, "/api/inbox/\(id)/unread")
    }

    public nonisolated func listArchivedInbox() async throws -> [InboxItem] {
        try await list("/api/inbox/archived")
    }

    public nonisolated func listArchivedInboxPage(_ filters: InboxFilters, cursor: String? = nil, groupId: String? = nil) async throws -> ArchivedInboxPage {
        var q = filters.queryItems
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let groupId { q.append(URLQueryItem(name: "group_id", value: groupId)) }
        return try await call(.get, "/api/inbox/archived/page", query: q)
    }

    public nonisolated func getArchivedInboxFacets(_ filters: InboxFilters) async throws -> ArchivedInboxFacets {
        try await call(.get, "/api/inbox/archived/facets", query: filters.queryItems)
    }

    public nonisolated func unarchiveInbox(_ id: String) async throws {
        try await callVoid(.post, "/api/inbox/\(id)/unarchive")
    }

    public nonisolated func getUnreadInboxCount() async throws -> Int {
        try await call(.get, "/api/inbox/unread-count", as: CountResponse.self).value
    }

    public nonisolated func archiveAllInbox() async throws -> Int {
        try await call(.post, "/api/inbox/archive-all", as: CountResponse.self).value
    }

    public nonisolated func archiveAllReadInbox() async throws -> Int {
        try await call(.post, "/api/inbox/archive-all-read", as: CountResponse.self).value
    }

    public nonisolated func archiveCompletedInbox() async throws -> Int {
        try await call(.post, "/api/inbox/archive-completed", as: CountResponse.self).value
    }

    // MARK: MCP servers

    public nonisolated func listWorkspaceMcpServers(workspaceId: String) async throws -> [WorkspaceMcpServer] {
        try await list("/api/workspaces/\(workspaceId)/mcp-servers")
    }

    public nonisolated func createWorkspaceMcpServer(workspaceId: String, name: String, config: [String: JSONValue]) async throws -> WorkspaceMcpServer {
        try await call(.post, "/api/workspaces/\(workspaceId)/mcp-servers", body: ["name": JSONValue(name), "config": JSONValue.object(config)] as JSONValue)
    }

    public nonisolated func updateWorkspaceMcpServer(workspaceId: String, serverId: String, name: String? = nil, config: [String: JSONValue]? = nil) async throws -> WorkspaceMcpServer {
        var body: [String: JSONValue] = [:]
        if let name { body["name"] = JSONValue(name) }
        if let config { body["config"] = .object(config) }
        return try await call(.put, "/api/workspaces/\(workspaceId)/mcp-servers/\(serverId.pathEscaped)", body: JSONValue.object(body))
    }

    public nonisolated func deleteWorkspaceMcpServer(workspaceId: String, serverId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/mcp-servers/\(serverId.pathEscaped)")
    }

    // MARK: Plugins

    public nonisolated func listPluginInstallations(workspaceId: String) async throws -> PluginInstallationListResponse {
        try await call(.get, "/api/workspaces/\(workspaceId)/plugins")
    }

    public nonisolated func listPluginPackages(workspaceId: String) async throws -> PluginPackageListResponse {
        try await call(.get, "/api/workspaces/\(workspaceId)/plugins/packages")
    }

    public func publishPluginPackage(workspaceId: String, fileName: String, data: Data) async throws -> PluginPackage {
        try await upload("/api/workspaces/\(workspaceId)/plugins/packages", fileName: fileName, mimeType: "application/zip", fileData: data)
    }

    public nonisolated func publishLocalPluginPackage(workspaceId: String, name: String) async throws -> PluginPackage {
        try await call(.post, "/api/workspaces/\(workspaceId)/plugins/packages/local", body: ["name": JSONValue(name)] as JSONValue)
    }

    public nonisolated func deletePluginPackage(workspaceId: String, packageId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/plugins/packages/\(packageId)")
    }

    public nonisolated func getPluginSurfaceLaunch(workspaceId: String, installationId: String, surfaceKey: String) async throws -> PluginSurfaceLaunch {
        try await call(.get, "/api/workspaces/\(workspaceId)/plugins/\(installationId)/surfaces/\(surfaceKey.pathEscaped)/launch")
    }

    public nonisolated func previewPlugin(workspaceId: String, _ request: PluginPreviewRequest) async throws -> PluginPreview {
        try await call(.post, "/api/workspaces/\(workspaceId)/plugins/preview", body: JSONValue(encoding: request))
    }

    public nonisolated func installPlugin(workspaceId: String, _ request: PluginInstallRequest) async throws -> PluginInstallation {
        try await call(.post, "/api/workspaces/\(workspaceId)/plugins", body: JSONValue(encoding: request))
    }

    public nonisolated func configurePlugin(workspaceId: String, installationId: String, _ request: PluginConfigRequest) async throws -> PluginInstallation {
        try await call(.put, "/api/workspaces/\(workspaceId)/plugins/\(installationId)/config", body: JSONValue(encoding: request))
    }

    public nonisolated func setPluginEnabled(workspaceId: String, installationId: String, enabled: Bool) async throws -> PluginInstallation {
        try await call(.post, "/api/workspaces/\(workspaceId)/plugins/\(installationId)/\(enabled ? "enable" : "disable")")
    }

    public nonisolated func invokePluginHook(installationId: String, hookKey: String, trigger: String, issueId: String? = nil, input: JSONValue? = nil) async throws -> PluginHookResult {
        try await call(.post, "/api/plugin-bridge/v1/hooks/\(hookKey.pathEscaped)",
                       body: ["trigger": JSONValue(trigger), "issue_id": JSONValue(issueId), "input": input ?? .null] as JSONValue,
                       headers: ["X-Multica-Plugin-Installation": installationId])
    }

    /// Plugin surfaces call back into Multica through this bridge.
    public nonisolated func callPluginAction(installationId: String, method: Method, path: String, body: JSONValue? = nil, issueId: String? = nil) async throws -> JSONValue {
        let q = path == "/context" && issueId != nil ? [URLQueryItem(name: "issue_id", value: issueId)] : []
        return try await call(method, "/api/plugin-bridge/v1\(path)", query: q, body: body,
                              headers: ["X-Multica-Plugin-Installation": installationId])
    }

    public nonisolated func listPluginInvocations(workspaceId: String, installationId: String) async throws -> [PluginInvocation] {
        try await list("/api/workspaces/\(workspaceId)/plugins/\(installationId)/invocations")
    }

    public nonisolated func rotatePluginToken(workspaceId: String, installationId: String) async throws -> PluginTokenIssue {
        try await call(.post, "/api/workspaces/\(workspaceId)/plugins/\(installationId)/token")
    }

    public nonisolated func revokePluginToken(workspaceId: String, installationId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/plugins/\(installationId)/token")
    }

    public nonisolated func listPluginMCPTools(workspaceId: String, installationId: String, hookKey: String) async throws -> [PluginMCPTool] {
        try await list("/api/workspaces/\(workspaceId)/plugins/\(installationId)/mcp/\(hookKey.pathEscaped)/tools")
    }

    public nonisolated func approvePluginMCPTools(workspaceId: String, installationId: String, hookKey: String, tools: [String]) async throws -> PluginInstallation {
        try await call(.put, "/api/workspaces/\(workspaceId)/plugins/\(installationId)/mcp/\(hookKey.pathEscaped)/tools",
                       body: ["tools": JSONValue(tools)] as JSONValue)
    }

    public nonisolated func uninstallPlugin(workspaceId: String, installationId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/plugins/\(installationId)")
    }
}
