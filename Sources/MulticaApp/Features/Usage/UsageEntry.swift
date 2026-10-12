import MulticaCore
import SwiftUI

/// Workspace usage dashboard (`/{slug}/usage`, upstream dashboard-page.tsx):
/// a Usage tab ("what did this cost") and an Errors tab ("what broke"),
/// sharing the page-scoped period and project filters.
struct UsagePage: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @State private var model = UsageModel()
    @State private var days = 30
    @State private var projectValue = UsageProjectFilter.all

    private var tab: String { nav.query("tab") == "errors" ? "errors" : "usage" }

    /// A stale project id (deleted, or from another workspace) means no filter.
    private var projectID: String? {
        projectValue == UsageProjectFilter.all || session.projects.item(projectValue) == nil ? nil : projectValue
    }

    private var loadKey: String { "\(days)|\(projectID ?? "")" }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar").foregroundStyle(.secondary)
                    Text(tr("usage", "title")).font(Theme.Font.bodyMedium)
                }
            } trailing: {
                HStack(spacing: 4) {
                    if let label = freshnessLabel {
                        Text(label).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await model.load(session: session, days: days, projectID: projectID) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(model.isRefreshing ? 360 : 0))
                            .animation(model.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                       value: model.isRefreshing)
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isRefreshing)
                    .help(tr("usage", "header.refresh"))
                }
            }
            toolbar
            ScrollView {
                Group {
                    if tab == "errors" {
                        if model.hasErrorData {
                            UsageErrorsTab(model: model, days: model.snapshotDays)
                        } else {
                            UsageSkeleton()
                        }
                    } else if !model.hasUsageData {
                        UsageSkeleton()
                    } else if model.snapshot.usageHasNoData {
                        UsageEmptyDashboard()
                    } else {
                        UsageTab(model: model, days: model.snapshotDays)
                    }
                }
                .frame(maxWidth: 1152)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .tabTitle(tr("usage", "title"))
        .task { await session.projects.loadIfNeeded() }
        .task(id: loadKey) {
            await model.load(session: session, days: days, projectID: projectID)
            // The rollups materialize every five minutes; poll at that cadence while visible.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                await model.load(session: session, days: days, projectID: projectID)
            }
        }
        .task(id: session.agentRecords.items.count) { await model.recompute(session: session) }
    }

    private var freshnessLabel: String? {
        guard let zone = TimeZone(identifier: model.timezone) else { return nil }
        let tz = Date().formatted(Date.FormatStyle(timeZone: zone).timeZone(.localizedGMT(.short)))
        guard let updated = model.lastUpdated else { return tz }
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = zone
        return tr("usage", "header.timezone_and_updated", ["tz": tz, "time": updated.formatted(style)])
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                UsageLineTab(title: tr("usage", "tab_usage"), selected: tab == "usage") { nav.setQuery("tab", nil) }
                UsageLineTab(title: tr("usage", "errors.title"), selected: tab == "errors") { nav.setQuery("tab", "errors") }
            }
            Spacer(minLength: 8)
            UsageTimeRangeFilter(days: $days)
            UsageProjectFilter(value: $projectValue)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct UsageLineTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? Color.primary : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Page-scoped period: a button stating the value plus a single-select menu.
struct UsageTimeRangeFilter: View {
    @Binding var days: Int

    var body: some View {
        let current = UsageDashboard.timeRanges.first { $0.days == days } ?? UsageDashboard.timeRanges[2]
        Menu {
            Picker(tr("usage", "filter.period_label"), selection: $days) {
                ForEach(UsageDashboard.timeRanges) { r in Text(r.label).tag(r.days) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                Text(current.label).monospacedDigit()
            }
        }
        .menuStyle(.button)
        .fixedSize()
        .help(tr("usage", "filter.period_label"))
    }
}

/// Page-scoped project filter.
struct UsageProjectFilter: View {
    static let all = "__all__"
    @Environment(WorkspaceSession.self) private var session
    @Binding var value: String

