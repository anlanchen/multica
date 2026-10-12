import MulticaCore
import SwiftUI

private enum RuntimesDimension: String { case daily, weekly }
private enum RuntimesMetric: String { case cost, tokens }

/// Period options per dimension: 7d is daily-only, 180d weekly-only.
private let runtimesRanges: [(days: Int, dims: Set<RuntimesDimension>)] = [
    (7, [.daily]), (30, [.daily, .weekly]), (90, [.daily, .weekly]), (180, [.weekly]),
]

/// Everything the section renders, derived off the main actor's render
/// path whenever usage, the window or custom pricing change.
private struct RuntimesUsageDerived: Sendable {
    var filtered: [RuntimeUsage] = []
    var totals = RuntimesUsageTotals()
    var previous = RuntimesUsageTotals()
    var dailyTokens: [RuntimesDailyTokens] = []
    var dailyCost: [RuntimesDailyCost] = []
    var weeklyTokens: [RuntimesWeeklyTokens] = []
    var weeklyCost: [RuntimesWeeklyCost] = []
    var heatmap: RuntimesHeatmap?
    var byModel: [RuntimesCostByKey] = []
    var unmapped: [String] = []
    var unmappedAll: [String] = []
    var hasTokens = false
    var grouped: [(date: String, rows: [RuntimeUsage])] = []

    static func compute(_ usage: [RuntimeUsage], days: Int, pricer: RuntimesPricer) -> RuntimesUsageDerived {
        let today = RuntimesCalendar.today(in: .current)
        let (filtered, previous) = RuntimesUsageMath.sliceWindow(usage, days: days, today: today)
        var d = RuntimesUsageDerived()
        d.filtered = filtered
        d.totals = RuntimesUsageMath.totals(filtered, pricer: pricer)
        d.previous = RuntimesUsageMath.totals(previous, pricer: pricer)
        let daily = RuntimesUsageMath.byDate(filtered, pricer: pricer)
        d.dailyTokens = daily.tokens
        d.dailyCost = daily.cost
        let weekly = RuntimesUsageMath.byWeek(usage, today: today, weekCount: max(1, Int((Double(days) / 7).rounded(.up))), pricer: pricer)
        d.weeklyTokens = weekly.tokens
        d.weeklyCost = weekly.cost
        d.heatmap = RuntimesUsageMath.heatmap(usage, today: today, pricer: pricer)
        d.byModel = RuntimesUsageMath.costByModel(filtered, pricer: pricer)
        d.unmapped = pricer.collectUnmappedModels(filtered)
        d.hasTokens = filtered.contains { $0.runtimesTotalTokens > 0 }
        d.grouped = RuntimesUsageMath.groupedByDate(filtered)
        return d
    }
}

private struct RuntimesUsageKey: Equatable {
    var usage: [RuntimeUsage]?
    var days: Int
    var pricings: [String: RuntimesModelPrice]
}

/// Runtime usage analytics (upstream `UsageSection`): one 180-day fetch,
/// sliced client-side into the selected window and the prior window.
struct RuntimesUsageSection: View {
    @Environment(WorkspaceSession.self) private var session
    let runtime: RuntimeDeviceRecord
    @State private var dimension: RuntimesDimension = .daily
    @State private var days = 30
    @State private var derived: RuntimesUsageDerived?

