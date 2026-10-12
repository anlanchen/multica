import Foundation

// Workspace usage dashboard aggregation (upstream packages/views/dashboard/utils.ts
// and the calendar helpers it borrows from runtimes/utils.ts). All date math
// runs on YYYY-MM-DD strings already bucketed in the viewer's timezone.

public enum UsageCalendar {
    private static let utc = TimeZone(identifier: "UTC")!

    private static func components(_ iso: String) -> DateComponents {
        let parts = iso.split(separator: "-").map { Int($0) ?? 1 }
        return DateComponents(year: parts.first ?? 1970, month: parts.count > 1 ? parts[1] : 1, day: parts.count > 2 ? parts[2] : 1)
    }

    private static var gregorianUTC: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c
    }

    private static func date(_ iso: String) -> Date {
        gregorianUTC.date(from: components(iso)) ?? Date(timeIntervalSince1970: 0)
    }

    private static func iso(_ date: Date) -> String {
        let c = gregorianUTC.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// Today's calendar date in an IANA timezone (falls back to the system zone).
    public static func today(in tz: String, now: Date = Date()) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz) ?? .current
        let d = c.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", d.year ?? 1970, d.month ?? 1, d.day ?? 1)
    }

    public static func addDays(_ iso: String, _ days: Int) -> String {
        Self.iso(gregorianUTC.date(byAdding: .day, value: days, to: date(iso)) ?? date(iso))
    }

    /// Monday of the ISO week containing `iso`.
    public static func weekStart(_ iso: String) -> String {
        let weekday = gregorianUTC.component(.weekday, from: date(iso)) // 1 = Sunday
        return addDays(iso, -((weekday + 5) % 7))
    }

    public static func diffDays(_ from: String, _ to: String) -> Int {
        Int(((date(to).timeIntervalSince1970 - date(from).timeIntervalSince1970) / 86_400).rounded())
    }

    /// "May 12" (upstream formats with the `en` locale regardless of UI language).
    public static func shortDate(_ iso: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc
        f.dateFormat = "MMM d"
        return f.string(from: date(iso))
    }

    /// "5/12" axis label.
    public static func dayLabel(_ iso: String) -> String {
        let c = components(iso)
        return "\(c.month ?? 1)/\(c.day ?? 1)"
    }
}

public enum UsageFailureClass: String, CaseIterable, Sendable, Hashable {
    case auth, rateLimit = "rate_limit", timeout, provider, runtime, agent, other

    private static let reasons: [String: UsageFailureClass] = [
        "agent_error.provider_auth_or_access": .auth,
        "agent_error.missing_config": .auth,
        "agent_error.provider_capacity_or_rate_limit": .rateLimit,
        "agent_error.provider_quota_limit": .rateLimit,
        "timeout": .timeout,
        "agent_error.agent_timeout": .timeout,
        "codex_semantic_inactivity": .timeout,
        "agent_error.provider_server_error": .provider,
        "agent_error.provider_network": .provider,
        "agent_error.model_not_found_or_unavailable": .provider,
        "api_invalid_request": .provider,
        "runtime_offline": .runtime,
        "runtime_recovery": .runtime,
        "queued_expired": .runtime,
        "agent_error.runtime_missing_executable": .runtime,
        "agent_error.runtime_version_unsupported": .runtime,
        "skill_bundle_unavailable": .runtime,
        "runtime_cli_timeout": .runtime,
        "environment_prepare_failed": .runtime,
        "agent_error.process_failure": .agent,
        "codex_resume_oversized": .agent,
        "agent_error.empty_or_unparseable_output": .agent,
        "agent_error.context_overflow": .agent,
        "iteration_limit": .agent,
        "agent_blocked": .agent,
        "agent_error.unknown": .other,
        "agent_error": .other,
        "manual": .other,
        "unclassified": .other,
    ]

    /// Unknown reasons (including ones from a newer backend) land in `other`.
    public init(reason: String) {
        self = Self.reasons[reason] ?? .other
    }
}

