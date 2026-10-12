import AppKit
import Charts
import MulticaCore
import SwiftUI

/// Run labels shared by the execution log, inline runs and the runs dialog
/// (upstream task-run-labels.ts, task-failure.ts).
enum IssueDetailRunText {
    static func status(_ status: String) -> String {
        let known: Set<String> = ["queued", "dispatched", "waiting_local_directory", "running", "completed", "failed", "cancelled"]
        return known.contains(status) ? tr("issues", "execution_log.status_\(status)") : status
    }

    static func failureReason(_ reason: String?) -> String? {
        guard let reason, !reason.isEmpty else { return nil }
        let key = "task_failure.reasons." + reason.replacingOccurrences(of: ".", with: "_")
        let s = tr("agents", key)
        return s == key ? reason : s
    }

    /// One label for how a run ended (upstream runOutcomeLabel).
    static func outcome(_ t: AgentTaskRecord) -> String {
        guard t.status == "failed" || t.status == "cancelled" else { return status(t.status) }
        return failureReason(t.failureReason) ?? status(t.status)
    }

    static let actionReasons: Set<String> = [
        "agent_error.provider_auth_or_access", "agent_error.missing_config", "agent_error.model_not_found_or_unavailable",
        "agent_error.runtime_version_unsupported", "agent_error.runtime_missing_executable", "runtime_access_denied",
        "environment_prepare_failed", "local_directory_error", "skill_bundle_unavailable", "agent_error.provider_quota_limit",
    ]

    static func needsAction(_ t: AgentTaskRecord) -> Bool {
        t.status == "failed" && actionReasons.contains(t.failureReason ?? "")
    }

    static func trigger(_ t: AgentTaskRecord) -> String {
        let retry = t.parentTaskId != nil
        let prefix = retry
            ? ((t.attempt ?? 0) > 1 ? tr("issues", "execution_log.trigger_retry_attempt_prefix", ["attempt": t.attempt ?? 0])
                : tr("issues", "execution_log.trigger_retry_prefix"))
            : ""
        if t.wakeupId != nil { return prefix + tr("issues", "wakeups.triggered_by_wakeup") }
        if let s = t.triggerSummary, !s.isEmpty {
            return prefix + IssueDetailFormat.plainTriggerSummary(s, imageLabel: tr("issues", "execution_log.trigger_image"))
        }
        if retry {
            return (t.attempt ?? 0) > 1 ? tr("issues", "execution_log.trigger_retry_attempt", ["attempt": t.attempt ?? 0])
                : tr("issues", "execution_log.trigger_retry")
        }
        if t.autopilotRunId != nil { return tr("issues", "execution_log.trigger_autopilot") }
        if t.triggerCommentId != nil { return tr("issues", "execution_log.trigger_comment") }
        return tr("issues", "execution_log.trigger_initial")
    }

    static func durationMs(_ t: AgentTaskRecord) -> Double? {
        guard let s = (t.startedAt ?? t.dispatchedAt).flatMap(Timestamp.parse), let e = t.completedAt.flatMap(Timestamp.parse), e >= s else { return nil }
        return e.timeIntervalSince(s) * 1000
    }

    /// Provider-priced cost (1e-10 USD per tick), nil when unpriced.
    static func cost(_ t: AgentTaskRecord) -> Double? {
        let ticks = (t.usage ?? []).compactMap(\.costUsdTicks)
        return ticks.isEmpty ? nil : ticks.reduce(0, +) / 1e10
    }

    static func tokens(_ t: AgentTaskRecord) -> Int {
        (t.usage ?? []).reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheWriteTokens }
    }

    /// Comments this run covered (upstream TaskCommentCoverage).
    static func coveredComments(_ t: AgentTaskRecord) -> Int {
        var ids = Set(t.deliveredCommentIds ?? ([t.triggerCommentId].compactMap { $0 } + (t.coalescedCommentIds ?? [])))
        ids.formUnion(t.supplementCommentIds ?? [])
        return ids.count
    }
}

