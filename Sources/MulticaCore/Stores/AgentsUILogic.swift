import Foundation

/// Pure logic behind the Agents screens (upstream packages/core/agents and the
/// list/inspector helpers in packages/views/agents), namespaced so the single
/// app module never collides with other areas.
public enum AgentsUI {
    public static let descriptionMaxLength = 255
    public static let conversationStartersMax = 3
    public static let conversationStarterLabelMaxLength = 80
    public static let conversationStarterMaxLength = 4000
    public static let concurrencyRange = 1...50
}

// MARK: - Access scope & permissions

extension AgentsUI {
    public enum AccessScope: String, Sendable, CaseIterable, Codable {
        case workspace
        case specificPeople = "specific-people"
        case ownerOnly = "owner-only"
    }

    /// Effective access derived from `permission_mode` + `invocation_targets`
    /// (the legacy `visibility` is a lossy projection of these).
    public static func accessScope(permissionMode: String?, targets: [AgentInvocationTarget]?) -> AccessScope {
        guard permissionMode == "public_to" else { return .ownerOnly }
        if (targets ?? []).contains(where: { $0.targetType == "workspace" }) { return .workspace }
        return .specificPeople
    }

    public static func isAdminLike(_ role: String?) -> Bool {
        role == "owner" || role == "admin"
    }

    /// Owner or workspace owner/admin (server `canManageAgent`).
    public static func canEdit(_ agent: AgentRecord, userID: String?, role: String?) -> Bool {
        guard let userID else { return false }
        if isAdminLike(role) { return true }
        return agent.ownerId != nil && agent.ownerId == userID
    }

    public enum AssignDenial: String, Sendable {
        case notAuthenticated = "not_authenticated"
        case notMember = "not_member"
        case privateVisibility = "private_visibility"
    }

    /// Invocation gate shared by assignment and chat (server `canInvokeAgent`).
    public static func assignDenial(_ agent: AgentRecord, userID: String?, role: String?) -> AssignDenial? {
        guard let userID else { return .notAuthenticated }
        if let owner = agent.ownerId, owner == userID { return nil }
        if agent.permissionMode == "private" { return .privateVisibility }
        let targets = agent.invocationTargets
        if targets.contains(where: { $0.targetType == "workspace" }) {
            return role == nil ? .notMember : nil
        }
        if targets.contains(where: { $0.targetType == "member" && $0.targetId == userID }) { return nil }
        return .privateVisibility
    }

    /// New servers send `runtime_bound`; older ones only a non-empty id.
    public static func isRuntimeBound(_ agent: AgentRecord) -> Bool {
        agent.runtimeBound != false && !agent.runtimeId.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public static func isRuntimeUsable(_ runtime: RuntimeDeviceRecord, userID: String?) -> Bool {
        guard let owner = runtime.ownerId, !owner.isEmpty else { return false }
        guard let userID else { return true }
        if owner == userID { return true }
        return runtime.visibility == "public"
    }
}

// MARK: - Presence

extension AgentsUI {
    public enum Availability: String, Sendable, CaseIterable, Codable {
        case online, unstable, offline, archived
        /// Filter-chip order (archived has its own scope, not a chip).
        public static let filterOrder: [Availability] = [.online, .unstable, .offline]
    }

    public enum Workload: String, Sendable {
        case working, queued, idle
    }

    public struct Presence: Sendable, Hashable {
        public var availability: Availability
        public var workload: Workload
        public var runningCount: Int
        public var queuedCount: Int
        public var capacity: Int

        public init(availability: Availability, workload: Workload, runningCount: Int, queuedCount: Int, capacity: Int) {
            self.availability = availability
            self.workload = workload
            self.runningCount = runningCount
            self.queuedCount = queuedCount
            self.capacity = capacity
        }
    }

    public enum RuntimeHealth: String, Sendable {
        case online, recentlyLost, offline, longOffline
    }

    public static func runtimeHealth(status: String, lastSeenAt: String?, now: Date) -> RuntimeHealth {
        if status == "online" { return .online }
        let lastSeen = lastSeenAt.flatMap(Timestamp.parse) ?? Date(timeIntervalSince1970: 0)
        let offlineFor = now.timeIntervalSince(lastSeen)
        if offlineFor < 5 * 60 { return .recentlyLost }
        if offlineFor > 6 * 24 * 3600 { return .longOffline }
        return .offline
    }

