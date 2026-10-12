import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// The network boundary. Swapped for a fake in tests.
public protocol HTTPTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.httpMaximumConnectionsPerHost = 6
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    public func perform(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResponse(status: status, body: data)
    }
}

public struct APIError: Error, Sendable, Equatable, CustomStringConvertible {
    public var status: Int
    public var message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }

    public var isUnauthorized: Bool { status == 401 }
    public var description: String { "HTTP \(status): \(message)" }

    static func from(status: Int, body: Data) -> APIError {
        struct ErrorBody: Decodable { var error: String? }
        let message = (try? JSONCoders.decoder.decode(ErrorBody.self, from: body))?.error
        return APIError(status: status, message: message ?? "Request failed with status \(status)")
    }
}

/// Counters surfaced in the in-app performance panel.
public struct NetworkMetrics: Sendable, Equatable {
    public var requests = 0
    public var deduplicated = 0
    public var bytesReceived = 0
    public var failures = 0

    public init() {}
}

/// HTTP client for the Multica REST API.
///
/// Two properties matter for performance:
/// - Identical concurrent GETs share one request (single-flight). The upstream
///   client relied on TanStack Query for this and still produced request
///   storms where several caches fetched the same endpoint (MUL-4159,
///   #9088: four identical `GET /api/issues?limit=50`).
/// - Decoding runs outside the actor, so a large transcript decode never
///   blocks other requests from being issued.
public actor APIClient {
    public nonisolated let config: ServerConfig
    public nonisolated let identity: ClientIdentity
    private let transport: HTTPTransport
    private var token: String?
    private var workspaceSlug: String?
    private var inflight: [String: Task<HTTPResponse, Error>] = [:]
    private var unauthorizedHandler: (@Sendable () -> Void)?
    public private(set) var metrics = NetworkMetrics()

    public init(config: ServerConfig, identity: ClientIdentity = ClientIdentity(), transport: HTTPTransport = URLSessionTransport(), token: String? = nil) {
        self.config = config
        self.identity = identity
        self.transport = transport
        self.token = token
    }

    public func setToken(_ token: String?) { self.token = token }
    public func currentToken() -> String? { token }
    public func setWorkspaceSlug(_ slug: String?) { workspaceSlug = slug }
    public func setUnauthorizedHandler(_ handler: (@Sendable () -> Void)?) { unauthorizedHandler = handler }

    // MARK: Core request path

    public enum Method: String, Sendable { case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE" }

    func makeRequest(_ method: Method, _ path: String, query: [URLQueryItem], body: Data?, slugOverride: String?) -> URLRequest {
        var base = config.apiURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.queryItems = query }
        var r = URLRequest(url: components.url!)
        r.httpMethod = method.rawValue
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")
        r.setValue(identity.platform, forHTTPHeaderField: "X-Client-Platform")
        r.setValue(identity.version, forHTTPHeaderField: "X-Client-Version")
        r.setValue(identity.os, forHTTPHeaderField: "X-Client-OS")
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let slug = slugOverride ?? workspaceSlug { r.setValue(slug, forHTTPHeaderField: "X-Workspace-Slug") }
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    /// Sends a request and returns the raw body for a 2xx response.
    func data(_ method: Method, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, slug: String? = nil) async throws -> Data {
        let request = makeRequest(method, path, query: query, body: body, slugOverride: slug)
        let credential = token
        // Only reads are safe to share. The key includes the credential and
        // workspace so a switch never receives the previous identity's data.
        let key = method == .get
            ? "\(request.url!.absoluteString)|\(credential ?? "")|\(slug ?? workspaceSlug ?? "")"
            : nil

        let task: Task<HTTPResponse, Error>
        var owner = true
        if let key, let existing = inflight[key] {
            metrics.deduplicated += 1
            task = existing
            owner = false
        } else {
            let transport = self.transport
            task = Task { try await transport.perform(request) }
            metrics.requests += 1
            if let key { inflight[key] = task }
        }

        let response: HTTPResponse
        do {
            response = try await task.value
        } catch {
            if let key, inflight[key] == task { inflight[key] = nil }
            metrics.failures += 1
            throw error
        }
        if let key, inflight[key] == task { inflight[key] = nil }
        if owner { metrics.bytesReceived += response.body.count }

        guard (200..<300).contains(response.status) else {
            metrics.failures += 1
            if response.status == 401 { handleUnauthorized(credential) }
            throw APIError.from(status: response.status, body: response.body)
        }
        return response.body
    }

    /// A 401 ends the session only if it answered the credential still in
    /// use; a late 401 for a replaced token must not sign the user out
    /// (upstream MUL-7028).
    private func handleUnauthorized(_ credentialUsed: String?) {
        guard credentialUsed == token else { return }
        token = nil
        unauthorizedHandler?()
    }

    public nonisolated func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [], slug: String? = nil, as type: T.Type = T.self) async throws -> T {
        let body = try await data(.get, path, query: query, slug: slug)
        return try Self.decode(T.self, from: body, path: path)
    }

    public nonisolated func send<T: Decodable & Sendable>(_ method: Method, _ path: String, body: (some Encodable & Sendable)? = Optional<Empty>.none, as type: T.Type = T.self) async throws -> T {
        let encoded = try body.map { try JSONCoders.encoder.encode($0) }
        let data = try await data(method, path, body: encoded)
        return try Self.decode(T.self, from: data, path: path)
    }

    public nonisolated func sendIgnoringResponse(_ method: Method, _ path: String, body: (some Encodable & Sendable)? = Optional<Empty>.none) async throws {
        let encoded = try body.map { try JSONCoders.encoder.encode($0) }
        _ = try await data(method, path, body: encoded)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try JSONCoders.decoder.decode(T.self, from: data)
        } catch {
            throw APIError(status: 0, message: "Malformed response from \(path): \(error)")
        }
    }

    public struct Empty: Codable, Sendable {}
}

