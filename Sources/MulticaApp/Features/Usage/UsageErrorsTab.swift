import MulticaCore
import SwiftUI

/// "What broke": KPIs, the failure trend, the class mix and the offenders
/// (upstream dashboard errors-tab.tsx).
struct UsageErrorsTab: View {
    let model: UsageModel
    let days: Int

    var body: some View {
        let s = model.snapshot
        let worst = s.agentFailures.first
        let worstName = worst.map { model.agents[$0.agentID]?.name ?? tr("usage", "errors.other_agents") }
        VStack(alignment: .leading, spacing: 20) {
            UsageKpiRow {
                UsageKpiTile(label: tr("usage", "errors.kpi_failed_label", ["days": days]), value: {
                    Text("\(s.failureTotals.failed)").contentTransition(.numericText(value: Double(s.failureTotals.failed)))
                }, hint: tr("usage", "errors.kpi_failed_hint", ["total": s.failureTotals.total]))
                Divider()
                UsageKpiTile(label: tr("usage", "errors.kpi_rate_label", ["days": days]), value: {
                    Text(UsageFormat.rate(failed: s.failureTotals.failed, total: s.failureTotals.total))
                }, hint: tr("usage", "errors.summary", ["failed": s.failureTotals.failed, "total": s.failureTotals.total,
                                                        "rate": UsageFormat.rate(failed: s.failureTotals.failed, total: s.failureTotals.total)]))
                Divider()
                UsageKpiTile(label: tr("usage", "errors.kpi_agents_label", ["days": days]), value: {
                    Text("\(s.agentFailures.count)").contentTransition(.numericText(value: Double(s.agentFailures.count)))
                }, hint: worst.flatMap { w in worstName.map { tr("usage", "errors.kpi_agents_hint", ["name": $0, "count": w.failed]) } })
            }
            if s.failureTotals.failed == 0 {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text(tr("usage", "errors.no_data")).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                UsageErrorTrendCard(charts: model.charts, allowedDims: UsageDashboard.dims(forDays: days))
                UsageFailureMixCard(totals: s.failureTotals, classRows: s.failureClasses, reasonRows: s.failureReasons)
                UsageOffendersCard(rows: s.agentFailures, agents: model.agents)
            }
        }
    }
}

private struct UsageErrorTrendCard: View {
    let charts: UsageCharts
    let allowedDims: [UsageDashboard.Dim]
    @State private var dim = UsageDashboard.Dim.daily

    var body: some View {
        let effective = allowedDims.contains(dim) ? dim : (allowedDims.first ?? .daily)
        let weekly = effective == .weekly
        let data = weekly ? charts.weeklyErrors : charts.dailyErrors
        UsageCard {
            HStack {
                Text(tr("usage", weekly ? "weekly.title_errors" : "daily.title_errors")).font(.system(size: 13, weight: .semibold))
                Spacer()
                UsageDimSegmented(allowed: allowedDims, value: $dim)
            }
            .padding(.bottom, 12)
            UsageBarChart(data: data, series: UsageSeries.errors(data.seriesIDs), formatAxis: { usageTrim($0) },
                          formatValue: { "\(Int($0))" }, footer: .rate, weekly: weekly)
                .equatable()
        }
    }
}

private struct UsageFailureMixCard: View {
    let totals: UsageFailureTotals
    let classRows: [UsageFailureClassRow]
    let reasonRows: [UsageFailureReasonRow]
    @State private var showReasons = false

    var body: some View {
        UsageCard(padded: false) {
            HStack {
                Text(tr("usage", "errors.mix_title", ["failed": totals.failed])).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(tr("usage", showReasons ? "errors.hide_reasons" : "errors.show_reasons")) { showReasons.toggle() }
                    .buttonStyle(.link)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            Divider()
            Group {
                if showReasons {
                    reasons
                } else {
                    composition
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private var composition: some View {
        let total = classRows.reduce(0) { $0 + $1.count }
        if total > 0 {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ForEach(classRows) { row in
                            Rectangle().fill(UsagePalette.failure(row.failureClass))
                                .frame(width: geo.size.width * CGFloat(row.count) / CGFloat(total))
                        }
                    }
                }
                .frame(height: 8)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
                UsageFlowLayout(spacing: 16, lineSpacing: 6) {
                    ForEach(classRows) { row in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(UsagePalette.failure(row.failureClass)).frame(width: 8, height: 8)
                            Text(UsagePalette.failureLabel(row.failureClass))
                            Text("\(row.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(Theme.Font.caption)
                    }
                }
                .accessibilityLabel(tr("usage", "errors.mix_label"))
            }
        }
    }

    private var reasons: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], alignment: .leading, spacing: 6) {
            ForEach(reasonRows) { row in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(UsagePalette.failure(row.failureClass)).frame(width: 8, height: 8)
                    Text(row.reason).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Text("\(row.count)").font(Theme.Font.caption).monospacedDigit()
                }
            }
        }
        .accessibilityLabel(tr("usage", "errors.codes_label"))
    }
}

