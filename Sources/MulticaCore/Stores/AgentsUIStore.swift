import Foundation
import Observation

/// Workspace-scoped data behind the Agents screens that is not a plain
/// catalog: the task snapshot (presence), 30-day activity and run counts,
/// per-runtime model and local-skill discovery, and builder drafts. One per
/// session; every fetch is single-flight and refreshed by realtime revisions
/// instead of polling.
@MainActor
@Observable
public final class AgentsUIStore {
    public private(set) var snapshot: [AgentTaskRecord] = []
    public private(set) var snapshotLoaded = false
    public private(set) var activityBuckets: [AgentActivityBucket] = []
    public private(set) var activityLoaded = false
    public private(set) var runCounts: [String: Int] = [:]
    public private(set) var runCountsLoaded = false
    public private(set) var builderSessions: [AgentBuilderSessionSummary] = []
    public private(set) var builderSessionsLoaded = false

    public enum Discovery<Value: Sendable & Hashable>: Sendable, Hashable {
        case idle
        case loading(previous: Value?)
        case loaded(Value)
        case failed(String, previous: Value?)

        public var value: Value? {
            switch self {
            case .loaded(let v): return v
            case .loading(let p), .failed(_, let p): return p
            case .idle: return nil
            }
        }

        public var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }

        /// First load with nothing to show yet.
        public var isInitialLoad: Bool {
            if case .loading(nil) = self { return true }
            return false
        }

