import Foundation

extension IssueDetailModel {
    /// `reaction:added` / `reaction:removed`, ordered by the comment revision
    /// the server stamps on the event (a stale echo never undoes a newer one).
    func applyReactionEvent(added: Bool, payload: JSONValue) {
        let commentID = added ? payload["reaction"]?["comment_id"]?.stringValue : payload["comment_id"]?.stringValue
        guard let commentID, let i = entries.firstIndex(where: { $0.id == commentID }) else { return }
        let revision = payload["comment_revision"]?.doubleValue.map { Int($0) }
        if let revision, let current = entries[i].revision, revision < current { return }
        var row = entries[i]
        if added {
            guard let raw = payload["reaction"], let data = try? JSONCoders.encoder.encode(raw),
                  let reaction = try? JSONCoders.decoder.decode(Reaction.self, from: data),
                  !row.reactions.contains(where: { $0.id == reaction.id }) else { return }
            row.reactions.removeAll { $0.id.hasPrefix("optimistic-") && $0.emoji == reaction.emoji && $0.actorID == reaction.actorID }
            row.reactions.append(reaction)
        } else {
            let emoji = payload["emoji"]?.stringValue
            let actorType = payload["actor_type"]?.stringValue
            let actorID = payload["actor_id"]?.stringValue
            row.reactions.removeAll { $0.emoji == emoji && $0.actorType == actorType && $0.actorID == actorID }
        }
        if let revision { row.revision = revision }
        if row != entries[i] { entries[i] = row }
    }

    /// Adopts a comment returned by a mutation (create, edit, resolve).
    public func issueDetailApply(_ comment: Comment) {
        upsertComment(comment)
    }

    /// Removes a deleted comment together with every reply hanging off it.
    public func issueDetailRemoveSubtree(_ commentID: String) {
        var doomed: Set<String> = [commentID]
        var grew = true
        while grew {
            grew = false
            for e in entries where e.kind == .comment && !doomed.contains(e.id) {
                if let p = e.parentID, doomed.contains(p) {
                    doomed.insert(e.id)
                    grew = true
                }
            }
        }
        entries.removeAll { doomed.contains($0.id) }
    }

    /// Local edit of one row (optimistic reactions); returns the previous row.
    @discardableResult
    public func issueDetailPatch(_ commentID: String, _ transform: (inout TimelineEntry) -> Void) -> TimelineEntry? {
        guard let i = entries.firstIndex(where: { $0.id == commentID }) else { return nil }
        let before = entries[i]
        var row = before
        transform(&row)
        if row != before { entries[i] = row }
        return before
    }

    public func issueDetailRestore(_ row: TimelineEntry) {
        guard let i = entries.firstIndex(where: { $0.id == row.id }) else { return }
        entries[i] = row
    }
}

/// An issue response read twice: the hot row model for the shared store and
/// the full upstream shape (properties, metadata, stage, source context).
public struct IssueDetailFetched: Sendable {
    public var issue: Issue
    public var record: IssueRecord

    init(_ v: JSONValue) throws {
        let data = try JSONCoders.encoder.encode(v)
        issue = try JSONCoders.decoder.decode(Issue.self, from: data)
        record = try JSONCoders.decoder.decode(IssueRecord.self, from: data)
    }
}

/// A saved comment plus the mentions the server did not clearly trigger.
public struct IssueDetailPosted: Sendable {
    public var comment: Comment
    public var unhandled: [CommentTriggerOutcome]

    static let handled: Set<String> = ["queued", "coalesced", "deferred", "steered"]

    init(_ v: JSONValue) throws {
        let data = try JSONCoders.encoder.encode(v)
        comment = try JSONCoders.decoder.decode(Comment.self, from: data)
        let outcomes = (v["trigger_outcomes"]?.arrayValue ?? []).compactMap { raw -> CommentTriggerOutcome? in
            guard let d = try? JSONCoders.encoder.encode(raw) else { return nil }
            return try? JSONCoders.decoder.decode(CommentTriggerOutcome.self, from: d)
        }
        unhandled = outcomes.filter { !Self.handled.contains($0.status) }
    }

    /// Upstream warnUnhandledTriggers copy, or nil when every mention fired.
    public var warning: String? {
        guard !unhandled.isEmpty else { return nil }
        if unhandled.count == 1, let o = unhandled.first,
           let name = IssueDetailPosted.mentionLabels(comment.content)["\(o.targetType):\(o.targetId)"] {
            return tr("issues", "comment.posted_partial_trigger_named", ["name": name, "reason": Self.shortReason(o.reasonCode)])
        }
        return tr("issues", "comment.posted_partial_trigger", ["count": unhandled.count])
    }