public struct UsageClassCounts: Sendable, Hashable {
    public var counts: [UsageFailureClass: Int] = [:]
    public var failed = 0
    public var total = 0

    public init() {}

    public subscript(c: UsageFailureClass) -> Int { counts[c] ?? 0 }

    mutating func fold(reason: String, count: Int) {
        total += count
        guard !reason.isEmpty else { return }
        failed += count
        counts[UsageFailureClass(reason: reason), default: 0] += count
    }
}

public struct UsageWeek: Sendable, Hashable {
    public var weekStart: String
    public var weekEnd: String
    public var label: String
    public var rangeLabel: String
    public var partial: Bool
    public var daysCovered: Int
}

/// One x-axis bucket of a dashboard chart (a day or a week).
public struct UsageBucket<Value: Sendable & Hashable>: Sendable, Hashable, Identifiable {
    public var key: String
    public var label: String
    /// Tooltip header: the date, or the week range.
    public var title: String
    public var week: UsageWeek?
    public var value: Value
    public var id: String { key }
}

public struct UsageTokenStack: Sendable, Hashable {
    public var input = 0.0
    public var output = 0.0
    public var cacheRead = 0.0
    public var cacheWrite = 0.0
    public var total: Double { input + output + cacheRead + cacheWrite }
}

public struct UsageTaskStack: Sendable, Hashable {
    public var completed = 0
    public var failed = 0
    public var cancelled = 0
}

public struct UsageTokenTotals: Sendable, Hashable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var cost = 0.0
    public var taskCount = 0
    public var tokens: Int { input + output + cacheRead + cacheWrite }
}

public struct UsageAgentCostRow: Sendable, Hashable {
    public var agentID: String
    public var tokens = 0
    public var cost = 0.0
    public var taskCount = 0
}

public struct UsageAgentRow: Sendable, Hashable, Identifiable {
    public var agentID: String
    public var tokens: Int
    public var cost: Double
    public var seconds: Int
    public var taskCount: Int
    public var unreportedTaskCount: Int
    public var hasReportedUsage: Bool
    public var hasUsageTotals: Bool
    public var id: String { agentID }
}

public enum UsageLeaderboardSort: String, CaseIterable, Sendable {
    case tokens, cost, time, tasks

    public func metric(_ r: UsageAgentRow) -> Double {
        switch self {
        case .tokens: return Double(r.tokens)
        case .cost: return r.cost
        case .time: return Double(r.seconds)
        case .tasks: return Double(r.taskCount)
        }
    }
}

public struct UsageFailureTotals: Sendable, Hashable {
    public var failed = 0
    public var total = 0
    public var rate: Double { total > 0 ? Double(failed) / Double(total) : 0 }
}

public struct UsageFailureClassRow: Sendable, Hashable, Identifiable {
    public var failureClass: UsageFailureClass
    public var count: Int
    public var id: String { failureClass.rawValue }
}

public struct UsageFailureReasonRow: Sendable, Hashable, Identifiable {
    public var reason: String
    public var failureClass: UsageFailureClass
    public var count: Int
    public var id: String { reason }
}

public struct UsageAgentFailureRow: Sendable, Hashable, Identifiable {
    public var agentID: String
    public var failed: Int
    public var total: Int
    public var classes: [UsageFailureClass: Int]
    public var rate: Double { total > 0 ? Double(failed) / Double(total) : 0 }
    public var id: String { agentID }
}

public enum UsageOffenderSort: String, Sendable {
    case failed, rate

    public func metric(_ r: UsageAgentFailureRow) -> Double {
        self == .failed ? Double(r.failed) : r.rate
    }
}

public enum UsageDashboard {
    public static let deletedAgentsRowID = "__deleted_agents__"
    public static let restrictedAgentsRowID = "__restricted_agents__"
    public static let unresolvedAgentsRowID = "__unresolved_agents__"
    public static let minRateSample = 10

