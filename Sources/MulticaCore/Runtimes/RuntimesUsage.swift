import Foundation

/// A priceable row bucketed by calendar day (`YYYY-MM-DD`).
public protocol RuntimesDatedUsage: RuntimesPriceable {
    var date: String { get }
}

extension RuntimeUsage: RuntimesDatedUsage {}

/// Date math on `YYYY-MM-DD` strings in UTC so neither DST nor the host
/// timezone can shift a bucket (upstream `todayIso` / `addDaysIso` / …).
public enum RuntimesCalendar {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func parse(_ iso: String) -> Date {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        let comps = DateComponents(year: parts.count > 0 ? parts[0] : 1970, month: parts.count > 1 ? parts[1] : 1, day: parts.count > 2 ? parts[2] : 1)
        return utc.date(from: comps) ?? Date(timeIntervalSince1970: 0)
    }

    static func format(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// Today's calendar date in `timeZone`.
    public static func today(in timeZone: TimeZone, now: Date = Date()) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        let d = c.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", d.year ?? 1970, d.month ?? 1, d.day ?? 1)
    }

    public static func addDays(_ iso: String, _ days: Int) -> String {
        format(utc.date(byAdding: .day, value: days, to: parse(iso)) ?? parse(iso))
    }

    /// Monday of the ISO week containing `iso`.
    public static func weekStart(_ iso: String) -> String {
        addDays(iso, -weekdayIndex(iso))
    }

    /// 0 = Monday … 6 = Sunday.
    public static func weekdayIndex(_ iso: String) -> Int {
        (utc.component(.weekday, from: parse(iso)) + 5) % 7
    }

    public static func diffDays(_ from: String, _ to: String) -> Int {
        Int((parse(to).timeIntervalSince(parse(from)) / 86_400).rounded())
    }

    /// Month index 1…12.
    public static func month(_ iso: String) -> Int {
        utc.component(.month, from: parse(iso))
    }

    /// `"May 12"` (fixed English, like upstream `formatShortDate`).
    public static func shortDate(_ iso: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d"
        return f.string(from: parse(iso))
    }

    /// `"5/12"` axis label.
    public static func axisLabel(_ iso: String) -> String {
        let c = utc.dateComponents([.month, .day], from: parse(iso))
        return "\(c.month ?? 1)/\(c.day ?? 1)"
    }

    /// The UTC midnight `Date` of a day key (for chart axes).
    public static func date(_ iso: String) -> Date { parse(iso) }
}

public struct RuntimesDailyTokens: Sendable, Hashable, Identifiable {
    public var date: String
    public var label: String
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var id: String { date }
    public var total: Int { input + output + cacheRead + cacheWrite }
}

public struct RuntimesDailyCost: Sendable, Hashable, Identifiable {
    public var date: String
    public var label: String
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var total: Double
    public var id: String { date }
}

public struct RuntimesWeekInfo: Sendable, Hashable {
    public var weekStart: String
    public var weekEnd: String
    public var label: String
    public var rangeLabel: String
    /// The week is still in progress (drawn at half opacity).
    public var partial: Bool
    public var daysCovered: Int
}

public struct RuntimesWeeklyTokens: Sendable, Hashable, Identifiable {
    public var week: RuntimesWeekInfo
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var id: String { week.weekStart }
    public var total: Int { input + output + cacheRead + cacheWrite }
}

public struct RuntimesWeeklyCost: Sendable, Hashable, Identifiable {
    public var week: RuntimesWeekInfo
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var total: Double
    public var id: String { week.weekStart }
}

public struct RuntimesCostByKey: Sendable, Hashable, Identifiable {
    public var key: String
    public var tokens = 0
    public var cost = 0.0
    public var taskCount = 0
    public var id: String { key }
}

public struct RuntimesUsageTotals: Sendable, Hashable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var cost = 0.0
    public var cacheSavings = 0.0
    public var tokens: Int { input + output + cacheRead + cacheWrite }

    public init() {}
}

public struct RuntimesHeatmapCell: Sendable, Hashable, Identifiable {
    public var date: String
    /// 0 = Monday … 6 = Sunday.
    public var dayOfWeek: Int
    public var week: Int
    public var cost: Double
    /// 0 (no activity) … 4 (top quartile).
    public var level: Int
    public var id: String { date }
}

