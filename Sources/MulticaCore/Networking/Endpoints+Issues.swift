import Foundation

// Issues, comments, reactions, subscribers, labels, properties, views,
// wakeups, pull requests, attachments and search. One method per method of
// the upstream ApiClient (packages/core/api/client.ts), same names.

public struct IssuesEnvelope: Decodable, Sendable, Hashable {
    public var issues: [Issue]
    enum CodingKeys: String, CodingKey { case issues }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issues = c.lossyArray(Issue.self, .issues)
    }
}

public struct ChildProgress: Decodable, Sendable, Hashable {
    public var parentIssueId: String
    public var total: Int
    public var done: Int
    enum CodingKeys: String, CodingKey {
        case total, done
        case parentIssueId = "parent_issue_id"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        parentIssueId = c.lenient(String.self, .parentIssueId) ?? ""
        total = c.lenient(Int.self, .total) ?? 0
        done = c.lenient(Int.self, .done) ?? 0
    }
}

public struct CountResponse: Decodable, Sendable, Hashable {
    public var value: Int
    public init(from decoder: Decoder) throws {
        let obj = try JSONValue(from: decoder)
        var n: Double = 0
        for key in ["count", "updated", "deleted", "cancelled"] {
            if let v = obj[key]?.doubleValue {
                n = v
                break
            }
        }
        value = Int(n)
    }
}

public struct TaskIDResponse: Decodable, Sendable, Hashable {
    public var taskId: String
    enum CodingKeys: String, CodingKey { case taskId = "task_id" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = c.lenient(String.self, .taskId) ?? ""
    }
}

extension ListIssuesParams {
    /// Same key/value pairs the TS client puts on the query string.
    public var queryItems: [URLQueryItem] {
        func join(_ a: [String]?) -> String? { a.flatMap { $0.isEmpty ? nil : $0.joined(separator: ",") } }
        func refs(_ a: [IssueActorRef]?) -> String? {
            a.flatMap { $0.isEmpty ? nil : $0.map { "\($0.type):\($0.id)" }.joined(separator: ",") }
        }
        func json(_ v: some Encodable) -> String { String(decoding: (try? JSONCoders.encoder.encode(v)) ?? Data(), as: UTF8.self) }
        var items = query([
            "limit": limit.flatMap { $0 > 0 ? String($0) : nil },
            "offset": offset.flatMap { $0 > 0 ? String($0) : nil },
            "workspace_id": workspaceId,
            "q": q.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) },
            "status": status,
            "statuses": join(statuses),
            "priority": priority,
            "priorities": join(priorities),
            "assignee_id": assigneeId,
            "assignee_ids": join(assigneeIds),
            "assignee_types": join(assigneeTypes),
            "creator_id": creatorId,
            "project_id": projectId,
            "assignee_filters": refs(assigneeFilters),
            "include_no_assignee": includeNoAssignee == true ? "true" : nil,
            "creator_filters": refs(creatorFilters),
            "project_ids": join(projectIds),
            "include_no_project": includeNoProject == true ? "true" : nil,
            "label_ids": join(labelIds),
            "top_level_only": topLevelOnly == true ? "true" : nil,
            "involves_user_id": involvesUserId,
            "open_only": openOnly == true ? "true" : nil,
            "scheduled": scheduled == true ? "true" : nil,
            "date_field": dateField,
            "date_start": dateStart,
            "date_end": dateEnd,
            "sort": sortBy,
            "direction": sortDirection,
        ])
        // An empty ids list is meaningful (empty window), so it is sent.
        if let ids { items.append(URLQueryItem(name: "ids", value: ids.joined(separator: ","))) }
        if let metadata, !metadata.isEmpty { items.append(URLQueryItem(name: "metadata", value: json(metadata))) }
        if let properties, !properties.isEmpty { items.append(URLQueryItem(name: "properties", value: json(properties))) }
        return items
    }
}

extension APIClient {
    // MARK: Lists & search

