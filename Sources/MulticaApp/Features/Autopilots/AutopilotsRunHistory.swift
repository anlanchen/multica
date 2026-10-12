import MulticaCore
import SwiftUI

private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
    tr("autopilots", key, args)
}

/// Run history of an autopilot (upstream RunHistoryList): visible runs, then
/// skipped runs folded into one expandable group.
struct AutopilotsRunHistory: View {
    let runs: [AutopilotRun]
    let agentID: String
    let agentName: String
    @State private var skippedOpen = false
    @State private var transcriptRun: AutopilotRun?

    var body: some View {
        let split = AutopilotsRuns.split(runs)
        AutopilotsRowsCard {
            ForEach(Array(split.visible.enumerated()), id: \.element.id) { i, run in
                if i > 0 { Divider() }
                AutopilotsRunRow(run: run, onTranscript: { transcriptRun = run }).equatable()
            }
            if let latest = split.skipped.first {
                if !split.visible.isEmpty { Divider() }
                Button { skippedOpen.toggle() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: skippedOpen ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 14)
                        Image(systemName: "nosign").foregroundStyle(.secondary).frame(width: 14)
                        Text(t("run.skipped_group.label")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading)
                        Text(t("run.skipped_group.summary", ["count": split.skipped.count])).font(Theme.Font.caption).foregroundStyle(.secondary)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(AutopilotsFormat.instant(latest.triggeredAt.isEmpty ? latest.createdAt : latest.triggeredAt))
                            .font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 128, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 0)
                .background(Color.primary.opacity(0.02))
                .accessibilityAddTraits(skippedOpen ? .isSelected : [])
                if skippedOpen {
                    Divider()
                    ForEach(Array(split.skipped.enumerated()), id: \.element.id) { i, run in
                        if i > 0 { Divider() }
                        AutopilotsRunRow(run: run, onTranscript: { transcriptRun = run }).equatable()
                    }
                }
            }
        }
        .sheet(item: $transcriptRun) { run in
            AutopilotsRunTranscriptSheet(run: run, agentID: agentID, agentName: agentName)
        }
    }
}

private struct AutopilotsRunRow: View, Equatable {
    @Environment(Navigator.self) private var nav
    let run: AutopilotRun
    let onTranscript: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.run == b.run }

    var body: some View {
        let status = AutopilotsRunVisual.status(run.status)
        let color = AutopilotsRunVisual.color(status)
        let content = HStack(spacing: 12) {
            if status == "running" {
                AutopilotsSpinner(size: 14, color: color)
            } else {
                Image(systemName: AutopilotsRunVisual.symbol(status)).foregroundStyle(color).frame(width: 14)
            }
            Text(AutopilotsLabels.runStatus(status)).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
                .frame(width: 96, alignment: .leading)
            Text(AutopilotsLabels.runSource(run.source)).font(Theme.Font.caption).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Group {
                if run.issueId != nil {
                    Text(t("run.issue_linked")).foregroundStyle(.secondary)
                } else if let reason = run.failureReason, !reason.isEmpty {
                    Text(reason).foregroundStyle(Theme.destructive).help(reason)
                } else {
                    Text("")
                }
            }
            .font(Theme.Font.caption)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(AutopilotsFormat.instant(run.triggeredAt.isEmpty ? run.createdAt : run.triggeredAt))
                .font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 128, alignment: .trailing)
            if run.taskId != nil && run.issueId == nil {
                Button(action: onTranscript) {
                    Image(systemName: "text.alignleft").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight()
                .help(t("run.view_log"))
                .accessibilityLabel(t("run.view_log"))
            }
        }
        .font(Theme.Font.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())

        if let issueID = run.issueId {
            Button { nav.push(.issue(issueID)) } label: { content }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 0)
        } else {
            content.hoverHighlight(cornerRadius: 0)
        }
    }
}

/// Execution log of a run_only run (upstream TranscriptButton +
/// AgentTranscriptDialog), with the webhook envelope above it for webhook
/// runs — fetched on open, since the run list omits payloads.
private struct AutopilotsRunTranscriptSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let run: AutopilotRun
    let agentID: String
    let agentName: String
    @State private var envelope: AutopilotsWebhook.Envelope?
    @State private var loadingPayload = false

    var body: some View {
        let taskStatus = AutopilotsRuns.taskStatus(for: run.status)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AvatarView(name: agentName, url: session.actorInfo(type: "agent", id: agentID).avatarURL, kind: .agent, size: 22)
                Text(agentName).font(Theme.Font.bodyMedium)
                TaskStatusPill(status: taskStatus)
                if !run.triggeredAt.isEmpty {
                    Text(Formatters.date(run.triggeredAt, style: .abbreviated, time: .shortened)).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                if let s = Timestamp.parse(run.triggeredAt), let e = run.completedAt.flatMap(Timestamp.parse) {
                    Text(Formatters.duration(ms: e.timeIntervalSince(s) * 1000)).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(t("dialog.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(t("run.view_log")).font(Theme.Font.caption).foregroundStyle(.secondary)
            if run.source == "webhook" {
                if loadingPayload {
                    AutopilotsSkeleton(height: 34)
                } else if let envelope {
                    AutopilotsWebhookPayloadPreview(envelope: envelope)
                }
            }
            if let reason = run.failureReason, !reason.isEmpty {
                Text(reason).font(Theme.Font.caption).foregroundStyle(Theme.destructive).textSelection(.enabled)
            }
            if let taskID = run.taskId {
                TaskTranscriptView(taskID: taskID, minHeight: 360, maxHeight: .infinity, followTail: run.status == "running")
            }
        }
        .padding(16)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 640)
        .task {
            guard run.source == "webhook" else { return }
            loadingPayload = true
            if let full = try? await session.api.getAutopilotRun(autopilotId: run.autopilotId, runId: run.id), !full.triggerPayload.isNull {
                envelope = AutopilotsWebhook.envelope(full.triggerPayload)
            }
            loadingPayload = false
        }
    }
}
