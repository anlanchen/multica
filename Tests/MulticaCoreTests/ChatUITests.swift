import XCTest
@testable import MulticaCore

final class ChatUIPendingTests: XCTestCase {
    func q(_ id: String, _ at: String = "2026-10-01T00:00:00Z", message: String? = nil) -> ChatQueuedTask {
        ChatQueuedTask(taskId: id, status: "queued", createdAt: at, messageId: message, content: message.map { "c-\($0)" })
    }

    func testIdleSendBecomesHeadAndFollowUpQueues() {
        var p = ChatUIPending.enqueue(nil, q("t1"))
        XCTAssertEqual(p.taskId, "t1")
        XCTAssertEqual(p.status, "queued")
        p.status = "running"
        p = ChatUIPending.enqueue(p, q("t2", "2026-10-01T00:00:02Z", message: "m2"))
        XCTAssertEqual(p.taskId, "t1")
        XCTAssertEqual(p.queuedTasks?.map(\.taskId), ["t2"])
        p = ChatUIPending.enqueue(p, q("t3", "2026-10-01T00:00:01Z"))
        XCTAssertEqual(p.queuedTasks?.map(\.taskId), ["t3", "t2"], "queue is ordered by creation time")
    }

    func testQueuedSendBeforeHeadLoadsAccumulatesWithoutHead() {
        var p = ChatUIPending.enqueue(ChatPendingTask(), q("t2"), queued: true)
        p = ChatUIPending.enqueue(p, q("t3", "2026-10-01T00:00:03Z"), queued: true)
        XCTAssertNil(p.taskId)
        XCTAssertEqual(p.queuedTasks?.map(\.taskId), ["t2", "t3"])
    }

    func testSameTaskKeepsAdvancedStatus() {
        let p = ChatUIPending.enqueue(ChatPendingTask(taskId: "t1", status: "running", createdAt: "x"), q("t1"))
        XCTAssertEqual(p.status, "running")
        XCTAssertEqual(p.createdAt, "x")
    }

    func testPromoteHeadAndWaitReasonOnlyWhileWaiting() {
        var p = ChatPendingTask(taskId: "t1", status: "queued")
        p = ChatUIPending.promote(p, taskID: "t1", status: "waiting_local_directory", waitReason: "repo held by abc")
        XCTAssertEqual(p.waitReason, "repo held by abc")
        p = ChatUIPending.promote(p, taskID: "t1", status: "running")
        XCTAssertNil(p.waitReason)
        XCTAssertEqual(p.status, "running")
    }

    func testPromoteQueuedTaskRequeuesQueuedHead() {
        let p = ChatPendingTask(taskId: "t1", status: "queued", createdAt: "a", supportsQueue: true, queuedTasks: [q("t2")])
        let next = ChatUIPending.promote(p, taskID: "t2", status: "running")
        XCTAssertEqual(next.taskId, "t2")
        XCTAssertEqual(next.status, "running")
        XCTAssertEqual(next.supportsQueue, true)
        XCTAssertEqual(next.queuedTasks?.map(\.taskId), ["t1"])
    }

    func testLateLifecycleForUnknownTaskIsIgnored() {
        XCTAssertEqual(ChatUIPending.promote(ChatPendingTask(), taskID: "zz", status: "running"), ChatPendingTask())
        let p = ChatPendingTask(taskId: "t1", status: "running")
        XCTAssertEqual(ChatUIPending.promote(p, taskID: "zz", status: "running"), p)
    }

    func testRemoveHeadPromotesNextQueued() {
        let p = ChatPendingTask(taskId: "t1", status: "running", supportsQueue: true, queuedTasks: [q("t2"), q("t3", "2026-10-01T00:00:05Z")])
        let next = ChatUIPending.remove(p, taskID: "t1")
        XCTAssertEqual(next.taskId, "t2")
        XCTAssertEqual(next.queuedTasks?.map(\.taskId), ["t3"])
        XCTAssertEqual(ChatUIPending.remove(ChatPendingTask(taskId: "t1"), taskID: "t1"), ChatPendingTask())
        XCTAssertEqual(ChatUIPending.remove(p, taskID: "t3").queuedTasks?.map(\.taskId), ["t2"])
    }

