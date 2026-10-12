import XCTest
@testable import MulticaCore

final class APIClientTests: XCTestCase {
    func testSendsAuthWorkspaceAndClientHeaders() async throws {
        let t = FakeTransport()
        t.on("GET", "/api/me", json: #"{"id":"u1","name":"Ada","email":"a@x"}"#)
        let api = APIClient(config: .localDevelopment, transport: t, token: "tok")
        await api.setWorkspaceSlug("acme")
        let me = try await api.me()
        XCTAssertEqual(me.name, "Ada")
        let r = t.requests[0]
        XCTAssertEqual(r.header("Authorization"), "Bearer tok")
        XCTAssertEqual(r.header("X-Workspace-Slug"), "acme")
        XCTAssertEqual(r.header("X-Client-Platform"), "macos-native")
        XCTAssertNotNil(r.header("X-Request-ID"))
    }

    func testConcurrentIdenticalGETsShareOneRequest() async throws {
        let t = FakeTransport()
        t.on("GET", "/api/issues", json: #"{"issues":[],"total":0}"#)
        t.setDelay(.milliseconds(50))
        let api = APIClient(config: .localDevelopment, transport: t, token: "tok")
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<8 { g.addTask { _ = try await api.listIssues() } }
            try await g.waitForAll()
        }
        XCTAssertEqual(t.count("GET", "/api/issues"), 1)
        let m = await api.metrics
        XCTAssertEqual(m.deduplicated, 7)
    }

    func testUnauthorizedOnlyForCurrentCredential() async throws {
        let t = FakeTransport()
        t.on("GET", "/api/me", status: 401, json: #"{"error":"expired"}"#)
        let api = APIClient(config: .localDevelopment, transport: t, token: "old")
        let fired = Locked(0)
        await api.setUnauthorizedHandler { fired.withLock { $0 += 1 } }
        do {
            _ = try await api.me()
            XCTFail()
        } catch let e as APIError {
            XCTAssertEqual(e, APIError(status: 401, message: "expired"))
        }
        XCTAssertEqual(fired.current, 1)
        let token = await api.currentToken()
        XCTAssertNil(token)
    }
}

final class WorkspaceSessionTests: XCTestCase {
    @MainActor func makeSession() -> (WorkspaceSession, FakeTransport, FakeConnector) {
        let t = FakeTransport()
        t.on("GET", "/api/issue-statuses", json: #"{"statuses":[]}"#)
        t.on("GET", "/api/issues", json: #"{"issues":[\#(Fixtures.issueJSON(id: "i1", number: 1)),\#(Fixtures.issueJSON(id: "i2", number: 2, status: "in_progress"))],"total":2}"#)
        t.on("GET", "/api/workspaces/ws1/members", json: #"[{"id":"m1","user_id":"u1","name":"Ada","email":"a@x","role":"owner"}]"#)
        t.on("GET", "/api/agents", json: #"[{"id":"a1","name":"Claude","status":"idle"}]"#)
        t.on("GET", "/api/agent-task-snapshot", json: #"[{"id":"t1","agent_id":"a1","issue_id":"i2","status":"running"}]"#)
        t.on("GET", "/api/inbox/unread-summary", json: #"[{"workspace_id":"ws1","count":4}]"#)
        t.on("GET", "/api/runtimes", json: "[]")
        t.on("GET", "/api/issues/i2", json: Fixtures.issueJSON(id: "i2", number: 2, status: "in_progress"))
        t.on("GET", "/api/issues/i2/timeline", json: #"[{"type":"comment","id":"c1","actor_type":"member","actor_id":"u1","content":"first","created_at":"2026-09-01T00:00:01Z"}]"#)
        t.on("GET", "/api/issues/i2/task-runs", json: #"[{"id":"t1","agent_id":"a1","issue_id":"i2","status":"running","created_at":"2026-09-01T00:00:02Z"}]"#)
        t.on("GET", "/api/tasks/t1/messages", json: #"[{"task_id":"t1","issue_id":"i2","seq":1,"type":"text","content":"from REST"}]"#)
        t.on("POST", "/api/issues/i2/comments", json: #"{"id":"c2","issue_id":"i2","author_type":"member","author_id":"u1","content":"hi","type":"comment","reactions":[],"attachments":[],"created_at":"2026-09-01T00:00:05Z","updated_at":"2026-09-01T00:00:05Z","parent_id":null,"resolved_at":null,"resolved_by_type":null,"resolved_by_id":null}"#)

        let connector = FakeConnector()
        let api = APIClient(config: .localDevelopment, transport: t, token: "tok")
        let rt = RealtimeClient(config: .localDevelopment, connector: connector, batchWindow: .milliseconds(20)) { "tok" }
        let ws = Workspace(id: "ws1", name: "Acme", slug: "acme")
        let s = WorkspaceSession(workspace: ws, user: User(id: "u1", name: "Ada", email: "a@x"), api: api, realtime: rt)
        return (s, t, connector)
    }

    @MainActor func testBootstrapThenLiveUpdatesAndTranscript() async throws {
        let (s, t, connector) = makeSession()
        await s.start()
        XCTAssertEqual(s.issues.count, 2)
        XCTAssertEqual(s.issues.model("i2")?.activeRuns, 1)
        XCTAssertEqual(s.inbox.unread(in: "ws1"), 4)
        XCTAssertEqual(s.directory.name(type: "agent", id: "a1"), "Claude")
        // The badge comes from the summary; the full inbox is never fetched.
        XCTAssertEqual(t.count("GET", "/api/inbox"), 0)

        let opened = await eventually { connector.sockets.first?.sent.isEmpty == false }
        XCTAssertTrue(opened)
        let socket = connector.sockets[0]
        socket.push(#"{"type":"auth_ack"}"#)

        // Open the running issue: timeline, runs and transcript backfill load.
        let detail = s.openIssue("i2")
        let loaded = await eventually { detail.entries.count == 1 && detail.runs.count == 1 && !detail.transcript(for: "t1").steps.isEmpty }
        XCTAssertTrue(loaded)

        // Live frames for this issue merge into the transcript by seq; frames
        // for other runs are dropped before decode.
        socket.push(Fixtures.taskMessageFrame(task: "t1", issue: "i2", seq: 2, content: "live 2"))
        socket.push(Fixtures.taskMessageFrame(task: "t1", issue: "i2", seq: 1, content: "from REST"))
        socket.push(Fixtures.taskMessageFrame(task: "zz", issue: "i9", seq: 1))
        let merged = await eventually { detail.transcript(for: "t1").steps.map(\.id) == [1, 2] }
        XCTAssertTrue(merged)

        // A status change from another client moves the row.
        socket.push(#"{"type":"issue:updated","payload":{"issue":\#(Fixtures.issueJSON(id: "i1", number: 1, status: "done", revision: 2))}}"#)
        let moved = await eventually {
            s.issues.resectionIfNeeded()
            return s.issues.sections.first { $0.key == .done }?.items.map(\.id) == ["i1"]
        }
        XCTAssertTrue(moved)

        // Comments: pending, then replaced by the server row; the WebSocket
        // echo of the same comment does not duplicate it.
        await s.postComment(issueID: "i2", content: "hi")
        XCTAssertTrue(detail.pendingComments.isEmpty)
        socket.push(#"{"type":"comment:created","payload":{"comment":{"id":"c2","issue_id":"i2","author_type":"member","author_id":"u1","content":"hi","type":"comment","created_at":"2026-09-01T00:00:05Z"}}}"#)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(detail.entries.map(\.id), ["c1", "c2"])

        s.closeIssue("i2")
        await s.stop()
    }

    @MainActor func testCatalogLoadsOnceAndFollowsResourceEvents() async throws {
        let (s, t, connector) = makeSession()
        let project = #"{"id":"p1","workspace_id":"ws1","title":"Beta","description":null,"icon":null,"status":"planned","priority":"none","lead_type":null,"lead_id":null,"start_date":null,"due_date":null,"created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-01T00:00:00Z","issue_count":0,"done_count":0,"resource_count":0}"#
        t.on("GET", "/api/projects", json: #"{"projects":[\#(project)],"total":1}"#)
        await s.start()
        await s.projects.loadIfNeeded()
        await s.projects.loadIfNeeded()
        XCTAssertEqual(t.count("GET", "/api/projects"), 1)
        XCTAssertEqual(s.projects.items.map(\.title), ["Beta"])

        let opened = await eventually { connector.sockets.first?.sent.isEmpty == false }
        XCTAssertTrue(opened)
        let socket = connector.sockets[0]
        socket.push(#"{"type":"auth_ack"}"#)
        let alpha = project.replacingOccurrences(of: "\"p1\"", with: "\"p2\"").replacingOccurrences(of: "Beta", with: "Alpha")
        socket.push(#"{"type":"project:created","payload":{"project":\#(alpha)}}"#)
        let added = await eventually { s.projects.items.map(\.id) == ["p2", "p1"] }
        XCTAssertTrue(added, "created project is inserted in title order")
        socket.push(#"{"type":"project:deleted","payload":{"project_id":"p1"}}"#)
        let removed = await eventually { s.projects.items.map(\.id) == ["p2"] }
        XCTAssertTrue(removed)
        socket.push(#"{"type":"pull_request:updated","payload":{"issue_id":"i1"}}"#)
        let bumped = await eventually { s.revision("pull_request") == 1 }
        XCTAssertTrue(bumped)
        await s.stop()
    }

    @MainActor func testFailedCommentStaysVisibleForRetry() async throws {
        let (s, t, _) = makeSession()
        t.on("POST", "/api/issues/i2/comments", status: 500, json: #"{"error":"boom"}"#)
        await s.start()
        let detail = s.openIssue("i2")
        await s.postComment(issueID: "i2", content: "hello")
        XCTAssertEqual(detail.pendingComments.count, 1)
        XCTAssertEqual(detail.pendingComments[0].state, .failed("boom"))
        await s.stop()
    }

    @MainActor func testOptimisticUpdateRollsBackOnFailure() async throws {
        let (s, t, _) = makeSession()
        t.on("PUT", "/api/issues/i1", status: 403, json: #"{"error":"forbidden"}"#)
        await s.start()
        var r = UpdateIssueRequest()
        r.status = .done
        await s.updateIssue("i1", r)
        XCTAssertEqual(s.issues.model("i1")?.issue.status, .todo)
        XCTAssertEqual(s.lastError, "forbidden")
        await s.stop()
    }
}