    var body: some View {
        let selected = value == Self.all ? nil : session.projects.item(value)
        Menu {
            Picker(tr("usage", "filter.project_label"), selection: $value) {
                Label(tr("usage", "filter.all_projects"), systemImage: "folder").tag(Self.all)
                ForEach(session.projects.items) { p in
                    Text("\(p.icon.map { $0.isEmpty ? "" : "\($0) " } ?? "")\(p.title)").tag(p.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                if let selected {
                    ProjectIconView(icon: selected.icon, size: 12)
                    Text(selected.title).lineLimit(1).frame(maxWidth: 160)
                } else {
                    Image(systemName: "folder")
                    Text(tr("usage", "filter.all_projects"))
                }
            }
            .foregroundStyle(selected == nil ? .secondary : .primary)
        }
        .menuStyle(.button)
        .fixedSize()
        .help(tr("usage", "filter.project_label"))
    }
}

private struct UsageSkeleton: View {
    var body: some View {
        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)).frame(height: 112)
            RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)).frame(height: 224)
            RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)).frame(height: 192)
        }
        .overlay { ProgressView().controlSize(.small) }
    }
}

private struct UsageEmptyDashboard: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar").font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(tr("usage", "empty.title")).font(Theme.Font.bodyMedium).padding(.top, 6)
            Text(tr("usage", "empty.body")).font(Theme.Font.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

/// KPI row helper: tiles separated by vertical dividers in one bordered card.
struct UsageKpiRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) { content() }
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }
}

func usageLessThanMinute() -> String { tr("usage", "duration.less_than_minute") }

// MARK: - Usage tab

private struct UsageTab: View {
    let model: UsageModel
    let days: Int

    var body: some View {
        let s = model.snapshot
        let lessThanMinute = usageLessThanMinute()
        VStack(alignment: .leading, spacing: 20) {
            UsageKpiRow {
                UsageKpiTile(label: tr("usage", "kpi.cost_label", ["days": days])) {
                    Text(s.totals.cost.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                        .contentTransition(.numericText(value: s.totals.cost))
                }
                Divider()
                UsageKpiTile(label: tr("usage", "kpi.tokens_label", ["days": days]), value: {
                    Text(Double(s.totals.tokens).formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))
                        .contentTransition(.numericText(value: Double(s.totals.tokens)))
                }, hint: tr("usage", "kpi.tokens_hint", ["input": UsageFormat.tokens(Double(s.totals.input)),
                                                         "output": UsageFormat.tokens(Double(s.totals.output))]))
                Divider()
                UsageKpiTile(label: tr("usage", "kpi.run_time_label", ["days": days]), value: {
                    Text(UsageFormat.duration(Double(s.runTimeSeconds), lessThanMinute: lessThanMinute))
                        .contentTransition(.numericText(value: Double(s.runTimeSeconds)))
                }, hint: tr("usage", "kpi.run_time_hint", ["tasks": s.runTimeTasks]))
                Divider()
                UsageKpiTile(label: tr("usage", "kpi.tasks_label", ["days": days]), value: {
                    Text("\(s.runTimeTasks)").contentTransition(.numericText(value: Double(s.runTimeTasks)))
                }, hint: tr("usage", "kpi.tasks_hint", ["failed": s.runTimeFailed]))
            }
            UsageTrendCard(charts: model.charts, allowedDims: UsageDashboard.dims(forDays: days))
            UsageLeaderboard(rows: s.agentRows, agents: model.agents, deletedAgentCount: s.deletedAgentCount)
        }
    }
}

private enum UsageMetric: String { case tokens, cost, time, tasks }

/// Spend over time: one x-axis, four metrics behind a toggle.
private struct UsageTrendCard: View {
    let charts: UsageCharts
    let allowedDims: [UsageDashboard.Dim]
    @State private var metric = UsageMetric.tokens
    @State private var dim = UsageDashboard.Dim.daily