/// Live elapsed time for an active run (ticks once a second), or the
/// final duration.
struct IssueDetailElapsed: View {
    let start: String
    let end: String?

    var body: some View {
        if let end {
            Text(format(end: Timestamp.parse(end)))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in Text(format(end: ctx.date)) }
        }
    }

    private func format(end: Date?) -> String {
        guard let s = Timestamp.parse(start), let e = end, e >= s else { return "" }
        return Formatters.duration(ms: e.timeIntervalSince(s) * 1000)
    }
}

/// Status glyph of a run (upstream TaskStatusIcon / RunActivityIndicator).
struct IssueDetailRunStatusIcon: View {
    let status: String

    var body: some View {
        switch status {
        case "running", "dispatched":
            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
        case "waiting_local_directory":
            Image(systemName: "pause.circle").foregroundStyle(.secondary).font(.system(size: 12))
        case "queued":
            Image(systemName: "clock").foregroundStyle(.secondary).font(.system(size: 12))
        case "completed":
            Image(systemName: "checkmark.circle").foregroundStyle(Theme.success).font(.system(size: 12))
        case "failed":
            Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.destructive).font(.system(size: 12))
        default:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary).font(.system(size: 12))
        }
    }
}

/// The compact run line inside a published reply's header (upstream
/// PlacedInlineCommentRun presentation="header").
struct IssueDetailRunHeader: View {
    let run: IssueDetailRun
    @Binding var expanded: Bool

    var body: some View {
        HStack(spacing: 5) {
            IssueDetailRunStatusIcon(status: run.task.status)
            Button { expanded.toggle() } label: {
                HStack(spacing: 3) {
                    Text(tr("issues", "inline_run.view_activity"))
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            IssueDetailElapsed(start: run.task.startedAt ?? run.task.dispatchedAt ?? run.task.createdAt,
                               end: run.isActive ? nil : run.task.completedAt)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
    }
}

/// A run's activity block (upstream InlineCommentRun): identity, live
/// summary, elapsed, stop/retry, the daemon's output, and the expandable
/// step list. Only this row observes the run's transcript, so streaming
/// re-renders nothing else.
struct IssueDetailRunBlock: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    let run: IssueDetailRun
    var showIdentity = true
    var replyTo: TimelineEntry? = nil
    var replacesFailureNotice = false
    var onJump: ((String) -> Void)? = nil
    @Binding var expanded: Bool
    @State private var confirmStop = false
    @State private var stopping = false
    @State private var retrying = false
    @State private var fullLog = false

    var body: some View {
        let task = run.task
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if showIdentity {
                    ActorAvatar(type: "agent", id: task.agentId, size: 22)
                    Text(tr("issues", "inline_run.label", ["name": session.actorInfo(type: "agent", id: task.agentId).name]))
                        .font(Theme.Font.bodyMedium).lineLimit(1)
                }
                IssueDetailRunStatusIcon(status: task.status)
                if run.isActive && !run.hasReply {
                    IssueDetailRunSummary(store: store, task: task)
                } else {
                    Text(IssueDetailRunText.outcome(task)).font(Theme.Font.caption).foregroundStyle(run.isEnded ? Theme.destructive : .secondary)
                        .help(task.error ?? "")
                    Spacer(minLength: 0)
                }
                Button { expanded.toggle() } label: {
                    HStack(spacing: 3) {
                        Text(tr("issues", "inline_run.view_activity"))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .buttonStyle(.plain)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                IssueDetailElapsed(start: task.startedAt ?? task.dispatchedAt ?? task.createdAt, end: run.isActive ? nil : task.completedAt)
                    .font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                if run.isActive {
                    Button { confirmStop = true } label: {
                        if stopping { ProgressView().controlSize(.mini) } else { Image(systemName: "stop.fill").font(.system(size: 9)) }
                    }
                    .buttonStyle(.borderless)
                    .disabled(stopping)
                    .help(tr("issues", stopping ? "inline_run.stopping" : "inline_run.stop"))
                }
                if (!run.hasReply || replacesFailureNotice) && run.isEnded {
                    Button {
                        retrying = true
                        Task {
                            await store.rerun(task.id, toaster: toaster)
                            retrying = false
                        }
                    } label: { Label(tr("issues", "execution_log.retry_task_tooltip"), systemImage: "arrow.counterclockwise") }
                    .controlSize(.small)
                    .disabled(retrying)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let replyTo { IssueDetailReplyToQuote(entry: replyTo, onJump: onJump) }
                if !run.hasReply, let output = run.output {
                    MarkdownView(source: Redactor.shared.redact(output)).padding(.top, 4)
                }
                if IssueDetailRunText.needsAction(task), let error = task.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                    Text(Redactor.shared.redact(error))
                        .font(Theme.Font.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.04)))
                }
                if expanded { IssueDetailRunSteps(store: store, task: task) { fullLog = true } }
            }
            .padding(.leading, showIdentity ? 28 : 0)
        }
        .modifier(IssueDetailStopConfirm(isPresented: $confirmStop, running: task.status != "queued") {
            stopping = true
            Task {
                await store.cancelTask(task.id, toaster: toaster)
                stopping = false
            }
        })
        .sheet(isPresented: $fullLog) { IssueDetailTranscriptSheet(store: store, taskID: task.id) }
    }
}

