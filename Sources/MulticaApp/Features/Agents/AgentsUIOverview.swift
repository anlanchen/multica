import MulticaCore
import Observation
import SwiftUI

/// Recent work for one agent, fetched one bounded page at a time.
@MainActor
@Observable
final class AgentsUIRecentTasksModel {
    private(set) var tasks: [AgentTaskRecord] = []
    private(set) var nextCursor: String?
    private(set) var loaded = false
    private(set) var loadingMore = false
    private(set) var loadMoreFailed = false
    /// Issue identifier + title for rows, resolved once per issue.
    private(set) var issues: [String: (identifier: String, title: String)] = [:]
    @ObservationIgnored private var resolving: Set<String> = []

    func reload(agentID: String, api: APIClient) async {
        guard let page = try? await api.agentsUITasksPage(agentId: agentID) else {
            loaded = true
            return
        }
        // Keep already-fetched older pages; refresh the newest page in place.
        var byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for t in page.tasks { byID[t.id] = t }
        let merged = Array(byID.values)
        if merged != tasks { tasks = merged }
        if !loaded { nextCursor = page.nextCursor }
        loaded = true
    }

    func loadMore(agentID: String, api: APIClient) async -> Bool {
        guard let cursor = nextCursor, !loadingMore else { return false }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await api.agentsUITasksPage(agentId: agentID, before: cursor)
            var byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for t in page.tasks { byID[t.id] = t }
            tasks = Array(byID.values)
            nextCursor = page.nextCursor
            loadMoreFailed = false
            return true
        } catch {
            loadMoreFailed = true
            return false
        }
    }

    func resolveIssues(_ ids: [String], session: WorkspaceSession) {
        for id in ids where !id.isEmpty && issues[id] == nil {
            if let m = session.issues.model(id) {
                issues[id] = (m.issue.identifier, m.issue.title)
                continue
            }
            guard !resolving.contains(id) else { continue }
            resolving.insert(id)
            Task {
                if let i = try? await session.api.issue(id) { issues[id] = (i.identifier, i.title) }
            }
        }
    }
}

/// Now / Last 30 days / Recent work (upstream tabs/activity-tab).
struct AgentsUIActivityTab: View {
    @Environment(WorkspaceSession.self) private var session
    let agent: AgentRecord
    var showPerformance = true

    @State private var recent = AgentsUIRecentTasksModel()
    @State private var displayLimit = 10

    private var store: AgentsUIStore { session.agentsUIStore }

