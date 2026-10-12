import XCTest
@testable import MulticaCore

final class FrameRouterTests: XCTestCase {
    func testDropsTaskMessagesNobodyWatches() {
        let interest = InterestRegistry()
        let router = FrameRouter(interest: interest)
        let frame = Fixtures.taskMessageFrame(task: "t1", issue: "i1", seq: 1)
        guard case .droppedTaskMessage = router.decode(Data(frame.utf8)) else { return XCTFail() }

        interest.retainTask("t1")
        guard case .taskMessage(let m) = router.decode(Data(frame.utf8)) else { return XCTFail() }
        XCTAssertEqual(m.seq, 1)
        XCTAssertEqual(m.content, "hello")
    }

    func testIssueInterestKeepsAllRunsOfThatIssue() {
        let interest = InterestRegistry()
        let router = FrameRouter(interest: interest)
        interest.retainIssue("i1")
        guard case .taskMessage = router.decode(Data(Fixtures.taskMessageFrame(task: "new-run", issue: "i1", seq: 1).utf8)) else {
            return XCTFail("a run that started after the issue opened must still be kept")
        }
        guard case .droppedTaskMessage = router.decode(Data(Fixtures.taskMessageFrame(task: "other", issue: "i2", seq: 1).utf8)) else {
            return XCTFail()
        }
    }

    func testDropsWithoutDecodingHugePayload() {
        let router = FrameRouter(interest: InterestRegistry())
        // An invalid `input` would fail a full decode; the drop path must not
        // look at it at all.
        let frame = #"{"type":"task:message","payload":{"task_id":"t","issue_id":"i","seq":1,"type":"tool_use","input":"\#(String(repeating: "A", count: 100_000))"}}"#
        guard case .droppedTaskMessage = router.decode(Data(frame.utf8)) else { return XCTFail() }
    }

    func testFastPathMatchesFullDecoder() {
        let interest = InterestRegistry()
        interest.retainTask("watched")
        // Go key order: fast path applies.
        let go = Fixtures.taskMessageFrame(task: "other", issue: "i1", seq: 1)
        XCTAssertNotNil(FastRouting.taskMessageKeys(Data(go.utf8)))
        XCTAssertEqual(FastRouting.taskMessageKeys(Data(go.utf8))?.taskID, "other")
        // Type-first order: fast path declines, full decoder still drops.
        let typeFirst = #"{"type":"task:message","payload":{"task_id":"other","issue_id":"i1","seq":1,"type":"text"}}"#
        XCTAssertNil(FastRouting.taskMessageKeys(Data(typeFirst.utf8)))
        let router = FrameRouter(interest: interest)
        guard case .droppedTaskMessage = router.decode(Data(typeFirst.utf8)) else { return XCTFail() }
        guard case .droppedTaskMessage = router.decode(Data(go.utf8)) else { return XCTFail() }
        guard case .taskMessage = router.decode(Data(Fixtures.taskMessageFrame(task: "watched", issue: "i1", seq: 2).utf8)) else { return XCTFail() }
    }

    func testFastPathNeverMisroutesOtherEvents() {
        // A nested "type":"task:message" is not the envelope type.
        let nested = #"{"actor_id":"","payload":{"task_id":"t","issue_id":"i","note":{"type":"task:message"}},"type":"task:queued"}"#
        XCTAssertNil(FastRouting.taskMessageKeys(Data(nested.utf8)))
        let trailingNested = #"{"type":"issue:updated","payload":{"type":"task:message"}}"#
        XCTAssertNil(FastRouting.taskMessageKeys(Data(trailingNested.utf8)))
        // issue_id after a nested value: cannot conclude, decline.
        let late = #"{"payload":{"task_id":"t","input":{"a":1},"issue_id":"i"},"type":"task:message"}"#
        XCTAssertNil(FastRouting.taskMessageKeys(Data(late.utf8)))
        // No issue_id at all, and the payload ended: conclusive.
        let chat = #"{"payload":{"task_id":"t","seq":1,"type":"text","content":"x"},"type":"task:message"}"#
        XCTAssertEqual(FastRouting.taskMessageKeys(Data(chat.utf8))?.taskID, "t")
        XCTAssertNil(FastRouting.taskMessageKeys(Data(chat.utf8))?.issueID)
        // Escaped ids are left to the real decoder.
        let escaped = #"{"payload":{"task_id":"t\u0031","issue_id":"i"},"type":"task:message"}"#
        XCTAssertNil(FastRouting.taskMessageKeys(Data(escaped.utf8)))
    }