    public static func availability(runtime: RuntimeDeviceRecord?, now: Date) -> Availability {
        guard let runtime else { return .offline }
        switch runtimeHealth(status: runtime.status, lastSeenAt: runtime.lastSeenAt, now: now) {
        case .online: return .online
        case .recentlyLost: return .unstable
        default: return .offline
        }
    }

    public static func workload(running: Int, queued: Int) -> Workload {
        if running > 0 { return .working }
        if queued > 0 { return .queued }
        return .idle
    }

    public static func isActiveTaskStatus(_ status: String) -> Bool {
        status == "running" || status == "queued" || status == "dispatched" || status == "waiting_local_directory"
    }

    public static func presence(agent: AgentRecord, runtime: RuntimeDeviceRecord?, tasks: [AgentTaskRecord], now: Date) -> Presence {
        if agent.archivedAt != nil {
            return Presence(availability: .archived, workload: .idle, runningCount: 0, queuedCount: 0, capacity: agent.maxConcurrentTasks)
        }
        let availability: Availability
        if let runtime {
            availability = Self.availability(runtime: runtime, now: now)
        } else {
            switch agent.runtimeAvailability {
            case "online": availability = .online
            case "unstable": availability = .unstable
            default: availability = .offline
            }
        }
        var running = 0, queued = 0
        for t in tasks {
            if t.status == "running" { running += 1 }
            else if t.status == "queued" || t.status == "dispatched" || t.status == "waiting_local_directory" { queued += 1 }
        }
        return Presence(availability: availability, workload: workload(running: running, queued: queued),
                        runningCount: running, queuedCount: queued, capacity: agent.maxConcurrentTasks)
    }

    public static func presenceMap(agents: [AgentRecord], runtimes: [RuntimeDeviceRecord], snapshot: [AgentTaskRecord], now: Date) -> [String: Presence] {
        let runtimesByID = Dictionary(runtimes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var tasksByAgent: [String: [AgentTaskRecord]] = [:]
        for t in snapshot { tasksByAgent[t.agentId, default: []].append(t) }
        var out: [String: Presence] = [:]
        out.reserveCapacity(agents.count)
        for a in agents {
            out[a.id] = presence(agent: a, runtime: runtimesByID[a.runtimeId], tasks: tasksByAgent[a.id] ?? [], now: now)
        }
        return out
    }
}

// MARK: - Activity

extension AgentsUI {
    public static let activityDays = 30

    public struct ActivityBucket: Sendable, Hashable {
        public var total = 0
        public var failed = 0
        public var completed = 0
        public var cancelled = 0
        public init(total: Int = 0, failed: Int = 0, completed: Int = 0, cancelled: Int = 0) {
            self.total = total
            self.failed = failed
            self.completed = completed
            self.cancelled = cancelled
        }
    }

    /// 30 daily buckets, oldest → newest (local days).
    public struct Activity: Sendable, Hashable {
        public var buckets: [ActivityBucket]
        public var daysSinceCreated: Int
        public var avgDurationMs: Double
    }

    public struct ActivitySummary: Sendable, Hashable {
        public var buckets: [ActivityBucket]
        public var totalRuns: Int
        public var totalFailed: Int
        public var totalCompleted: Int
        public var totalCancelled: Int
        /// Completed / (completed + failed), rounded percent; nil without outcomes.
        public var successRate: Int?
        public var windowDays: Int
    }

    public static func activity(buckets: [AgentActivityBucket], createdAt: String, now: Date, calendar: Calendar = .current) -> Activity {
        var series = Array(repeating: ActivityBucket(), count: activityDays)
        let today = calendar.startOfDay(for: now)
        var durationMs = 0
        var durationCount = 0
        for b in buckets {
            durationMs += b.durationMs ?? 0
            durationCount += b.durationCount ?? 0
            guard let ts = Timestamp.parse(b.bucketAt) else { continue }
            let day = calendar.startOfDay(for: ts)
            guard let daysAgo = calendar.dateComponents([.day], from: day, to: today).day,
                  daysAgo >= 0, daysAgo < activityDays else { continue }
            let slot = activityDays - 1 - daysAgo
            series[slot].total += b.taskCount
            series[slot].failed += b.failedCount
            series[slot].completed += b.completedCount
            series[slot].cancelled += b.cancelledCount
        }
        let age = Timestamp.parse(createdAt).map { now.timeIntervalSince($0) } ?? .infinity
        let days = age.isFinite ? min(activityDays, max(0, Int(age / 86400))) : activityDays
        return Activity(buckets: series, daysSinceCreated: days,
                        avgDurationMs: durationCount > 0 ? (Double(durationMs) / Double(durationCount)).rounded() : 0)
    }