        public var error: String? {
            if case .failed(let e, _) = self { return e }
            return nil
        }
    }

    public struct LocalSkills: Sendable, Hashable {
        public var skills: [RuntimeLocalSkillSummary]
        public var supported: Bool
        public var mcpServers: [RuntimeLocalMcpServerSummary]
        public var mcpSupported: Bool
    }

    public private(set) var models: [String: Discovery<AgentsUI.ModelsResult>] = [:]
    public private(set) var localSkills: [String: Discovery<LocalSkills>] = [:]
    /// HTTP status of the last failed local-skill discovery (403 = forbidden).
    public private(set) var localSkillsStatus: [String: Int] = [:]

    @ObservationIgnored private weak var session: WorkspaceSession?
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private var inflight: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var modelsFetchedAt: [String: Date] = [:]
    @ObservationIgnored private var skillsFetchedAt: [String: Date] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var seen: [String: Int] = [:]

    private static var stores: [ObjectIdentifier: AgentsUIStore] = [:]

    /// The store for a session (created on first use).
    public static func shared(for session: WorkspaceSession) -> AgentsUIStore {
        let key = ObjectIdentifier(session)
        if let s = stores[key], s.session === session { return s }
        stores = stores.filter { $0.value.session != nil }
        let s = AgentsUIStore(session: session)
        stores[key] = s
        return s
    }

    init(session: WorkspaceSession) {
        self.session = session
        self.api = session.api
    }

    private func single(_ key: String, _ work: @escaping @MainActor () async -> Void) async {
        if let t = inflight[key] {
            await t.value
            return
        }
        let t = Task { @MainActor in await work() }
        inflight[key] = t
        await t.value
        inflight[key] = nil
    }

    // MARK: Workspace projections

    public func loadSnapshot() async {
        await single("snapshot") {
            if let s = try? await self.api.agentsUITaskSnapshot() {
                if s != self.snapshot { self.snapshot = s }
            }
            self.snapshotLoaded = true
        }
    }

    public func loadActivity() async {
        await single("activity") {
            if let b = try? await self.api.getWorkspaceAgentActivity30d() {
                if b != self.activityBuckets { self.activityBuckets = b }
            }
            self.activityLoaded = true
        }
    }

    public func loadRunCounts() async {
        await single("runCounts") {
            if let r = try? await self.api.getWorkspaceAgentRunCounts() {
                let map = Dictionary(r.map { ($0.agentId, $0.runCount) }, uniquingKeysWith: +)
                if map != self.runCounts { self.runCounts = map }
            }
            self.runCountsLoaded = true
        }
    }

    public func loadProjectionsIfNeeded() async {
        async let a: Void = snapshotLoaded ? () : loadSnapshot()
        async let b: Void = activityLoaded ? () : loadActivity()
        async let c: Void = runCountsLoaded ? () : loadRunCounts()
        _ = await (a, b, c)
    }

    /// Applies realtime revisions the screens observe. Each key refetches
    /// only when it actually moved since the last call.
    public func sync(task: Int, agent: Int, runtime: Int, daemon: Int) {
        guard let session else { return }
        let taskMoved = moved("task", task)
        let agentMoved = moved("agent", agent)
        let runtimeOnlyMoved = moved("runtime", runtime)
        let daemonMoved = moved("daemon", daemon)
        let runtimeMoved = runtimeOnlyMoved || daemonMoved
        if taskMoved {
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                async let a: Void = self.loadSnapshot()
                async let b: Void = self.activityLoaded ? self.loadActivity() : ()
                async let c: Void = self.runCountsLoaded ? self.loadRunCounts() : ()
                _ = await (a, b, c)
            }
        }
        if agentMoved || runtimeMoved {
            Task { await session.agentRecords.refreshIfLoaded() }
        }
        if runtimeMoved {
            Task { await session.runtimeRecords.refreshIfLoaded() }
        }
    }

    private func moved(_ key: String, _ value: Int) -> Bool {
        defer { seen[key] = value }
        guard let last = seen[key] else { return false }
        return last != value
    }

    // MARK: Model discovery

    public func modelsState(_ runtimeID: String?) -> Discovery<AgentsUI.ModelsResult> {
        guard let runtimeID else { return .idle }
        return models[runtimeID] ?? .idle
    }

    /// Discovers a runtime's models (daemon round-trip, polled). Live results
    /// stay fresh for five minutes; cached answers are re-asked every time.
    public func loadModels(_ runtimeID: String, force: Bool = false) async {
        if !force, case .loaded(let r) = models[runtimeID], !r.cached,
           let at = modelsFetchedAt[runtimeID], Date().timeIntervalSince(at) < 300 { return }
        await single("models:\(runtimeID):\(force)") {
            let previous = self.models[runtimeID]?.value
            self.models[runtimeID] = .loading(previous: previous)
            do {
                let r = try await self.resolveModels(runtimeID, force: force)
                self.models[runtimeID] = .loaded(r)
                self.modelsFetchedAt[runtimeID] = Date()
            } catch {
                self.models[runtimeID] = .failed(Self.message(error), previous: previous)
            }
        }
    }

    private func resolveModels(_ runtimeID: String, force: Bool) async throws -> AgentsUI.ModelsResult {
        let initial = try await api.initiateListModels(runtimeID, force: force)
        let start = Date()
        var current = initial
        while current.status == "pending" || current.status == "running" {
            if Date().timeIntervalSince(start) > 100 { throw AgentsUIDiscoveryError.message("model discovery timed out") }
            try await Task.sleep(for: .milliseconds(500))
            current = try await api.getListModelsResult(runtimeID, requestId: initial.id)
        }
        guard current.status == "completed" else {
            throw AgentsUIDiscoveryError.message(current.error ?? "model discovery failed (status: \(current.status))")
        }
        return AgentsUI.ModelsResult(models: current.models ?? [], unavailableModels: current.unavailableModels ?? [],
                                     supported: current.supported, cached: current.cached == true)
    }

    // MARK: Local skills & MCP inventory

    public func localSkillsState(_ runtimeID: String?) -> Discovery<LocalSkills> {
        guard let runtimeID else { return .idle }
        return localSkills[runtimeID] ?? .idle
    }

    public func loadLocalSkills(_ runtimeID: String, force: Bool = false) async {
        if !force, case .loaded = localSkills[runtimeID], let at = skillsFetchedAt[runtimeID],
           Date().timeIntervalSince(at) < 30 { return }
        await single("skills:\(runtimeID)") {
            let previous = self.localSkills[runtimeID]?.value
            self.localSkills[runtimeID] = .loading(previous: previous)
            do {
                let initial = try await self.api.initiateListLocalSkills(runtimeID)
                let start = Date()
                var current = initial
                while current.status == "pending" || current.status == "running" {
                    if Date().timeIntervalSince(start) > 30 { throw AgentsUIDiscoveryError.message("runtime local skill discovery timed out") }
                    try await Task.sleep(for: .milliseconds(500))
                    current = try await self.api.getListLocalSkillsResult(runtimeID, requestId: initial.id)
                }
                if current.status == "failed" || current.status == "timeout" {
                    throw AgentsUIDiscoveryError.message(current.error ?? "runtime local skill discovery failed")
                }
                self.localSkills[runtimeID] = .loaded(LocalSkills(skills: current.skills ?? [], supported: current.supported,
                                                                  mcpServers: current.mcpServers ?? [], mcpSupported: current.mcpSupported == true))
                self.localSkillsStatus[runtimeID] = nil
                self.skillsFetchedAt[runtimeID] = Date()
            } catch {
                self.localSkillsStatus[runtimeID] = (error as? APIError)?.status
                self.localSkills[runtimeID] = .failed(Self.message(error), previous: previous)
            }
        }
    }

    // MARK: Builder drafts

    public func loadBuilderSessions() async {
        await single("builder") {
            if let list = try? await self.api.listAgentBuilderSessions() {
                if list != self.builderSessions { self.builderSessions = list }
            }
            self.builderSessionsLoaded = true
        }
    }

    static func message(_ error: Error) -> String {
        if let e = error as? APIError { return e.message }
        if case AgentsUIDiscoveryError.message(let m) = error { return m }
        return error.localizedDescription
    }
}

public enum AgentsUIDiscoveryError: Error, Sendable {
    case message(String)
}