    var body: some View {
        let query = session.runtimesStore.usage(runtimeID: runtime.id, days: 180, timeZone: TimeZone.current.identifier)
        let pricing = RuntimesCustomPricing.shared
        Group {
            if query.value == nil && query.error == nil {
                VStack(spacing: 20) {
                    RuntimesSkeleton(height: 112, radius: 8)
                    RuntimesSkeleton(height: 224, radius: 8)
                    RuntimesSkeleton(height: 128, radius: 4)
                }
            } else if (query.value ?? []).isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar").foregroundStyle(.tertiary)
                    Text(tr("runtimes", "usage.no_data")).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Theme.border))
            } else if let derived {
                content(derived)
            } else {
                RuntimesSkeleton(height: 112, radius: 8)
            }
        }
        .task(id: runtime.id) { await query.load() }
        .task(id: RuntimesUsageKey(usage: query.value, days: days, pricings: pricing.pricings)) {
            guard let usage = query.value else { return }
            let pricer = pricing.pricer
            let window = days
            derived = await Task.detached(priority: .userInitiated) {
                RuntimesUsageDerived.compute(usage, days: window, pricer: pricer)
            }.value
        }
    }

    private func setDimension(_ next: RuntimesDimension) {
        dimension = next
        if !(runtimesRanges.first { $0.days == days }?.dims.contains(next) ?? false) {
            days = next == .daily ? 30 : 90
        }
    }

    @ViewBuilder
    private func content(_ d: RuntimesUsageDerived) -> some View {
        let costDelta = RuntimesFormat.pctChange(d.totals.cost, d.previous.cost)
        let hitRate = RuntimesFormat.cacheHitRatePercent(input: d.totals.input, cacheRead: d.totals.cacheRead, cacheWrite: d.totals.cacheWrite)
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    Text(tr("runtimes", "usage.dimension_label").uppercased()).font(Theme.Font.caption).tracking(0.6).foregroundStyle(.secondary)
                    RuntimesSegmented(selection: Binding(get: { dimension }, set: { setDimension($0) }),
                                      options: [(.daily, tr("runtimes", "usage.when_tab_daily")), (.weekly, tr("runtimes", "usage.when_tab_weekly"))])
                }
                Spacer()
                HStack(spacing: 12) {
                    Text(tr("runtimes", "usage.period_label").uppercased()).font(Theme.Font.caption).tracking(0.6).foregroundStyle(.secondary)
                    RuntimesSegmented(selection: $days, options: runtimesRanges.filter { $0.dims.contains(dimension) }.map { ($0.days, "\($0.days)d") })
                }
            }
            RuntimesCustomPricingBar(unmapped: d.unmapped)
            RuntimesCard {
                HStack(spacing: 0) {
                    RuntimesKpiCard(label: tr("runtimes", "usage.kpi_cost_label", ["days": days]), value: RuntimesFormat.usdCurrency(d.totals.cost)) {
                        if let costDelta {
                            Text(tr("runtimes", "usage.kpi_cost_delta", ["sign": costDelta > 0 ? "+" : "", "pct": costDelta]))
                                .foregroundStyle(costDelta > 0 ? Theme.warning : costDelta < 0 ? Theme.success : .secondary)
                        }
                    }
                    Divider()
                    RuntimesKpiCard(label: tr("runtimes", "usage.kpi_cache_label", ["days": days]), value: RuntimesFormat.usdCurrency(d.totals.cacheSavings),
                                    accent: d.totals.cacheSavings > 0 ? Theme.success : nil) {
                        Text(hitRate.map { tr("runtimes", "usage.kpi_cache_hint", ["pct": $0, "reads": RuntimesFormat.tokens(d.totals.cacheRead)]) } ?? "—")
                    }
                    Divider()
                    RuntimesKpiCard(label: tr("runtimes", "usage.kpi_tokens_label", ["days": days]), value: RuntimesFormat.compactNumber(Double(d.totals.tokens))) {
                        Text(tr("runtimes", "usage.kpi_tokens_hint", ["input": RuntimesFormat.tokens(d.totals.input), "output": RuntimesFormat.tokens(d.totals.output)]))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            RuntimesWhenChart(derived: d, dimension: dimension)
            RuntimesCostByBlock(runtimeID: runtime.id, days: days, byModel: d.byModel)
            RuntimesBreakdownFold(grouped: d.grouped)
        }
    }
}

private struct RuntimesWhenChart: View {
    let derived: RuntimesUsageDerived
    let dimension: RuntimesDimension
    @State private var heatmap = false
    @State private var metric: RuntimesMetric = .cost