    var body: some View {
        // Derived, never written back: narrowing the range keeps the reader's choice.
        let effective = allowedDims.contains(dim) ? dim : (allowedDims.first ?? .daily)
        let weekly = effective == .weekly
        let lessThanMinute = usageLessThanMinute()
        let data: UsageChartData = switch (metric, weekly) {
        case (.cost, false): charts.dailyCost
        case (.cost, true): charts.weeklyCost
        case (.tokens, false): charts.dailyTokens
        case (.tokens, true): charts.weeklyTokens
        case (.time, false): charts.dailyTime
        case (.time, true): charts.weeklyTime
        case (.tasks, false): charts.dailyTasks
        case (.tasks, true): charts.weeklyTasks
        }
        UsageCard {
            HStack(spacing: 12) {
                Text(tr("usage", "\(weekly ? "weekly" : "daily").title_\(metric.rawValue)")).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                UsageSegmented(label: tr("usage", "daily.metric_label"), value: $metric, options: [
                    (.tokens, tr("usage", "daily.metric_tokens")), (.cost, tr("usage", "daily.metric_cost")),
                    (.time, tr("usage", "daily.metric_time")), (.tasks, tr("usage", "daily.metric_tasks")),
                ])
                UsageDimSegmented(allowed: allowedDims, value: $dim)
            }
            .padding(.bottom, 12)
            if data.sum == 0 {
                UsageEmptyChart(message: tr("usage", "daily.no_data"))
            } else {
                switch metric {
                case .cost:
                    UsageBarChart(data: data, series: UsageSeries.tokenStack, formatAxis: { "$\(usageTrim($0))" },
                                  formatValue: { String(format: "$%.2f", $0) }, weekly: weekly).equatable()
                case .tokens:
                    UsageBarChart(data: data, series: UsageSeries.tokenStack, formatAxis: { UsageFormat.tokens($0) },
                                  formatValue: { Int($0).formatted() }, weekly: weekly).equatable()
                case .time:
                    UsageBarChart(data: data, series: UsageSeries.time,
                                  formatAxis: { UsageFormat.duration($0, lessThanMinute: lessThanMinute) },
                                  formatValue: { UsageFormat.duration($0, lessThanMinute: lessThanMinute) },
                                  footer: .none, weekly: weekly).equatable()
                case .tasks:
                    UsageBarChart(data: data, series: UsageSeries.tasks, formatAxis: { usageTrim($0) },
                                  formatValue: { Int($0).formatted() }, weekly: weekly).equatable()
                }
            }
        }
    }
}

func usageTrim(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
}

// MARK: - Leaderboard

private struct UsageLeaderboard: View {
    static let limit = 10
    let rows: [UsageAgentRow]
    let agents: [String: UsageAgentInfo]
    let deletedAgentCount: Int
    @State private var sort = UsageLeaderboardSort.tokens
    @State private var showAll = false