    /// `ids` windows can carry hundreds of UUIDs, so they go through the POST
    /// twin with the same key/value pairs as a JSON body.
    public nonisolated func listIssues(params: ListIssuesParams) async throws -> ListIssuesResponse {
        let items = params.queryItems
        if params.ids != nil {
            var body: [String: JSONValue] = [:]
            for i in items { body[i.name] = JSONValue(i.value) }
            return try await call(.post, "/api/issues/query", body: JSONValue.object(body))
        }
        return try await call(.get, "/api/issues", query: items)
    }

    public nonisolated func listGroupedIssues(params: ListGroupedIssuesParams) async throws -> GroupedIssuesResponse {
        try await call(.get, "/api/issues/grouped", query: params.queryItems)
    }

    public nonisolated func listIssueTableGroups(_ params: IssueTableGroupsRequest) async throws -> IssueTableGroupsResponse {
        try await call(.post, "/api/issues/table/groups", body: JSONValue(encoding: params))
    }

    public nonisolated func listIssueTableRows(_ params: IssueTableRowsRequest) async throws -> IssueTableRowsResponse {
        try await call(.post, "/api/issues/table/rows", body: JSONValue(encoding: params))
    }

    public nonisolated func listIssueTableFacets(_ params: IssueTableFacetsRequest) async throws -> IssueTableFacetsResponse {
        try await call(.post, "/api/issues/table/facets", body: JSONValue(encoding: params))
    }

    public nonisolated func searchIssues(q: String, limit: Int? = nil, offset: Int? = nil, includeClosed: Bool? = nil) async throws -> SearchIssuesResponse {
        try await call(.get, "/api/issues/search", query: MulticaCore.query([
            "q": q, "limit": limit.map(String.init), "offset": offset.map(String.init),
            "include_closed": includeClosed.map { $0 ? "true" : "false" },
        ]))
    }

    public nonisolated func searchProjects(q: String, limit: Int? = nil, offset: Int? = nil, includeClosed: Bool? = nil) async throws -> SearchProjectsResponse {
        try await call(.get, "/api/projects/search", query: MulticaCore.query([
            "q": q, "limit": limit.map(String.init), "offset": offset.map(String.init),
            "include_closed": includeClosed.map { $0 ? "true" : "false" },
        ]))
    }

    public nonisolated func getSearchIndexManifest(workspaceSlug: String) async throws -> SearchIndexManifest {
        try await call(.get, "/api/search-index/manifest", slug: workspaceSlug)
    }

    public nonisolated func getSearchIndexSnapshot(workspaceSlug: String, afterNumber: Int, limit: Int? = nil) async throws -> SearchIndexSnapshotPage {
        try await call(.get, "/api/search-index/snapshot", query: MulticaCore.query([
            "after_number": String(afterNumber), "limit": limit.map(String.init),
        ]), slug: workspaceSlug)
    }

    public nonisolated func getSearchIndexChanges(workspaceSlug: String, cursor: String, limit: Int? = nil) async throws -> SearchIndexChanges {
        try await call(.post, "/api/search-index/changes", body: ["cursor": JSONValue(cursor), "limit": JSONValue(limit)] as JSONValue, slug: workspaceSlug)
    }

    // MARK: Wakeups

    public nonisolated func listWorkspaceWakeups(_ f: WorkspaceWakeupFilters) async throws -> WorkspaceWakeupPage {
        try await call(.get, "/api/issue-wakeups", query: MulticaCore.query([
            "scope": f.scope, "kind": f.kind, "source": f.source, "search": f.search,
            "agent_id": f.agentId, "offset": String(f.offset), "limit": String(f.limit),
        ]))
    }

    public nonisolated func listIssueWakeups(issueId: String) async throws -> [IssueWakeup] {
        try await list("/api/issues/\(issueId.pathEscaped)/wakeups")
    }

