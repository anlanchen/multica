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

extension APIClient {
    /// `listTasksByIssue` with the full task shape (trigger, coverage,
    /// usage, workdir), which the run views need.
    public nonisolated func issueDetailListTasks(issueId: String) async throws -> [AgentTaskRecord] {
        try await list("/api/issues/\(issueId.pathEscaped)/task-runs")
    }

    /// `PUT /api/issues/:id` with an explicit body, so a field can be cleared
    /// with JSON null (start date, project, parent, stage).
    public nonisolated func issueDetailUpdate(_ id: String, fields: [String: JSONValue]) async throws -> Issue {
        try await call(.put, "/api/issues/\(id.pathEscaped)", body: JSONValue.object(fields))
    }
}