    func testPrioritizeMovesTaskToFront() {
        let p = ChatPendingTask(taskId: "t1", queuedTasks: [q("t2"), q("t3")])
        XCTAssertEqual(ChatUIPending.prioritize(p, taskID: "t3").queuedTasks?.map(\.taskId), ["t3", "t2"])
    }

    func testHideQueuedKeepsMessagesWithoutTask() {
        let messages = [
            ChatMessage(id: "m1", role: "user", content: "a", taskId: nil),
            ChatMessage(id: "m2", role: "user", content: "b", taskId: "t2"),
            ChatMessage(id: "m3", role: "user", content: "c", taskId: "t3"),
        ]
        let p = ChatPendingTask(taskId: "t1", queuedTasks: [q("t2", message: "m2")])
        XCTAssertEqual(ChatUIPending.hideQueued(messages, pending: p).map(\.id), ["m1", "m3"])
    }
}

final class ChatUIMessagesTests: XCTestCase {
    func testMergeKeepsHeldFieldsAndFillsGaps() {
        let sent = ChatMessage(id: "m1", role: "user", content: "hi", taskId: "t1", createdAt: "2026-10-01T00:00:01Z", attachments: [Attachment(id: "a1")])
        let echo = ChatMessage(id: "m1", role: "user", content: "hi", taskId: "t1", createdAt: "2026-10-01T00:00:01Z")
        XCTAssertEqual(ChatUIMessages.upsert([sent], echo), [sent], "the echo without attachments never downgrades the send row")
        let reply = ChatMessage(id: "m2", role: "assistant", content: "ok", taskId: "t1")
        let supplement = ChatMessage(id: "m2", role: "assistant", content: "ok", quickActions: [ChatQuickAction(label: "Next", prompt: "next")])
        XCTAssertEqual(ChatUIMessages.upsert([reply], supplement)[0].quickActions?.count, 1)
        XCTAssertEqual(ChatUIMessages.upsert([reply], ChatMessage(id: "m3")).map(\.id), ["m2", "m3"])
    }

    func testReconcileKeepsOlderPagesAndRowsNewerThanSnapshot() {
        let held = [
            ChatMessage(id: "old", createdAt: "2026-10-01T00:00:00Z"),
            ChatMessage(id: "deleted", createdAt: "2026-10-01T00:00:02Z"),
            ChatMessage(id: "a", createdAt: "2026-10-01T00:00:03Z"),
            ChatMessage(id: "late", createdAt: "2026-10-01T00:00:09Z"),
        ]
        let page = ChatMessagesPage(messages: [
            ChatMessage(id: "w", createdAt: "2026-10-01T00:00:01Z"),
            ChatMessage(id: "a", content: "server", createdAt: "2026-10-01T00:00:03Z"),
        ], limit: 2, hasMore: true)
        let merged = ChatUIMessages.reconcile(held: held, page: page)
        XCTAssertEqual(merged.map(\.id), ["old", "w", "a", "late"])
        XCTAssertEqual(merged[2].content, "server")
    }

    func testPrependSkipsDuplicates() {
        let list = [ChatMessage(id: "b"), ChatMessage(id: "c")]
        XCTAssertEqual(ChatUIMessages.prepend(list, older: [ChatMessage(id: "a"), ChatMessage(id: "b")]).map(\.id), ["a", "b", "c"])
    }
}

final class ChatUITimelineTests: XCTestCase {
    func m(_ seq: Int, _ kind: TaskMessageKind, _ content: String = "", tool: String? = nil) -> TaskMessage {
        TaskMessage(taskID: "t", seq: seq, kind: kind, tool: tool, content: content)
    }