    public static func isSyntheticAgentRow(_ id: String) -> Bool {
        id == deletedAgentsRowID || id == restrictedAgentsRowID
    }

    // MARK: Ranges

    public struct TimeRange: Sendable, Hashable, Identifiable {
        public var label: String
        public var days: Int
        public var dims: [Dim]
        public var id: Int { days }
    }

    public enum Dim: String, Sendable, Hashable { case daily, weekly }

    public static let timeRanges: [TimeRange] = [
        TimeRange(label: "1d", days: 1, dims: [.daily]),
        TimeRange(label: "7d", days: 7, dims: [.daily]),
        TimeRange(label: "30d", days: 30, dims: [.daily, .weekly]),
        TimeRange(label: "90d", days: 90, dims: [.daily, .weekly]),
        TimeRange(label: "180d", days: 180, dims: [.weekly]),
    ]

    public static func dims(forDays days: Int) -> [Dim] {
        timeRanges.first { $0.days == days }?.dims ?? [.daily]
    }

    // MARK: Daily

    private static func round2(_ n: Double) -> Double { (n * 100).rounded() / 100 }

    private static func dayBucket<V>(_ date: String, _ value: V) -> UsageBucket<V> {
        UsageBucket(key: date, label: UsageCalendar.dayLabel(date), title: UsageCalendar.dayLabel(date), week: nil, value: value)
    }

    public static func dailyCost(_ usage: [DashboardUsageDaily], pricing: UsagePricing) -> [UsageBucket<UsageTokenStack>] {
        var map: [String: UsageTokenStack] = [:]
        for u in usage {
            let b = pricing.estimateCostBreakdown(u)
            map[u.date, default: UsageTokenStack()].input += b.input
            map[u.date]!.output += b.output
            map[u.date]!.cacheRead += b.cacheRead
            map[u.date]!.cacheWrite += b.cacheWrite
        }
        return map.keys.sorted().map { date in
            let s = map[date]!
            return dayBucket(date, UsageTokenStack(input: round2(s.input), output: round2(s.output),
                                                   cacheRead: round2(s.cacheRead), cacheWrite: round2(s.cacheWrite)))
        }
    }

    public static func dailyTokens(_ usage: [DashboardUsageDaily]) -> [UsageBucket<UsageTokenStack>] {
        var map: [String: UsageTokenStack] = [:]
        for u in usage {
            map[u.date, default: UsageTokenStack()].input += Double(u.inputTokens)
            map[u.date]!.output += Double(u.outputTokens)
            map[u.date]!.cacheRead += Double(u.cacheReadTokens)
            map[u.date]!.cacheWrite += Double(u.cacheWriteTokens)
        }
        return map.keys.sorted().map { dayBucket($0, map[$0]!) }
    }

    public static func dailyTime(_ rows: [DashboardRunTimeDaily]) -> [UsageBucket<Int>] {
        rows.sorted { $0.date < $1.date }.map { dayBucket($0.date, $0.totalSeconds) }
    }

    public static func taskStack(_ r: DashboardRunTimeDaily) -> UsageTaskStack {
        UsageTaskStack(completed: max(0, r.taskCount - r.failedCount - r.cancelledCount), failed: r.failedCount, cancelled: r.cancelledCount)
    }

    public static func dailyTasks(_ rows: [DashboardRunTimeDaily]) -> [UsageBucket<UsageTaskStack>] {
        rows.sorted { $0.date < $1.date }.map { dayBucket($0.date, taskStack($0)) }
    }

    public static func dailyErrors(_ rows: [DashboardFailureDaily]) -> [UsageBucket<UsageClassCounts>] {
        var map: [String: UsageClassCounts] = [:]
        for r in rows { map[r.date, default: UsageClassCounts()].fold(reason: r.failureReason, count: r.taskCount) }
        return map.keys.sorted().map { dayBucket($0, map[$0]!) }
    }