    var body: some View {
        let active = activeTasks
        let finished = recentAll
        let shown = Array(finished.prefix(displayLimit))
        VStack(alignment: .leading, spacing: 24) {
            section(tr("agents", "tab_body.activity.section_now"),
                    subtitle: active.isEmpty ? tr("agents", "tab_body.activity.subtitle_no_active")
                        : tr("agents", "tab_body.activity.subtitle_active", ["count": active.count])) {
                if active.isEmpty {
                    emptyText(tr("agents", "tab_body.activity.empty_now"))
                } else {
                    VStack(spacing: 8) {
                        ForEach(active, id: \.id) { t in
                            AgentsUITaskRow(task: t, issue: recent.issues[t.issueId], activeMode: true, agentName: agent.name)
                        }
                    }
                }
            }
            if showPerformance {
                Divider()
                last30d
            }
            Divider()
            section(tr("agents", "tab_body.activity.section_recent"), subtitle: recentSubtitle(shown: shown.count, total: finished.count)) {
                if !recent.loaded {
                    AgentsUIRecentSkeleton()
                } else if shown.isEmpty {
                    if recent.nextCursor == nil { emptyText(tr("agents", "tab_body.activity.empty_recent")) }
                } else {
                    VStack(spacing: 0) {
                        ForEach(shown, id: \.id) { t in
                            AgentsUITaskRow(task: t, issue: recent.issues[t.issueId], activeMode: false, agentName: agent.name)
                            if t.id != shown.last?.id { Divider() }
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
                }
                if recent.loaded && (finished.count > shown.count || recent.nextCursor != nil) {
                    Button(recent.loadMoreFailed ? tr("agents", "detail.try_again") : tr("agents", "tab_body.activity.show_more")) {
                        showMore(available: finished.count)
                    }
                    .buttonStyle(.borderless)
                    .disabled(recent.loadingMore)
                }
            }
        }
        .task(id: agent.id) { await recent.reload(agentID: agent.id, api: session.api) }
        .task(id: session.revision("task")) {
            guard recent.loaded else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await recent.reload(agentID: agent.id, api: session.api)
        }
        .onChange(of: (active + shown).map(\.issueId), initial: true) { _, ids in
            recent.resolveIssues(ids, session: session)
        }
    }

    private var activeTasks: [AgentTaskRecord] {
        let rank = ["running": 0, "dispatched": 1, "waiting_local_directory": 2, "queued": 3]
        return store.snapshot
            .filter { $0.agentId == agent.id && $0.chatSessionId == nil && AgentsUI.isActiveTaskStatus($0.status) }
            .sorted { a, b in
                let ra = rank[a.status] ?? 99, rb = rank[b.status] ?? 99
                if ra != rb { return ra < rb }
                return (Timestamp.parse(a.createdAt) ?? .distantPast) < (Timestamp.parse(b.createdAt) ?? .distantPast)
            }
    }

    private var recentAll: [AgentTaskRecord] {
        recent.tasks
            .filter { $0.chatSessionId == nil && $0.completedAt != nil && ["completed", "failed", "cancelled"].contains($0.status) }
            .sorted { (Timestamp.parse($0.completedAt ?? "") ?? .distantPast) > (Timestamp.parse($1.completedAt ?? "") ?? .distantPast) }
    }

    private func recentSubtitle(shown: Int, total: Int) -> String {
        guard recent.loaded else { return "" }
        if shown == 0 { return recent.nextCursor == nil ? tr("agents", "tab_body.activity.subtitle_no_recent") : "" }
        if recent.nextCursor == nil && total > shown {
            return tr("agents", "tab_body.activity.subtitle_recent_progress", ["shown": shown, "total": total])
        }
        return tr("agents", "tab_body.activity.subtitle_recent_latest", ["count": shown])
    }

    private func showMore(available: Int) {
        if displayLimit < available {
            displayLimit += 20
        } else if recent.nextCursor != nil {
            Task {
                if await recent.loadMore(agentID: agent.id, api: session.api) { displayLimit += 20 }
            }
        }
    }

    private var last30d: some View {
        let activity = AgentsUI.activity(buckets: store.activityBuckets.filter { $0.agentId == agent.id }, createdAt: agent.createdAt, now: Date())
        let s = AgentsUI.summarize(activity, windowDays: 30)
        return section(tr("agents", "tab_body.activity.section_last_30d"), subtitle: tr("agents", "tab_body.activity.subtitle_performance")) {
            if s.totalRuns == 0 {
                emptyText(tr("agents", "tab_body.activity.empty_30d"))
            } else {
                HStack(alignment: .bottom, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(s.totalRuns.formatted()).font(.system(size: 30, weight: .bold)).monospacedDigit()
                            Text(tr("agents", "tab_body.activity.runs", ["count": s.totalRuns])).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Text(s.successRate.map { tr("agents", "tab_body.activity.success_pct", ["percent": $0]) } ?? "—")
                                .help(s.successRate == nil ? tr("agents", "tab_body.activity.success_unavailable") : tr("agents", "tab_body.activity.success_hint"))
                            if activity.avgDurationMs > 0 {
                                Text("·").foregroundStyle(.tertiary)
                                Text(tr("agents", "tab_body.activity.avg_duration", ["value": AgentsUI.formatDuration(ms: activity.avgDurationMs)]))
                            }
                            if s.totalFailed > 0 {
                                Text("·").foregroundStyle(.tertiary)
                                Text(tr("agents", "tab_body.activity.failed_count", ["count": s.totalFailed])).foregroundStyle(Theme.destructive)
                            }
                            if s.totalCancelled > 0 {
                                Text("·").foregroundStyle(.tertiary)
                                Text(tr("agents", "tab_body.activity.cancelled_count", ["count": s.totalCancelled]))
                            }
                        }
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    AgentsUISparkline(buckets: s.buckets, height: 32).frame(width: 120)
                }
            }
        }
    }

    private func section<C: View>(_ title: String, subtitle: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(Theme.Font.micro).foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func emptyText(_ s: String) -> some View {
        Text(s).font(Theme.Font.caption).italic().foregroundStyle(.secondary)
    }
}

struct AgentsUIRecentSkeleton: View {
    var body: some View {
        let titles: [CGFloat] = [0.6, 0.8, 0.5, 0.66]
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { i in
                HStack(spacing: 12) {
                    Circle().fill(Color.primary.opacity(0.07)).frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 6) {
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: g.size.width * titles[i], height: 12)
                        }
                        .frame(height: 12)
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.05)).frame(width: 120, height: 10)
                    }
                }
                .padding(12)
                if i < 3 { Divider() }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
    }
}