public struct RuntimesHeatmapInsights: Sendable, Hashable {
    public var busiestDate: String?
    public var busiestCost = 0.0
    public var busyWeekday: Int?
    public var busyWeekdayAverage = 0.0
    public var quietWeekday: Int?
    public var quietWeekdayAverage = 0.0
    public var totalCost = 0.0
    public var windowDays = 0
}

public struct RuntimesHeatmap: Sendable, Hashable {
    public static let weeks = 26
    public var cells: [RuntimesHeatmapCell]
    /// First Monday cell of each month: (date of that cell, column).
    public var months: [(date: String, week: Int)]
    public var insights: RuntimesHeatmapInsights

    public static func == (a: RuntimesHeatmap, b: RuntimesHeatmap) -> Bool {
        a.cells == b.cells && a.insights == b.insights && a.months.map(\.date) == b.months.map(\.date)
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(cells) }
}

/// Usage aggregations behind the runtime detail charts (upstream
/// `aggregateByDate`, `aggregateByWeek`, `sliceWindow`, …).
public enum RuntimesUsageMath {
    static func round2(_ n: Double) -> Double { (n * 100).rounded() / 100 }

    public static func totals<T: RuntimesPriceable>(_ rows: [T], pricer: RuntimesPricer) -> RuntimesUsageTotals {
        var t = RuntimesUsageTotals()
        for u in rows {
            t.input += u.inputTokens
            t.output += u.outputTokens
            t.cacheRead += u.cacheReadTokens
            t.cacheWrite += u.cacheWriteTokens
            t.cost += pricer.estimateCost(u)
            t.cacheSavings += pricer.estimateCacheSavings(u)
        }
        return t
    }

    /// Rows in the selected window `[today - days, …]` and the equal prior window.
    public static func sliceWindow<T: RuntimesDatedUsage>(_ usage: [T], days: Int, today: String) -> (current: [T], previous: [T]) {
        let currentStart = RuntimesCalendar.addDays(today, -days)
        let previousStart = RuntimesCalendar.addDays(today, -days * 2)
        return (usage.filter { $0.date >= currentStart }, usage.filter { $0.date >= previousStart && $0.date < currentStart })
    }

    /// Cost over `[today - offset - days, today - offset)`.
    public static func costInWindow<T: RuntimesDatedUsage>(_ rows: [T], days: Int, today: String, offset: Int = 0, pricer: RuntimesPricer) -> Double {
        let end = RuntimesCalendar.addDays(today, -offset)
        let start = RuntimesCalendar.addDays(today, -offset - days)
        return rows.reduce(0) { $1.date >= start && $1.date < end ? $0 + pricer.estimateCost($1) : $0 }
    }

    public static func byDate<T: RuntimesDatedUsage>(_ usage: [T], pricer: RuntimesPricer) -> (tokens: [RuntimesDailyTokens], cost: [RuntimesDailyCost]) {
        var tokens: [String: RuntimesDailyTokens] = [:]
        var stacks: [String: RuntimesCostBreakdown] = [:]
        for u in usage {
            var t = tokens[u.date] ?? RuntimesDailyTokens(date: u.date, label: RuntimesCalendar.axisLabel(u.date))
            t.input += u.inputTokens
            t.output += u.outputTokens
            t.cacheRead += u.cacheReadTokens
            t.cacheWrite += u.cacheWriteTokens
            tokens[u.date] = t
            let b = pricer.estimateCostBreakdown(u)
            var s = stacks[u.date] ?? RuntimesCostBreakdown()
            s.input += b.input
            s.output += b.output
            s.cacheRead += b.cacheRead
            s.cacheWrite += b.cacheWrite
            stacks[u.date] = s
        }
        let cost = stacks.keys.sorted().map { date -> RuntimesDailyCost in
            let s = stacks[date]!
            let i = round2(s.input), o = round2(s.output), r = round2(s.cacheRead), w = round2(s.cacheWrite)
            return RuntimesDailyCost(date: date, label: RuntimesCalendar.axisLabel(date), input: i, output: o, cacheRead: r, cacheWrite: w, total: round2(i + o + r + w))
        }
        return (tokens.values.sorted { $0.date < $1.date }, cost)
    }

