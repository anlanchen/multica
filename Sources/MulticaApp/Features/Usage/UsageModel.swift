import Foundation
import MulticaCore
import Observation

/// One chart's buckets with values aligned to its series.
struct UsageChartData: Equatable, Sendable {
    struct Bucket: Equatable, Sendable, Identifiable {
        var key: String
        var label: String
        var title: String
        var partial: Bool
        var daysCovered: Int
        var values: [Double]
        /// Failed / total runs (errors charts' tooltip rate).
        var failed = 0
        var total = 0
        var id: String { key }
    }

    var buckets: [Bucket] = []
    /// Series ids present (errors charts draw only the classes that occurred).
    var seriesIDs: [String] = []
    var sum: Double = 0

    static func stack(_ b: [UsageBucket<UsageTokenStack>]) -> UsageChartData {
        var out = UsageChartData(seriesIDs: ["input", "output", "cacheRead", "cacheWrite"])
        out.buckets = b.map { Bucket(key: $0.key, label: $0.label, title: $0.title, partial: $0.week?.partial ?? false,
                                     daysCovered: $0.week?.daysCovered ?? 7,
                                     values: [$0.value.input, $0.value.output, $0.value.cacheRead, $0.value.cacheWrite]) }
        out.sum = b.reduce(0) { $0 + $1.value.total }
        return out
    }

    static func time(_ b: [UsageBucket<Int>]) -> UsageChartData {
        var out = UsageChartData(seriesIDs: ["totalSeconds"])
        out.buckets = b.map { Bucket(key: $0.key, label: $0.label, title: $0.title, partial: $0.week?.partial ?? false,
                                     daysCovered: $0.week?.daysCovered ?? 7, values: [Double($0.value)]) }
        out.sum = Double(b.reduce(0) { $0 + $1.value })
        return out
    }

    static func tasks(_ b: [UsageBucket<UsageTaskStack>]) -> UsageChartData {
        var out = UsageChartData(seriesIDs: ["completed", "cancelled", "failed"])
        out.buckets = b.map { Bucket(key: $0.key, label: $0.label, title: $0.title, partial: $0.week?.partial ?? false,
                                     daysCovered: $0.week?.daysCovered ?? 7,
                                     values: [Double($0.value.completed), Double($0.value.cancelled), Double($0.value.failed)]) }
        // Upstream's emptiness check counts completed + failed only.
        out.sum = Double(b.reduce(0) { $0 + $1.value.completed + $1.value.failed })
        return out
    }

    static func errors(_ b: [UsageBucket<UsageClassCounts>]) -> UsageChartData {
        let classes = UsageDashboard.activeClasses(b)
        var out = UsageChartData(seriesIDs: classes.map(\.rawValue))
        out.buckets = b.map { bucket in
            Bucket(key: bucket.key, label: bucket.label, title: bucket.title, partial: bucket.week?.partial ?? false,
                   daysCovered: bucket.week?.daysCovered ?? 7, values: classes.map { Double(bucket.value[$0]) },
                   failed: bucket.value.failed, total: bucket.value.total)
        }
        out.sum = Double(b.reduce(0) { $0 + $1.value.failed })
        return out
    }
}

struct UsageCharts: Equatable, Sendable {
    var dailyCost = UsageChartData()
    var dailyTokens = UsageChartData()
    var dailyTime = UsageChartData()
    var dailyTasks = UsageChartData()
    var dailyErrors = UsageChartData()
    var weeklyCost = UsageChartData()
    var weeklyTokens = UsageChartData()
    var weeklyTime = UsageChartData()
    var weeklyTasks = UsageChartData()
    var weeklyErrors = UsageChartData()

    init() {}

    init(_ s: UsageDashboardSnapshot) {
        dailyCost = .stack(s.dailyCost)
        dailyTokens = .stack(s.dailyTokens)
        dailyTime = .time(s.dailyTime)
        dailyTasks = .tasks(s.dailyTasks)
        dailyErrors = .errors(s.dailyErrors)
        weeklyCost = .stack(s.weeklyCost)
        weeklyTokens = .stack(s.weeklyTokens)
        weeklyTime = .time(s.weeklyTime)
        weeklyTasks = .tasks(s.weeklyTasks)
        weeklyErrors = .errors(s.weeklyErrors)
    }
}

struct UsageAgentInfo: Equatable, Sendable {
    var name: String
    var avatarURL: String?
}