    func testCoalescesTextAndThinkingButNotTools() {
        let items = ChatUITimelineBuilder.build([
            m(1, .text, "Hel"), m(2, .text, "lo"), m(3, .thinking, "a"), m(4, .thinking, "b"),
            m(5, .toolUse, tool: "bash"), m(6, .toolResult, tool: "bash"), m(7, .text, "done"),
        ])
        XCTAssertEqual(items.map(\.kind), [.text, .thinking, .toolUse, .toolResult, .text])
        XCTAssertEqual(items[0].content, "Hello")
        XCTAssertEqual(items[0].seq, 1)
        XCTAssertEqual(items[1].content, "ab")
    }

    func testIncrementalSyncMatchesFullBuild() {
        let all = (1...40).map { i in m(i, i % 7 == 0 ? .toolUse : (i % 5 == 0 ? .thinking : .text), "x\(i)", tool: "read") }
        var b = ChatUITimelineBuilder()
        var upto = 0
        while upto < all.count {
            upto = min(all.count, upto + Int.random(in: 1...6))
            b.sync(Array(all[..<upto]))
        }
        XCTAssertEqual(b.items, ChatUITimelineBuilder.build(all))
    }

    func testOutOfOrderInsertOrNewGenerationRebuilds() {
        var b = ChatUITimelineBuilder()
        b.sync([m(1, .text, "a"), m(3, .text, "c")])
        b.sync([m(1, .text, "a"), m(2, .toolUse, tool: "x"), m(3, .text, "c")])
        XCTAssertEqual(b.items.map(\.kind), [.text, .toolUse, .text])
        b.sync([m(1, .text, "A"), m(2, .toolUse, tool: "x"), m(3, .text, "c")], generation: 1)
        XCTAssertEqual(b.items.first?.content, "A")
    }

    func testSplitRegions() {
        let items = ChatUITimelineBuilder.build([m(1, .text, "pre"), m(2, .toolUse, tool: "a"), m(3, .text, "mid"), m(4, .toolResult), m(5, .text, "fin")])
        let s = ChatUITimeline.split(items)
        XCTAssertEqual(s.preface.map(\.content), ["pre"])
        XCTAssertEqual(s.middle.map(\.seq), [2, 3, 4])
        XCTAssertEqual(s.final.map(\.content), ["fin"])
        XCTAssertEqual(ChatUITimeline.split([items[0]]).final.count, 1)
    }

    func testStripsTrailingQuickActionsFenceOnly() {
        XCTAssertEqual(ChatUITimeline.stripQuickActionsProtocol("Answer\n\n```quick-actions\n[{\"label\""), "Answer")
        XCTAssertEqual(ChatUITimeline.stripQuickActionsProtocol("Answer\n```quick-actions\n[]\n```\n"), "Answer")
        let example = "Like this:\n```quick-actions\n[]\n```\nThen more prose."
        XCTAssertEqual(ChatUITimeline.stripQuickActionsProtocol(example), example)
        XCTAssertEqual(ChatUITimeline.stripQuickActionsProtocol("plain"), "plain")
    }

    func testCopyTextPrefersCanonicalAnswer() {
        let items = ChatUITimelineBuilder.build([m(1, .text, "pre"), m(2, .toolUse), m(3, .text, "fin")])
        XCTAssertEqual(ChatUITimeline.copyText(ChatMessage(content: "final"), items: items), "final")
        XCTAssertEqual(ChatUITimeline.copyText(ChatMessage(content: "  "), items: items), "pre\n\nfin")
    }
}

final class ChatUIRulesTests: XCTestCase {
    func agent(owner: String? = "u2", mode: String = "public_to", targets: [AgentInvocationTarget] = [AgentInvocationTarget(targetType: "workspace")], runtime: String = "r1", bound: Bool? = nil) -> AgentRecord {
        AgentRecord(id: "a1", runtimeId: runtime, runtimeBound: bound, name: "A", permissionMode: mode, invocationTargets: targets, ownerId: owner)
    }