/// Live one-line activity of a working run.
private struct IssueDetailRunSummary: View {
    @Environment(WorkspaceSession.self) private var session
    let store: IssueDetailStore
    let task: AgentTaskRecord

    var body: some View {
        let transcript = store.model.transcript(for: task.id)
        Text(summary(transcript))
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { if task.status == "running" { session.watchTranscript(transcript) } }
            .onDisappear { if task.status == "running" { session.unwatchTranscript(transcript) } }
    }

    private func summary(_ t: TranscriptModel) -> String {
        switch task.status {
        case "queued": return tr("issues", "inline_run.queued")
        case "dispatched": return tr("issues", "inline_run.starting")
        case "waiting_local_directory": return tr("issues", "inline_run.waiting_directory")
        default: break
        }
        guard let step = t.steps.last(where: { $0.kind != .text || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return tr("issues", "inline_run.waiting_response")
        }
        switch step.kind {
        case .tool: return t.displaySummary(for: step, limit: 140)
        case .text: return t.displaySummary(for: step, limit: 140)
        case .thinking:
            let s = t.displaySummary(for: step, limit: 140)
            return s.isEmpty ? tr("issues", "inline_run.thinking") : s
        case .error: return tr("issues", "inline_run.error")
        }
    }
}

/// The expanded step list: the latest steps with "show earlier", then a
/// link to the full log.
struct IssueDetailRunSteps: View {
    @Environment(WorkspaceSession.self) private var session
    let store: IssueDetailStore
    let task: AgentTaskRecord
    let onFullLog: () -> Void
    @State private var visible = 12