private struct UsageOffendersCard: View {
    static let limit = 8
    let rows: [UsageAgentFailureRow]
    let agents: [String: UsageAgentInfo]
    @State private var sort = UsageOffenderSort.failed
    @State private var showAll = false

    var body: some View {
        let sorted = UsageDashboard.sortAgentFailures(rows, by: sort)
        let maxValue = sorted.first.map { sort.metric($0) } ?? 0
        let visible = showAll ? sorted : Array(sorted.prefix(Self.limit))
        UsageCard(padded: false) {
            HStack(spacing: 12) {
                Text(tr("usage", "errors.by_agent")).font(.system(size: 13, weight: .semibold))
                Spacer()
                UsageSegmented(label: tr("usage", "errors.sort_label"), value: $sort, options: [
                    (.failed, tr("usage", "errors.sort_failed")), (.rate, tr("usage", "errors.sort_rate")),
                ])
                if sorted.count > Self.limit {
                    Button(showAll ? tr("usage", "errors.show_less", ["count": Self.limit]) : tr("usage", "errors.show_all", ["count": sorted.count])) {
                        showAll.toggle()
                    }
                    .buttonStyle(.link)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            Divider()
            VStack(spacing: 0) {
                if !sorted.isEmpty {
                    HStack(spacing: 12) {
                        Text(tr("usage", "errors.header_agent")).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1.4)
                        Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                        Text(tr("usage", "errors.header_failed")).foregroundStyle(sort == .failed ? .primary : .secondary).frame(width: 64, alignment: .trailing)
                        Text(tr("usage", "errors.header_runs")).frame(width: 64, alignment: .trailing)
                        Text(tr("usage", "errors.header_rate")).foregroundStyle(sort == .rate ? .primary : .secondary).frame(width: 64, alignment: .trailing)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    Divider()
                }
                ForEach(visible) { row in
                    UsageOffenderRow(row: row, name: agents[row.agentID]?.name, sort: sort, maxValue: maxValue)
                        .equatable()
                    if row.id != visible.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}

private struct UsageOffenderRow: View, Equatable {
    @Environment(Navigator.self) private var nav
    let row: UsageAgentFailureRow
    let name: String?
    let sort: UsageOffenderSort
    let maxValue: Double

    static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.name == b.name && a.sort == b.sort && a.maxValue == b.maxValue
    }

    var body: some View {
        let segments = UsageFailureClass.allCases.filter { (row.classes[$0] ?? 0) > 0 }
        let composition = segments.map { "\(UsagePalette.failureLabel($0)) \(row.classes[$0] ?? 0)" }.joined(separator: " · ")
        let pct = maxValue > 0 ? min(1, sort.metric(row) / maxValue) : 0
        let weakSample = !UsageDashboard.hasRateSample(row)
        HStack(spacing: 12) {
            Group {
                if let name {
                    Button(name) { nav.push(.agent(row.agentID), query: ["view": "overview"], title: name) }
                        .buttonStyle(.plain)
                } else {
                    Text(tr("usage", "errors.other_agents")).italic().foregroundStyle(.secondary)
                }
            }
            .font(Theme.Font.caption)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1.4)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    HStack(spacing: 0) {
                        ForEach(segments, id: \.self) { c in
                            Rectangle().fill(UsagePalette.failure(c))
                                .frame(width: geo.size.width * pct * CGFloat(row.classes[c] ?? 0) / CGFloat(max(1, row.failed)))
                        }
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 6)
            .help(composition)
            .accessibilityLabel(composition)
            Text("\(row.failed)")
                .font(sort == .failed ? .system(size: 11, weight: .medium) : Theme.Font.caption)
                .foregroundStyle(sort == .failed ? .primary : .secondary)
                .frame(width: 64, alignment: .trailing)
            Text("\(row.total)").font(Theme.Font.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            Text(UsageFormat.rate(failed: row.failed, total: row.total))
                .font(sort == .rate && !weakSample ? .system(size: 11, weight: .medium) : Theme.Font.caption)
                .foregroundStyle(sort == .rate && !weakSample ? .primary : .secondary)
                .frame(width: 64, alignment: .trailing)
                .help(weakSample ? tr("usage", "errors.low_sample", ["count": UsageDashboard.minRateSample]) : "")
        }
        .monospacedDigit()
        .padding(.vertical, 8)
    }
}

/// Wrapping row layout for legends.
struct UsageFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