    public nonisolated func listIssueWakeupSummaries() async throws -> [IssueWakeupSummaryRow] {
        try await list("/api/issue-wakeup-summaries")
    }

    public nonisolated func enableIssueWakeup(issueId: String, wakeupId: String, revision: Int, at: String? = nil, rearm: Bool? = nil) async throws {
        try await callVoid(.post, "/api/issues/\(issueId.pathEscaped)/wakeups/\(wakeupId.pathEscaped)/enable",
                           body: ["revision": JSONValue(revision), "at": JSONValue(at), "rearm": JSONValue(rearm)] as JSONValue)
    }

    public nonisolated func editIssueWakeupInstruction(issueId: String, wakeupId: String, instruction: String, expectedInstruction: String, revision: Int) async throws {
        try await callVoid(.patch, "/api/issues/\(issueId.pathEscaped)/wakeups/\(wakeupId.pathEscaped)/instruction",
                           body: ["instruction": JSONValue(instruction), "expected_instruction": JSONValue(expectedInstruction), "revision": JSONValue(revision)] as JSONValue)
    }

    public nonisolated func createIssueWakeup(issueId: String, _ input: IssueWakeupInput) async throws {
        try await callVoid(.post, "/api/issues/\(issueId.pathEscaped)/wakeups", body: input)
    }

    public nonisolated func listIssueSystemWakeups(issueId: String) async throws -> [SystemWakeup] {
        try await list("/api/issues/\(issueId.pathEscaped)/system-wakeups")
    }

    public nonisolated func listIssueWakeupRuns(issueId: String, wakeupId: String) async throws -> [WakeupRun] {
        try await list("/api/issues/\(issueId.pathEscaped)/wakeups/\(wakeupId.pathEscaped)/runs")
    }

    public nonisolated func listPausedWakeups() async throws -> [PausedWakeup] {
        try await list("/api/issue-wakeup-paused")
    }

    public nonisolated func triggerIssueWakeup(issueId: String, wakeupId: String) async throws {
        try await callVoid(.post, "/api/issues/\(issueId.pathEscaped)/wakeups/\(wakeupId.pathEscaped)/trigger")
    }

    public nonisolated func deleteIssueWakeup(issueId: String, wakeupId: String) async throws {
        try await callVoid(.delete, "/api/issues/\(issueId.pathEscaped)/wakeups/\(wakeupId.pathEscaped)")
    }

    public nonisolated func disableIssueWakeup(issueId: String, wakeupId: String) async throws {
        try await callVoid(.post, "/api/issues/\(issueId.pathEscaped)/wakeups/\(wakeupId.pathEscaped)/disable")
    }

    public nonisolated func updateIssueSystemWakeup(issueId: String, rule: String, enabled: Bool? = nil, instruction: String? = nil) async throws {
        try await callVoid(.put, "/api/issues/\(issueId.pathEscaped)/system-wakeups/\(rule.pathEscaped)",
                           body: ["enabled": JSONValue(enabled), "instruction": JSONValue(instruction)] as JSONValue)
    }

    public nonisolated func listWorkspaceSystemWakeups() async throws -> [WorkspaceSystemWakeup] {
        try await list("/api/system-wakeups")
    }

    public nonisolated func updateWorkspaceSystemWakeup(rule: String, enabled: Bool? = nil, instruction: String? = nil) async throws {
        try await callVoid(.put, "/api/system-wakeups/\(rule.pathEscaped)",
                           body: ["enabled": JSONValue(enabled), "instruction": JSONValue(instruction)] as JSONValue)
    }

    // MARK: Issue CRUD

    public nonisolated func getIssue(_ id: String) async throws -> IssueRecord {
        try await call(.get, "/api/issues/\(id.pathEscaped)")
    }

    public nonisolated func createIssue(record: CreateIssueRequestRecord) async throws -> Issue {
        try await call(.post, "/api/issues", body: JSONValue(encoding: record))
    }