    var body: some View {
        let sorted = UsageDashboard.sortLeaderboard(rows, by: sort)
        let maxValue = sorted.map { sort.metric($0) }.max() ?? 0
        let visible = showAll ? sorted : Array(sorted.prefix(Self.limit))
        let named = rows.filter { !UsageDashboard.isSyntheticAgentRow($0.agentID) }.count
        UsageCard(padded: false) {
            HStack(spacing: 12) {
                Text(tr("usage", "leaderboard.title")).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                UsageSegmented(label: tr("usage", "leaderboard.sort_label"), value: $sort, options: [
                    (.tokens, tr("usage", "leaderboard.header_tokens")), (.cost, tr("usage", "leaderboard.header_cost")),
                    (.time, tr("usage", "leaderboard.header_time")), (.tasks, tr("usage", "leaderboard.header_tasks")),
                ])
                Text(deletedAgentCount > 0
                     ? tr("usage", "leaderboard.caption_with_deleted", ["count": named, "deleted": deletedAgentCount])
                     : tr("usage", "leaderboard.caption", ["count": named]))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                if sorted.count > Self.limit {
                    Button(showAll ? tr("usage", "leaderboard.show_less", ["count": Self.limit]) : tr("usage", "leaderboard.show_all")) {
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
            if sorted.isEmpty {
                Text(tr("usage", "leaderboard.no_data"))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                UsageLeaderboardHeader(sort: sort)
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(visible) { row in
                        UsageLeaderboardRow(row: row, info: agents[row.agentID], sort: sort, maxValue: maxValue)
                            .equatable()
                        if row.id != visible.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

private enum UsageLeaderboardColumns {
    static let metric: CGFloat = 80
    static let tasks: CGFloat = 64
}

private struct UsageLeaderboardHeader: View {
    let sort: UsageLeaderboardSort

    var body: some View {
        HStack(spacing: 12) {
            Text(tr("usage", "leaderboard.header_agent")).frame(minWidth: 160, maxWidth: .infinity, alignment: .leading).layoutPriority(1.6)
            Color.clear.frame(minWidth: 96, maxWidth: .infinity).frame(height: 1)
            column("leaderboard.header_tokens", .tokens, UsageLeaderboardColumns.metric)
            column("leaderboard.header_cost", .cost, UsageLeaderboardColumns.metric)
            column("leaderboard.header_time", .time, UsageLeaderboardColumns.metric)
            column("leaderboard.header_tasks", .tasks, UsageLeaderboardColumns.tasks)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func column(_ key: String, _ s: UsageLeaderboardSort, _ width: CGFloat) -> some View {
        Text(tr("usage", key)).foregroundStyle(sort == s ? .primary : .secondary).frame(width: width, alignment: .trailing)
    }
}

private struct UsageLeaderboardRow: View, Equatable {
    @Environment(Navigator.self) private var nav
    let row: UsageAgentRow
    let info: UsageAgentInfo?
    let sort: UsageLeaderboardSort
    let maxValue: Double

    static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.info == b.info && a.sort == b.sort && a.maxValue == b.maxValue
    }

    var body: some View {
        let isDeleted = row.agentID == UsageDashboard.deletedAgentsRowID
        let isBucket = isDeleted || row.agentID == UsageDashboard.restrictedAgentsRowID
        let unavailable = !row.hasUsageTotals
        let incomplete = row.unreportedTaskCount > 0
        let pending = row.hasReportedUsage && !row.hasUsageTotals
        let pct = maxValue > 0 ? sort.metric(row) / maxValue : 0
        let lessThanMinute = usageLessThanMinute()
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                if isBucket {
                    Image(systemName: isDeleted ? "trash" : "eye.slash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                } else {
                    AvatarView(name: info?.name ?? row.agentID, url: info?.avatarURL, kind: .agent, size: 22)
                }
                VStack(alignment: .leading, spacing: 1) {
                    if isBucket {
                        Text(tr("usage", isDeleted ? "leaderboard.deleted_agents" : "leaderboard.other_agents"))
                            .italic().foregroundStyle(.secondary)
                    } else {
                        Button(info?.name ?? row.agentID) { nav.push(.agent(row.agentID)) }
                            .buttonStyle(.plain)
                    }
                    if let coverage = coverageText(unreported: row.unreportedTaskCount, pending: pending) {
                        Text(coverage).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1).help(coverage)
                    }
                }
                .font(Theme.Font.bodyMedium)
                .lineLimit(1)
            }
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1.6)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(UsagePalette.chart1).frame(width: geo.size.width * pct)
                }
            }
            .frame(minWidth: 96, maxWidth: .infinity)
            .frame(height: 8)
            metric(unavailable ? "—" : "\(incomplete ? "≥" : "")\(UsageFormat.tokens(Double(row.tokens)))", active: sort == .tokens)
            metric(unavailable ? "—" : "\(incomplete ? "≥" : "")$\(String(format: "%.2f", row.cost))", active: sort == .cost, emphasized: true)
            metric(isDeleted ? "—" : UsageFormat.duration(Double(row.seconds), lessThanMinute: lessThanMinute), active: sort == .time)
            metric(isDeleted ? "—" : "\(row.taskCount)", active: sort == .tasks, width: UsageLeaderboardColumns.tasks)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func metric(_ text: String, active: Bool, emphasized: Bool = false, width: CGFloat = UsageLeaderboardColumns.metric) -> some View {
        Text(text)
            .font(active && emphasized ? Theme.Font.bodyMedium : (active ? .system(size: 11, weight: .medium) : Theme.Font.caption))
            .foregroundStyle(active ? .primary : .secondary)
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    private func coverageText(unreported: Int, pending: Bool) -> String? {
        if unreported > 0 {
            return tr("usage", pending ? "leaderboard.usage_unreported_pending" : "leaderboard.usage_unreported", ["count": unreported])
        }
        return pending ? tr("usage", "leaderboard.usage_totals_pending") : nil
    }
}