    public static func totals(_ usage: [DashboardUsageDaily], pricing: UsagePricing) -> UsageTokenTotals {
        usage.reduce(into: UsageTokenTotals()) { acc, u in
            acc.input += u.inputTokens
            acc.output += u.outputTokens
            acc.cacheRead += u.cacheReadTokens
            acc.cacheWrite += u.cacheWriteTokens
            acc.cost += pricing.estimateCost(u)
            acc.taskCount += u.taskCount
        }
    }

    // MARK: Weekly

    public static func weeks(today: String, count weekCount: Int) -> [UsageWeek] {
        let count = max(1, weekCount)
        let currentWeekStart = UsageCalendar.weekStart(today)
        let first = UsageCalendar.addDays(currentWeekStart, -(count - 1) * 7)
        return (0..<count).map { i in
            let start = UsageCalendar.addDays(first, i * 7)
            let end = UsageCalendar.addDays(start, 6)
            let partial = today < end
            let clamped = today < start ? start : (today < end ? today : end)
            let elapsed = min(7, max(1, UsageCalendar.diffDays(start, clamped) + 1))
            return UsageWeek(weekStart: start, weekEnd: end, label: UsageCalendar.shortDate(start),
                             rangeLabel: "\(UsageCalendar.shortDate(start)) – \(UsageCalendar.shortDate(end))",
                             partial: partial, daysCovered: partial ? elapsed : 7)
        }
    }

    private static func weekly<Row, V>(_ rows: [Row], today: String, weekCount: Int, zero: V,
                                       date: (Row) -> String, fold: (inout V, Row) -> Void) -> [UsageBucket<V>] {
        let shells = weeks(today: today, count: weekCount)
        var buckets: [String: V] = Dictionary(uniqueKeysWithValues: shells.map { ($0.weekStart, zero) })
        for r in rows {
            let start = UsageCalendar.weekStart(date(r))
            guard buckets[start] != nil else { continue }
            fold(&buckets[start]!, r)
        }
        return shells.map { UsageBucket(key: $0.weekStart, label: $0.label, title: $0.rangeLabel, week: $0, value: buckets[$0.weekStart] ?? zero) }
    }

    public static func weeklyCost(_ usage: [DashboardUsageDaily], pricing: UsagePricing, today: String, weekCount: Int) -> [UsageBucket<UsageTokenStack>] {
        weekly(usage, today: today, weekCount: weekCount, zero: UsageTokenStack(), date: \.date) { acc, u in
            let b = pricing.estimateCostBreakdown(u)
            acc.input += b.input
            acc.output += b.output
            acc.cacheRead += b.cacheRead
            acc.cacheWrite += b.cacheWrite
        }.map { b in
            var out = b
            out.value = UsageTokenStack(input: round2(b.value.input), output: round2(b.value.output),
                                        cacheRead: round2(b.value.cacheRead), cacheWrite: round2(b.value.cacheWrite))
            return out
        }
    }

    public static func weeklyTokens(_ usage: [DashboardUsageDaily], today: String, weekCount: Int) -> [UsageBucket<UsageTokenStack>] {
        weekly(usage, today: today, weekCount: weekCount, zero: UsageTokenStack(), date: \.date) { acc, u in
            acc.input += Double(u.inputTokens)
            acc.output += Double(u.outputTokens)
            acc.cacheRead += Double(u.cacheReadTokens)
            acc.cacheWrite += Double(u.cacheWriteTokens)
        }
    }

    public static func weeklyTime(_ rows: [DashboardRunTimeDaily], today: String, weekCount: Int) -> [UsageBucket<Int>] {
        weekly(rows, today: today, weekCount: weekCount, zero: 0, date: \.date) { $0 += $1.totalSeconds }
    }