    public nonisolated func quickCreateIssue(prompt: String, agentId: String? = nil, squadId: String? = nil, priority: String? = nil,
                                             dueDate: String? = nil, projectId: String? = nil, parentIssueId: String? = nil,
                                             attachmentIds: [String]? = nil) async throws -> TaskIDResponse {
        var body: [String: JSONValue] = ["prompt": JSONValue(prompt)]
        if let agentId { body["agent_id"] = JSONValue(agentId) }
        if let squadId { body["squad_id"] = JSONValue(squadId) }
        if let priority { body["priority"] = JSONValue(priority) }
        if let dueDate { body["due_date"] = JSONValue(dueDate) }
        if let projectId { body["project_id"] = JSONValue(projectId) }
        if let parentIssueId { body["parent_issue_id"] = JSONValue(parentIssueId) }
        if let attachmentIds, !attachmentIds.isEmpty { body["attachment_ids"] = JSONValue(attachmentIds) }
        return try await call(.post, "/api/issues/quick-create", body: JSONValue.object(body))
    }

    public nonisolated func getCommentSubIssuePreview(anchorCommentId: String) async throws -> SourceContextPreview {
        try await call(.get, "/api/comments/\(anchorCommentId)/sub-issue-preview")
    }

    public nonisolated func createCommentSubIssue(anchorCommentId: String, manual: CreateCommentSubIssueManualRequest) async throws -> Issue {
        try await call(.post, "/api/comments/\(anchorCommentId)/sub-issues", body: JSONValue(encoding: manual))
    }

    public nonisolated func createCommentSubIssue(anchorCommentId: String, agent: CreateCommentSubIssueAgentRequest) async throws -> TaskIDResponse {
        try await call(.post, "/api/comments/\(anchorCommentId)/sub-issues", body: JSONValue(encoding: agent))
    }

    public nonisolated func updateIssue(_ id: String, record: UpdateIssueRequestRecord) async throws -> Issue {
        try await call(.put, "/api/issues/\(id)", body: JSONValue(encoding: record))
    }

    public nonisolated func moveIssue(_ id: String, _ data: MoveIssueRequest) async throws -> Issue {
        try await call(.post, "/api/issues/\(id)/move", body: JSONValue(encoding: data))
    }

    public nonisolated func listIssueDuplicates(_ id: String) async throws -> IssueDuplicates {
        try await call(.get, "/api/issues/\(id)/duplicates")
    }

    public nonisolated func listChildIssues(_ id: String) async throws -> [Issue] {
        try await call(.get, "/api/issues/\(id)/children", as: IssuesEnvelope.self).issues
    }

    public nonisolated func listChildrenByParents(_ parentIds: [String]) async throws -> [Issue] {
        try await call(.get, "/api/issues/children", query: [URLQueryItem(name: "parent_ids", value: parentIds.joined(separator: ","))],
                       as: IssuesEnvelope.self).issues
    }

    public nonisolated func getChildIssueProgress() async throws -> [ChildProgress] {
        try await field(.get, "/api/issues/child-progress", "progress", as: LossyList<ChildProgress>.self).items
    }

    public nonisolated func getIssueLimitUsage() async throws -> IssueLimitUsage? {
        let v: JSONValue = try await call(.get, "/api/issues/limit-usage")
        guard !v.isNull else { return nil }
        return try JSONCoders.decoder.decode(IssueLimitUsage.self, from: JSONCoders.encoder.encode(v))
    }

    public nonisolated func deleteIssue(_ id: String) async throws {
        try await callVoid(.delete, "/api/issues/\(id)")
    }

    public nonisolated func batchUpdateIssues(_ issueIds: [String], updates: UpdateIssueRequestRecord) async throws -> Int {
        try await call(.post, "/api/issues/batch-update",
                       body: ["issue_ids": JSONValue(issueIds), "updates": JSONValue(encoding: updates)] as JSONValue,
                       as: CountResponse.self).value
    }