    public static func activityMap(agents: [AgentRecord], buckets: [AgentActivityBucket], now: Date, calendar: Calendar = .current) -> [String: Activity] {
        var byAgent: [String: [AgentActivityBucket]] = [:]
        for b in buckets { byAgent[b.agentId, default: []].append(b) }
        var out: [String: Activity] = [:]
        for a in agents {
            out[a.id] = activity(buckets: byAgent[a.id] ?? [], createdAt: a.createdAt, now: now, calendar: calendar)
        }
        return out
    }

    public static func summarize(_ activity: Activity?, windowDays: Int) -> ActivitySummary {
        guard let activity else {
            return ActivitySummary(buckets: [], totalRuns: 0, totalFailed: 0, totalCompleted: 0, totalCancelled: 0, successRate: nil, windowDays: windowDays)
        }
        let window = min(max(0, windowDays), activity.buckets.count)
        let slice = window == 0 ? [] : Array(activity.buckets.suffix(window))
        var runs = 0, failed = 0, completed = 0, cancelled = 0
        for b in slice {
            runs += b.total
            failed += b.failed
            completed += b.completed
            cancelled += b.cancelled
        }
        let outcomes = completed + failed
        let rate = outcomes > 0 ? Int((Double(completed) / Double(outcomes) * 100).rounded()) : nil
        return ActivitySummary(buckets: slice, totalRuns: runs, totalFailed: failed, totalCompleted: completed,
                               totalCancelled: cancelled, successRate: rate, windowDays: windowDays)
    }

    /// Days since the newest bucket with runs (0 = today); nil when idle all window.
    public static func lastActiveDaysAgo(_ activity: Activity?) -> Int? {
        guard let activity else { return nil }
        for i in stride(from: activity.buckets.count - 1, through: 0, by: -1) where activity.buckets[i].total > 0 {
            return activity.buckets.count - 1 - i
        }
        return nil
    }

    /// Compact duration: "12s", "2m 04s", "1h 30m".
    public static func formatDuration(ms: Double) -> String {
        if ms <= 0 { return "—" }
        if ms < 60_000 { return "\(max(1, Int((ms / 1000).rounded())))s" }
        if ms < 3_600_000 {
            let m = Int(ms / 60_000)
            let s = Int((ms.truncatingRemainder(dividingBy: 60_000) / 1000).rounded())
            return "\(m)m \(s < 10 ? "0" : "")\(s)s"
        }
        let h = Int(ms / 3_600_000)
        let m = Int(ms.truncatingRemainder(dividingBy: 3_600_000) / 60_000)
        return "\(h)h \(m)m"
    }
}

extension AgentsUI {
    /// Live elapsed time for an active run: "42s", "3m 07s", "1h 05m".
    public static func formatElapsed(since start: Date, now: Date) -> String {
        let sec = max(0, Int(now.timeIntervalSince(start).rounded()))
        func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        if sec < 60 { return "\(sec)s" }
        let min = sec / 60
        if min < 60 { return "\(min)m \(pad(sec % 60))s" }
        return "\(min / 60)h \(pad(min % 60))m"
    }
}

// MARK: - List view state

extension AgentsUI {
    public enum ListScope: String, Sendable, CaseIterable, Codable {
        case mine, all, archived
    }

    public enum SortField: String, Sendable, CaseIterable, Codable {
        case lastActive, name, runs, created
        public var defaultDirection: SortDirection { self == .name ? .asc : .desc }
    }

    public enum SortDirection: String, Sendable, Codable {
        case asc, desc
        public var toggled: SortDirection { self == .asc ? .desc : .asc }
    }

    public enum Column: String, Sendable, CaseIterable, Codable {
        case status, owner, access, runtime, lastActive, runs, model, created
        public static let defaultHidden: [Column] = [.model, .created]
    }

    public enum FilterKey: String, Sendable, CaseIterable, Codable {
        case availability, runtimes, owners, models, access
    }

    public struct ListFilters: Sendable, Hashable, Codable {
        public var availability: [String] = []
        public var runtimes: [String] = []
        public var owners: [String] = []
        public var models: [String] = []
        public var access: [String] = []

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            availability = (try? c.decode([String].self, forKey: .availability)) ?? []
            runtimes = (try? c.decode([String].self, forKey: .runtimes)) ?? []
            owners = (try? c.decode([String].self, forKey: .owners)) ?? []
            models = (try? c.decode([String].self, forKey: .models)) ?? []
            access = (try? c.decode([String].self, forKey: .access)) ?? []
        }