    public static func shortReason(_ code: String) -> String {
        let known: Set<String> = ["invocation_not_allowed", "target_unavailable", "runtime_offline", "runtime_unusable",
                                  "runtime_profile_missing", "agent_runtime_required", "runtime_access_denied"]
        return tr("issues", "comment.trigger_blocked_short_" + (known.contains(code) ? code : "generic"))
    }

    public static func mentionLabels(_ content: String) -> [String: String] {
        guard let re = try? NSRegularExpression(pattern: #"\[@?(.+?)\]\(mention://(member|agent|squad|issue|all)/([0-9a-fA-F-]+|all)\)"#) else { return [:] }
        var out: [String: String] = [:]
        let ns = content as NSString
        for m in re.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            out["\(ns.substring(with: m.range(at: 2))):\(ns.substring(with: m.range(at: 3)))"] = ns.substring(with: m.range(at: 1))
        }
        return out
    }
}

extension APIClient {
    /// `listTasksByIssue` with the full task shape (trigger, coverage,
    /// usage, workdir), which the run views need.
    public nonisolated func issueDetailListTasks(issueId: String) async throws -> [AgentTaskRecord] {
        try await list("/api/issues/\(issueId.pathEscaped)/task-runs")
    }

    /// `listChildIssues` keeping each child's full record (stage, properties).
    public nonisolated func issueDetailListChildren(_ id: String) async throws -> [IssueDetailFetched] {
        let v: JSONValue = try await call(.get, "/api/issues/\(id.pathEscaped)/children")
        return (v["issues"]?.arrayValue ?? []).compactMap { try? IssueDetailFetched($0) }
    }

    public nonisolated func issueDetailFetch(_ idOrIdentifier: String) async throws -> IssueDetailFetched {
        try IssueDetailFetched(try await call(.get, "/api/issues/\(idOrIdentifier.pathEscaped)", as: JSONValue.self))
    }

    /// `PUT /api/issues/:id` with an explicit body, so a field can be cleared
    /// with JSON null (start date, project, parent, stage).
    public nonisolated func issueDetailUpdate(_ id: String, fields: [String: JSONValue]) async throws -> IssueDetailFetched {
        try IssueDetailFetched(try await call(.put, "/api/issues/\(id.pathEscaped)", body: JSONValue.object(fields), as: JSONValue.self))
    }

    public nonisolated func issueDetailCreateComment(issueId: String, content: String, parentId: String?, attachmentIds: [String],
                                                     suppressAgentIds: [String], steerTaskIds: [String]) async throws -> IssueDetailPosted {
        var body: [String: JSONValue] = ["content": JSONValue(content), "type": "comment"]
        if let parentId { body["parent_id"] = JSONValue(parentId) }
        if !attachmentIds.isEmpty { body["attachment_ids"] = JSONValue(attachmentIds) }
        if !suppressAgentIds.isEmpty { body["suppress_agent_ids"] = JSONValue(suppressAgentIds) }
        if !steerTaskIds.isEmpty { body["steer_task_ids"] = JSONValue(steerTaskIds) }
        return try IssueDetailPosted(try await call(.post, "/api/issues/\(issueId)/comments", body: JSONValue.object(body), as: JSONValue.self))
    }

    /// `runQuickAction` keeping the comment's trigger outcome.
    public nonisolated func issueDetailRunQuickAction(issueId: String, quickActionId: String) async throws -> (comment: Comment, outcome: CommentTriggerOutcome?) {
        let v: JSONValue = try await call(.post, "/api/issues/\(issueId)/quick-actions/\(quickActionId)/run")
        let comment = try JSONCoders.decoder.decode(Comment.self, from: JSONCoders.encoder.encode(v))
        let outcome = v["trigger_outcomes"]?.arrayValue?.first.flatMap { raw -> CommentTriggerOutcome? in
            guard let d = try? JSONCoders.encoder.encode(raw) else { return nil }
            return try? JSONCoders.decoder.decode(CommentTriggerOutcome.self, from: d)
        }
        return (comment, outcome)
    }

    public nonisolated func issueDetailUpdateComment(_ commentId: String, content: String, attachmentIds: [String],
                                                     suppressAgentIds: [String], contentBase: String?) async throws -> IssueDetailPosted {
        var body: [String: JSONValue] = ["content": JSONValue(content), "attachment_ids": JSONValue(attachmentIds)]
        if !suppressAgentIds.isEmpty { body["suppress_agent_ids"] = JSONValue(suppressAgentIds) }
        if let contentBase { body["content_base"] = JSONValue(contentBase) }
        return try IssueDetailPosted(try await call(.put, "/api/comments/\(commentId)", body: JSONValue.object(body), as: JSONValue.self))
    }
}