/// One task row: status glyph, source + issue title, meta line, and hover
/// actions (open issue, transcript, cancel).
struct AgentsUITaskRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let task: AgentTaskRecord
    let issue: (identifier: String, title: String)?
    let activeMode: Bool
    let agentName: String
    @State private var hovering = false
    @State private var cancelling = false
    @State private var transcriptOpen = false

    var body: some View {
        let (icon, color) = task.agentsUIStatusIcon
        let running = task.status == "running"
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 14))
                .symbolEffect(.pulse, isActive: running)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: sourceIcon).font(.system(size: 10)).foregroundStyle(.tertiary).help(sourceLabel)
                    if let issue { Text(issue.identifier).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                    Text(title).font(Theme.Font.body).lineLimit(1)
                        .help(task.triggerSummary.map { tr("agents", "tab_body.activity.triggered_by") + "\n" + $0 } ?? "")
                }
                HStack(spacing: 6) {
                    Text(task.agentsUICancellationLabel ?? task.agentsUIStatusLabel).foregroundStyle(color)
                    sep
                    Text(timeText)
                    if let d = durationText { sep; Text(d) }
                    if let f = task.agentsUIFailureLabel { sep; Text(f).foregroundStyle(Theme.destructive).lineLimit(1) }
                    if let initiator = task.attribution?.initiator {
                        sep
                        AvatarView(name: initiator.name ?? initiator.email ?? "", url: initiator.avatarUrl, size: 14)
                            .help(initiator.name ?? initiator.email ?? "")
                    }
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if !task.issueId.isEmpty {
                    Button { nav.push(.issue(task.issueId)) } label: { Image(systemName: "arrow.up.right") }
                        .help(tr("agents", "tab_body.activity.open_issue_tooltip"))
                }
                if task.status != "queued" {
                    Button { transcriptOpen = true } label: { Image(systemName: "text.alignleft") }
                        .help(tr("agents", "tab_body.activity.transcript_tooltip"))
                }
                if activeMode && ["queued", "dispatched", "running"].contains(task.status) {
                    Button { cancel() } label: { Image(systemName: "xmark") }
                        .disabled(cancelling)
                        .help(cancelling ? tr("agents", "tab_body.activity.cancelling_tooltip") : tr("agents", "tab_body.activity.cancel_task_tooltip"))
                }
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
        }
        .padding(12)
        .background(activeMode ? RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(running ? Theme.brand.opacity(0.05) : .clear) : nil)
        .overlay(activeMode ? RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(running ? Theme.brand.opacity(0.4) : Theme.border) : nil)
        .background(!activeMode && hovering ? Theme.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .sheet(isPresented: $transcriptOpen) { TaskTranscriptSheet(task: task.agentsUITask) }
    }

    private var sep: some View { Text("·").foregroundStyle(.tertiary) }

    private var sourceIcon: String {
        if !task.issueId.isEmpty { return "number" }
        if task.chatSessionId != nil { return "bubble.left" }
        if task.autopilotRunId != nil { return "flowchart" }
        return "questionmark.circle"
    }

    private var sourceLabel: String {
        if !task.issueId.isEmpty { return tr("agents", "tab_body.activity.source_issue") }
        if task.chatSessionId != nil { return tr("agents", "tab_body.activity.source_chat") }
        if task.autopilotRunId != nil { return tr("agents", "tab_body.activity.source_autopilot") }
        return tr("agents", "tab_body.activity.source_untracked")
    }

    private var title: String {
        if let issue { return issue.title }
        if !task.issueId.isEmpty { return tr("agents", "tab_body.activity.issue_short_fallback", ["prefix": String(task.issueId.prefix(8))]) }
        let terminal = ["completed", "failed", "cancelled"].contains(task.status)
        if task.kind == "quick_create" {
            return terminal ? tr("agents", "tab_body.activity.source_quick_create") : tr("agents", "tab_body.activity.source_creating_issue")
        }
        if task.chatSessionId != nil { return tr("agents", "tab_body.activity.source_chat_session") }
        if task.autopilotRunId != nil { return tr("agents", "tab_body.activity.source_autopilot_run") }
        return tr("agents", "tab_body.activity.source_untracked")
    }

    private var timeText: String {
        if activeMode {
            if task.status == "running", let s = task.startedAt {
                return tr("agents", "tab_body.activity.started_prefix", ["when": Formatters.relative(s)])
            }
            if task.status == "dispatched", let d = task.dispatchedAt {
                return tr("agents", "tab_body.activity.dispatched_prefix", ["when": Formatters.relative(d)])
            }
            return tr("agents", "tab_body.activity.queued_prefix", ["when": Formatters.relative(task.createdAt)])
        }
        return task.completedAt.map { Formatters.relative($0) } ?? "—"
    }

    private var durationText: String? {
        guard !activeMode, let s = task.startedAt.flatMap(Timestamp.parse), let e = task.completedAt.flatMap(Timestamp.parse) else { return nil }
        let ms = e.timeIntervalSince(s) * 1000
        return ms > 0 ? AgentsUI.formatDuration(ms: ms) : nil
    }

    private func cancel() {
        cancelling = true
        Task {
            do {
                _ = try await session.api.cancelTaskById(task.id)
                await session.agentsUIStore.loadSnapshot()
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("agents", "tab_body.activity.cancel_failed_toast"), kind: .error)
                cancelling = false
            }
        }
    }
}