    public static func weeklyTasks(_ rows: [DashboardRunTimeDaily], today: String, weekCount: Int) -> [UsageBucket<UsageTaskStack>] {
        weekly(rows, today: today, weekCount: weekCount, zero: UsageTaskStack(), date: \.date) { acc, r in
            let s = taskStack(r)
            acc.completed += s.completed
            acc.failed += s.failed
            acc.cancelled += s.cancelled
        }
    }

    public static func weeklyErrors(_ rows: [DashboardFailureDaily], today: String, weekCount: Int) -> [UsageBucket<UsageClassCounts>] {
        weekly(rows, today: today, weekCount: weekCount, zero: UsageClassCounts(), date: \.date) {
            $0.fold(reason: $1.failureReason, count: $1.taskCount)
        }
    }

    // MARK: Agents

    public static func agentTokens(_ rows: [DashboardUsageByAgent], pricing: UsagePricing) -> [UsageAgentCostRow] {
        var map: [String: UsageAgentCostRow] = [:]
        var order: [String] = []
        for r in rows {
            if map[r.agentId] == nil { order.append(r.agentId); map[r.agentId] = UsageAgentCostRow(agentID: r.agentId) }
            map[r.agentId]!.tokens += r.inputTokens + r.outputTokens + r.cacheReadTokens + r.cacheWriteTokens
            map[r.agentId]!.cost += pricing.estimateCost(r)
            map[r.agentId]!.taskCount += r.taskCount
        }
        return order.compactMap { map[$0] }.usageStableSorted { $0.cost > $1.cost }
    }

    public static func mergeAgentRows(_ tokenRows: [UsageAgentCostRow], _ runTimeRows: [DashboardAgentRunTime]) -> [UsageAgentRow] {
        let runTime = Dictionary(runTimeRows.map { ($0.agentId, $0) }, uniquingKeysWith: { a, _ in a })
        var merged: [UsageAgentRow] = []
        var seen = Set<String>()
        for r in tokenRows {
            let rt = runTime[r.agentID]
            let taskCount = rt?.taskCount ?? r.taskCount
            let metered = rt?.meteredTaskCount ?? taskCount
            merged.append(UsageAgentRow(agentID: r.agentID, tokens: r.tokens, cost: r.cost, seconds: rt?.totalSeconds ?? 0,
                                        taskCount: taskCount, unreportedTaskCount: max(0, taskCount - metered),
                                        hasReportedUsage: true, hasUsageTotals: true))
            seen.insert(r.agentID)
        }
        for r in runTimeRows where !seen.contains(r.agentId) {
            seen.insert(r.agentId)
            let known = r.meteredTaskCount != nil
            let metered = r.meteredTaskCount ?? 0
            merged.append(UsageAgentRow(agentID: r.agentId, tokens: 0, cost: 0, seconds: r.totalSeconds, taskCount: r.taskCount,
                                        unreportedTaskCount: known ? max(0, r.taskCount - metered) : 0,
                                        hasReportedUsage: known && metered > 0, hasUsageTotals: false))
        }
        return merged.usageStableSorted { a, b in
            a.cost != b.cost ? a.cost > b.cost : a.seconds > b.seconds
        }
    }

    /// Folds rows of hard-deleted agents into one bucket so the breakdown
    /// still reconciles with the KPI totals. `known == nil` (agents loading)
    /// passes rows through.
    public static func bucketUnknownAgents(_ rows: [UsageAgentRow], known: Set<String>?) -> [UsageAgentRow] {
        guard let known else { return rows }
        var out: [UsageAgentRow] = []
        var bucket = UsageAgentRow(agentID: deletedAgentsRowID, tokens: 0, cost: 0, seconds: 0, taskCount: 0,
                                   unreportedTaskCount: 0, hasReportedUsage: false, hasUsageTotals: false)
        var hasDeleted = false
        for r in rows {
            if known.contains(r.agentID) || r.agentID == restrictedAgentsRowID {
                out.append(r)
                continue
            }
            hasDeleted = true
            bucket.tokens += r.tokens
            bucket.cost += r.cost
            bucket.unreportedTaskCount += r.unreportedTaskCount
            bucket.hasReportedUsage = bucket.hasReportedUsage || r.hasReportedUsage
            bucket.hasUsageTotals = bucket.hasUsageTotals || r.hasUsageTotals
        }
        return hasDeleted ? out + [bucket] : out
    }