    var body: some View {
        RuntimesCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text(tr("runtimes", "usage.when_title")).font(Theme.Font.bodyMedium)
                    if !heatmap {
                        RuntimesSegmented(selection: $metric, options: [(.cost, tr("runtimes", "usage.daily_metric_cost")), (.tokens, tr("runtimes", "usage.daily_metric_tokens"))])
                    }
                    Button { heatmap.toggle() } label: {
                        Text(tr("runtimes", "usage.when_tab_heatmap"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(heatmap ? Color(nsColor: .windowBackgroundColor) : .secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(heatmap ? Color.primary : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(heatmap ? Color.primary : Theme.border))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if !heatmap { RuntimesChartLegend() }
                }
                if heatmap {
                    Text(tr("runtimes", "usage.heatmap_caption")).font(Theme.Font.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                Group {
                    if heatmap, let map = derived.heatmap {
                        RuntimesActivityHeatmap(heatmap: map)
                    } else if dimension == .daily {
                        if metric == .tokens {
                            if derived.dailyTokens.reduce(0, { $0 + $1.total }) == 0 { RuntimesEmptyChart(derived: derived) } else { RuntimesDailyTokensChart(data: derived.dailyTokens) }
                        } else {
                            if derived.dailyCost.reduce(0, { $0 + $1.total }) == 0 { RuntimesEmptyChart(derived: derived) } else { RuntimesDailyCostChart(data: derived.dailyCost) }
                        }
                    } else {
                        if metric == .tokens {
                            if derived.weeklyTokens.reduce(0, { $0 + $1.total }) == 0 { RuntimesEmptyChart(derived: derived) } else { RuntimesWeeklyTokensChart(data: derived.weeklyTokens) }
                        } else {
                            if derived.weeklyCost.reduce(0, { $0 + $1.total }) == 0 { RuntimesEmptyChart(derived: derived) } else { RuntimesWeeklyCostChart(data: derived.weeklyCost) }
                        }
                    }
                }
                .frame(minHeight: 260)
            }
        }
    }
}

/// Why a chart would be empty: no usage, or tokens without a price.
private struct RuntimesEmptyChart: View {
    let derived: RuntimesUsageDerived

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar").foregroundStyle(.tertiary)
            if !derived.hasTokens {
                Text(tr("runtimes", "usage.empty_no_usage")).font(Theme.Font.caption).foregroundStyle(.secondary)
            } else if !derived.unmapped.isEmpty {
                Text(tr("runtimes", "usage.empty_pricing_missing")).font(Theme.Font.caption).foregroundStyle(.secondary)
                Text(derived.unmapped.joined(separator: ", ")).font(.system(size: 10, design: .monospaced))
                Text(tr("runtimes", "usage.empty_pricing_hint")).font(Theme.Font.micro).foregroundStyle(.secondary)
            } else {
                Text(tr("runtimes", "usage.empty_zero_cost")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .aspectRatio(3, contentMode: .fit)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Theme.border))
    }
}

/// Entry into custom pricing: a warning when the window has unpriced
/// models, a quiet row while overrides exist, hidden otherwise.
private struct RuntimesCustomPricingBar: View {
    let unmapped: [String]
    @State private var open = false

    var body: some View {
        let hasOverrides = !RuntimesCustomPricing.shared.pricings.isEmpty
        if !unmapped.isEmpty || hasOverrides {
            let gap = !unmapped.isEmpty
            HStack(spacing: 12) {
                if gap {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("runtimes", "usage.unmapped_notice", ["count": unmapped.count]))
                        Text(unmapped.joined(separator: ", ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(tr("runtimes", "usage.custom_pricing.active_notice")).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(tr("runtimes", gap ? "usage.custom_pricing.open_button" : "usage.custom_pricing.edit_button")) { open = true }
                    .controlSize(.small)
            }
            .font(Theme.Font.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(gap ? Theme.warning.opacity(0.1) : Color.primary.opacity(0.02)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(gap ? Theme.warning.opacity(0.3) : Theme.border))
            .sheet(isPresented: $open) { RuntimesCustomPricingDialog(unmapped: unmapped) }
        }
    }
}

private enum RuntimesCostByTab: String { case agent, model }

private struct RuntimesCostByBlock: View {
    @Environment(WorkspaceSession.self) private var session
    let runtimeID: String
    let days: Int
    let byModel: [RuntimesCostByKey]
    @State private var tab: RuntimesCostByTab = .agent
    @State private var byAgent: [RuntimesCostByKey] = []

    var body: some View {
        let query = session.runtimesStore.usageByAgent(runtimeID: runtimeID, days: days, timeZone: TimeZone.current.identifier)
        let pricing = RuntimesCustomPricing.shared
        let rows = tab == .agent ? byAgent : byModel
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(tr("runtimes", tab == .agent ? "usage.cost_by_title_agent" : "usage.cost_by_title_model")).font(Theme.Font.bodyMedium)
                RuntimesSegmented(selection: $tab, options: [(.agent, tr("runtimes", "usage.cost_by_tab_agent")), (.model, tr("runtimes", "usage.cost_by_tab_model"))])
                Spacer()
                Text(tr("runtimes", tab == .agent ? "usage.cost_by_caption_agent" : "usage.cost_by_caption_model", ["count": rows.count]))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
            Divider()
            Group {
                if rows.isEmpty {
                    Text(tr("runtimes", "usage.empty_no_usage")).font(Theme.Font.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                } else {
                    let maxCost = rows.map(\.cost).max() ?? 0
                    VStack(spacing: 8) {
                        ForEach(rows) { row in
                            HStack(spacing: 12) {
                                Group {
                                    if tab == .agent {
                                        HStack(spacing: 8) {
                                            ActorAvatar(type: "agent", id: row.key, size: 22)
                                            Text(session.agentRecords.item(row.key)?.name ?? row.key).font(Theme.Font.bodyMedium).lineLimit(1)
                                        }
                                    } else {
                                        Text(row.key).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(RuntimesPalette.muted)
                                        Capsule().fill(RuntimesPalette.chart1).frame(width: maxCost > 0 ? g.size.width * row.cost / maxCost : 0)
                                    }
                                }
                                .frame(height: 8)
                                .frame(maxWidth: .infinity)
                                .layoutPriority(1)
                                Text(RuntimesFormat.tokens(row.tokens)).font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                                Text(RuntimesFormat.usd2(row.cost)).font(Theme.Font.bodyMedium.monospacedDigit()).frame(width: 80, alignment: .trailing)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding(.top, 16)
        }
        .task(id: "\(tab.rawValue)|\(days)") { if tab == .agent { await query.load() } }
        .task(id: RuntimesByAgentKey(rows: query.value, pricings: pricing.pricings)) {
            byAgent = RuntimesUsageMath.costByAgent(query.value ?? [], pricer: pricing.pricer)
        }
    }
}

private struct RuntimesByAgentKey: Equatable {
    var rows: [RuntimeUsageByAgent]?
    var pricings: [String: RuntimesModelPrice]
}

private struct RuntimesBreakdownFold: View {
    let grouped: [(date: String, rows: [RuntimeUsage])]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                    Text(tr("runtimes", "usage.daily_breakdown_toggle"))
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if open {
                RuntimesCard {
                    VStack(spacing: 0) {
                        row(tr("runtimes", "usage.table_date"), tr("runtimes", "usage.table_model"), tr("runtimes", "usage.table_input"),
                            tr("runtimes", "usage.table_output"), tr("runtimes", "usage.table_cache_r"), tr("runtimes", "usage.table_cache_w"), header: true)
                        Divider()
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(grouped, id: \.date) { group in
                                    ForEach(Array(group.rows.enumerated()), id: \.offset) { _, u in
                                        row(group.date, u.model, RuntimesFormat.tokens(u.inputTokens), RuntimesFormat.tokens(u.outputTokens),
                                            RuntimesFormat.tokens(u.cacheReadTokens), RuntimesFormat.tokens(u.cacheWriteTokens), header: false)
                                        Divider()
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 256)
                    }
                }
                .padding(16)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            }
        }
    }

    private func row(_ date: String, _ model: String, _ i: String, _ o: String, _ r: String, _ w: String, header: Bool) -> some View {
        HStack(spacing: 8) {
            Text(date).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(model).font(header ? Theme.Font.caption.weight(.medium) : .system(size: 11, design: .monospaced)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(i).frame(width: 80, alignment: .trailing)
            Text(o).frame(width: 80, alignment: .trailing)
            Text(r).frame(width: 80, alignment: .trailing)
            Text(w).frame(width: 80, alignment: .trailing)
        }
        .font(header ? Theme.Font.caption.weight(.medium) : Theme.Font.caption.monospacedDigit())
        .foregroundStyle(header ? .secondary : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, header ? 8 : 6)
    }
}

extension RuntimesFormat {
    /// Locale currency (`$1,234.56`) like upstream `CurrencyNumberFlow`.
    static func usdCurrency(_ n: Double) -> String {
        n.formatted(.currency(code: "USD").locale(Locale(identifier: L10n.shared.language)))
    }

    /// Compact locale number (`960.1M`) like upstream `CompactNumberFlow`.
    static func compactNumber(_ n: Double) -> String {
        n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: L10n.shared.language)))
    }
}