    func testInvokeGate() {
        XCTAssertTrue(ChatUIAgents.canInvoke(agent(owner: "u1", mode: "private"), userID: "u1", role: nil))
        XCTAssertFalse(ChatUIAgents.canInvoke(agent(mode: "private"), userID: "u1", role: "owner"), "admins no longer bypass private agents")
        XCTAssertTrue(ChatUIAgents.canInvoke(agent(), userID: "u1", role: "member"))
        XCTAssertFalse(ChatUIAgents.canInvoke(agent(), userID: "u1", role: nil))
        XCTAssertTrue(ChatUIAgents.canInvoke(agent(targets: [AgentInvocationTarget(targetType: "member", targetId: "u1")]), userID: "u1", role: nil))
        XCTAssertFalse(ChatUIAgents.canInvoke(agent(targets: [AgentInvocationTarget(targetType: "team", targetId: "x")]), userID: "u1", role: "admin"))
        XCTAssertFalse(ChatUIAgents.canInvoke(agent(), userID: nil, role: "member"))
    }

    func testRuntimeBindingAndAvailability() {
        XCTAssertTrue(ChatUIAgents.isRuntimeBound(agent()))
        XCTAssertFalse(ChatUIAgents.isRuntimeBound(agent(runtime: " ")))
        XCTAssertFalse(ChatUIAgents.isRuntimeBound(agent(bound: false)))
        let now = Date()
        let online = RuntimeDeviceRecord(id: "r1", status: "online")
        let lost = RuntimeDeviceRecord(id: "r1", status: "offline", lastSeenAt: ChatUIStore.isoNow())
        let gone = RuntimeDeviceRecord(id: "r1", status: "offline", lastSeenAt: "2020-01-01T00:00:00Z")
        XCTAssertEqual(ChatUIAgents.availability(agent(), runtime: online, now: now), "online")
        XCTAssertEqual(ChatUIAgents.availability(agent(), runtime: lost, now: now), "unstable")
        XCTAssertEqual(ChatUIAgents.availability(agent(), runtime: gone, now: now), "offline")
        XCTAssertEqual(ChatUIAgents.availability(agent(), runtime: nil, now: now), "offline")
    }

    func testProjectContextVersionGate() {
        XCTAssertTrue(ChatUIAgents.projectContextSupported(cliVersion: "0.4.10"))
        XCTAssertTrue(ChatUIAgents.projectContextSupported(cliVersion: "v0.5.0"))
        XCTAssertFalse(ChatUIAgents.projectContextSupported(cliVersion: "0.4.9"))
        XCTAssertTrue(ChatUIAgents.projectContextSupported(cliVersion: "v0.4.8-37-g5d0275d68"))
        XCTAssertFalse(ChatUIAgents.projectContextSupported(cliVersion: "garbage"))
        XCTAssertFalse(ChatUIAgents.projectContextSupported(cliVersion: nil))
    }

    func testFailureKeyDegradesToFamily() {
        let known: Set<String> = ["agent_error", "timeout", "agent_error.provider_network"]
        XCTAssertEqual(ChatUIAgents.failureKey("agent_error.provider_network", known: known), "agent_error.provider_network")
        XCTAssertEqual(ChatUIAgents.failureKey("agent_error.something_new", known: known), "agent_error")
        XCTAssertNil(ChatUIAgents.failureKey("brand_new", known: known))
    }

    func testStagePicking() {
        XCTAssertEqual(ChatUIStage.pick(status: "deferred", latest: nil, availability: "offline").key, .retrying)
        XCTAssertEqual(ChatUIStage.pick(status: "queued", latest: nil, availability: "offline"), ChatUIStage(key: .offline, isStatic: true))
        XCTAssertEqual(ChatUIStage.pick(status: "dispatched", latest: nil, availability: "unstable").key, .reconnecting)
        XCTAssertTrue(ChatUIStage.pick(status: "waiting_local_directory", latest: nil, availability: nil).needsWaitReason)
        XCTAssertEqual(ChatUIStage.pick(status: "running", latest: (.text, nil), availability: nil).key, .typing)
        XCTAssertEqual(ChatUIStage.pick(status: "running", latest: (.toolUse, "Bash"), availability: nil).tool, .runningCommand)
        XCTAssertEqual(ChatUIStage.pick(status: "running", latest: (.toolUse, "mcp_x"), availability: nil).tool, .fallback)
        XCTAssertEqual(ChatUIStage.effectiveStatus("queued", hasMessages: true), "running")
        XCTAssertEqual(ChatUIStage.effectiveStatus("deferred", hasMessages: true), "deferred")
    }

