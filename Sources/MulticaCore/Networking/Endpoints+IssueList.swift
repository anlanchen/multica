import Foundation

// Issue list surface requests that need exact JSON bodies: explicit nulls
// (clearing assignee/project/dates), the move intent, `scope_variant` on view
// edits, and table rows decoded with their custom property bags.

extension APIClient {
    public nonisolated func issueListRows(_ request: IssueTableRowsRequest) async throws -> IssueListRowsPage {
        try await call(.post, "/api/issues/table/rows", body: JSONValue(encoding: request))
    }

    /// `PUT /api/issues/{id}` with a raw field bag (`null` clears a field).
    public nonisolated func issueListUpdate(_ id: String, fields: [String: JSONValue]) async throws -> Issue {
        try await call(.put, "/api/issues/\(id.pathEscaped)", body: JSONValue.object(fields))
    }

    /// Positional move (`before_id` / `after_id` anchors plus target fields).
    public nonisolated func issueListMove(_ id: String, fields: [String: JSONValue]) async throws -> Issue {
        try await call(.post, "/api/issues/\(id.pathEscaped)/move", body: JSONValue.object(fields))
    }

    public nonisolated func issueListBatchUpdate(_ ids: [String], updates: [String: JSONValue]) async throws -> Int {
        try await call(.post, "/api/issues/batch-update",
                       body: ["issue_ids": JSONValue(ids), "updates": JSONValue.object(updates)] as JSONValue,
                       as: CountResponse.self).value
    }

    public nonisolated func issueListCreateView(_ data: CreateIssueViewRequest) async throws -> IssueView? {
        let v: JSONValue = try await call(.post, "/api/issue-views", body: JSONValue(encoding: data))
        guard !v.isNull, let data = try? JSONCoders.encoder.encode(v) else { return nil }
        return try? JSONCoders.decoder.decode(IssueView.self, from: data)
    }

    /// `scopeVariant`: nil leaves it alone, `.some(nil)` clears it.
    public nonisolated func issueListUpdateView(
        _ id: String, name: String?, visibility: String?, scopeVariant: String??,
        query: [String: JSONValue]?, display: [String: JSONValue]?, expectedRevision: Int
    ) async throws -> IssueView? {
        var body: [String: JSONValue] = ["expected_revision": JSONValue(expectedRevision)]
        if let name { body["name"] = .string(name) }
        if let visibility { body["visibility"] = .string(visibility) }
        if let scopeVariant { body["scope_variant"] = JSONValue(scopeVariant) }
        if let query { body["query"] = .object(query) }
        if let display { body["display"] = .object(display) }
        let v: JSONValue = try await call(.patch, "/api/issue-views/\(id.pathEscaped)", body: JSONValue.object(body))
        guard !v.isNull, let data = try? JSONCoders.encoder.encode(v) else { return nil }
        return try? JSONCoders.decoder.decode(IssueView.self, from: data)
    }
}
