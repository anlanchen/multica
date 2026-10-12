import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum WebSocketFrame: Sendable, Equatable {
    case text(String)
    case data(Data)

    public var bytes: Data {
        switch self {
        case .text(let s): return Data(s.utf8)
        case .data(let d): return d
        }
    }
}

public protocol WebSocketConnection: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> WebSocketFrame
    func close()
}

public protocol WebSocketConnector: Sendable {
    func connect(to url: URL) async throws -> WebSocketConnection
}

public struct URLSessionWebSocketConnector: WebSocketConnector {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    public func connect(to url: URL) async throws -> WebSocketConnection {
        let task = session.webSocketTask(with: url)
        // Server frames are small except task messages with large tool
        // payloads; leave headroom above the default 1 MiB.
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> WebSocketFrame {
        switch try await task.receive() {
        case .string(let s): return .text(s)
        case .data(let d): return .data(d)
        @unknown default: return .data(Data())
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