        public subscript(key: FilterKey) -> [String] {
            get {
                switch key {
                case .availability: return availability
                case .runtimes: return runtimes
                case .owners: return owners
                case .models: return models
                case .access: return access
                }
            }
            set {
                switch key {
                case .availability: availability = newValue
                case .runtimes: runtimes = newValue
                case .owners: owners = newValue
                case .models: models = newValue
                case .access: access = newValue
                }
            }
        }

        public var activeDimensionCount: Int {
            FilterKey.allCases.filter { !self[$0].isEmpty }.count
        }
    }

    /// Persisted per workspace (upstream `multica_agents_view`).
    public struct ViewState: Sendable, Hashable, Codable {
        public var scope: ListScope = .mine
        public var sortField: SortField = .lastActive
        public var sortDirection: SortDirection = .desc
        public var hiddenColumns: [Column] = Column.defaultHidden
        public var filters = ListFilters()

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scope = (try? c.decode(ListScope.self, forKey: .scope)) ?? .mine
            sortField = (try? c.decode(SortField.self, forKey: .sortField)) ?? .lastActive
            sortDirection = (try? c.decode(SortDirection.self, forKey: .sortDirection)) ?? sortField.defaultDirection
            hiddenColumns = (try? c.decode([Column].self, forKey: .hiddenColumns)) ?? Column.defaultHidden
            filters = (try? c.decode(ListFilters.self, forKey: .filters)) ?? ListFilters()
        }

        /// "Mine" is the clean personal view: entering it clears filters.
        public mutating func setScope(_ s: ListScope) {
            scope = s
            if s == .mine { filters = ListFilters() }
        }

        /// Header click: flips direction on the active field, otherwise
        /// switches field with its default direction.
        public mutating func toggleSort(_ field: SortField) {
            if sortField == field {
                sortDirection = sortDirection.toggled
            } else {
                sortField = field
                sortDirection = field.defaultDirection
            }
        }

        public mutating func setSortField(_ field: SortField) {
            guard sortField != field else { return }
            sortField = field
            sortDirection = field.defaultDirection
        }

        public mutating func toggleColumn(_ c: Column) {
            if let i = hiddenColumns.firstIndex(of: c) { hiddenColumns.remove(at: i) } else { hiddenColumns.append(c) }
        }

        public func isVisible(_ c: Column) -> Bool { !hiddenColumns.contains(c) }

        /// Applying any filter leaves "mine" for "all".
        public mutating func toggleFilter(_ key: FilterKey, _ value: String) {
            var list = filters[key]
            if let i = list.firstIndex(of: value) { list.remove(at: i) } else { list.append(value) }
            filters[key] = list
            if scope == .mine { scope = .all }
        }

        public mutating func clearFilters() { filters = ListFilters() }
    }

    public struct ListRow: Sendable, Hashable, Identifiable {
        public var agent: AgentRecord
        public var runtime: RuntimeDeviceRecord?
        public var presence: Presence?
        public var activity: Activity?
        public var runCount: Int
        public var lastActiveDays: Int?
        public var isOwnedByMe: Bool
        public var canManage: Bool
        public var id: String { agent.id }

        public init(agent: AgentRecord, runtime: RuntimeDeviceRecord?, presence: Presence?, activity: Activity?, runCount: Int,
                    lastActiveDays: Int?, isOwnedByMe: Bool, canManage: Bool) {
            self.agent = agent
            self.runtime = runtime
            self.presence = presence
            self.activity = activity
            self.runCount = runCount
            self.lastActiveDays = lastActiveDays
            self.isOwnedByMe = isOwnedByMe
            self.canManage = canManage
        }

        public var accessScope: AccessScope {
            AgentsUI.accessScope(permissionMode: agent.permissionMode, targets: agent.invocationTargets)
        }
    }

    public struct ScopeCounts: Sendable, Hashable {
        public var mine = 0
        public var all = 0
        public var archived = 0

        public init(mine: Int = 0, all: Int = 0, archived: Int = 0) {
            self.mine = mine
            self.all = all
            self.archived = archived
        }

        public subscript(scope: ListScope) -> Int {
            switch scope {
            case .mine: return mine
            case .all: return all
            case .archived: return archived
            }
        }
    }