    public static func deletedAgentCount(_ rows: [UsageAgentRow], known: Set<String>?) -> Int {
        guard let known else { return 0 }
        return rows.filter { !known.contains($0.agentID) && !isSyntheticAgentRow($0.agentID) }.count
    }

    public static func sortLeaderboard(_ rows: [UsageAgentRow], by sort: UsageLeaderboardSort) -> [UsageAgentRow] {
        rows.usageStableSorted { sort.metric($0) > sort.metric($1) }
    }

    // MARK: Failures

    public static func failureTotals(_ rows: [DashboardFailureDaily]) -> UsageFailureTotals {
        rows.reduce(into: UsageFailureTotals()) { acc, r in
            acc.total += r.taskCount
            if !r.failureReason.isEmpty { acc.failed += r.taskCount }
        }
    }

    public static func failureClasses(_ rows: [DashboardFailureDaily]) -> [UsageFailureClassRow] {
        var counts: [UsageFailureClass: Int] = [:]
        for r in rows where !r.failureReason.isEmpty { counts[UsageFailureClass(reason: r.failureReason), default: 0] += r.taskCount }
        return UsageFailureClass.allCases
            .map { UsageFailureClassRow(failureClass: $0, count: counts[$0] ?? 0) }
            .filter { $0.count > 0 }
            .usageStableSorted { $0.count > $1.count }
    }

    public static func failureReasons(_ rows: [DashboardFailureDaily]) -> [UsageFailureReasonRow] {
        var counts: [String: Int] = [:]
        for r in rows where !r.failureReason.isEmpty { counts[r.failureReason, default: 0] += r.taskCount }
        return counts.map { UsageFailureReasonRow(reason: $0.key, failureClass: UsageFailureClass(reason: $0.key), count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.reason < $1.reason }
    }

    /// Rewrites rows whose agent the viewer cannot resolve onto one neutral
    /// id before aggregation (anonymized even while agents are loading).
    public static func anonymizeUnresolved(_ rows: [DashboardFailureByAgent], known: Set<String>?) -> [DashboardFailureByAgent] {
        guard rows.contains(where: { !(known?.contains($0.agentId) ?? false) }) else { return rows }
        return rows.map { r in
            guard !(known?.contains(r.agentId) ?? false) else { return r }
            var copy = r
            copy.agentId = unresolvedAgentsRowID
            return copy
        }
    }

    public static func agentFailures(_ rows: [DashboardFailureByAgent]) -> [UsageAgentFailureRow] {
        var map: [String: UsageAgentFailureRow] = [:]
        var order: [String] = []
        for r in rows {
            if map[r.agentId] == nil { order.append(r.agentId); map[r.agentId] = UsageAgentFailureRow(agentID: r.agentId, failed: 0, total: 0, classes: [:]) }
            map[r.agentId]!.total += r.taskCount
            guard !r.failureReason.isEmpty else { continue }
            map[r.agentId]!.failed += r.taskCount
            map[r.agentId]!.classes[UsageFailureClass(reason: r.failureReason), default: 0] += r.taskCount
        }
        return sortAgentFailures(order.compactMap { map[$0] }.filter { $0.failed > 0 }, by: .failed)
    }

    public static func hasRateSample(_ r: UsageAgentFailureRow) -> Bool { r.total >= minRateSample }

    public static func sortAgentFailures(_ rows: [UsageAgentFailureRow], by sort: UsageOffenderSort) -> [UsageAgentFailureRow] {
        switch sort {
        case .failed:
            return rows.usageStableSorted { a, b in a.failed != b.failed ? a.failed > b.failed : a.rate > b.rate }
        case .rate:
            return rows.usageStableSorted { a, b in
                let sa = hasRateSample(a) ? 0 : 1, sb = hasRateSample(b) ? 0 : 1
                if sa != sb { return sa < sb }
                if a.rate != b.rate { return a.rate > b.rate }
                return a.failed > b.failed
            }
        }
    }

    /// Failure classes present in any bucket, in canonical order.
    public static func activeClasses(_ buckets: [UsageBucket<UsageClassCounts>]) -> [UsageFailureClass] {
        UsageFailureClass.allCases.filter { c in buckets.contains { $0.value[c] > 0 } }
    }
}

/// The six rollups plus the page scope, as fetched.
public struct UsageDashboardInput: Sendable {
    public var days: Int
    public var today: String
    public var daily: [DashboardUsageDaily] = []
    public var byAgent: [DashboardUsageByAgent] = []
    public var runTime: [DashboardAgentRunTime] = []
    public var runTimeDaily: [DashboardRunTimeDaily] = []
    public var failuresDaily: [DashboardFailureDaily] = []
    public var failuresByAgent: [DashboardFailureByAgent] = []
    /// nil while the agent list is loading.
    public var knownAgentIDs: Set<String>?
    public var pricing = UsagePricing()