/// Fetches the six dashboard rollups for the page scope and derives the
/// snapshot off the main actor.
@MainActor
@Observable
final class UsageModel {
    private(set) var snapshot = UsageDashboardSnapshot()
    private(set) var charts = UsageCharts()
    private(set) var hasUsageData = false
    private(set) var hasErrorData = false
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var timezone = TimeZone.current.identifier
    /// Snapshot days (KPI labels follow the data on screen while a range change loads).
    private(set) var snapshotDays = 30
    /// Names and avatars of every agent the viewer can resolve (archived included).
    private(set) var agents: [String: UsageAgentInfo] = [:]

    @ObservationIgnored private var raw: UsageDashboardInput?
    @ObservationIgnored private var scopeKey: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timezoneLoaded = false

    func load(session: WorkspaceSession, days: Int, projectID: String?) async {
        if !timezoneLoaded {
            timezoneLoaded = true
            if let tz = try? await session.api.getMe().timezone?.trimmingCharacters(in: .whitespaces), !tz.isEmpty,
               TimeZone(identifier: tz) != nil {
                timezone = tz
            }
        }
        let scope = "\(projectID ?? "")|\(timezone)"
        if scopeKey != scope {
            // Scope changes never carry the previous scope's numbers over.
            scopeKey = scope
            raw = nil
            hasUsageData = false
            hasErrorData = false
            snapshot = UsageDashboardSnapshot()
            charts = UsageCharts()
        }
        generation += 1
        let gen = generation
        isRefreshing = true
        defer { if gen == generation { isRefreshing = false } }

        let api = session.api
        let tz = timezone
        let fetchDays = UsageDashboardInput.chartFetchDays(days)
        async let daily = api.getDashboardUsageDaily(days: fetchDays, projectId: projectID, tz: tz)
        async let byAgent = api.getDashboardUsageByAgent(days: days, projectId: projectID, tz: tz)
        async let runTime = api.getDashboardAgentRunTime(days: days, projectId: projectID, tz: tz)
        async let runTimeDaily = api.getDashboardRunTimeDaily(days: fetchDays, projectId: projectID, tz: tz)
        async let failuresDaily = api.getDashboardFailuresDaily(days: fetchDays, projectId: projectID, tz: tz)
        async let failuresByAgent = api.getDashboardFailuresByAgent(days: days, projectId: projectID, tz: tz)
        async let agents: Void = session.agentRecords.loadIfNeeded()

        var input = UsageDashboardInput(days: days, today: UsageCalendar.today(in: tz))
        let prev = raw
        input.daily = (try? await daily) ?? prev?.daily ?? []
        input.byAgent = (try? await byAgent) ?? prev?.byAgent ?? []
        input.runTime = (try? await runTime) ?? prev?.runTime ?? []
        input.runTimeDaily = (try? await runTimeDaily) ?? prev?.runTimeDaily ?? []
        input.failuresDaily = (try? await failuresDaily) ?? prev?.failuresDaily ?? []
        input.failuresByAgent = (try? await failuresByAgent) ?? prev?.failuresByAgent ?? []
        _ = await agents
        guard gen == generation else { return }
        raw = input
        lastUpdated = Date()
        hasUsageData = true
        hasErrorData = true
        await recompute(session: session)
    }

    /// Re-derives from the last fetch (agents or custom pricing changed).
    func recompute(session: WorkspaceSession) async {
        guard var input = raw else { return }
        if session.agentRecords.isLoaded {
            input.knownAgentIDs = Set(session.agentRecords.items.map(\.id))
            agents = Dictionary(session.agentRecords.items.map { ($0.id, UsageAgentInfo(name: $0.name, avatarURL: $0.avatarUrl)) },
                                uniquingKeysWith: { a, _ in a })
        }
        input.pricing = UsagePricing(custom: Self.customPricing())
        let gen = generation
        let result = await Task.detached(priority: .userInitiated) { () -> (UsageDashboardSnapshot, UsageCharts) in
            let s = UsageDashboardSnapshot(input)
            return (s, UsageCharts(s))
        }.value
        guard gen == generation else { return }
        snapshot = result.0
        charts = result.1
        snapshotDays = input.days
    }

    nonisolated static func customPricing() -> [String: UsageModelPricing] {
        let d = UserDefaults.standard
        if let data = d.data(forKey: UsagePricing.customPricingStorageKey) { return UsagePricing.decodeCustomPricing(data) }
        if let s = d.string(forKey: UsagePricing.customPricingStorageKey) { return UsagePricing.decodeCustomPricing(Data(s.utf8)) }
        return [:]
    }
}