    /// Exactly `weekCount` trailing ISO weeks ending with the current one,
    /// pre-zeroed so empty weeks still render.
    public static func byWeek<T: RuntimesDatedUsage>(_ usage: [T], today: String, weekCount: Int, pricer: RuntimesPricer)
        -> (tokens: [RuntimesWeeklyTokens], cost: [RuntimesWeeklyCost]) {
        let count = max(1, weekCount)
        let currentWeek = RuntimesCalendar.weekStart(today)
        let firstWeek = RuntimesCalendar.addDays(currentWeek, -(count - 1) * 7)
        let starts = (0..<count).map { RuntimesCalendar.addDays(firstWeek, $0 * 7) }
        var tokens: [String: RuntimesWeeklyTokens] = [:]
        var stacks: [String: RuntimesCostBreakdown] = [:]
        for s in starts {
            tokens[s] = RuntimesWeeklyTokens(week: weekInfo(s, today: today))
            stacks[s] = RuntimesCostBreakdown()
        }
        for u in usage {
            let wk = RuntimesCalendar.weekStart(u.date)
            guard wk >= firstWeek, wk <= currentWeek, tokens[wk] != nil else { continue }
            tokens[wk]!.input += u.inputTokens
            tokens[wk]!.output += u.outputTokens
            tokens[wk]!.cacheRead += u.cacheReadTokens
            tokens[wk]!.cacheWrite += u.cacheWriteTokens
            let b = pricer.estimateCostBreakdown(u)
            stacks[wk]!.input += b.input
            stacks[wk]!.output += b.output
            stacks[wk]!.cacheRead += b.cacheRead
            stacks[wk]!.cacheWrite += b.cacheWrite
        }
        let cost = starts.map { s -> RuntimesWeeklyCost in
            let b = stacks[s]!
            let i = round2(b.input), o = round2(b.output), r = round2(b.cacheRead), w = round2(b.cacheWrite)
            return RuntimesWeeklyCost(week: weekInfo(s, today: today), input: i, output: o, cacheRead: r, cacheWrite: w, total: round2(i + o + r + w))
        }
        return (starts.map { tokens[$0]! }, cost)
    }

    public static func weekInfo(_ weekStart: String, today: String) -> RuntimesWeekInfo {
        let weekEnd = RuntimesCalendar.addDays(weekStart, 6)
        let partial = today < weekEnd
        let clampedToday = today < weekStart ? weekStart : (today < weekEnd ? today : weekEnd)
        let elapsed = min(7, max(1, RuntimesCalendar.diffDays(weekStart, clampedToday) + 1))
        return RuntimesWeekInfo(weekStart: weekStart, weekEnd: weekEnd, label: RuntimesCalendar.shortDate(weekStart),
                                rangeLabel: "\(RuntimesCalendar.shortDate(weekStart)) – \(RuntimesCalendar.shortDate(weekEnd))",
                                partial: partial, daysCovered: partial ? elapsed : 7)
    }

    /// Per-(agent, model) rows folded per agent, most expensive first.
    public static func costByAgent(_ rows: [RuntimeUsageByAgent], pricer: RuntimesPricer) -> [RuntimesCostByKey] {
        var map: [String: RuntimesCostByKey] = [:]
        var order: [String] = []
        for r in rows {
            if map[r.agentId] == nil { order.append(r.agentId); map[r.agentId] = RuntimesCostByKey(key: r.agentId) }
            map[r.agentId]!.tokens += r.runtimesTotalTokens
            map[r.agentId]!.cost += pricer.estimateCost(r)
            map[r.agentId]!.taskCount += r.taskCount
        }
        return sortedByCost(order.map { map[$0]! })
    }

    public static func costByModel<T: RuntimesDatedUsage>(_ rows: [T], pricer: RuntimesPricer) -> [RuntimesCostByKey] {
        var map: [String: RuntimesCostByKey] = [:]
        var order: [String] = []
        for r in rows {
            let key = pricer.modelGroupingKey(r.model, provider: r.runtimesProvider)
            if map[key] == nil { order.append(key); map[key] = RuntimesCostByKey(key: key) }
            map[key]!.tokens += r.runtimesTotalTokens
            map[key]!.cost += pricer.estimateCost(r)
        }
        return sortedByCost(order.map { map[$0]! })
    }