    public init(days: Int, today: String) {
        self.days = days
        self.today = today
    }

    /// Per-date queries over-fetch whole trailing weeks so the leftmost
    /// weekly bucket is complete.
    public static func chartFetchDays(_ days: Int) -> Int { weekCount(days) * 7 }
    public static func weekCount(_ days: Int) -> Int { max(1, Int((Double(days) / 7).rounded(.up))) }
}

/// Everything both dashboard tabs render, derived once per data change.
public struct UsageDashboardSnapshot: Sendable {
    public var totals = UsageTokenTotals()
    public var runTimeSeconds = 0
    public var runTimeTasks = 0
    public var runTimeFailed = 0
    public var dailyCost: [UsageBucket<UsageTokenStack>] = []
    public var dailyTokens: [UsageBucket<UsageTokenStack>] = []
    public var dailyTime: [UsageBucket<Int>] = []
    public var dailyTasks: [UsageBucket<UsageTaskStack>] = []
    public var dailyErrors: [UsageBucket<UsageClassCounts>] = []
    public var weeklyCost: [UsageBucket<UsageTokenStack>] = []
    public var weeklyTokens: [UsageBucket<UsageTokenStack>] = []
    public var weeklyTime: [UsageBucket<Int>] = []
    public var weeklyTasks: [UsageBucket<UsageTaskStack>] = []
    public var weeklyErrors: [UsageBucket<UsageClassCounts>] = []
    public var agentRows: [UsageAgentRow] = []
    public var deletedAgentCount = 0
    public var failureTotals = UsageFailureTotals()
    public var failureClasses: [UsageFailureClassRow] = []
    public var failureReasons: [UsageFailureReasonRow] = []
    public var agentFailures: [UsageAgentFailureRow] = []
    public var usageHasNoData = true

    public init() {}

