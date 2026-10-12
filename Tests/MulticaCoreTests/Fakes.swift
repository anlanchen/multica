import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MulticaCore

/// Routes requests to canned JSON by "METHOD path" and records what was sent.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Recorded {
        var method: String
        var path: String
        var query: String?
        var request: URLRequest
        var body: Data?

        func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
    }

    private let state = Locked<(routes: [String: (Int, Data)], requests: [Recorded], delay: Duration)>(([:], [], .zero))

    func on(_ method: String, _ path: String, status: Int = 200, json: String) {
        state.withLock { $0.routes["\(method) \(path)"] = (status, Data(json.utf8)) }
    }

    func setDelay(_ d: Duration) { state.withLock { $0.delay = d } }

    var requests: [Recorded] { state.current.requests }

    func count(_ method: String, _ path: String) -> Int {
        requests.filter { $0.method == method && $0.path == path }.count
    }

    func perform(_ request: URLRequest) async throws -> HTTPResponse {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let path = url.path
        let rec = Recorded(method: method, path: path, query: url.query, request: request, body: request.httpBody)
        let (route, delay) = state.withLock { s -> ((Int, Data)?, Duration) in
            s.requests.append(rec)
            return (s.routes["\(method) \(path)"], s.delay)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let (status, body) = route else {
            return HTTPResponse(status: 404, body: Data(#"{"error":"no route \#(method) \#(path)"}"#.utf8))
        }
        return HTTPResponse(status: status, body: body)
    }
}

/// In-memory WebSocket: the test pushes server frames and reads client frames.
final class FakeWebSocket: WebSocketConnection, @unchecked Sendable {
    private let inbound: AsyncStream<WebSocketFrame>
    private let inboundContinuation: AsyncStream<WebSocketFrame>.Continuation
    private let state = Locked<(sent: [String], closed: Bool)>(([], false))
    private let iteratorBox = Locked<AsyncStream<WebSocketFrame>.Iterator?>(nil)

    init() {
        (inbound, inboundContinuation) = AsyncStream.makeStream(of: WebSocketFrame.self)
    }

    var sent: [String] { state.current.sent }
    var isClosed: Bool { state.current.closed }

    func push(_ text: String) { inboundContinuation.yield(.text(text)) }

    func send(_ text: String) async throws {
        if state.current.closed { throw URLError(.networkConnectionLost) }
        state.withLock { $0.sent.append(text) }
    }

    func receive() async throws -> WebSocketFrame {
        var it = iteratorBox.withLock { box -> AsyncStream<WebSocketFrame>.Iterator in
            if box == nil { box = inbound.makeAsyncIterator() }
            return box!
        }
        let next = await it.next()
        iteratorBox.withLock { $0 = it }
        guard let next, !state.current.closed else { throw URLError(.networkConnectionLost) }
        return next
    }

    func close() {
        state.withLock { $0.closed = true }
        inboundContinuation.finish()
    }
}

final class FakeConnector: WebSocketConnector, @unchecked Sendable {
    private let state = Locked<(sockets: [FakeWebSocket], urls: [URL])>(([], []))

    var sockets: [FakeWebSocket] { state.current.sockets }
    var urls: [URL] { state.current.urls }

    func connect(to url: URL) async throws -> WebSocketConnection {
        let s = FakeWebSocket()
        state.withLock {
            $0.sockets.append(s)
            $0.urls.append(url)
        }
        return s
    }
}

/// Polls until `condition` holds or the timeout elapses.
func eventually(
    isolation: isolated (any Actor)? = #isolation,
    timeout: Duration = .seconds(3),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

enum Fixtures {
    static func issueJSON(id: String, number: Int, status: String = "todo", title: String = "Issue",
                          revision: Int = 1, position: Double = 0, assigneeType: String? = nil, assigneeID: String? = nil) -> String {
        let assignee = assigneeType.map { #""assignee_type":"\#($0)","assignee_id":"\#(assigneeID ?? "")","# } ?? ""
        return """
        {"id":"\(id)","workspace_id":"ws1","number":\(number),"identifier":"MUL-\(number)","title":"\(title)",
         "description":null,"status":"\(status)","priority":"high",\(assignee)"creator_type":"member","creator_id":"u1",
         "parent_issue_id":null,"project_id":null,"position":\(position),"stage":null,"start_date":null,"due_date":null,
         "metadata":{},"properties":{},"labels":[],"created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-01T00:00:0\(min(revision, 9))Z",
         "revision":\(revision)}
        """
    }

    static func taskMessageFrame(task: String, issue: String, seq: Int, type: String = "text", content: String = "hello",
                                 callID: String? = nil, tool: String? = nil) -> String {
        // Same shape the Go server emits: sorted envelope keys (map), payload
        // fields in struct order.
        var fields = ""
        if let callID { fields += #""call_id":"\#(callID)","# }
        fields += #""task_id":"\#(task)","issue_id":"\#(issue)","seq":\#(seq),"type":"\#(type)""#
        if let tool { fields += #","tool":"\#(tool)""# }
        fields += #","content":"\#(content)""#
        return #"{"actor_id":"","actor_type":"system","payload":{\#(fields)},"type":"task:message"}"#
    }
}