    public static func scopeCounts(_ agents: [AgentRecord], userID: String?) -> ScopeCounts {
        var c = ScopeCounts()
        for a in agents {
            if a.archivedAt != nil { c.archived += 1; continue }
            c.all += 1
            if let userID, a.ownerId == userID { c.mine += 1 }
        }
        return c
    }

    public static func inScope(_ agent: AgentRecord, scope: ListScope, userID: String?) -> Bool {
        switch scope {
        case .archived: return agent.archivedAt != nil
        case .all: return agent.archivedAt == nil
        case .mine: return agent.archivedAt == nil && userID != nil && agent.ownerId == userID
        }
    }

    /// Search over name + description. `latinize` adds a transliterated form
    /// (pinyin for CJK names) so typing Latin letters matches.
    public static func matchesSearch(_ agent: AgentRecord, query: String, latinize: ((String) -> String)? = nil) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        if agent.name.lowercased().contains(q) || agent.description.lowercased().contains(q) { return true }
        guard let latinize else { return false }
        let squashed = q.replacingOccurrences(of: " ", with: "")
        for text in [agent.name, agent.description] where !text.isEmpty {
            let latin = latinize(text).lowercased()
            if latin.contains(q) || latin.replacingOccurrences(of: " ", with: "").contains(squashed) { return true }
            let initials = latin.split(separator: " ").compactMap(\.first).map(String.init).joined()
            if initials.contains(squashed) { return true }
        }
        return false
    }

    public static func rowMatches(_ row: ListRow, filters: ListFilters, query: String, latinize: ((String) -> String)? = nil) -> Bool {
        guard matchesSearch(row.agent, query: query, latinize: latinize) else { return false }
        if !filters.availability.isEmpty {
            guard let p = row.presence, filters.availability.contains(p.availability.rawValue) else { return false }
        }
        if !filters.runtimes.isEmpty, !filters.runtimes.contains(row.agent.runtimeId) { return false }
        if !filters.owners.isEmpty {
            guard let owner = row.agent.ownerId, filters.owners.contains(owner) else { return false }
        }
        if !filters.models.isEmpty, !filters.models.contains(row.agent.model) { return false }
        if !filters.access.isEmpty, !filters.access.contains(row.accessScope.rawValue) { return false }
        return true
    }

    public static func sortRows(_ rows: [ListRow], field: SortField, direction: SortDirection) -> [ListRow] {
        let dir = direction == .asc ? 1 : -1
        func byName(_ a: ListRow, _ b: ListRow) -> Int {
            switch a.agent.name.localizedCompare(b.agent.name) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            }
        }
        return rows.sorted { a, b in
            switch field {
            case .name:
                return byName(a, b) * dir < 0
            case .runs:
                let d = (a.runCount - b.runCount) * dir
                return d != 0 ? d < 0 : byName(a, b) < 0
            case .created:
                let ad = Timestamp.parse(a.agent.createdAt) ?? .distantPast
                let bd = Timestamp.parse(b.agent.createdAt) ?? .distantPast
                return dir > 0 ? ad < bd : ad > bd
            case .lastActive:
                let av = a.lastActiveDays ?? Int.max
                let bv = b.lastActiveDays ?? Int.max
                if av != bv { return direction == .desc ? av < bv : av > bv }
                if a.runCount != b.runCount { return a.runCount > b.runCount }
                return byName(a, b) < 0
            }
        }
    }
}

// MARK: - Runtimes

extension AgentsUI {
    private static let providerDisplayNames: [String: String] = [
        "codearts": "CodeArts", "dsh": "DeepSeek Harness", "qoderclicn": "Qoder CN", "traecli": "Trae",
        "qwen": "Qwen Code", "qwenpaw": "QwenPaw", "mcode": "MiniMax Code", "omp": "Oh-My-Pi", "zeroclaw": "ZeroClaw",
    ]

    public static func providerDisplayName(_ provider: String) -> String {
        if let known = providerDisplayNames[provider] { return known }
        guard let first = provider.first else { return provider }
        return first.uppercased() + provider.dropFirst()
    }

    public static func runtimeDisplayName(_ r: RuntimeDeviceRecord) -> String {
        let custom = r.customName?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? r.name : custom
    }