    func testRoutesDomainEvents() {
        let router = FrameRouter(interest: InterestRegistry())
        let upd = #"{"type":"issue:updated","payload":{"issue":\#(Fixtures.issueJSON(id: "i1", number: 1, status: "done")),"status_changed":true}}"#
        guard case .event(.issueUpsert(let issue, let flags)) = router.decode(Data(upd.utf8)) else { return XCTFail() }
        XCTAssertEqual(issue.status, .done)
        XCTAssertTrue(flags.statusChanged)

        let del = #"{"type":"comment:deleted","payload":{"comment_id":"c1","issue_id":"i1"}}"#
        guard case .event(.commentDeleted(let c, let i)) = router.decode(Data(del.utf8)) else { return XCTFail() }
        XCTAssertEqual([c, i], ["c1", "i1"])

        let life = #"{"type":"task:dispatch","payload":{"task_id":"t","agent_id":"a","issue_id":"i","runtime_id":"r"}}"#
        guard case .event(.taskLifecycle(let l)) = router.decode(Data(life.utf8)) else { return XCTFail() }
        XCTAssertEqual(l.status, .dispatched)
    }

    func testControlAndUnknownFrames() {
        let router = FrameRouter(interest: InterestRegistry())
        guard case .control(.authAck) = router.decode(Data(#"{"type":"auth_ack"}"#.utf8)) else { return XCTFail() }
        guard case .control(.authError(let e)) = router.decode(Data(#"{"error":"invalid token"}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(e, "invalid token")
        guard case .ignored = router.decode(Data(#"{"type":"pin:created","payload":{}}"#.utf8)) else { return XCTFail() }
        guard case .ignored = router.decode(Data("not json".utf8)) else { return XCTFail() }
        guard case .ignored = router.decode(Data("[1,2]".utf8)) else { return XCTFail() }
    }
}

final class BatchingTests: XCTestCase {
    func testLeadingEdgeThenFixedWindow() {
        var b = FixedWindowBatcher<Int>(window: .milliseconds(100))
        let t0 = ContinuousClock.now
        guard case .flushNow([1]) = b.offer(1, now: t0) else { return XCTFail("leading edge must flush immediately") }
        guard case .held(let deadline) = b.offer(2, now: t0 + .milliseconds(10)) else { return XCTFail() }
        XCTAssertEqual(deadline, t0 + .milliseconds(100))
        // A later arrival does not extend the window.
        guard case .held(let d2) = b.offer(3, now: t0 + .milliseconds(90)) else { return XCTFail() }
        XCTAssertEqual(d2, deadline)

        let (batch, next) = b.windowElapsed(now: t0 + .milliseconds(100))
        XCTAssertEqual(batch, [2, 3])
        XCTAssertEqual(next, t0 + .milliseconds(200))

        // Window that elapses empty closes; the next offer is a leading edge.
        let (empty, none) = b.windowElapsed(now: t0 + .milliseconds(200))
        XCTAssertEqual(empty, [])
        XCTAssertNil(none)
        guard case .flushNow([4]) = b.offer(4, now: t0 + .milliseconds(250)) else { return XCTFail() }
    }

    func testBackoffGrowsAndCaps() {
        var b = Backoff()
        XCTAssertEqual(b.nextDelay(random: 0), 1)
        XCTAssertEqual(b.nextDelay(random: 0), 2)
        XCTAssertEqual(b.nextDelay(random: 0), 4)
        for _ in 0..<10 { _ = b.nextDelay(random: 0) }
        XCTAssertEqual(b.nextDelay(random: 1), 30)
        b.reset()
        XCTAssertEqual(b.nextDelay(random: -1), 0.8, accuracy: 1e-9)
    }
}

/// Collects a client's events on a background task so tests can wait for
/// them with a timeout instead of blocking on the stream.
final class EventRecorder: @unchecked Sendable {
    private let events = Locked<[RealtimeEvent]>([])
    private var task: Task<Void, Never>?

    init(_ client: RealtimeClient) {
        let stream = client.events
        task = Task { [events] in
            for await e in stream { events.withLock { $0.append(e) } }
        }
    }

    deinit { task?.cancel() }

    var all: [RealtimeEvent] { events.current }

    func connectedCount(recovered: Bool) -> Int {
        all.filter { if case .connection(.connected(let r)) = $0 { return r == recovered }; return false }.count
    }

    var taskMessageBatches: [[TaskMessage]] {
        all.compactMap { if case .taskMessages(let b) = $0 { return b }; return nil }
    }

    var deletedIssues: [String] {
        all.compactMap { if case .issueDeleted(let id) = $0 { return id }; return nil }
    }
}

final class RealtimeClientTests: XCTestCase {
    func makeClient(_ connector: FakeConnector) -> RealtimeClient {
        RealtimeClient(config: .localDevelopment, connector: connector, batchWindow: .milliseconds(50),
                       pingInterval: .seconds(60)) { "jwt-token" }
    }

    /// Starts the client and completes the token handshake on socket `index`.
    func connect(_ client: RealtimeClient, _ connector: FakeConnector, _ recorder: EventRecorder) async throws {
        await client.start(workspaceSlug: "acme")
        let opened = await eventually { connector.sockets.first?.sent.isEmpty == false }
        XCTAssertTrue(opened)
        connector.sockets[0].push(#"{"type":"auth_ack"}"#)
        let connected = await eventually { recorder.connectedCount(recovered: false) == 1 }
        XCTAssertTrue(connected)
    }

    func testHandshakeAuthFirstAndTokenNotInURL() async throws {
        let connector = FakeConnector()
        let client = makeClient(connector)
        await client.start(workspaceSlug: "acme")
        let connected = await eventually { connector.sockets.first?.sent.isEmpty == false }
        XCTAssertTrue(connected)
        let socket = connector.sockets[0]
        XCTAssertEqual(socket.sent.first, #"{"payload":{"token":"jwt-token"},"type":"auth"}"#)
        let url = connector.urls[0].absoluteString
        XCTAssertTrue(url.hasPrefix("ws://localhost:8080/ws?workspace_slug=acme"))
        XCTAssertFalse(url.contains("jwt-token"))
        await client.stop()
    }

    func testBatchesTaskMessagesAndRoutesEvents() async throws {
        let connector = FakeConnector()
        let client = makeClient(connector)
        let recorder = EventRecorder(client)
        try await connect(client, connector, recorder)
        let socket = connector.sockets[0]

        await client.watchTask("t1")
        XCTAssertTrue(socket.sent.contains(#"{"payload":{"id":"t1","scope":"task"},"type":"subscribe"}"#))

        for seq in 1...5 { socket.push(Fixtures.taskMessageFrame(task: "t1", issue: "i1", seq: seq)) }
        socket.push(Fixtures.taskMessageFrame(task: "unwatched", issue: "i9", seq: 1))
        socket.push(#"{"type":"issue:deleted","payload":{"issue_id":"i7"}}"#)

        let delivered = await eventually {
            recorder.taskMessageBatches.flatMap { $0 }.count == 5 && recorder.deletedIssues == ["i7"]
        }
        XCTAssertTrue(delivered)
        XCTAssertEqual(recorder.taskMessageBatches.flatMap { $0 }.map(\.seq), [1, 2, 3, 4, 5])
        XCTAssertLessThan(recorder.taskMessageBatches.count, 5, "frames inside one window must coalesce")
        let metrics = await client.metrics
        XCTAssertEqual(metrics.taskMessagesDropped, 1)
        await client.stop()
    }

    func testReconnectReplaysSubscriptionsAndReportsRecovery() async throws {
        let connector = FakeConnector()
        let client = makeClient(connector)
        let recorder = EventRecorder(client)
        try await connect(client, connector, recorder)
        await client.watchTask("t1")

        connector.sockets[0].close()
        let reconnected = await eventually(timeout: .seconds(5)) { connector.sockets.count >= 2 && !connector.sockets[1].sent.isEmpty }
        XCTAssertTrue(reconnected)
        connector.sockets[1].push(#"{"type":"auth_ack"}"#)

        let recovered = await eventually { recorder.connectedCount(recovered: true) == 1 }
        XCTAssertTrue(recovered)
        let replayed = await eventually { connector.sockets[1].sent.contains { $0.contains(#""type":"subscribe""#) && $0.contains("t1") } }
        XCTAssertTrue(replayed)
        await client.stop()
    }
}
