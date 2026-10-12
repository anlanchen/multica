import Charts
import MulticaCore
import SwiftUI

struct RuntimesChartSeries: Hashable {
    let key: String
    let label: String
    let color: Color
}

/// One bar: a value per series, in series order.
struct RuntimesChartPoint: Identifiable, Hashable {
    let id: String
    let axisLabel: String
    let title: String
    var partial = false
    let values: [Double]
    /// Extra footer row in the tooltip (e.g. failure rate) instead of a total.
    var footer: (label: String, value: String)? = nil

    static func == (a: RuntimesChartPoint, b: RuntimesChartPoint) -> Bool {
        a.id == b.id && a.values == b.values && a.partial == b.partial && a.title == b.title
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(values)
    }
}

/// Stacked bar chart replicating the recharts cards: horizontal grid only,
/// sparse x labels, hover tooltip with per-series values and a total.
struct RuntimesBarChart: View {
    let series: [RuntimesChartSeries]
    let points: [RuntimesChartPoint]
    var yFormat: (Double) -> String = { RuntimesFormat.tokens($0) }
    var valueFormat: (Double) -> String = { RuntimesFormat.tokens($0) }
    var totalFormat: ((Double) -> String)? = nil
    var showTotal = true
    @State private var selected: String?

    var body: some View {
        let labels = Dictionary(points.map { ($0.id, $0.axisLabel) }, uniquingKeysWith: { a, _ in a })
        Chart {
            ForEach(points) { p in
                ForEach(Array(series.enumerated()), id: \.element.key) { index, s in
                    let v = index < p.values.count ? p.values[index] : 0
                    if v > 0 || index == series.count - 1 {
                        BarMark(x: .value("x", p.id), y: .value(s.label, v), width: .ratio(0.8))
                            .foregroundStyle(s.color)
                            .opacity(p.partial ? 0.5 : (selected == nil || selected == p.id ? 1 : 0.55))
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: topIndex(p) == index ? 3 : 0,
                                                              topTrailingRadius: topIndex(p) == index ? 3 : 0))
                    }
                }
            }
            if let selected, let point = points.first(where: { $0.id == selected }) {
                RuleMark(x: .value("x", selected))
                    .foregroundStyle(Color.primary.opacity(0.06))
                    .lineStyle(StrokeStyle(lineWidth: 18))
                    .zIndex(-1)
                    .annotation(position: .top, alignment: .center, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(point)
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartXAxis {
            AxisMarks(values: axisValues) { value in
                AxisValueLabel {
                    if let id = value.as(String.self) { Text(labels[id] ?? id).font(.system(size: 10)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(yFormat(v)).font(.system(size: 10)) }
                }
            }
        }
        .aspectRatio(3, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private func topIndex(_ p: RuntimesChartPoint) -> Int {
        p.values.lastIndex { $0 > 0 } ?? series.count - 1
    }

    /// Start, end, and evenly spaced ids in between (recharts
    /// `interval="preserveStartEnd"`).
    private var axisValues: [String] {
        guard points.count > 8 else { return points.map(\.id) }
        let step = Int((Double(points.count - 1) / 7).rounded(.up))
        var out = stride(from: 0, to: points.count - 1, by: max(1, step)).map { points[$0].id }
        if let last = points.last?.id, out.last != last {
            if out.count > 1, (points.firstIndex { $0.id == out.last! } ?? 0) > points.count - 1 - step / 2 { out.removeLast() }
            out.append(last)
        }
        return out
    }

    private func tooltip(_ p: RuntimesChartPoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(p.title).font(.system(size: 11, weight: .medium))
            ForEach(Array(series.enumerated()), id: \.element.key) { index, s in
                let v = index < p.values.count ? p.values[index] : 0
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 8, height: 8)
                    Text(s.label).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(valueFormat(v)).monospacedDigit()
                }
                .font(.system(size: 11))
            }
            if let footer = p.footer {
                Divider()
                HStack {
                    Text(footer.label)
                    Spacer(minLength: 12)
                    Text(footer.value).font(.system(size: 11, design: .monospaced))
                }
                .font(.system(size: 11, weight: .medium))
            } else if showTotal {
                Divider()
                HStack {
                    Text(tr("runtimes", "charts.tooltip_total"))
                    Spacer(minLength: 12)
                    Text((totalFormat ?? valueFormat)(p.values.reduce(0, +))).font(.system(size: 11, design: .monospaced))
                }
                .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(8)
        .frame(minWidth: 150)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
    }
}

// MARK: Token / cost charts

enum RuntimesUsageSeries {
    /// Input / output / cache read / cache write — the order both stacks draw.
    static var all: [RuntimesChartSeries] {
        [RuntimesChartSeries(key: "input", label: tr("runtimes", "usage.legend_input"), color: RuntimesPalette.chart1),
         RuntimesChartSeries(key: "output", label: tr("runtimes", "usage.legend_output"), color: RuntimesPalette.chart2),
         RuntimesChartSeries(key: "cacheRead", label: tr("runtimes", "usage.legend_cache_read"), color: RuntimesPalette.chart4),
         RuntimesChartSeries(key: "cacheWrite", label: tr("runtimes", "usage.legend_cache_write"), color: RuntimesPalette.chart3)]
    }

    static func weekTitle(_ w: RuntimesWeekInfo) -> String {
        w.partial ? tr("runtimes", "usage.weekly_partial_label", ["range": w.rangeLabel, "covered": w.daysCovered]) : w.rangeLabel
    }
}

struct RuntimesDailyCostChart: View {
    let data: [RuntimesDailyCost]

    var body: some View {
        RuntimesBarChart(series: RuntimesUsageSeries.all,
                         points: data.map { RuntimesChartPoint(id: $0.date, axisLabel: $0.label, title: $0.label, values: [$0.input, $0.output, $0.cacheRead, $0.cacheWrite]) },
                         yFormat: { "$\(RuntimesFormat.trimmedNumber($0))" }, valueFormat: RuntimesFormat.usd2)
    }
}

struct RuntimesDailyTokensChart: View {
    let data: [RuntimesDailyTokens]

    var body: some View {
        RuntimesBarChart(series: RuntimesUsageSeries.all,
                         points: data.map { RuntimesChartPoint(id: $0.date, axisLabel: $0.label, title: $0.label,
                                                               values: [Double($0.input), Double($0.output), Double($0.cacheRead), Double($0.cacheWrite)]) },
                         totalFormat: { RuntimesFormat.grouped($0) })
    }
}

struct RuntimesWeeklyCostChart: View {
    let data: [RuntimesWeeklyCost]

    var body: some View {
        RuntimesBarChart(series: RuntimesUsageSeries.all,
                         points: data.map { RuntimesChartPoint(id: $0.week.weekStart, axisLabel: $0.week.label, title: RuntimesUsageSeries.weekTitle($0.week),
                                                               partial: $0.week.partial, values: [$0.input, $0.output, $0.cacheRead, $0.cacheWrite]) },
                         yFormat: { "$\(RuntimesFormat.trimmedNumber($0))" }, valueFormat: RuntimesFormat.usd2)
    }
}

struct RuntimesWeeklyTokensChart: View {
    let data: [RuntimesWeeklyTokens]

    var body: some View {
        RuntimesBarChart(series: RuntimesUsageSeries.all,
                         points: data.map { RuntimesChartPoint(id: $0.week.weekStart, axisLabel: $0.week.label, title: RuntimesUsageSeries.weekTitle($0.week), partial: $0.week.partial,
                                                               values: [Double($0.input), Double($0.output), Double($0.cacheRead), Double($0.cacheWrite)]) },
                         totalFormat: { RuntimesFormat.grouped($0) })
    }
}

/// Legend pips rendered in the chart card header.
struct RuntimesChartLegend: View {
    var series: [RuntimesChartSeries] = RuntimesUsageSeries.all

    var body: some View {
        HStack(spacing: 12) {
            ForEach(series, id: \.key) { s in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 8, height: 8)
                    Text(s.label)
                }
            }
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: Run time / tasks / errors (dashboard charts)

/// Daily or weekly bucket of run time in seconds.
struct RuntimesTimePoint: Hashable {
    var id: String
    var label: String
    var title: String
    var partial = false
    var totalSeconds: Double
}

/// Single-series run-time bars; the caller formats durations.
struct RuntimesTimeChart: View {
    let data: [RuntimesTimePoint]
    let formatY: (Double) -> String
    let formatTooltip: (Double) -> String

    var body: some View {
        RuntimesBarChart(series: [RuntimesChartSeries(key: "totalSeconds", label: trd("usage", "charts.run_time", "Run time"), color: RuntimesPalette.chart1)],
                         points: data.map { RuntimesChartPoint(id: $0.id, axisLabel: $0.label, title: $0.title, partial: $0.partial, values: [$0.totalSeconds]) },
                         yFormat: formatY, valueFormat: formatTooltip, showTotal: false)
    }
}

/// Completed / cancelled / failed runs per bucket.
struct RuntimesTasksPoint: Hashable {
    var id: String
    var label: String
    var title: String
    var partial = false
    var completed: Int
    var failed: Int
    var cancelled: Int
}

struct RuntimesTasksChart: View {
    let data: [RuntimesTasksPoint]

    var body: some View {
        RuntimesBarChart(series: [RuntimesChartSeries(key: "completed", label: trd("usage", "charts.completed", "Completed"), color: RuntimesPalette.chart1),
                                  RuntimesChartSeries(key: "cancelled", label: trd("usage", "charts.cancelled", "Cancelled"), color: RuntimesPalette.chart3),
                                  RuntimesChartSeries(key: "failed", label: trd("usage", "charts.failed", "Failed"), color: RuntimesPalette.chart5)],
                         points: data.map { RuntimesChartPoint(id: $0.id, axisLabel: $0.label, title: $0.title, partial: $0.partial,
                                                               values: [Double($0.completed), Double($0.cancelled), Double($0.failed)]) },
                         yFormat: { String(Int($0)) }, valueFormat: { String(Int($0)) }, totalFormat: { RuntimesFormat.grouped($0) })
    }
}

/// Display classes for failed runs, most actionable first.
enum RuntimesFailureClass: String, CaseIterable {
    case auth, rateLimit = "rate_limit", timeout, provider, runtime, agent, other

    var label: String { tr("usage", "errors.class.\(rawValue)") }

    /// A step down a destructive ramp so the stack reads as "errors".
    var color: Color {
        let mix: [RuntimesFailureClass: Double] = [.auth: 1, .rateLimit: 0.86, .timeout: 0.72, .provider: 0.6, .runtime: 0.48, .agent: 0.38, .other: 0.3]
        return Theme.destructive.opacity(mix[self] ?? 1)
    }
}

struct RuntimesErrorsPoint: Hashable {
    var id: String
    var label: String
    var title: String
    var partial = false
    var counts: [RuntimesFailureClass: Int]
    var failed: Int
    var total: Int
}

/// Failed runs per bucket stacked by class; the tooltip footer is the rate.
struct RuntimesErrorsChart: View {
    let data: [RuntimesErrorsPoint]

    var body: some View {
        let classes = RuntimesFailureClass.allCases.filter { c in data.contains { ($0.counts[c] ?? 0) > 0 } }
        RuntimesBarChart(series: classes.map { RuntimesChartSeries(key: $0.rawValue, label: $0.label, color: $0.color) },
                         points: data.map { p in
                             RuntimesChartPoint(id: p.id, axisLabel: p.label, title: p.title, partial: p.partial,
                                                values: classes.map { Double(p.counts[$0] ?? 0) },
                                                footer: (tr("usage", "errors.tooltip_rate"), RuntimesFormat.rate(failed: p.failed, total: p.total)))
                         },
                         yFormat: { String(Int($0)) }, valueFormat: { String(Int($0)) })
    }
}

// MARK: Heatmap

/// 26-week daily-cost calendar with busiest/quietest insights.
struct RuntimesActivityHeatmap: View {
    let heatmap: RuntimesHeatmap
    static let cell: CGFloat = 16
    static let gap: CGFloat = 3

    var body: some View {
        let weekdays = Self.weekdayLabels()
        let step = Self.cell + Self.gap
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    grid(weekdays: weekdays, step: step)
                    ScrollView(.horizontal, showsIndicators: false) { grid(weekdays: weekdays, step: step) }
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: 4) {
                    Text(tr("runtimes", "charts.heatmap_less"))
                    ForEach(0..<5, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2).fill(Self.color(level)).frame(width: 10, height: 10)
                    }
                    Text(tr("runtimes", "charts.heatmap_more"))
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            Divider()
            let i = heatmap.insights
            HStack(alignment: .top, spacing: 16) {
                insight(tr("runtimes", "charts.heatmap_busiest_day"), i.busiestDate.map(Self.dayLabel) ?? "—",
                        i.busiestDate == nil ? nil : RuntimesFormat.usd(i.busiestCost))
                insight(tr("runtimes", "charts.heatmap_most_active_weekday"), i.busyWeekday.map { weekdays[$0] } ?? "—",
                        i.busyWeekday == nil ? nil : tr("runtimes", "charts.heatmap_average", ["value": RuntimesFormat.usd(i.busyWeekdayAverage)]))
                insight(tr("runtimes", "charts.heatmap_quietest_weekday"), i.quietWeekday.map { weekdays[$0] } ?? "—",
                        i.quietWeekday == nil ? nil : tr("runtimes", "charts.heatmap_average", ["value": RuntimesFormat.usd(i.quietWeekdayAverage)]))
                insight(tr("runtimes", "charts.heatmap_window_total", ["count": i.windowDays]), RuntimesFormat.usd(i.totalCost), nil)
            }
        }
    }

    private func grid(weekdays: [String], step: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                ForEach(heatmap.months, id: \.date) { m in
                    Text(Self.monthLabel(m.date)).font(.system(size: 9)).foregroundStyle(.secondary)
                        .offset(x: 28 + CGFloat(m.week) * step)
                }
            }
            .frame(width: 28 + CGFloat(RuntimesHeatmap.weeks) * step, height: 14, alignment: .topLeading)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { i in
                        Text([0, 2, 4].contains(i) ? weekdays[i] : "")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .frame(width: 28, height: Self.cell, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(0..<RuntimesHeatmap.weeks, id: \.self) { week in
                        VStack(spacing: Self.gap) {
                            ForEach(0..<7, id: \.self) { day in
                                let index = week * 7 + day
                                if index < heatmap.cells.count {
                                    let c = heatmap.cells[index]
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Self.color(c.level))
                                        .frame(width: Self.cell, height: Self.cell)
                                        .help("\(c.date): " + (c.cost > 0 ? RuntimesFormat.usd2(c.cost) : tr("runtimes", "charts.heatmap_no_activity")))
                                } else {
                                    Color.clear.frame(width: Self.cell, height: Self.cell)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func insight(_ label: String, _ value: String, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 10)).tracking(0.6).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(Theme.Font.bodyMedium).monospacedDigit().lineLimit(1)
                if let sub { Text(sub).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func color(_ level: Int) -> Color {
        guard level > 0 else { return RuntimesPalette.muted }
        return RuntimesPalette.chart1.opacity([0.2, 0.45, 0.7, 1][min(level, 4) - 1])
    }

    /// Monday-first short weekday names in the UI language.
    static func weekdayLabels() -> [String] {
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.shared.language)
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("EEE")
        return (0..<7).map { f.string(from: RuntimesCalendar.date(RuntimesCalendar.addDays("2026-01-05", $0))) }
    }

    static func monthLabel(_ iso: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.shared.language)
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("MMM")
        return f.string(from: RuntimesCalendar.date(iso))
    }

    static func dayLabel(_ iso: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.shared.language)
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: RuntimesCalendar.date(iso))
    }
}

extension RuntimesFormat {
    /// `12` / `1.5` axis tick numbers without trailing zeros.
    static func trimmedNumber(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
}