    /// Custom-named runtimes carry the provider so two renamed runtimes on one
    /// machine stay distinguishable.
    public static func runtimeDisplayLabel(_ r: RuntimeDeviceRecord) -> String {
        let display = runtimeDisplayName(r)
        let hasCustom = !(r.customName?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty
        let provider = r.provider.trimmingCharacters(in: .whitespaces)
        guard hasCustom, !provider.isEmpty else { return display }
        return "\(display) (\(providerDisplayName(provider)))"
    }

    /// `"Claude (MacBook)"` → base "Claude", hostname "MacBook".
    public static func splitRuntimeName(_ name: String) -> (base: String, hostname: String?) {
        guard name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) else { return (name, nil) }
        let base = String(name[..<open.lowerBound])
        let host = String(name[open.upperBound..<name.index(before: name.endIndex)])
        guard !base.isEmpty, !host.isEmpty, !host.contains("("), !host.contains(")") else { return (name, nil) }
        return (base.trimmingCharacters(in: .whitespaces), host)
    }

    public static func runtimeRowLabel(_ r: RuntimeDeviceRecord, machineTitle: String) -> String {
        let custom = r.customName?.trimmingCharacters(in: .whitespaces) ?? ""
        if !custom.isEmpty, custom != machineTitle { return custom }
        return splitRuntimeName(r.name).base
    }

    public enum MachineSection: Int, Sendable { case local = 0, remote, cloud }

    public struct RuntimeMachine: Sendable, Hashable, Identifiable {
        public var id: String
        public var daemonId: String?
        public var title: String
        public var mode: String
        public var section: MachineSection
        public var runtimes: [RuntimeDeviceRecord]
        public var onlineCount: Int
        public var providerNames: [String]
    }

    static func runtimeDeviceName(_ r: RuntimeDeviceRecord) -> String? {
        if let host = splitRuntimeName(r.name).hostname { return host }
        let raw = r.deviceInfo.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let first = raw.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? nil : first
    }

    static func runtimeMachineID(_ r: RuntimeDeviceRecord) -> String {
        if let d = r.daemonId, !d.isEmpty { return "\(r.runtimeMode):\(d)" }
        if let device = runtimeDeviceName(r) { return "\(r.runtimeMode):device:\(device)" }
        return "\(r.runtimeMode):runtime:\(r.id)"
    }

    static func sharedCustomName(_ runtimes: [RuntimeDeviceRecord]) -> String? {
        let names = runtimes.map { $0.customName?.trimmingCharacters(in: .whitespaces) ?? "" }
        guard let first = names.first, !first.isEmpty else { return nil }
        return names.allSatisfy { $0 == first } ? first : nil
    }

    /// Groups runtimes by the daemon (machine) that hosts them, sorted local →
    /// remote → cloud, then by online count and title.
    public static func runtimeMachines(_ runtimes: [RuntimeDeviceRecord], now: Date) -> [RuntimeMachine] {
        var order: [String] = []
        var groups: [String: [RuntimeDeviceRecord]] = [:]
        for r in runtimes {
            let id = runtimeMachineID(r)
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(r)
        }
        let machines = order.map { id -> RuntimeMachine in
            let list = (groups[id] ?? []).sorted { $0.provider < $1.provider }
            let first = list.first
            let title: String
            if let shared = sharedCustomName(list) {
                title = shared
            } else if let first, let device = runtimeDeviceName(first) {
                title = device
            } else if let first, first.runtimeMode == "cloud" {
                title = "\(first.provider.prefix(1).uppercased() + first.provider.dropFirst()) cloud"
            } else if let d = first?.daemonId, !d.isEmpty {
                title = String(d.prefix(8))
            } else {
                title = "Unknown machine"
            }
            let mode = first?.runtimeMode ?? "local"
            let online = list.filter { runtimeHealth(status: $0.status, lastSeenAt: $0.lastSeenAt, now: now) == .online }.count
            return RuntimeMachine(id: id, daemonId: first?.daemonId, title: title, mode: mode,
                                  section: mode == "cloud" ? .cloud : .remote, runtimes: list, onlineCount: online,
                                  providerNames: Array(Set(list.map(\.provider))).sorted())
        }
        return machines.sorted { a, b in
            if a.section != b.section { return a.section.rawValue < b.section.rawValue }
            if a.onlineCount != b.onlineCount { return a.onlineCount > b.onlineCount }
            return a.title.localizedCompare(b.title) == .orderedAscending
        }
    }

