import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One cached request: single-flight, refetched only when older than the
/// stale window (upstream TanStack `staleTime`).
@MainActor
@Observable
public final class RuntimesQuery<Value: Sendable> {
    public private(set) var value: Value?
    public private(set) var error: String?
    public private(set) var isLoading = false
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private let fetch: @Sendable () async throws -> Value

    public init(fetch: @escaping @Sendable () async throws -> Value) {
        self.fetch = fetch
    }

    public var isLoaded: Bool { value != nil }

    public func load(staleAfter: TimeInterval = 60, force: Bool = false) async {
        if !force, let fetchedAt, Date().timeIntervalSince(fetchedAt) < staleAfter { return }
        if let inflight {
            await inflight.value
            return
        }
        isLoading = value == nil
        let fetch = self.fetch
        let task = Task { @MainActor in
            do {
                self.value = try await fetch()
                self.error = nil
                self.fetchedAt = Date()
            } catch {
                self.error = (error as? APIError)?.message ?? error.localizedDescription
            }
            self.isLoading = false
        }
        inflight = task
        await task.value
        inflight = nil
    }

    public func set(_ value: Value) {
        self.value = value
        fetchedAt = Date()
    }
}

/// Runtimes-area state for the active workspace session: the custom runtime
/// profile catalog, the agent task snapshot (workloads), and usage reports.
@MainActor
@Observable
public final class RuntimesStore {
    public let profiles = CollectionStore<RuntimeProfile>()
    public private(set) var tasks: [AgentTask] = []
    public private(set) var tasksLoaded = false

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let workspaceID: String
    @ObservationIgnored private var queries: [String: AnyObject] = [:]
    @ObservationIgnored private var tasksRefresh: Task<Void, Never>?
    @ObservationIgnored private var tasksInflight: Task<Void, Never>?

    private static var current: (key: ObjectIdentifier, store: RuntimesStore)?

    /// The store of the active session (one session is live at a time).
    public static func shared(for session: WorkspaceSession) -> RuntimesStore {
        let key = ObjectIdentifier(session)
        if let current, current.key == key { return current.store }
        let store = RuntimesStore(api: session.api, workspaceID: session.workspace.id)
        current = (key, store)
        return store
    }

    init(api: APIClient, workspaceID: String) {
        self.api = api
        self.workspaceID = workspaceID
        profiles.configure { try await api.listRuntimeProfiles(workspaceId: workspaceID) }
    }

    // MARK: Task snapshot

    public func loadTasksIfNeeded() async {
        guard !tasksLoaded else { return }
        await loadTasks()
    }

    public func loadTasks() async {
        if let tasksInflight {
            await tasksInflight.value
            return
        }
        let api = self.api
        let task = Task { @MainActor in
            if let list = try? await api.agentTaskSnapshot() {
                if list != self.tasks { self.tasks = list }
                self.tasksLoaded = true
            }
        }
        tasksInflight = task
        await task.value
        tasksInflight = nil
    }

    /// Debounced snapshot refetch after agent activity changed.
    public func scheduleTasksRefresh() {
        guard tasksLoaded else { return }
        tasksRefresh?.cancel()
        tasksRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            await self.loadTasks()
        }
    }

    // MARK: Queries

    private func query<V: Sendable>(_ key: String, _ fetch: @escaping @Sendable () async throws -> V) -> RuntimesQuery<V> {
        if let q = queries[key] as? RuntimesQuery<V> { return q }
        let q = RuntimesQuery(fetch: fetch)
        queries[key] = q
        return q
    }

    public func usage(runtimeID: String, days: Int, timeZone: String) -> RuntimesQuery<[RuntimeUsage]> {
        let api = self.api
        return query("usage|\(runtimeID)|\(days)|\(timeZone)") { try await api.getRuntimeUsage(runtimeID, days: days, tz: timeZone) }
    }

    public func usageByAgent(runtimeID: String, days: Int, timeZone: String) -> RuntimesQuery<[RuntimeUsageByAgent]> {
        let api = self.api
        return query("by-agent|\(runtimeID)|\(days)|\(timeZone)") { try await api.getRuntimeUsageByAgent(runtimeID, days: days, tz: timeZone) }
    }

    public func cloudNodes() -> RuntimesQuery<[CloudRuntimeNode]> {
        let api = self.api
        return query("cloud-nodes") { try await api.listCloudRuntimeNodes(limit: 20, offset: 0) }
    }

    /// Drops cached usage so the next read refetches (after a delete).
    public func invalidateUsage() {
        queries = queries.filter { !$0.key.hasPrefix("usage|") && !$0.key.hasPrefix("by-agent|") }
    }
}