    var body: some View {
        let transcript = store.model.transcript(for: task.id)
        let steps = transcript.steps
        VStack(alignment: .leading, spacing: 2) {
            if transcript.isLoading && steps.isEmpty {
                Text(tr("issues", "inline_run.loading")).font(Theme.Font.caption).foregroundStyle(.secondary)
            } else if steps.isEmpty {
                Text(tr("issues", "inline_run.empty")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            if steps.count > visible {
                Button(tr("issues", "inline_run.show_earlier", ["count": steps.count - visible])) { visible += 12 }
                    .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            ForEach(steps.suffix(visible)) { step in
                TranscriptStepRow(step: step, transcript: transcript).equatable()
            }
            Button(action: onFullLog) {
                HStack(spacing: 4) {
                    Text(tr("issues", "inline_run.full_log"))
                    Image(systemName: "arrow.up.right.square").font(.system(size: 10))
                }
            }
            .buttonStyle(.plain)
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        }
        .padding(.top, 6)
        .onAppear { session.watchTranscript(transcript) }
        .onDisappear { session.unwatchTranscript(transcript) }
    }
}

/// "Replying to <name>: <preview>" (upstream ReplyToQuote).
struct IssueDetailReplyToQuote: View {
    @Environment(WorkspaceSession.self) private var session
    let entry: TimelineEntry
    var onJump: ((String) -> Void)?

    var body: some View {
        let name = entry.actorName ?? session.actorInfo(type: entry.actorType, id: entry.actorID).name
        let label = tr("issues", "comment.replying_to", ["name": name, "preview": IssueDetailFormat.preview(entry.content ?? "")])
        Button { onJump?(entry.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrowshape.turn.up.left").font(.system(size: 10))
                Text(label).lineLimit(1)
            }
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(onJump == nil)
        .help(label)
    }
}

/// Upstream AgentTranscriptDialog: run facts, details, and the full step
/// log with search and order.
struct IssueDetailTranscriptSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let store: IssueDetailStore
    let taskID: String
    @State private var query = ""
    @State private var newestFirst = false
    @State private var detailsOpen = false
    @State private var filtered: [TranscriptStep]?
    @State private var copied = false

    var body: some View {
        let transcript = store.model.transcript(for: taskID)
        VStack(alignment: .leading, spacing: 10) {
            if let task = store.task(taskID) { header(task) }
            HStack(spacing: 8) {
                SearchField(text: $query, prompt: tr("agents", "transcript.search_placeholder"))
                Picker("", selection: $newestFirst) {
                    Text(tr("agents", "transcript.sort_chronological")).tag(false)
                    Text(tr("agents", "transcript.sort_newest_first")).tag(true)
                }
                .labelsHidden()
                .fixedSize()
                Button(copied ? tr("agents", "transcript.copied") : tr("agents", query.isEmpty ? "transcript.copy_all" : "transcript.copy_filtered")) {
                    copy(transcript)
                }
            }
            let steps = filtered ?? transcript.steps
            Text(query.isEmpty ? tr("agents", "transcript.steps_count", ["count": transcript.steps.count])
                 : tr("agents", "transcript.steps_filtered", ["shown": steps.count, "total": transcript.steps.count]))
                .font(Theme.Font.micro).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if transcript.isLoading && transcript.steps.isEmpty {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else if transcript.steps.isEmpty {
                        Text(tr("agents", store.task(taskID).map { IssueDetailRun.activeStatuses.contains($0.status) } == true
                                ? "transcript.waiting_events" : "transcript.no_data"))
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                    } else if steps.isEmpty {
                        Text(tr("agents", "transcript.no_matches")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                    ForEach(newestFirst ? steps.reversed() : steps) { step in
                        TranscriptStepRow(step: step, transcript: transcript).equatable()
                    }
                }
                .padding(10)
            }
            .defaultScrollAnchor(newestFirst ? .top : .bottom)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
            HStack {
                Spacer()
                Button(tr("agents", "transcript.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 540, idealHeight: 680)
        .onAppear { session.watchTranscript(transcript) }
        .onDisappear { session.unwatchTranscript(transcript) }
        .onChange(of: query) { refilter(transcript) }
        .onChange(of: transcript.version) { if !query.isEmpty { refilter(transcript) } }
    }

    @ViewBuilder private func header(_ task: AgentTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ActorAvatar(type: "agent", id: task.agentId, size: 22, showName: true, nameFont: Theme.Font.bodyMedium)
                IssueDetailRunStatusIcon(status: task.status)
                Text(IssueDetailRunText.outcome(task)).font(Theme.Font.caption).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text(tr("agents", "transcript.fact_created", ["time": Formatters.relative(task.createdAt)])).font(Theme.Font.caption).foregroundStyle(.secondary)
                if let ms = IssueDetailRunText.durationMs(task) {
                    Text(tr("agents", "transcript.fact_took", ["duration": Formatters.duration(ms: ms)])).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                if IssueDetailRunText.tokens(task) > 0 {
                    Text(usageLabel(task))
                        .font(Theme.Font.micro.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .help(tr("agents", "transcript.usage_chip_title"))
                }
                Spacer()
                if IssueDetailRun.activeStatuses.contains(task.status) {
                    Button(role: .destructive) { Task { await store.cancelTask(task.id, toaster: toaster) } } label: {
                        Text(tr("issues", "agent_live.stop_button"))
                    }
                }
            }
            Text(IssueDetailRunText.trigger(task)).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(2)
            DisclosureGroup(tr("agents", "transcript.run_info"), isExpanded: $detailsOpen) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    if let rt = session.directory.runtimes.first(where: { $0.id == task.runtimeId }) {
                        detailRow(tr("agents", "transcript.details_runtime"), rt.displayName)
                        detailRow(tr("agents", "transcript.details_provider"), rt.provider)
                        detailRow(tr("agents", "transcript.details_mode"), rt.runtimeMode)
                    }
                    if let target = IssueDetailFormat.workdirTarget([task]) {
                        detailRow(tr("agents", target.isProjectDirectory ? "transcript.details_project_directory" : "transcript.details_workdir"), target.path, copyable: true)
                    }
                    if let branch = task.branchName, !branch.isEmpty {
                        detailRow(tr("agents", "transcript.details_branch"), branch, copyable: true)
                    }
                    if let reason = IssueDetailRunText.failureReason(task.failureReason) {
                        detailRow(tr("agents", "transcript.details_reason"), reason)
                    }
                    detailRow(tr("agents", "transcript.details_created"), Formatters.date(task.createdAt, style: .abbreviated, time: .standard))
                    if let s = task.startedAt { detailRow(tr("agents", "transcript.details_started"), Formatters.date(s, style: .abbreviated, time: .standard)) }
                    if let c = task.completedAt { detailRow(tr("agents", "transcript.details_completed"), Formatters.date(c, style: .abbreviated, time: .standard)) }
                    if let error = task.error, !error.isEmpty {
                        detailRow(tr("agents", "transcript.details_diagnostics"), Redactor.shared.redact(error))
                    }
                }
                .font(Theme.Font.caption)
                .padding(.top, 4)
            }
            .font(Theme.Font.caption)
        }
    }

    private func detailRow(_ label: String, _ value: String, copyable: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(value).textSelection(.enabled).lineLimit(3)
                if copyable { CopyButton(text: value).buttonStyle(.borderless).controlSize(.mini) }
            }
        }
    }

    private func usageLabel(_ t: AgentTaskRecord) -> String {
        let tokens = Formatters.compact(Double(IssueDetailRunText.tokens(t)))
        return IssueDetailRunText.cost(t).map { "\(tokens) · \(Formatters.usd($0))" } ?? tokens
    }

    private func refilter(_ t: TranscriptModel) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            filtered = nil
            return
        }
        filtered = t.steps.filter { s in
            s.summary.localizedCaseInsensitiveContains(q) || (s.output?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private func copy(_ t: TranscriptModel) {
        let steps = filtered ?? t.steps
        let text = steps.map { s -> String in
            switch s.kind {
            case .tool: return "[\(s.tool ?? "tool")] \(s.summary)\n\(s.output ?? "")"
            default: return s.text
            }
        }.joined(separator: "\n\n")
        IssueDetailFiles.copy(text)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// Upstream ExecutionLogSection: active runs, the latest past runs and
/// the issue totals, with the full timeline one click away.
struct IssueDetailExecutionLog: View {
    @Environment(WorkspaceSession.self) private var session
    let store: IssueDetailStore
    @State private var open = true
    @State private var dialog = false

    var body: some View {
        let all = store.tasks.filter { $0.kind != "quick_create" || $0.issueId == store.issueID }
        if !all.isEmpty {
            let active = store.activeTasks
            let past = all.filter { !IssueDetailRun.activeStatuses.contains($0.status) }.sorted { $0.createdAt > $1.createdAt }
            VStack(alignment: .leading, spacing: 0) {
                IssueDetailSectionHeader(title: tr("issues", "execution_log.section"), open: $open) {
                    Button { dialog = true } label: {
                        Text(tr("issues", "execution_log.summary_runs", ["count": all.count]) + totalsSuffix(all))
                            .font(Theme.Font.micro).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .buttonStyle(.plain)
                    .help(tr("issues", "execution_log.usage_total_tooltip"))
                }
                if open {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(active, id: \.id) { t in IssueDetailActiveTaskRow(store: store, task: t) }
                        if !past.isEmpty {
                            Text(tr("issues", "execution_log.latest")).font(Theme.Font.micro).foregroundStyle(.secondary).padding(.top, active.isEmpty ? 0 : 6)
                        }
                        ForEach(past.prefix(3), id: \.id) { t in IssueDetailPastRunRow(store: store, task: t) }
                        HStack {
                            Button(tr("issues", "execution_log.open_timeline")) { dialog = true }
                            if past.count > 3 {
                                Text(tr("issues", "execution_log.more_runs", ["count": past.count - 3])).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.link)
                        .font(Theme.Font.caption)
                        .padding(.top, 4)
                    }
                    .padding(.leading, 8)
                }
            }
            .sheet(isPresented: $dialog) { IssueDetailRunsDialog(store: store) }
        }
    }

    private func totalsSuffix(_ tasks: [AgentTaskRecord]) -> String {
        let costs = tasks.compactMap(IssueDetailRunText.cost)
        return costs.isEmpty ? "" : " · " + Formatters.usd(costs.reduce(0, +))
    }
}

/// A finished run in the execution log (upstream PastRow).
struct IssueDetailPastRunRow: View {
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    let task: AgentTaskRecord
    @State private var transcript = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ActorAvatar(type: "agent", id: task.agentId, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(IssueDetailRunText.trigger(task)).font(Theme.Font.caption).lineLimit(1)
                HStack(spacing: 4) {
                    IssueDetailRunStatusIcon(status: task.status)
                    Text(IssueDetailRunText.outcome(task))
                    if let ms = IssueDetailRunText.durationMs(task) { Text("· " + Formatters.duration(ms: ms)) }
                    if let cost = IssueDetailRunText.cost(task) { Text("· " + Formatters.usd(cost)) }
                    Text("· " + Formatters.relative(task.completedAt ?? task.createdAt))
                }
                .font(Theme.Font.micro).foregroundStyle(.secondary).lineLimit(1)
                let covered = IssueDetailRunText.coveredComments(task)
                if covered > 1 {
                    Text(tr("issues", "execution_log.included_comments", ["count": covered])).font(Theme.Font.micro).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if task.status == "failed" || task.status == "cancelled" {
                Button { Task { await store.rerun(task.id, toaster: toaster) } } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help(tr("issues", "execution_log.retry_task_tooltip"))
            }
            Button { transcript = true } label: { Image(systemName: "text.alignleft") }
                .buttonStyle(.borderless)
                .help(tr("issues", "execution_log.transcript_tooltip"))
        }
        .padding(.vertical, 3)
        .sheet(isPresented: $transcript) { IssueDetailTranscriptSheet(store: store, taskID: task.id) }
    }
}

/// Upstream IssueRunsDialog: totals, cumulative cost over time, and every
/// run grouped by day.
struct IssueDetailRunsDialog: View {
    @Environment(\.dismiss) private var dismiss
    let store: IssueDetailStore

    private struct Point: Identifiable {
        var id: String
        var date: Date
        var total: Double
    }

    var body: some View {
        let tasks = store.tasks.sorted { $0.createdAt > $1.createdAt }
        let costs = tasks.compactMap(IssueDetailRunText.cost)
        let agentMs = tasks.compactMap(IssueDetailRunText.durationMs).reduce(0, +)
        let failed = tasks.filter { $0.status == "failed" }.count
        let cancelled = tasks.filter { $0.status == "cancelled" }.count
        let active = tasks.filter { IssueDetailRun.activeStatuses.contains($0.status) }.count
        let points = cumulative(tasks)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(tr("issues", "runs_timeline.title")).font(Theme.Font.title)
                Spacer()
                Button(tr("agents", "transcript.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 24) {
                stat(tr("issues", "runs_timeline.stat_spent"), costs.isEmpty ? "—" : Formatters.usd(costs.reduce(0, +)))
                stat(tr("issues", "runs_timeline.stat_agent_time"), agentMs > 0 ? Formatters.duration(ms: agentMs) : "—")
                stat(tr("issues", "runs_timeline.stat_elapsed"), elapsed(tasks))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("issues", "runs_timeline.stat_runs")).font(Theme.Font.micro).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("\(tasks.count)").font(Theme.Font.title).monospacedDigit()
                        if failed > 0 { Badge(text: tr("issues", "runs_timeline.count_failed", ["count": failed]), color: Theme.destructive) }
                        if cancelled > 0 { Badge(text: tr("issues", "runs_timeline.count_cancelled", ["count": cancelled])) }
                        if active > 0 { Badge(text: tr("issues", "runs_timeline.count_active", ["count": active]), color: Theme.info) }
                    }
                }
            }
            if points.count > 1 {
                Chart(points) { p in
                    LineMark(x: .value("t", p.date), y: .value("$", p.total)).interpolationMethod(.stepEnd)
                    AreaMark(x: .value("t", p.date), y: .value("$", p.total)).foregroundStyle(Theme.brand.opacity(0.1)).interpolationMethod(.stepEnd)
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 120)
                .accessibilityLabel(tr("issues", "runs_timeline.chart_aria", ["count": tasks.count]))
            } else if costs.isEmpty {
                Text(tr("issues", "runs_timeline.no_usage")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(groupedByDay(tasks), id: \.day) { group in
                    Section(dayLabel(group.day) + " · " + tr("issues", "runs_timeline.day_runs", ["count": group.tasks.count])) {
                        ForEach(group.tasks, id: \.id) { t in IssueDetailPastRunRow(store: store, task: t) }
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(18)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 520, idealHeight: 640)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.Font.micro).foregroundStyle(.secondary)
            Text(value).font(Theme.Font.title).monospacedDigit()
        }
    }

    private func elapsed(_ tasks: [AgentTaskRecord]) -> String {
        let starts = tasks.compactMap { Timestamp.parse($0.createdAt) }
        let ends = tasks.compactMap { $0.completedAt.flatMap(Timestamp.parse) }
        guard let s = starts.min(), let e = (ends + [IssueDetailRun.activeStatuses.isDisjoint(with: tasks.map(\.status)) ? Date.distantPast : Date()]).max(), e > s else { return "—" }
        return Formatters.duration(ms: e.timeIntervalSince(s) * 1000)
    }

    private func cumulative(_ tasks: [AgentTaskRecord]) -> [Point] {
        var total = 0.0
        return tasks.reversed().compactMap { t in
            guard let c = IssueDetailRunText.cost(t), let d = Timestamp.parse(t.completedAt ?? t.createdAt) else { return nil }
            total += c
            return Point(id: t.id, date: d, total: total)
        }
    }

    private func groupedByDay(_ tasks: [AgentTaskRecord]) -> [(day: Date, tasks: [AgentTaskRecord])] {
        var byDay: [Date: [AgentTaskRecord]] = [:]
        for t in tasks {
            let day = Calendar.current.startOfDay(for: Timestamp.parse(t.createdAt) ?? Date())
            byDay[day, default: []].append(t)
        }
        return byDay.keys.sorted(by: >).map { ($0, byDay[$0]!) }
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return tr("issues", "runs_timeline.day_today") }
        if Calendar.current.isDateInYesterday(day) { return tr("issues", "runs_timeline.day_yesterday") }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}
