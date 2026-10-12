import Foundation

public struct RealtimeMetrics: Sendable, Equatable {
    public var frames = 0
    public var bytes = 0
    public var taskMessagesKept = 0
    public var taskMessagesDropped = 0
    public var batchesEmitted = 0
    public var reconnects = 0
    public var decodeTime: Duration = .zero

    public init() {}
}

struct RealtimeConnectionError: Error, CustomStringConvertible {
    var description: String
}

/// Owns the workspace WebSocket: token handshake, decode/route, task message
/// batching, scope subscriptions, liveness, and reconnect with backoff.
///
/// Everything here runs off the main thread. The UI only sees the already
/// decoded, already batched `events` stream, so a burst of streamed agent
/// output costs the main thread one store update per 100 ms window rather
/// than one JSON parse + cache merge per frame.
public actor RealtimeClient {
    public nonisolated let events: AsyncStream<RealtimeEvent>
    private let continuation: AsyncStream<RealtimeEvent>.Continuation

    public nonisolated let interest: InterestRegistry
    public nonisolated let router: FrameRouter
    private let config: ServerConfig
    private let identity: ClientIdentity
    private let connector: WebSocketConnector
    private let tokenProvider: @Sendable () async -> String?
    private let redactor = Redactor.shared
    private let batchWindow: Duration
    private let pingInterval: Duration
    private let staleAfter: Duration

    private var workspaceSlug: String?
    private var loop: Task<Void, Never>?
    private var connection: WebSocketConnection?
    private var subscribedTasks: Set<String> = []
    private var batcher: FixedWindowBatcher<TaskMessage>
    private var flushTimer: Task<Void, Never>?
    private var backoff = Backoff()
    private var hasConnected = false
    private var lastFrameAt = ContinuousClock.now
    public private(set) var metrics = RealtimeMetrics()

    public init(
        config: ServerConfig,
        identity: ClientIdentity = ClientIdentity(),
        connector: WebSocketConnector = URLSessionWebSocketConnector(),
        interest: InterestRegistry = InterestRegistry(),
        batchWindow: Duration = .milliseconds(100),
        pingInterval: Duration = .seconds(25),
        staleAfter: Duration = .seconds(70),
        tokenProvider: @escaping @Sendable () async -> String?
    ) {
        self.config = config
        self.identity = identity
        self.connector = connector
        self.interest = interest
        self.router = FrameRouter(interest: interest)
        self.batchWindow = batchWindow
        self.pingInterval = pingInterval
        self.staleAfter = staleAfter
        self.tokenProvider = tokenProvider
        self.batcher = FixedWindowBatcher(window: batchWindow)
        (events, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self, bufferingPolicy: .unbounded)
    }

    // MARK: Lifecycle

    public func start(workspaceSlug: String) {
        stopConnection()
        self.workspaceSlug = workspaceSlug
        hasConnected = false
        backoff.reset()
        loop = Task { [weak self] in await self?.runLoop() }
    }

    public func stop() {
        stopConnection()
        workspaceSlug = nil
        continuation.yield(.connection(.stopped))
    }

    private func stopConnection() {
        loop?.cancel()
        loop = nil
        connection?.close()
        connection = nil
        flushTimer?.cancel()
        flushTimer = nil
        batcher = FixedWindowBatcher(window: batchWindow)
    }

    /// Forces an immediate reconnect, e.g. after the machine wakes or the
    /// network path changes, instead of waiting out the backoff.
    public func reconnectNow() {
        guard let slug = workspaceSlug else { return }
        let recovered = hasConnected
        start(workspaceSlug: slug)
        hasConnected = recovered
    }

    // MARK: Interest

    /// Marks a run's transcript as on screen. Sends a `task` scope subscription
    /// so the client keeps receiving the run once the server switches
    /// high-frequency events from workspace fan-out to per-task rooms.
    public func watchTask(_ taskID: String) async {
        guard interest.retainTask(taskID) else { return }
        subscribedTasks.insert(taskID)
        try? await connection?.send(Self.scopeFrame("subscribe", scope: "task", id: taskID))
    }

    public func unwatchTask(_ taskID: String) async {
        guard interest.releaseTask(taskID) else { return }
        subscribedTasks.remove(taskID)
        try? await connection?.send(Self.scopeFrame("unsubscribe", scope: "task", id: taskID))
    }

    public nonisolated func watchIssue(_ issueID: String) { interest.retainIssue(issueID) }
    public nonisolated func unwatchIssue(_ issueID: String) { interest.releaseIssue(issueID) }

    // MARK: Connection loop

    private func runLoop() async {
        while !Task.isCancelled {
            continuation.yield(.connection(.connecting))
            do {
                try await connectAndReceive()
            } catch {
                // Fall through to backoff.
            }
            connection?.close()
            connection = nil
            if Task.isCancelled { return }
            let delay = backoff.nextDelay()
            metrics.reconnects += 1
            continuation.yield(.connection(.disconnected(retryIn: delay)))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    func webSocketURL(slug: String) -> URL {
        var c = URLComponents(url: config.wsURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "workspace_slug", value: slug),
            URLQueryItem(name: "client_platform", value: identity.platform),
            URLQueryItem(name: "client_version", value: identity.version),
            URLQueryItem(name: "client_os", value: identity.os),
        ]
        return c.url!
    }

    private func connectAndReceive() async throws {
        guard let slug = workspaceSlug else { throw RealtimeConnectionError(description: "no workspace") }
        guard let token = await tokenProvider() else { throw RealtimeConnectionError(description: "no token") }

        let conn = try await connector.connect(to: webSocketURL(slug: slug))
        connection = conn
        // The token travels in the first frame, never in the URL, so proxies
        // and logs never see it.
        try await conn.send(Self.authFrame(token: token))
        // A socket that never answers the handshake is closed, which makes the
        // pending receive throw. (Cancelling a task does not interrupt a
        // URLSessionWebSocketTask receive, so a racing timeout task would not.)
        let handshakeTimer = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { conn.close() }
        }
        let first = try await conn.receive()
        handshakeTimer.cancel()
        switch router.decode(first) {
        case .control(.authAck):
            break
        case .control(.authError(let message)):
            throw RealtimeConnectionError(description: "auth rejected: \(message)")
        default:
            throw RealtimeConnectionError(description: "expected auth_ack")
        }

        backoff.reset()
        let recovered = hasConnected
        hasConnected = true
        lastFrameAt = .now
        continuation.yield(.connection(.connected(recovered: recovered)))
        for id in subscribedTasks {
            try? await conn.send(Self.scopeFrame("subscribe", scope: "task", id: id))
        }

        let watchdog = Task { [weak self, pingInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pingInterval)
                guard let self, await self.livenessTick(conn) else { return }
            }
        }
        defer { watchdog.cancel() }

        while !Task.isCancelled {
            let frame = try await conn.receive()
            handle(frame)
        }
    }

    /// Sends an application ping; closes the socket when nothing has arrived
    /// for `staleAfter`, which turns a silently dead link into a reconnect.
    private func livenessTick(_ conn: WebSocketConnection) async -> Bool {
        guard connection != nil else { return false }
        if ContinuousClock.now - lastFrameAt > staleAfter {
            conn.close()
            return false
        }
        try? await conn.send(#"{"type":"ping"}"#)
        return true
    }

    // MARK: Frame handling

    func handle(_ frame: WebSocketFrame) {
        lastFrameAt = .now
        metrics.frames += 1
        let started = ContinuousClock.now
        let decoded: DecodedFrame
        switch frame {
        case .text(let s):
            metrics.bytes += s.utf8.count
            decoded = router.decode(frame)
        case .data(let d):
            metrics.bytes += d.count
            decoded = router.decode(d)
        }
        metrics.decodeTime += ContinuousClock.now - started

        switch decoded {
        case .event(let e):
            continuation.yield(e)
        case .taskMessage(let m):
            metrics.taskMessagesKept += 1
            // Redact here, once, off the main thread; the UI renders what it
            // receives.
            enqueue(redactor.redacted(m))
        case .droppedTaskMessage:
            metrics.taskMessagesDropped += 1
        case .control, .ignored:
            break
        }
    }

    private func enqueue(_ message: TaskMessage) {
        switch batcher.offer(message, now: .now) {
        case .flushNow(let batch):
            emitBatch(batch)
        case .held(let deadline):
            scheduleFlush(at: deadline)
        }
    }

    private func scheduleFlush(at deadline: ContinuousClock.Instant) {
        guard flushTimer == nil else { return }
        flushTimer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            await self?.windowElapsed()
        }
    }

    private func windowElapsed() {
        flushTimer = nil
        let (batch, next) = batcher.windowElapsed(now: .now)
        if !batch.isEmpty { emitBatch(batch) }
        if let next, batcher.hasPending || !batch.isEmpty {
            scheduleFlush(at: next)
        }
    }

    private func emitBatch(_ batch: [TaskMessage]) {
        metrics.batchesEmitted += 1
        continuation.yield(.taskMessages(batch))
    }

    /// Flushes any held task messages immediately (tests, teardown).
    public func flushPending() {
        flushTimer?.cancel()
        flushTimer = nil
        let (batch, _) = batcher.windowElapsed(now: .now.advanced(by: batchWindow))
        if !batch.isEmpty { emitBatch(batch) }
    }

    // MARK: Frames

    static func authFrame(token: String) -> String {
        struct Frame: Encodable { var type = "auth"; var payload: [String: String] }
        let data = (try? JSONCoders.encoder.encode(Frame(payload: ["token": token]))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func scopeFrame(_ type: String, scope: String, id: String) -> String {
        struct Frame: Encodable { var type: String; var payload: [String: String] }
        let data = (try? JSONCoders.encoder.encode(Frame(type: type, payload: ["scope": scope, "id": id]))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
