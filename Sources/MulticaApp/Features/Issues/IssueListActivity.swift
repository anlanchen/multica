import MulticaCore
import Observation
import SwiftUI

/// Per-issue agent activity for the row/card badge: which agents are running
/// or queued, and upcoming wakeups. One observable entry per issue so a task
/// event re-renders only the rows whose own tasks moved.
@MainActor
@Observable
final class IssueListActivityEntry {
    var running: [String] = []
    var queued: [String] = []
    var wakeupCount = 0
    var nextWakeup: IssueWakeupSummaryRow?
    var paused = false
}

@MainActor
final class IssueListActivity {
    private var entries: [String: IssueListActivityEntry] = [:]
    private var pollTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?

    func entry(_ issueID: String) -> IssueListActivityEntry {
        if let e = entries[issueID] { return e }
        let e = IssueListActivityEntry()
        entries[issueID] = e
        return e
    }

    func refreshSnapshot(_ api: APIClient) {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            guard let tasks = try? await api.agentTaskSnapshot(), !Task.isCancelled, let self else { return }
            var running: [String: [String]] = [:]
            var queued: [String: [String]] = [:]
            for t in tasks where t.status.isActive && !t.issueID.isEmpty {
                if t.status == .running {
                    if !(running[t.issueID]?.contains(t.agentID) ?? false) { running[t.issueID, default: []].append(t.agentID) }
                } else if !(queued[t.issueID]?.contains(t.agentID) ?? false) {
                    queued[t.issueID, default: []].append(t.agentID)
                }
            }
            for (id, e) in self.entries {
                let r = running[id] ?? [], q = queued[id] ?? []
                if e.running != r { e.running = r }
                if e.queued != q { e.queued = q }
            }
            for (id, r) in running where self.entries[id] == nil { self.entry(id).running = r }
            for (id, q) in queued where self.entries[id] == nil { self.entry(id).queued = q }
        }
    }

    /// One wakeup-summary poller per surface (upstream polls every 10s while
    /// the surface is mounted).
    func startPolling(_ api: APIClient) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                async let summaries = try? api.listIssueWakeupSummaries()
                async let paused = try? api.listPausedWakeups()
                let rows = await summaries ?? []
                let pausedRows = await paused ?? []
                guard let self, !Task.isCancelled else { return }
                var byIssue: [String: IssueWakeupSummaryRow] = [:]
                for r in rows where byIssue[r.issueId] == nil { byIssue[r.issueId] = r }
                let pausedIDs = Set(pausedRows.map(\.issueId))
                for (id, e) in self.entries {
                    let r = byIssue[id]
                    if e.nextWakeup != r { e.nextWakeup = r }
                    let count = r?.activeCount ?? 0
                    if e.wakeupCount != count { e.wakeupCount = count }
                    let p = pausedIDs.contains(id)
                    if e.paused != p { e.paused = p }
                }
                for (id, r) in byIssue where self.entries[id] == nil {
                    let e = self.entry(id)
                    e.nextWakeup = r
                    e.wakeupCount = r.activeCount
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        snapshotTask?.cancel()
    }
}

/// "Is an agent working on this right now" badge (upstream
/// IssueAgentActivityIndicator): running → avatars + shimmering "Working",
/// queued → dimmed avatars + "Queued", otherwise the next wakeup.
struct IssueListActivityBadge: View {
    let entry: IssueListActivityEntry
    let activeRuns: Int
    @State private var hoverOpen = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        let agents = entry.running.isEmpty ? entry.queued : entry.running
        let isRunning = !entry.running.isEmpty || (agents.isEmpty && activeRuns > 0)
        if activeRuns > 0 || !agents.isEmpty {
            HStack(spacing: 4) {
                if !agents.isEmpty {
                    IssueListAvatarStack(refs: agents.prefix(3).map { ActorRef(type: "agent", id: $0) }, size: 14, dimmed: !isRunning)
                }
                IssueListShimmerText(text: isRunning ? tr("issues", "agent_activity.status_running") : tr("issues", "agent_activity.status_queued"),
                                     active: isRunning)
                if entry.wakeupCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bell").font(.system(size: 9))
                        Text("+\(entry.wakeupCount)").monospacedDigit()
                    }
                    .font(Theme.Font.micro)
                    .foregroundStyle(.secondary)
                    .help(tr("issues", "wakeups.upcoming", ["count": entry.wakeupCount]))
                }
            }
            .fixedSize()
            .onHover { inside in
                hoverTask?.cancel()
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(inside ? 900 : 150))
                    if !Task.isCancelled { hoverOpen = inside }
                }
            }
            .popover(isPresented: $hoverOpen, arrowEdge: .bottom) {
                IssueListActivityHover(running: entry.running, queued: entry.queued)
                    .padding(12)
                    .frame(width: 280, alignment: .leading)
            }
        } else if let next = entry.nextWakeup {
            HStack(spacing: 3) {
                Image(systemName: next.kind == "event" ? "bell" : "clock").font(.system(size: 9))
                Text(Self.waiting(next)).lineLimit(1).frame(maxWidth: 144, alignment: .leading)
                if entry.wakeupCount > 1 { Text("+\(entry.wakeupCount - 1)").monospacedDigit() }
            }
            .font(Theme.Font.micro)
            .foregroundStyle(.secondary)
            .fixedSize()
        } else if entry.paused {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 9))
                Text(tr("issues", "wakeups.wait.paused")).lineLimit(1)
            }
            .font(Theme.Font.micro)
            .foregroundStyle(Theme.destructive)
            .fixedSize()
        }
    }

    static func waiting(_ row: IssueWakeupSummaryRow) -> String {
        if row.kind == "event" { return tr("issues", "wakeups.waiting_event") }
        guard let at = row.nextFireAt.flatMap(Timestamp.parse) else { return tr("issues", "wakeups.waiting_event") }
        return tr("issues", "wakeups.at_time", ["time": at.formatted(date: .omitted, time: .shortened)])
    }
}

private struct IssueListActivityHover: View {
    let running: [String]
    let queued: [String]
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !running.isEmpty {
                Text(tr("issues", "agent_activity.hover_header", ["count": running.count]))
                    .font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(running, id: \.self) { row($0, label: tr("issues", "agent_activity.status_running")) }
            }
            if !queued.isEmpty {
                Text(tr("issues", "agent_activity.hover_header_queued", ["count": queued.count]))
                    .font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(queued, id: \.self) { row($0, label: tr("issues", "agent_activity.status_queued")) }
            }
        }
    }

    private func row(_ id: String, label: String) -> some View {
        HStack(spacing: 8) {
            ActorAvatar(type: "agent", id: id, size: 18)
            Text(session.actorInfo(type: "agent", id: id).name).font(Theme.Font.caption.weight(.medium)).lineLimit(1)
            Spacer(minLength: 4)
            Text(label).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
    }
}

/// Text with a moving highlight while `active` (chat's ShimmerText).
struct IssueListShimmerText: View {
    let text: String
    let active: Bool
    @State private var phase: CGFloat = -1

    var body: some View {
        Text(text)
            .font(Theme.Font.micro)
            .foregroundStyle(.secondary)
            .overlay {
                if active {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Color.primary.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width)
                    }
                    .mask(Text(text).font(Theme.Font.micro))
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard active else { return }
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
    }
}