// MARK: - Endpoints

extension APIClient {
    // Auth
    public func sendCode(email: String) async throws {
        try await sendIgnoringResponse(.post, "/auth/send-code", body: ["email": email])
    }

    public func verifyCode(email: String, code: String) async throws -> LoginResponse {
        try await send(.post, "/auth/verify-code", body: ["email": email, "code": code])
    }

    public func me() async throws -> User {
        try await get("/api/me")
    }

    /// Mints a non-expiring personal access token for the local daemon,
    /// the same call the Electron shell makes before starting it.
    public func mintPersonalAccessToken(name: String = "Multica Native") async throws -> String {
        struct TokenResponse: Decodable, Sendable { var token: String }
        let r: TokenResponse = try await send(.post, "/api/tokens", body: ["name": name])
        return r.token
    }

    // Workspace
    public func workspaces() async throws -> [Workspace] {
        try await get("/api/workspaces", as: LossyList<Workspace>.self).items
    }

    public func members(workspaceID: String) async throws -> [Member] {
        try await get("/api/workspaces/\(workspaceID)/members", as: LossyList<Member>.self).items
    }

    public func agents() async throws -> [Agent] {
        try await get("/api/agents", as: LossyList<Agent>.self).items
    }

    public func runtimes() async throws -> [RuntimeDevice] {
        try await get("/api/runtimes", as: LossyList<RuntimeDevice>.self).items
    }

    public func issueStatuses() async throws -> [IssueStatusEntry] {
        try await get("/api/issue-statuses", as: ListIssueStatusesResponse.self).statuses
    }

    // Issues
    public struct IssueQuery: Sendable, Hashable {
        public var limit = 200
        public var offset = 0
        public var openOnly = false
        public var assigneeID: String?
        public var search: String?

        public init(limit: Int = 200, offset: Int = 0, openOnly: Bool = false, assigneeID: String? = nil, search: String? = nil) {
            self.limit = limit
            self.offset = offset
            self.openOnly = openOnly
            self.assigneeID = assigneeID
            self.search = search
        }

        var items: [URLQueryItem] {
            var q = [URLQueryItem(name: "limit", value: String(limit))]
            if offset > 0 { q.append(URLQueryItem(name: "offset", value: String(offset))) }
            if openOnly { q.append(URLQueryItem(name: "open_only", value: "true")) }
            if let assigneeID { q.append(URLQueryItem(name: "assignee_id", value: assigneeID)) }
            if let s = search?.trimmingCharacters(in: .whitespaces), !s.isEmpty { q.append(URLQueryItem(name: "q", value: s)) }
            return q
        }
    }

    public func listIssues(_ query: IssueQuery = IssueQuery()) async throws -> ListIssuesResponse {
        try await get("/api/issues", query: query.items)
    }

    public func issue(_ idOrIdentifier: String) async throws -> Issue {
        try await get("/api/issues/\(idOrIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? idOrIdentifier)")
    }

    public func createIssue(_ request: CreateIssueRequest) async throws -> Issue {
        try await send(.post, "/api/issues", body: request)
    }

    public func updateIssue(id: String, _ request: UpdateIssueRequest) async throws -> Issue {
        try await send(.put, "/api/issues/\(id)", body: request)
    }

    public func timeline(issueID: String) async throws -> [TimelineEntry] {
        try await get("/api/issues/\(issueID)/timeline", as: LossyList<TimelineEntry>.self).items
    }

    public func createComment(issueID: String, content: String, parentID: String? = nil) async throws -> Comment {
        struct Body: Encodable, Sendable {
            var content: String
            var type = "comment"
            var parent_id: String?
        }
        return try await send(.post, "/api/issues/\(issueID)/comments", body: Body(content: content, parent_id: parentID))
    }

    // Tasks
    public func taskRuns(issueID: String) async throws -> [AgentTask] {
        try await get("/api/issues/\(issueID)/task-runs", as: LossyList<AgentTask>.self).items
    }

    public func taskMessages(taskID: String) async throws -> [TaskMessage] {
        try await get("/api/tasks/\(taskID)/messages", as: LossyList<TaskMessage>.self).items
    }

    public func agentTaskSnapshot() async throws -> [AgentTask] {
        try await get("/api/agent-task-snapshot", as: LossyList<AgentTask>.self).items
    }

    public func cancelTask(issueID: String, taskID: String) async throws -> AgentTask {
        try await send(.post, "/api/issues/\(issueID)/tasks/\(taskID)/cancel")
    }

    // Inbox
    public func inbox() async throws -> [InboxItem] {
        try await get("/api/inbox", as: LossyList<InboxItem>.self).items
    }

    public func inboxUnreadSummary() async throws -> [InboxWorkspaceUnread] {
        try await get("/api/inbox/unread-summary", as: LossyList<InboxWorkspaceUnread>.self).items
    }

    public func markInboxRead(id: String) async throws {
        try await sendIgnoringResponse(.post, "/api/inbox/\(id)/read")
    }

    public func archiveInbox(id: String) async throws {
        try await sendIgnoringResponse(.post, "/api/inbox/\(id)/archive")
    }

    public func markAllInboxRead() async throws {
        try await sendIgnoringResponse(.post, "/api/inbox/mark-all-read")
    }
}