    public nonisolated func batchDeleteIssues(_ issueIds: [String]) async throws -> Int {
        try await call(.post, "/api/issues/batch-delete", body: ["issue_ids": JSONValue(issueIds)] as JSONValue, as: CountResponse.self).value
    }

    // MARK: Comments

    public nonisolated func listComments(issueId: String) async throws -> [Comment] {
        try await list("/api/issues/\(issueId)/comments")
    }

    public nonisolated func createComment(issueId: String, content: String, type: String? = nil, parentId: String? = nil,
                                          attachmentIds: [String]? = nil, suppressAgentIds: [String]? = nil,
                                          steerTaskIds: [String]? = nil) async throws -> Comment {
        var body: [String: JSONValue] = ["content": JSONValue(content), "type": JSONValue(type ?? "comment")]
        if let parentId { body["parent_id"] = JSONValue(parentId) }
        if let attachmentIds, !attachmentIds.isEmpty { body["attachment_ids"] = JSONValue(attachmentIds) }
        if let suppressAgentIds, !suppressAgentIds.isEmpty { body["suppress_agent_ids"] = JSONValue(suppressAgentIds) }
        if let steerTaskIds, !steerTaskIds.isEmpty { body["steer_task_ids"] = JSONValue(steerTaskIds) }
        return try await call(.post, "/api/issues/\(issueId)/comments", body: JSONValue.object(body))
    }

    public nonisolated func previewCommentTriggers(issueId: String, content: String, parentId: String? = nil, editingCommentId: String? = nil) async throws -> CommentTriggerPreview {
        var body: [String: JSONValue] = ["content": JSONValue(content)]
        if let parentId { body["parent_id"] = JSONValue(parentId) }
        if let editingCommentId { body["editing_comment_id"] = JSONValue(editingCommentId) }
        return try await call(.post, "/api/issues/\(issueId)/comments/trigger-preview", body: JSONValue.object(body))
    }

    public nonisolated func previewIssueTrigger(_ p: IssueTriggerPreviewParams) async throws -> IssueTriggerPreview {
        var body: [String: JSONValue] = [:]
        if let ids = p.issueIds, !ids.isEmpty { body["issue_ids"] = JSONValue(ids) }
        if p.isCreate == true { body["is_create"] = true }
        if let t = p.assigneeType { body["assignee_type"] = JSONValue(t) }
        if let a = p.assigneeId { body["assignee_id"] = JSONValue(a) }
        if let s = p.status { body["status"] = JSONValue(s) }
        return try await call(.post, "/api/issues/preview-trigger", body: JSONValue.object(body))
    }

    public nonisolated func listTimeline(issueId: String) async throws -> [TimelineEntry] {
        try await list("/api/issues/\(issueId)/timeline")
    }

    public nonisolated func getAssigneeFrequency() async throws -> [AssigneeFrequencyEntry] {
        try await list("/api/assignee-frequency")
    }

    public nonisolated func updateComment(_ commentId: String, content: String, attachmentIds: [String]? = nil, suppressAgentIds: [String]? = nil,
                                          contentBase: String? = nil, expectedRevision: Int? = nil) async throws -> Comment {
        var body: [String: JSONValue] = ["content": JSONValue(content)]
        if let attachmentIds { body["attachment_ids"] = JSONValue(attachmentIds) }
        if let suppressAgentIds, !suppressAgentIds.isEmpty { body["suppress_agent_ids"] = JSONValue(suppressAgentIds) }
        if let contentBase { body["content_base"] = JSONValue(contentBase) }
        if let expectedRevision { body["expected_revision"] = JSONValue(expectedRevision) }
        return try await call(.put, "/api/comments/\(commentId)", body: JSONValue.object(body))
    }

    public nonisolated func deleteComment(_ commentId: String, keepReplies: Bool = false) async throws {
        try await callVoid(.delete, keepReplies ? "/api/comments/\(commentId)/keep-replies" : "/api/comments/\(commentId)")
    }