    func testTextHelpers() {
        XCTAssertEqual(ChatUIText.deriveTitle("\n  # Fix the **login** bug in [auth](http://x)\nmore"), "Fix the login bug in auth")
        XCTAssertEqual(ChatUIText.deriveTitle(String(repeating: "a", count: 40)), String(repeating: "a", count: 29) + "…")
        XCTAssertEqual(ChatUIText.preview("**Hi**\n\n```swift\nlet x\n```\nthere"), "Hi there")
        XCTAssertEqual(ChatUIText.elapsed(seconds: 38), "38s")
        XCTAssertEqual(ChatUIText.elapsed(seconds: 180), "3m")
        XCTAssertEqual(ChatUIText.elapsed(ms: 61_400), "1m 1s")
        XCTAssertTrue(ChatUIText.isTaskID("11111111-2222-3333-4444-555555555555"))
        XCTAssertFalse(ChatUIText.isTaskID("optimistic-1"))
        XCTAssertEqual(ChatUIText.toolSummary(.object(["command": .string("bash -lc 'ls -la'")])), "ls -la")
        XCTAssertEqual(ChatUIText.toolSummary(.object(["file_path": .string("/Users/a/src/app/main.swift")])), ".../app/main.swift")
        XCTAssertEqual(ChatUIText.toolSummary(.object(["query": .object([:]), "pattern": .string("TODO")])), "TODO")
        XCTAssertEqual(ChatUIText.toolSummary(nil), "")
        let inline = Attachment(id: "a1", markdownUrl: "/api/attachments/a1/file")
        let card = Attachment(id: "a2", markdownUrl: "/api/attachments/a2/file")
        XCTAssertEqual(ChatUIText.standaloneAttachments([inline, card, card], content: "![x](/api/attachments/a1/file)").map(\.id), ["a2"])
    }

    func testSessionOrderingAndUnread() {
        let a = ChatSession(id: "a", status: "active", hasUnread: true, unreadCount: 2, updatedAt: "2026-10-01T00:00:01Z")
        let b = ChatSession(id: "b", status: "active", lastMessage: ChatLastMessage(createdAt: "2026-10-01T00:00:09Z"), updatedAt: "2026-10-01T00:00:00Z")
        let c = ChatSession(id: "c", status: "archived", hasUnread: true, unreadCount: 3, pinned: true, updatedAt: "2026-09-01T00:00:00Z")
        XCTAssertEqual(ChatUISessions.sorted([a, b, c]).map(\.id), ["c", "b", "a"])
        XCTAssertEqual(ChatUISessions.unreadSessionCount([a, b, c]), 1)
        XCTAssertEqual(ChatUISessions.unreadMessageCount([a, b, c], excluding: "c"), 2)
        XCTAssertEqual(ChatUISessions.nextAfterArchive("b", history: [a, b])?.id, "a")
        XCTAssertNil(ChatUISessions.nextAfterArchive("b", history: [b]))
        XCTAssertEqual(ChatUISessions.nextAfterArchive("b", history: [b, a])?.id, "a")
        XCTAssertEqual(ChatUISessions.nextAfterArchive("a", history: [b, a])?.id, "b")
    }

    func testProjectChangePlan() {
        let s = ChatSession(id: "s1", agentId: "a1")
        XCTAssertEqual(ChatUIProjectChange.plan(target: "p1", activeSessionID: nil, current: nil), .setDraftProject("p1"))
        XCTAssertEqual(ChatUIProjectChange.plan(target: "p1", activeSessionID: "s1", current: nil), .awaitSession)
        XCTAssertEqual(ChatUIProjectChange.plan(target: nil, activeSessionID: "s1", current: s), .detachCurrent(sessionID: "s1"))
        XCTAssertEqual(ChatUIProjectChange.plan(target: "p2", activeSessionID: "s1", current: s), .startFreshChat(agentID: "a1", projectID: "p2"))
    }
}