    static func sortedByCost(_ rows: [RuntimesCostByKey]) -> [RuntimesCostByKey] {
        rows.enumerated().sorted { a, b in a.element.cost != b.element.cost ? a.element.cost > b.element.cost : a.offset < b.offset }.map(\.element)
    }

    /// Rows grouped by day, in first-seen order (the folded breakdown table).
    public static func groupedByDate<T: RuntimesDatedUsage>(_ rows: [T]) -> [(date: String, rows: [T])] {
        var order: [String] = []
        var map: [String: [T]] = [:]
        for r in rows {
            if map[r.date] == nil { order.append(r.date) }
            map[r.date, default: []].append(r)
        }
        return order.map { ($0, map[$0]!) }
    }

    /// The 26-week daily-cost heatmap and its side insights.
    public static func heatmap<T: RuntimesDatedUsage>(_ usage: [T], today: String, pricer: RuntimesPricer, weeks: Int = RuntimesHeatmap.weeks) -> RuntimesHeatmap {
        var dateCost: [String: Double] = [:]
        for u in usage { dateCost[u.date, default: 0] += pricer.estimateCost(u) }
        let lastWeekStart = RuntimesCalendar.weekStart(today)
        let start = RuntimesCalendar.addDays(lastWeekStart, -(weeks - 1) * 7)
        let todayIndex = (weeks - 1) * 7 + RuntimesCalendar.weekdayIndex(today)
        var cells: [RuntimesHeatmapCell] = []
        cells.reserveCapacity(todayIndex + 1)
        for i in 0...todayIndex {
            let date = RuntimesCalendar.addDays(start, i)
            cells.append(RuntimesHeatmapCell(date: date, dayOfWeek: i % 7, week: i / 7, cost: dateCost[date] ?? 0, level: 0))
        }
        let nonZero = cells.map(\.cost).filter { $0 > 0 }.sorted()
        func level(_ cost: Double) -> Int {
            if cost == 0 { return 0 }
            if nonZero.count <= 1 { return 4 }
            let p = Double(nonZero.firstIndex(of: cost) ?? 0) / Double(nonZero.count - 1)
            if p <= 0.25 { return 1 }
            if p <= 0.5 { return 2 }
            if p <= 0.75 { return 3 }
            return 4
        }
        for i in cells.indices { cells[i].level = level(cells[i].cost) }

        var months: [(String, Int)] = []
        var lastMonth = -1
        for c in cells where c.dayOfWeek == 0 {
            let m = RuntimesCalendar.month(c.date)
            if m != lastMonth {
                months.append((c.date, c.week))
                lastMonth = m
            }
        }

        var insights = RuntimesHeatmapInsights()
        var sums = [Double](repeating: 0, count: 7), counts = [Int](repeating: 0, count: 7)
        for c in cells {
            insights.totalCost += c.cost
            sums[c.dayOfWeek] += c.cost
            counts[c.dayOfWeek] += 1
            if c.cost > 0 && (insights.busiestDate == nil || c.cost > insights.busiestCost) {
                insights.busiestDate = c.date
                insights.busiestCost = c.cost
            }
        }
        var quietAvg = Double.infinity
        for i in 0..<7 {
            let avg = counts[i] > 0 ? sums[i] / Double(counts[i]) : 0
            if avg > insights.busyWeekdayAverage {
                insights.busyWeekdayAverage = avg
                insights.busyWeekday = i
            }
            if avg < quietAvg {
                quietAvg = avg
                insights.quietWeekday = i
            }
        }
        insights.quietWeekdayAverage = quietAvg.isFinite ? quietAvg : 0
        if insights.totalCost == 0 {
            insights.busyWeekday = nil
            insights.quietWeekday = nil
        }
        insights.windowDays = cells.count
        return RuntimesHeatmap(cells: cells, months: months.map { (date: $0.0, week: $0.1) }, insights: insights)
    }
}