    public nonisolated func resolveComment(_ commentId: String) async throws -> Comment {
        try await call(.post, "/api/comments/\(commentId)/resolve")
    }

    public nonisolated func unresolveComment(_ commentId: String) async throws -> Comment {
        try await call(.delete, "/api/comments/\(commentId)/resolve")
    }

    public nonisolated func addReaction(commentId: String, emoji: String) async throws -> Reaction {
        try await call(.post, "/api/comments/\(commentId)/reactions", body: ["emoji": JSONValue(emoji)] as JSONValue)
    }

    public nonisolated func removeReaction(commentId: String, emoji: String) async throws {
        try await callVoid(.delete, "/api/comments/\(commentId)/reactions", body: ["emoji": JSONValue(emoji)] as JSONValue)
    }

    public nonisolated func addIssueReaction(issueId: String, emoji: String) async throws -> IssueReaction {
        try await call(.post, "/api/issues/\(issueId)/reactions", body: ["emoji": JSONValue(emoji)] as JSONValue)
    }

    public nonisolated func removeIssueReaction(issueId: String, emoji: String) async throws {
        try await callVoid(.delete, "/api/issues/\(issueId)/reactions", body: ["emoji": JSONValue(emoji)] as JSONValue)
    }

    // MARK: Subscribers

    public nonisolated func listIssueSubscribers(issueId: String) async throws -> [IssueSubscriber] {
        try await list("/api/issues/\(issueId)/subscribers")
    }

    private nonisolated func subscriberTarget(_ userId: String?, _ userType: String?) -> JSONValue {
        var body: [String: JSONValue] = [:]
        if let userId { body["user_id"] = JSONValue(userId) }
        if let userType { body["user_type"] = JSONValue(userType) }
        return .object(body)
    }

    public nonisolated func subscribeToIssue(issueId: String, userId: String? = nil, userType: String? = nil) async throws {
        try await callVoid(.post, "/api/issues/\(issueId)/subscribe", body: subscriberTarget(userId, userType))
    }

    public nonisolated func unsubscribeFromIssue(issueId: String, userId: String? = nil, userType: String? = nil) async throws {
        try await callVoid(.post, "/api/issues/\(issueId)/unsubscribe", body: subscriberTarget(userId, userType))
    }

    public nonisolated func unsubscribeFromIssueSubtree(issueId: String, userId: String? = nil, userType: String? = nil) async throws {
        try await callVoid(.post, "/api/issues/\(issueId)/unsubscribe/subtree", body: subscriberTarget(userId, userType))
    }

    // MARK: Runs on an issue

    public nonisolated func getActiveTasksForIssue(issueId: String) async throws -> [AgentTask] {
        try await field(.get, "/api/issues/\(issueId)/active-task", "tasks", as: LossyList<AgentTask>.self).items
    }

    public nonisolated func retryTaskSupplement(issueId: String, taskId: String, commentId: String) async throws {
        try await callVoid(.post, "/api/issues/\(issueId)/tasks/\(taskId)/supplements/\(commentId)/retry")
    }

    public nonisolated func getIssueUsage(issueId: String) async throws -> IssueUsageSummary {
        try await call(.get, "/api/issues/\(issueId)/usage")
    }

    public nonisolated func rerunIssue(issueId: String, taskId: String? = nil) async throws -> AgentTask {
        try await call(.post, "/api/issues/\(issueId)/rerun", body: taskId.map { ["task_id": JSONValue($0)] as JSONValue } ?? JSONValue.object([:]))
    }

    public nonisolated func retrySourceContextQuickCreate(taskId: String) async throws -> AgentTask {
        try await call(.post, "/api/tasks/\(taskId)/retry-source-context")
    }

    // MARK: Labels on issues

    public nonisolated func listLabelsForIssue(issueId: String) async throws -> IssueLabelsResponse {
        try await call(.get, "/api/issues/\(issueId)/labels")
    }