    public init(_ input: UsageDashboardInput) {
        let cutoff = UsageCalendar.addDays(input.today, -(input.days - 1))
        let weekCount = UsageDashboardInput.weekCount(input.days)
        let daily = input.daily.filter { $0.date >= cutoff }
        let runTimeDaily = input.runTimeDaily.filter { $0.date >= cutoff }
        let failuresDaily = input.failuresDaily.filter { $0.date >= cutoff }
        let pricing = input.pricing

        usageHasNoData = input.daily.isEmpty && input.byAgent.isEmpty && input.runTime.isEmpty && input.runTimeDaily.isEmpty
        totals = UsageDashboard.totals(daily, pricing: pricing)
        for r in input.runTime {
            runTimeSeconds += r.totalSeconds
            runTimeTasks += r.taskCount
            runTimeFailed += r.failedCount
        }
        dailyCost = UsageDashboard.dailyCost(daily, pricing: pricing)
        dailyTokens = UsageDashboard.dailyTokens(daily)
        dailyTime = UsageDashboard.dailyTime(runTimeDaily)
        dailyTasks = UsageDashboard.dailyTasks(runTimeDaily)
        dailyErrors = UsageDashboard.dailyErrors(failuresDaily)
        weeklyCost = UsageDashboard.weeklyCost(input.daily, pricing: pricing, today: input.today, weekCount: weekCount)
        weeklyTokens = UsageDashboard.weeklyTokens(input.daily, today: input.today, weekCount: weekCount)
        weeklyTime = UsageDashboard.weeklyTime(input.runTimeDaily, today: input.today, weekCount: weekCount)
        weeklyTasks = UsageDashboard.weeklyTasks(input.runTimeDaily, today: input.today, weekCount: weekCount)
        weeklyErrors = UsageDashboard.weeklyErrors(input.failuresDaily, today: input.today, weekCount: weekCount)

        let merged = UsageDashboard.mergeAgentRows(UsageDashboard.agentTokens(input.byAgent, pricing: pricing), input.runTime)
        agentRows = UsageDashboard.bucketUnknownAgents(merged, known: input.knownAgentIDs)
        deletedAgentCount = UsageDashboard.deletedAgentCount(merged, known: input.knownAgentIDs)

        failureTotals = UsageDashboard.failureTotals(failuresDaily)
        failureClasses = UsageDashboard.failureClasses(failuresDaily)
        failureReasons = UsageDashboard.failureReasons(failuresDaily)
        agentFailures = UsageDashboard.agentFailures(UsageDashboard.anonymizeUnresolved(input.failuresByAgent, known: input.knownAgentIDs))
    }
}

public enum UsageFormat {
    /// "1h 23m" / "12m 30s" / "45s" / "<1m", at most two segments.
    public static func duration(_ seconds: Double, lessThanMinute: String) -> String {
        guard seconds >= 0, seconds.isFinite else { return lessThanMinute }
        if seconds < 60 {
            return seconds < 1 ? lessThanMinute : "\(Int(seconds.rounded()))s"
        }
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        if hours == 0 {
            let secs = Int(seconds) % 60
            return secs > 0 ? "\(mins)m \(secs)s" : "\(mins)m"
        }
        if hours >= 24 {
            let days = hours / 24, h = hours % 24
            return h > 0 ? "\(days)d \(h)h" : "\(days)d"
        }
        return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
    }

    private static let tokenUnits: [(divisor: Double, suffix: String)] = [
        (1, ""), (1_000, "K"), (1_000_000, "M"), (1_000_000_000, "B"), (1_000_000_000_000, "T"),
    ]

    private static func oneDecimal(_ n: Double) -> String {
        let r = (n * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    /// Compact token count: 999 → "999", 1500 → "1.5K", 999_999 → "1M".
    public static func tokens(_ n: Double) -> String {
        let magnitude = abs(n)
        var index = max(0, tokenUnits.lastIndex { magnitude >= $0.divisor } ?? 0)
        if index == 0 { return String(Int(n)) }
        var scaled = n / tokenUnits[index].divisor
        if abs((scaled * 10).rounded() / 10) >= 1_000, index < tokenUnits.count - 1 {
            index += 1
            scaled = n / tokenUnits[index].divisor
        }
        return oneDecimal(scaled) + tokenUnits[index].suffix
    }

    /// "12.5%", "40%"; sub-10% keeps one decimal; no runs renders "—".
    public static func rate(failed: Int, total: Int) -> String {
        guard total > 0 else { return "—" }
        let pct = Double(failed) / Double(total) * 100
        return pct >= 10 || pct == 0 ? "\(Int(pct.rounded()))%" : String(format: "%.1f%%", pct)
    }
}

extension Array {
    /// Sort that keeps the input order for equal elements (JS `toSorted`).
    func usageStableSorted(by less: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}