    public static func filterMachines(_ machines: [RuntimeMachine], query: String) -> [RuntimeMachine] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return machines }
        return machines.filter { m in
            let hay = ([m.title, m.daemonId ?? "", m.providerNames.joined(separator: " ")]
                + m.runtimes.map(\.name) + m.runtimes.map { $0.customName ?? "" } + m.runtimes.map(\.deviceInfo))
                .joined(separator: " ").lowercased()
            return hay.contains(q)
        }
    }

    /// Create-flow ordering: mine first, then usable, otherwise stable.
    public static func createPickerRuntimes(_ runtimes: [RuntimeDeviceRecord], mineOnly: Bool, userID: String?) -> [RuntimeDeviceRecord] {
        let base = mineOnly && userID != nil ? runtimes.filter { $0.ownerId == userID } : runtimes
        return base.enumerated().sorted { x, y in
            let a = x.element, b = y.element
            let aMine = a.ownerId == userID, bMine = b.ownerId == userID
            if aMine != bMine { return aMine }
            let aUsable = isRuntimeUsable(a, userID: userID), bUsable = isRuntimeUsable(b, userID: userID)
            if aUsable != bUsable { return aUsable }
            return x.offset < y.offset
        }.map(\.element)
    }
}

// MARK: - Provider capabilities

extension AgentsUI {
    /// Providers whose backend forwards `agent.mcp_config` to the CLI; the MCP
    /// tab is hidden for every other provider.
    public static let mcpSupportedProviders: Set<String> = [
        "claude", "codebuddy", "codearts", "codex", "cursor", "grok", "hermes", "kimi", "reasonix", "dsh", "kiro",
        "opencode", "openclaw", "pi", "qoder", "qoderclicn", "qwen", "qwenpaw", "mcode", "traecli", "dim", "omp",
    ]

    public static func providerSupportsMcp(_ provider: String?) -> Bool {
        guard let provider else { return false }
        return mcpSupportedProviders.contains(provider)
    }
}

// MARK: - Model capability

extension AgentsUI {
    public struct ModelsResult: Sendable, Hashable {
        public var models: [RuntimeModel]
        public var unavailableModels: [RuntimeUnavailableModel]
        public var supported: Bool
        public var cached: Bool

        public init(models: [RuntimeModel], unavailableModels: [RuntimeUnavailableModel], supported: Bool, cached: Bool) {
            self.models = models
            self.unavailableModels = unavailableModels
            self.supported = supported
            self.cached = cached
        }
    }

    /// Claude appends a numeric context-window tag (`claude-opus-5[1m]`);
    /// capability lookups ignore it.
    public static func modelIDForCapabilityLookup(provider: String, model: String) -> String {
        guard provider == "claude", model.hasSuffix("]"), let open = model.lastIndex(of: "[") else { return model }
        let tag = model[model.index(after: open)..<model.index(before: model.endIndex)]
        guard let unit = tag.last, unit == "k" || unit == "m" else { return model }
        let digits = tag.dropLast()
        guard let first = digits.first, first != "0", digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return model }
        return String(model[..<open])
    }

    public static func findModelCapabilityEntry(_ models: [RuntimeModel], model: String, provider: String) -> RuntimeModel? {
        guard !model.isEmpty else { return nil }
        let id = modelIDForCapabilityLookup(provider: provider, model: model)
        return models.first { modelIDForCapabilityLookup(provider: provider, model: $0.id) == id }
    }

    /// The model whose thinking levels the Thinking field offers: the exact
    /// model, or (when following the runtime default) the catalog default,
    /// except for providers whose default cannot be previewed.
    public static func thinkingModelEntry(_ models: [RuntimeModel], model: String, provider: String) -> RuntimeModel? {
        if !model.isEmpty { return findModelCapabilityEntry(models, model: model, provider: provider) }
        if provider == "codex" || provider == "omp" { return nil }
        return models.first { $0.default == true } ?? models.first
    }

    public struct ModelChange: Sendable, Hashable {
        public var model: String
        public var thinkingLevel: String?
        public var serviceTier: String?

        public var patch: [String: JSONValue] {
            var p: [String: JSONValue] = ["model": .string(model)]
            if let thinkingLevel { p["thinking_level"] = .string(thinkingLevel) }
            if let serviceTier { p["service_tier"] = .string(serviceTier) }
            return p
        }
    }

    /// Clears only the per-model overrides the authoritative catalog says the
    /// new model does not support; unknown catalog or model leaves them.
    public static func modelChange(provider: String, model: String, thinkingLevel: String, serviceTier: String, catalog: [RuntimeModel]?) -> ModelChange {
        var change = ModelChange(model: model)
        if thinkingLevel.isEmpty && serviceTier.isEmpty { return change }
        guard let catalog, !model.isEmpty, let entry = findModelCapabilityEntry(catalog, model: model, provider: provider) else { return change }
        let supportsThinking = (entry.thinking?.supportedLevels ?? []).contains { $0.value == thinkingLevel }
        if !thinkingLevel.isEmpty && !supportsThinking { change.thinkingLevel = "" }
        let supportsTier = (entry.serviceTiers ?? []).contains { $0.id == serviceTier }
            || (serviceTier == "default" && catalog.contains { $0.supportsExplicitStandardServiceTier == true })
        if !serviceTier.isEmpty && !supportsTier { change.serviceTier = "" }
        return change
    }
}