    public nonisolated func attachLabel(issueId: String, labelId: String) async throws -> IssueLabelsResponse {
        try await call(.post, "/api/issues/\(issueId)/labels", body: ["label_id": JSONValue(labelId)] as JSONValue)
    }

    public nonisolated func detachLabel(issueId: String, labelId: String) async throws -> IssueLabelsResponse {
        try await call(.delete, "/api/issues/\(issueId)/labels/\(labelId)")
    }

    // MARK: Custom properties on issues

    public nonisolated func setIssueProperty(issueId: String, propertyId: String, value: JSONValue) async throws -> IssuePropertiesResponse {
        try await call(.put, "/api/issues/\(issueId)/properties/\(propertyId)", body: ["value": value] as JSONValue)
    }

    public nonisolated func unsetIssueProperty(issueId: String, propertyId: String) async throws -> IssuePropertiesResponse {
        try await call(.delete, "/api/issues/\(issueId)/properties/\(propertyId)")
    }

    // MARK: Quick actions on issues

    public nonisolated func runQuickAction(issueId: String, quickActionId: String) async throws -> Comment {
        try await call(.post, "/api/issues/\(issueId)/quick-actions/\(quickActionId)/run")
    }

    public nonisolated func renderQuickAction(issueId: String, quickActionId: String) async throws -> String {
        let v: JSONValue = try await call(.post, "/api/issues/\(issueId)/quick-actions/\(quickActionId)/render")
        return v["rendered"]?.stringValue ?? v["prompt"]?.stringValue ?? v.stringValue ?? ""
    }

    // MARK: Saved views

    public nonisolated func listIssueViews(scopeType: String, scopeId: String? = nil) async throws -> [IssueView] {
        try await list("/api/issue-views", query: MulticaCore.query(["scope_type": scopeType, "scope_id": scopeId]))
    }

    public nonisolated func createIssueView(_ data: CreateIssueViewRequest) async throws -> IssueView? {
        try? await call(.post, "/api/issue-views", body: JSONValue(encoding: data), as: IssueView.self)
    }

    public nonisolated func updateIssueView(_ id: String, name: String? = nil, visibility: String? = nil, query q: [String: JSONValue]? = nil,
                                            display: [String: JSONValue]? = nil, expectedRevision: Int) async throws -> IssueView {
        var body: [String: JSONValue] = ["expected_revision": JSONValue(expectedRevision)]
        if let name { body["name"] = JSONValue(name) }
        if let visibility { body["visibility"] = JSONValue(visibility) }
        if let q { body["query"] = .object(q) }
        if let display { body["display"] = .object(display) }
        return try await call(.patch, "/api/issue-views/\(id)", body: JSONValue.object(body))
    }

    public nonisolated func getIssueView(_ id: String) async throws -> IssueView {
        try await call(.get, "/api/issue-views/\(id)")
    }

    public nonisolated func deleteIssueView(_ id: String) async throws {
        try await callVoid(.delete, "/api/issue-views/\(id)")
    }

    public nonisolated func getIssueViewPreference(scopeType: String, scopeId: String? = nil) async throws -> IssueViewPreference {
        try await call(.get, "/api/issue-view-preferences", query: MulticaCore.query(["scope_type": scopeType, "scope_id": scopeId]))
    }

    public nonisolated func putIssueViewPreference(scopeType: String, scopeId: String? = nil, hidden: [String], order: [String]) async throws -> IssueViewPreference {
        try await call(.put, "/api/issue-view-preferences", body: [
            "scope_type": JSONValue(scopeType), "scope_id": JSONValue(scopeId),
            "prefs": ["hidden": JSONValue(hidden), "order": JSONValue(order)],
        ] as JSONValue)
    }

    // MARK: Pull requests

    public nonisolated func listIssuePullRequests(issueId: String) async throws -> IssuePullRequestsResponse {
        try await call(.get, "/api/issues/\(issueId)/pull-requests")
    }