final class ChatUIStoreTests: XCTestCase {
    static let task = "11111111-2222-3333-4444-555555555555"

    @MainActor func makeStore() -> (ChatUIStore, WorkspaceSession, FakeTransport) {
        let t = FakeTransport()
        t.on("GET", "/api/agents", json: #"[{"id":"a1","workspace_id":"ws1","runtime_id":"r1","name":"Claude","permission_mode":"public_to","invocation_targets":[{"target_type":"workspace"}],"owner_id":"u1","created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z"}]"#)
        t.on("GET", "/api/chat/sessions", json: "[]")
        t.on("POST", "/api/chat/sessions", json: #"{"id":"s1","workspace_id":"ws1","agent_id":"a1","creator_id":"u1","title":"hello","status":"active","has_unread":false,"created_at":"2026-10-01T00:00:00Z","updated_at":"2026-10-01T00:00:00Z"}"#)
        t.on("POST", "/api/chat/sessions/s1/messages", json: #"{"message_id":"m1","task_id":"\#(Self.task)","created_at":"2026-10-01T00:00:01Z","supports_queue":true}"#)
        t.on("GET", "/api/chat/sessions/s1/messages/page", json: #"{"messages":[{"id":"m1","chat_session_id":"s1","role":"user","content":"hello","task_id":"\#(Self.task)","created_at":"2026-10-01T00:00:01Z"}],"limit":50,"has_more":false}"#)
        t.on("GET", "/api/chat/sessions/s1/pending-task", json: #"{"task_id":"\#(Self.task)","status":"queued","created_at":"2026-10-01T00:00:01Z","supports_queue":true}"#)
        t.on("GET", "/api/chat/sessions/s1/draft-restores", json: #"{"restores":[]}"#)
        let api = APIClient(config: .localDevelopment, transport: t, token: "tok")
        let rt = RealtimeClient(config: .localDevelopment, connector: FakeConnector()) { "tok" }
        let s = WorkspaceSession(workspace: Workspace(id: "ws1", name: "Acme", slug: "acme"), user: User(id: "u1", name: "Ada", email: "a@x"), api: api, realtime: rt)
        let store = ChatUIStore(session: s, storage: ChatUIMemoryStorage())
        return (store, s, t)
    }

    @MainActor func sendFirstMessage() async -> (ChatUIStore, WorkspaceSession, FakeTransport) {
        let (store, s, t) = makeStore()
        await s.agentRecords.load()
        await s.chatSessions.load()
        let resolved = await eventually { store.context.activeAgent?.id == "a1" }
        XCTAssertTrue(resolved)
        store.setDraft(ChatUIStore.draftNewSession, "hello")
        let accepted = await store.send("hello", attachmentIDs: [], attachments: [], draftKey: ChatUIStore.draftNewSession, surface: .page)
        XCTAssertTrue(accepted)
        return (store, s, t)
    }

    @MainActor func testSendCreatesSessionSeedsTranscriptAndClearsDraft() async {
        let (store, _, t) = await sendFirstMessage()
        XCTAssertEqual(store.activeSessionID, "s1")
        let c = store.conversation("s1")
        XCTAssertEqual(c.visibleMessages.map(\.id), ["m1"])
        XCTAssertEqual(c.pendingTaskID, Self.task)
        XCTAssertEqual(c.pending.supportsQueue, true)
        XCTAssertEqual(store.draft(ChatUIStore.draftNewSession), "")
        let body = t.requests.first { $0.method == "POST" && $0.path == "/api/chat/sessions" }?.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(body.contains(#""title":"hello""#))
    }

    @MainActor func testRealtimeLifecycleAndDoneSettleTheTurn() async {
        let (store, s, _) = await sendFirstMessage()
        store.view("s1")
        var running = TaskLifecycle(taskID: Self.task, agentID: "a1", issueID: "", status: .running)
        running.chatSessionID = "s1"
        s.apply(.taskLifecycle(running))
        XCTAssertEqual(store.conversation("s1").pending.status, "running")

        let done: JSONValue = .object([
            "chat_session_id": .string("s1"), "task_id": .string(Self.task), "message_id": .string("m2"),
            "content": .string("Hi Ada"), "elapsed_ms": .number(38000), "created_at": .string("2026-10-01T00:00:40Z"),
            "quick_actions_pending": .bool(true),
        ])
        s.apply(.resource(type: "chat:done", payload: done))
        let c = store.conversation("s1")
        XCTAssertEqual(c.visibleMessages.last?.content, "Hi Ada")
        XCTAssertEqual(c.visibleMessages.last?.elapsedMs, 38000)
        XCTAssertNil(c.pendingTaskID)
        XCTAssertEqual(c.quickActionsMarker?.messageID, "m2")

        s.apply(.resource(type: "chat:quick_actions", payload: .object([
            "chat_session_id": .string("s1"), "task_id": .string(Self.task), "message_id": .string("m2"),
            "quick_actions": .array([.object(["label": .string("More"), "prompt": .string("Tell me more")])]),
        ])))
        XCTAssertNil(c.quickActionsMarker)
        XCTAssertEqual(c.visibleMessages.last?.quickActions?.first?.label, "More")
        store.leave("s1")
    }

    @MainActor func testStopRestoresPromptOnlyIntoEmptyDraft() async {
        let (store, _, t) = await sendFirstMessage()
        t.on("POST", "/api/tasks/\(Self.task)/cancel", json: #"{"id":"\#(Self.task)","agent_id":"a1","runtime_id":"r1","issue_id":"","status":"cancelled","priority":0,"result":null,"created_at":"2026-10-01T00:00:01Z","cancelled_chat_message":{"chat_session_id":"s1","message_id":"m1","content":"hello","restore_to_input":true}}"#)
        store.attachSurface()
        store.conversation("s1").setPending(ChatPendingTask(taskId: Self.task, status: "running"))
        store.stop()
        let offered = await eventually { store.restoreRequest?.id == "m1" }
        XCTAssertTrue(offered)
        XCTAssertEqual(t.requests.last { $0.path.hasSuffix("/cancel") }?.header("X-Client-Capabilities"), "chat-draft-restore-v1")
        store.setDraft("s1", "typing something else")
        XCTAssertFalse(store.applyRestoreIfPossible(draftKey: "s1"), "work in progress is never overwritten")
        store.setDraft("s1", "")
        XCTAssertTrue(store.applyRestoreIfPossible(draftKey: "s1"))
        XCTAssertEqual(store.draft("s1"), "hello")
        XCTAssertNil(store.restoreRequest)
        store.detachSurface()
    }

    @MainActor func testSessionUpdatedEventPatchesRowAndArchiveZeroesUnread() async {
        let (store, s, t) = await sendFirstMessage()
        t.on("GET", "/api/chat/sessions", json: #"[{"id":"s2","agent_id":"a1","title":"New","status":"archived","has_unread":false,"unread_count":0,"updated_at":"2026-10-01T00:00:00Z"}]"#)
        s.chatSessions.upsert(ChatSession(id: "s2", agentId: "a1", title: "Old", status: "active", hasUnread: true, unreadCount: 4, updatedAt: "2026-10-01T00:00:00Z"))
        s.apply(.resource(type: "chat:session_updated", payload: .object(["chat_session_id": .string("s2"), "title": .string("New"), "status": .string("archived")])))
        let row = s.chatSessions.item("s2")
        XCTAssertEqual(row?.title, "New")
        XCTAssertEqual(row?.unreadCount, 0)
        let split = await eventually { store.archivedSessions.map(\.id) == ["s2"] }
        XCTAssertTrue(split)
    }
}