// MARK: - Task outcomes

extension AgentsUI {
    /// Server failure taxonomy → `task_failure.reasons.*` key.
    public static let failureReasonKeys: [String: String] = [
        "queued_expired": "queued_expired", "runtime_offline": "runtime_offline",
        "runtime_reconnect_timeout": "runtime_reconnect_timeout", "runtime_recovery": "runtime_recovery",
        "timeout": "timeout", "iteration_limit": "iteration_limit", "agent_blocked": "agent_blocked",
        "api_invalid_request": "api_invalid_request", "skill_bundle_unavailable": "skill_bundle_unavailable",
        "runtime_cli_timeout": "runtime_cli_timeout", "environment_prepare_failed": "environment_prepare_failed",
        "invalid_task_identity": "invalid_task_identity", "runtime_access_denied": "runtime_access_denied",
        "agent_error.provider_auth_or_access": "agent_error_provider_auth_or_access",
        "agent_error.provider_quota_limit": "agent_error_provider_quota_limit",
        "agent_error.provider_capacity_or_rate_limit": "agent_error_provider_capacity_or_rate_limit",
        "agent_error.provider_server_error": "agent_error_provider_server_error",
        "agent_error.provider_network": "agent_error_provider_network",
        "agent_error.process_failure": "agent_error_process_failure",
        "agent_error.empty_or_unparseable_output": "agent_error_empty_or_unparseable_output",
        "agent_error.agent_timeout": "agent_error_agent_timeout",
        "agent_error.context_overflow": "agent_error_context_overflow",
        "agent_error.missing_config": "agent_error_missing_config",
        "agent_error.model_not_found_or_unavailable": "agent_error_model_not_found_or_unavailable",
        "agent_error.runtime_version_unsupported": "agent_error_runtime_version_unsupported",
        "agent_error.runtime_missing_executable": "agent_error_runtime_missing_executable",
        "agent_error.unknown": "agent_error_unknown",
        "agent_fallback_message": "agent_fallback_message", "codex_semantic_inactivity": "codex_semantic_inactivity",
        "codex_resume_oversized": "codex_resume_oversized", "idle_watchdog": "idle_watchdog",
        "local_directory_error": "local_directory_error", "cancelled": "cancelled",
        "agent_error": "agent_error", "manual": "manual", "user_cancelled": "user_cancelled",
    ]

    public enum FailureLabel: Sendable, Hashable {
        /// A `task_failure.reasons.<key>` translation.
        case key(String)
        /// An unknown reason, shown verbatim.
        case raw(String)
    }

    public static func failureLabel(_ reason: String?) -> FailureLabel? {
        guard let reason, !reason.isEmpty else { return nil }
        if let key = failureReasonKeys[reason] { return .key(key) }
        return .raw(reason)
    }

    /// Whether a chat's empty state may offer "customize starters" for this
    /// agent: live agent, backend support, and edit rights.
    public static func canCustomizeConversationStarters(_ agent: AgentRecord?, supported: Bool, canEdit: Bool) -> Bool {
        guard let agent, agent.archivedAt == nil, supported else { return false }
        return canEdit
    }

    /// Picks the configured starters when complete, else the fallbacks.
    public static func selectConversationStarters(_ configured: [AgentConversationStarter]?, fallback: [AgentConversationStarter])
        -> (starters: [AgentConversationStarter], isFallback: Bool) {
        let complete = (configured ?? []).filter {
            !$0.label.trimmingCharacters(in: .whitespaces).isEmpty && !$0.prompt.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return complete.isEmpty ? (fallback, true) : (complete, false)
    }
}
