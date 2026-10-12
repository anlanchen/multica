import MulticaCore
import SwiftUI

/// Overlapping agent avatars with a "+N" overflow (upstream
/// AgentAvatarStack), for chips that show who is working.
struct AgentsUIAvatarStack: View {
    @Environment(WorkspaceSession.self) private var session
    let agentIDs: [String]
    var size: CGFloat = 18
    var max = 3
    var dimmed = false

    var body: some View {
        if !agentIDs.isEmpty {
            let visible = Array(agentIDs.prefix(max))
            let overflow = agentIDs.count - visible.count
            let overlap = (size * 0.3).rounded()
            HStack(spacing: -overlap) {
                ForEach(visible, id: \.self) { id in
                    let info = session.actorInfo(type: "agent", id: id)
                    AgentsUIAvatar(name: info.name, avatarURL: info.avatarURL, size: size)
                        .padding(1.5)
                        .background(RoundedRectangle(cornerRadius: size * 0.32).fill(Color(nsColor: .windowBackgroundColor)))
                        .help(info.name)
                }
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.system(size: Swift.max(9, (size * 0.45).rounded()), weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: size, height: size)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .padding(1.5)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .accessibilityLabel(tr("agents", "avatar_stack.overflow_aria", ["count": overflow]))
                }
            }
            .opacity(dimmed ? 0.5 : 1)
        }
    }
}

/// Hover card answering "what is this agent doing right now?" (upstream
/// AgentLivePeekCard): workload, current issue, last finished run.
struct AgentsUILivePeekCard: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let agentID: String
    @State private var issue: (identifier: String, title: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let agent = session.agentRecords.item(agentID) {
                let tasks = session.agentsUIStore.snapshot.filter { $0.agentId == agentID }
                let presence = AgentsUI.presence(agent: agent, runtime: session.runtimeRecords.item(agent.runtimeId), tasks: tasks, now: Date())
                let running = tasks.first { $0.status == "running" && !$0.issueId.isEmpty }
                let last = tasks.filter { ($0.status == "completed" || $0.status == "failed") && $0.completedAt != nil }
                    .max { ($0.completedAt ?? "") < ($1.completedAt ?? "") }
                HStack(alignment: .top, spacing: 10) {
                    AgentsUIAvatar(name: agent.name, avatarURL: agent.avatarUrl, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(agent.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if presence.availability == .archived {
                            Label(tr("agents", "availability.archived"), systemImage: "archivebox").foregroundStyle(.secondary)
                        } else {
                            Label(tr("agents", "workload.\(presence.workload.rawValue)"), systemImage: workloadIcon(presence.workload))
                                .foregroundStyle(presence.workload == .working ? Theme.brand : (presence.workload == .queued ? Theme.warning : .secondary))
                        }
                    }
                    .font(Theme.Font.caption)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(tr("agents", "live_peek.current_issue_label")).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        if let running {
                            if let issue {
                                Button { nav.push(.issue(running.issueId)) } label: {
                                    (Text(issue.identifier + " ").font(.system(size: 10, design: .monospaced)) + Text(issue.title))
                                        .foregroundStyle(Theme.brand).lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                .help("\(issue.identifier) \(issue.title)")
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                        } else {
                            Text(tr("agents", "live_peek.no_current_issue")).foregroundStyle(.secondary)
                        }
                    }
                    .task(id: running?.issueId) { await resolve(running?.issueId) }
                    HStack(spacing: 6) {
                        Text(tr("agents", "live_peek.last_activity_label")).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        if let last, let at = last.completedAt {
                            Text(Formatters.relative(at))
                            if last.status == "failed" {
                                Label(tr("agents", "live_peek.failed_indicator"), systemImage: "exclamationmark.triangle")
                                    .font(Theme.Font.micro.weight(.medium)).foregroundStyle(Theme.warning)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.warning.opacity(0.1)))
                            }
                        } else {
                            Text(tr("agents", "live_peek.no_recent_activity")).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(Theme.Font.caption)
            } else {
                Text(tr("agents", "profile_card.unavailable")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .task {
            async let a: Void = session.agentRecords.loadIfNeeded()
            async let s: Void = session.agentsUIStore.loadSnapshot()
            _ = await (a, s)
        }
    }

    private func workloadIcon(_ w: AgentsUI.Workload) -> String {
        switch w {
        case .working: return "arrow.triangle.2.circlepath"
        case .queued: return "clock"
        case .idle: return "moon.zzz"
        }
    }

    private func resolve(_ issueID: String?) async {
        guard let issueID else { issue = nil; return }
        if let m = session.issues.model(issueID) { issue = (m.issue.identifier, m.issue.title); return }
        if let i = try? await session.api.issue(issueID) { issue = (i.identifier, i.title) }
    }
}

/// Active runs on an issue, one row per run with a live elapsed clock
/// (upstream AgentActivityHoverContent).
struct AgentsUIActivityHoverContent: View {
    @Environment(WorkspaceSession.self) private var session
    let tasks: [AgentTaskRecord]

    var body: some View {
        if !tasks.isEmpty {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("issues", "agent_activity.hover_header_tasks", ["count": tasks.count]))
                        .font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(tasks, id: \.id) { t in row(t, now: context.date) }
                    }
                }
            }
            .padding(12)
            .frame(width: 300, alignment: .leading)
        }
    }

    func row(_ task: AgentTaskRecord, now: Date) -> some View {
        let agent = session.agentRecords.item(task.agentId)
        let availability = agent.map { AgentsUI.presence(agent: $0, runtime: session.runtimeRecords.item($0.runtimeId), tasks: [], now: now).availability } ?? .offline
        let running = task.status == "running"
        let dot: Color = running ? Theme.brand : (availability == .online ? Color.secondary.opacity(0.4) : Theme.warning)
        let label: Color = running ? Theme.brand : (availability == .online ? .secondary : Theme.warning)
        let from = running ? (task.startedAt ?? task.dispatchedAt ?? task.createdAt) : task.createdAt
        let info = session.actorInfo(type: "agent", id: task.agentId)
        return HStack(spacing: 8) {
            AgentsUIAvatar(name: info.name, avatarURL: info.avatarURL, size: 18)
            Text(info.name).font(Theme.Font.caption.weight(.medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if task.wakeupId != nil {
                Image(systemName: "bell").font(.system(size: 10)).foregroundStyle(.secondary).help(tr("issues", "wakeups.triggered_by_wakeup"))
            }
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(running ? tr("issues", "agent_activity.status_running") : tr("issues", "agent_activity.status_queued")).foregroundStyle(label)
            if let start = Timestamp.parse(from) {
                Text(AgentsUI.formatElapsed(since: start, now: now)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .font(Theme.Font.caption)
    }
}

/// Workspace-wide variant: active runs grouped by issue.
struct AgentsUIWorkspaceActivityHoverContent: View {
    let issues: [Issue]
    let tasksByIssue: [String: [AgentTaskRecord]]
    let taskCount: Int

    var body: some View {
        Group {
            if issues.isEmpty {
                Text(tr("issues", "agent_activity.empty_hover")).font(Theme.Font.caption).foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tr("issues", "agent_activity.issues_count", ["count": issues.count]) + " · "
                             + tr("issues", "agent_activity.tasks_count", ["count": taskCount]))
                            .font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                        ForEach(issues) { issue in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(issue.identifier).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                    Text(issue.title).font(Theme.Font.caption).lineLimit(1)
                                }
                                ForEach(tasksByIssue[issue.id] ?? [], id: \.id) { t in
                                    AgentsUIActivityHoverContent(tasks: [t]).row(t, now: context.date)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }
}
