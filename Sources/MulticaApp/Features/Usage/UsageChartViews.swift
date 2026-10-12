import Charts
import MulticaCore
import SwiftUI

/// Upstream `--chart-1…5` (a single-hue blue ramp; darker first in light mode).
enum UsagePalette {
    static let chart1 = Color(light: 0x2171CC, dark: 0x59A6FF)
    static let chart2 = Color(light: 0x5894E0, dark: 0x4C88D3)
    static let chart3 = Color(light: 0x85B4F0, dark: 0x3F6AA1)
    static let chart4 = Color(light: 0xB4D0F5, dark: 0x34507A)
    static let chart5 = Color(light: 0xD9E6F7, dark: 0x283546)

    /// Failure classes step down a destructive ramp, most actionable darkest.
    static func failure(_ c: UsageFailureClass) -> Color {
        let opacity: Double
        switch c {
        case .auth: opacity = 1
        case .rateLimit: opacity = 0.86
        case .timeout: opacity = 0.72
        case .provider: opacity = 0.60
        case .runtime: opacity = 0.48
        case .agent: opacity = 0.38
        case .other: opacity = 0.30
        }
        return Theme.destructive.opacity(opacity)
    }

    static func failureLabel(_ c: UsageFailureClass) -> String {
        tr("usage", "errors.class.\(c.rawValue)")
    }
}

struct UsageSeries: Identifiable {
    var id: String
    var label: String
    var color: Color

    static let tokenStack: [UsageSeries] = [
        UsageSeries(id: "input", label: "Input", color: UsagePalette.chart1),
        UsageSeries(id: "output", label: "Output", color: UsagePalette.chart2),
        UsageSeries(id: "cacheRead", label: "Cache read", color: UsagePalette.chart4),
        UsageSeries(id: "cacheWrite", label: "Cache write", color: UsagePalette.chart3),
    ]
    static let time: [UsageSeries] = [UsageSeries(id: "totalSeconds", label: "Run time", color: UsagePalette.chart1)]
    static let tasks: [UsageSeries] = [
        UsageSeries(id: "completed", label: "Completed", color: UsagePalette.chart1),
        UsageSeries(id: "cancelled", label: "Cancelled", color: UsagePalette.chart3),
        UsageSeries(id: "failed", label: "Failed", color: UsagePalette.chart5),
    ]

    static func errors(_ ids: [String]) -> [UsageSeries] {
        ids.compactMap { UsageFailureClass(rawValue: $0) }.map {
            UsageSeries(id: $0.rawValue, label: UsagePalette.failureLabel($0), color: UsagePalette.failure($0))
        }
    }
}

/// Stacked bar chart with a hover tooltip (upstream recharts BarChart +
/// ChartTooltipContent).
struct UsageBarChart: View, Equatable {
    enum Footer: Equatable { case total, rate, none }

    let data: UsageChartData
    let series: [UsageSeries]
    let formatAxis: (Double) -> String
    let formatValue: (Double) -> String
    var footer: Footer = .total
    var weekly = false

    @State private var selection: String?

    static func == (a: UsageBarChart, b: UsageBarChart) -> Bool {
        a.data == b.data && a.series.map(\.id) == b.series.map(\.id) && a.footer == b.footer && a.weekly == b.weekly
    }

    private var axisKeys: [String] {
        let keys = data.buckets.map(\.key)
        guard keys.count > 8 else { return keys }
        let step = Int((Double(keys.count) / 7).rounded(.up))
        var out = stride(from: 0, to: keys.count, by: step).map { keys[$0] }
        if let last = keys.last, out.last != last { out.append(last) }
        return out
    }

    var body: some View {
        let labels = Dictionary(uniqueKeysWithValues: data.buckets.map { ($0.key, $0.label) })
        Chart {
            ForEach(data.buckets) { bucket in
                ForEach(Array(series.enumerated()), id: \.element.id) { index, s in
                    BarMark(x: .value("Bucket", bucket.key), y: .value("Value", index < bucket.values.count ? bucket.values[index] : 0))
                        .foregroundStyle(by: .value("Series", s.label))
                        .opacity(bucket.partial ? 0.5 : 1)
                }
            }
            if let selection, let bucket = data.buckets.first(where: { $0.key == selection }) {
                RuleMark(x: .value("Bucket", selection))
                    .foregroundStyle(Color.primary.opacity(0.06))
                    .lineStyle(StrokeStyle(lineWidth: 18))
                    .annotation(position: .top, alignment: .center, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(bucket)
                    }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.label), range: series.map(\.color))
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: axisKeys) { value in
                AxisValueLabel {
                    if let key = value.as(String.self) { Text(labels[key] ?? key) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(formatAxis(v)) }
                }
            }
        }
        .chartXSelection(value: $selection)
        .font(Theme.Font.caption)
        .frame(height: 260)
    }

    private func tooltip(_ bucket: UsageChartData.Bucket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(weekly && bucket.partial
                 ? tr("usage", "weekly.partial_label", ["range": bucket.title, "covered": bucket.daysCovered])
                 : bucket.title)
                .font(.system(size: 11, weight: .medium))
            ForEach(Array(series.enumerated()), id: \.element.id) { index, s in
                let v = index < bucket.values.count ? bucket.values[index] : 0
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 8, height: 8)
                    Text("\(formatValue(v)) \(s.label)").monospacedDigit()
                }
            }
            switch footer {
            case .total:
                Divider()
                HStack {
                    Text(tr("runtimes", "charts.tooltip_total"))
                    Spacer(minLength: 12)
                    Text(formatValue(bucket.values.reduce(0, +))).font(.system(size: 11, design: .monospaced))
                }
                .font(.system(size: 11, weight: .medium))
            case .rate:
                Divider()
                HStack {
                    Text(tr("usage", "errors.tooltip_rate"))
                    Spacer(minLength: 12)
                    Text(UsageFormat.rate(failed: bucket.failed, total: bucket.total)).font(.system(size: 11, design: .monospaced))
                }
                .font(.system(size: 11, weight: .medium))
            case .none:
                EmptyView()
            }
        }
        .font(.system(size: 11))
        .padding(8)
        .frame(minWidth: 140, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

/// Card-local pill toggle (upstream `Segmented`).
struct UsageSegmented<Value: Hashable>: View {
    let label: String
    @Binding var value: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { o in
                Button { value = o.value } label: {
                    Text(o.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(o.value == value ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(o.value == value ? Color(nsColor: .controlBackgroundColor) : .clear)
                            .shadow(color: .black.opacity(o.value == value ? 0.08 : 0), radius: 1, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(o.value == value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// Daily / Weekly, rendered only when the range allows both.
struct UsageDimSegmented: View {
    let allowed: [UsageDashboard.Dim]
    @Binding var value: UsageDashboard.Dim

    var body: some View {
        if allowed.count >= 2 {
            UsageSegmented(label: tr("usage", "dim.label"), value: $value,
                           options: allowed.map { ($0, tr("usage", "dim.\($0.rawValue)")) })
        }
    }
}

/// KPI tile (upstream runtimes KpiCard).
struct UsageKpiTile<Value: View>: View {
    let label: String
    @ViewBuilder var value: () -> Value
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            value()
                .font(.system(size: 26, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let hint {
                Text(hint).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The bordered card every dashboard section sits in.
struct UsageCard<Content: View>: View {
    var padded = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(padded ? 16 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }
}

struct UsageEmptyChart: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar").foregroundStyle(.tertiary)
            Text(message).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