/// User-entered rates for models without a maintained price. Global (not
/// per workspace) and stored locally, like upstream's persisted store.
@MainActor
@Observable
public final class RuntimesCustomPricing {
    public static let shared = RuntimesCustomPricing()
    static let defaultsKey = "multica.runtimes.customPricing"

    public private(set) var pricings: [String: RuntimesModelPrice]
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: RuntimesModelPrice].self, from: data) {
            pricings = saved
        } else {
            pricings = [:]
        }
    }

    public var pricer: RuntimesPricer { RuntimesPricer(custom: pricings) }

    public func set(_ model: String, _ price: RuntimesModelPrice) {
        pricings[model] = price
        persist()
    }

    public func remove(_ model: String) {
        guard pricings.removeValue(forKey: model) != nil else { return }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pricings) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// Latest published CLI release (GitHub), cached for ten minutes.
public enum RuntimesRelease {
    static let cache = Locked<(version: String?, at: Date)>((nil, .distantPast))
    static let url = URL(string: "https://api.github.com/repos/multica-ai/multica/releases/latest")!

    public static func latestVersion() async -> String? {
        let cached = cache.current
        if let v = cached.version, Date().timeIntervalSince(cached.at) < 600 { return v }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        cache.withLock { $0 = (tag, Date()) }
        return tag
    }

    /// `"v0.4.17"` → `[0, 4, 17]`; nil for source builds (`git describe`, `dev`).
    public static func parseReleaseVersion(_ v: String) -> [Int]? {
        var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    /// Strictly newer by release version; unparseable on either side is "no".
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let l = parseReleaseVersion(latest), let c = parseReleaseVersion(current) else { return false }
        for (lv, cv) in zip(l, c) where lv != cv { return lv > cv }
        return false
    }
}

/// Structured 409 bodies returned by runtime/profile deletes.
public enum RuntimesConflict {
    public enum DeleteCode: String, Sendable { case hasActiveAgents = "runtime_has_active_agents", planChanged = "runtime_delete_plan_changed" }

    /// The active agents a runtime delete refused over, or nil when the
    /// error is not such a conflict.
    public static func runtimeDelete(_ error: Error) -> (code: DeleteCode, agents: [AgentRecord])? {
        guard let e = error as? APIError, e.status == 409, let obj = e.body,
              let raw = obj["code"]?.stringValue, let code = DeleteCode(rawValue: raw) else { return nil }
        guard let list = obj["active_agents"]?.arrayValue else { return (code, []) }
        let agents = list.compactMap { v -> AgentRecord? in
            guard v["id"]?.stringValue != nil, v["name"]?.stringValue != nil, let data = try? JSONCoders.encoder.encode(v) else { return nil }
            return try? JSONCoders.decoder.decode(AgentRecord.self, from: data)
        }
        return (code, agents)
    }

    /// The server's explanation when a profile delete is refused because
    /// agents are still bound.
    public static func profileBound(_ error: Error) -> String? {
        guard let e = error as? APIError, e.status == 409 else { return nil }
        if let obj = e.body {
            for key in ["message", "error"] {
                if let s = obj[key]?.stringValue, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
            }
        }
        return e.message
    }
}

extension RuntimesKit {
    public static let mikaSystemKey = "mika"

    /// Whether this member still needs "Start with Mika": no Mika agent, no
    /// conversation with it, or a conversation that was never kicked off.
    public static func memberNeedsMikaSetup(agents: [AgentRecord], sessions: [ChatSession]) -> Bool {
        guard let mika = agents.first(where: { $0.systemKey == mikaSystemKey }) else { return true }
        guard let session = sessions.first(where: { $0.agentId == mika.id }) else { return true }
        return session.lastMessage == nil
    }

    /// Mika onboarding content language for a UI language.
    public static func mikaContentLanguage(_ language: String) -> String {
        if language.hasPrefix("zh") { return "zh" }
        if language.hasPrefix("ko") { return "ko" }
        if language.hasPrefix("ja") { return "ja" }
        return "en"
    }

    public static func mikaChatTitle(_ language: String) -> String {
        switch mikaContentLanguage(language) {
        case "zh": return "和 Mika 开始"
        case "ko": return "Mika와 시작하기"
        case "ja": return "Mika と始める"
        default: return "Getting started with Mika"
        }
    }
}