    public nonisolated func linkIssuePullRequest(issueId: String, url: String) async throws -> IssuePullRequestsResponse {
        try await call(.post, "/api/issues/\(issueId)/pull-requests", body: ["url": JSONValue(url)] as JSONValue)
    }

    public nonisolated func unlinkIssuePullRequest(issueId: String, pullRequestId: String) async throws -> IssuePullRequestsResponse {
        try await call(.delete, "/api/issues/\(issueId)/pull-requests/\(pullRequestId)")
    }

    public nonisolated func setIssuePRAutoComplete(issueId: String, disabled: Bool) async throws -> IssuePullRequestsResponse {
        try await call(.put, "/api/issues/\(issueId)/pr-auto-complete", body: ["disabled": JSONValue(disabled)] as JSONValue)
    }

    // MARK: Attachments

    public func uploadFile(name: String, mimeType: String, data: Data, issueId: String? = nil, commentId: String? = nil,
                           chatSessionId: String? = nil) async throws -> Attachment {
        var fields: [String: String] = [:]
        if let issueId { fields["issue_id"] = issueId }
        if let commentId { fields["comment_id"] = commentId }
        if let chatSessionId { fields["chat_session_id"] = chatSessionId }
        return try await upload("/api/upload-file", fileName: name, mimeType: mimeType, fileData: data, fields: fields)
    }

    public nonisolated func listAttachments(issueId: String) async throws -> [Attachment] {
        try await list("/api/issues/\(issueId)/attachments")
    }

    public nonisolated func getAttachment(_ id: String) async throws -> Attachment {
        try await call(.get, "/api/attachments/\(id)")
    }

    public nonisolated func deleteAttachment(_ id: String) async throws {
        try await callVoid(.delete, "/api/attachments/\(id)")
    }

    public nonisolated func getAttachmentTextContent(_ id: String) async throws -> (text: String, contentType: String) {
        let v: JSONValue = try await call(.get, "/api/attachments/\(id)/content")
        return (v["text"]?.stringValue ?? "", v["original_content_type"]?.stringValue ?? v["content_type"]?.stringValue ?? "")
    }

    public func getAttachmentBlob(_ id: String) async throws -> Data {
        try await download("/api/attachments/\(id)/download")
    }
}

extension ListGroupedIssuesParams {
    public var queryItems: [URLQueryItem] {
        func join(_ a: [String]?) -> String? { a.flatMap { $0.isEmpty ? nil : $0.joined(separator: ",") } }
        func refs(_ a: [IssueActorRef]?) -> String? {
            a.flatMap { $0.isEmpty ? nil : $0.map { "\($0.type):\($0.id)" }.joined(separator: ",") }
        }
        func json(_ v: some Encodable) -> String { String(decoding: (try? JSONCoders.encoder.encode(v)) ?? Data(), as: UTF8.self) }
        var items = query([
            "limit": limit.map(String.init), "offset": offset.map(String.init),
            "statuses": join(statuses), "priorities": join(priorities), "assignee_types": join(assigneeTypes),
            "assignee_id": assigneeId, "assignee_ids": join(assigneeIds), "creator_id": creatorId,
            "project_id": projectId, "involves_user_id": involvesUserId,
            "assignee_filters": refs(assigneeFilters), "include_no_assignee": includeNoAssignee == true ? "true" : nil,
            "creator_filters": refs(creatorFilters), "project_ids": join(projectIds),
            "include_no_project": includeNoProject == true ? "true" : nil, "label_ids": join(labelIds),
            "group_assignee_type": groupAssigneeType, "group_assignee_id": groupAssigneeId,
            "date_field": dateField, "date_start": dateStart, "date_end": dateEnd,
            "sort": sortBy, "direction": sortDirection,
        ])
        if let metadata, !metadata.isEmpty { items.append(URLQueryItem(name: "metadata", value: json(metadata))) }
        if let properties, !properties.isEmpty { items.append(URLQueryItem(name: "properties", value: json(properties))) }
        return items
    }
}