/// Read-only context card on the Overview (upstream AgentOverviewSummary).
struct AgentsUIOverviewSummary: View {
    @Environment(WorkspaceSession.self) private var session
    let agent: AgentRecord
    let runtime: RuntimeDeviceRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("agents", "overview.agent_context")).font(Theme.Font.bodyMedium)
            VStack(alignment: .leading, spacing: 10) {
                if let owner = agent.ownerId.flatMap({ session.directory.member(userID: $0) }) {
                    row(tr("agents", "inspector.prop_owner")) {
                        AvatarView(name: owner.name, url: owner.avatarURL, size: 16)
                        Text(owner.name).lineLimit(1)
                    }
                }
                row(tr("agents", "overview.access")) { AgentsUIVisibilityBadge(visibility: agent.visibility) }
                row(tr("agents", "inspector.prop_runtime")) {
                    AgentsUIRuntimeDot(online: runtime?.status == "online")
                    Image(systemName: "server.rack").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(runtime.map(AgentsUI.runtimeDisplayLabel) ?? tr("agents", "pickers.runtime_none")).lineLimit(1)
                }
                row(tr("agents", "inspector.prop_model")) {
                    Image(systemName: "cpu").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(agent.model.isEmpty ? tr("agents", "pickers.model_default") : agent.model).lineLimit(1)
                }
                row(tr("agents", "inspector.prop_concurrency")) {
                    Text("\(agent.maxConcurrentTasks)").font(.system(size: 11, design: .monospaced))
                }
            }
            .font(Theme.Font.caption)
            .padding(.top, 14)
            Divider().padding(.vertical, 18)
            HStack {
                Text(tr("agents", "inspector.section_skills")).font(Theme.Font.bodyMedium)
                Spacer()
                Text("\(agent.skills.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            if agent.skills.isEmpty {
                Text(tr("agents", "tab_body.skills.empty_title")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(.top, 10)
            } else {
                AgentsUIFlowLayout(spacing: 6) {
                    ForEach(agent.skills, id: \.id) { s in
                        Text(s.name).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.hover))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
                    }
                }
                .padding(.top, 10)
            }
            AgentsUIPerformanceSummary(agent: agent)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
            HStack(spacing: 6) { content() }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Compact 30-day metrics for the Overview sidebar.
struct AgentsUIPerformanceSummary: View {
    @Environment(WorkspaceSession.self) private var session
    let agent: AgentRecord

    var body: some View {
        let activity = AgentsUI.activity(buckets: session.agentsUIStore.activityBuckets.filter { $0.agentId == agent.id },
                                         createdAt: agent.createdAt, now: Date())
        let s = AgentsUI.summarize(activity, windowDays: 30)
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 18)
            Text(tr("agents", "tab_body.activity.section_last_30d")).font(Theme.Font.bodyMedium)
            if s.totalRuns == 0 {
                Text(tr("agents", "tab_body.activity.empty_30d")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(.top, 10)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 12) {
                    metric("\(s.totalRuns)", tr("agents", "tab_body.activity.runs", ["count": s.totalRuns]))
                    metric(s.successRate.map { "\($0)%" } ?? "—", tr("agents", "tab_body.activity.success_label"))
                        .help(s.successRate == nil ? tr("agents", "tab_body.activity.success_unavailable") : tr("agents", "tab_body.activity.success_hint"))
                    metric(activity.avgDurationMs > 0 ? AgentsUI.formatDuration(ms: activity.avgDurationMs) : "—",
                           tr("agents", "tab_body.activity.avg_duration_label"))
                    metric("\(s.totalFailed)", tr("agents", "tab_body.activity.failed_label"), destructive: s.totalFailed > 0)
                }
                .padding(.top, 14)
                if s.totalCancelled > 0 {
                    Text(tr("agents", "tab_body.activity.cancelled_count", ["count": s.totalCancelled]))
                        .font(Theme.Font.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
                AgentsUISparkline(buckets: s.buckets, height: 36).padding(.top, 14)
            }
        }
    }

    private func metric(_ value: String, _ label: String, destructive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(destructive ? Theme.destructive : .primary)
            Text(label).font(Theme.Font.micro).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// Wrapping row layout for chips.
struct AgentsUIFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            let w = min(size.width, width)
            if x > 0 && x + w > width {
                y += rowH + spacing
                x = 0
                rowH = 0
            }
            x += w + spacing
            rowH = max(rowH, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            let w = min(size.width, bounds.width)
            if x > bounds.minX && x + w > bounds.maxX {
                y += rowH + spacing
                x = bounds.minX
                rowH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: size.height))
            x += w + spacing
            rowH = max(rowH, size.height)
        }
    }
}
