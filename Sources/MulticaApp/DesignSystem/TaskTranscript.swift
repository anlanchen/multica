import AppKit
import MulticaCore
import SwiftUI

/// Live transcript of one agent task (upstream common/task-transcript):
/// assistant text as Markdown, thinking dimmed, tool calls with expandable
/// input and output, errors in red. Backfills from REST and follows live
/// `task:message` frames while visible.
struct TaskTranscriptView: View {
    @Environment(WorkspaceSession.self) private var session
    let taskID: String
    var minHeight: CGFloat = 120
    var maxHeight: CGFloat = 520
    var followTail = true

    var body: some View {
        let transcript = session.transcript(taskID: taskID)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if transcript.isLoading && transcript.steps.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else if transcript.steps.isEmpty {
                    Text(trd("agents", "transcript.empty", "No output yet."))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                ForEach(transcript.steps) { step in
                    TranscriptStepRow(step: step, transcript: transcript)
                        .equatable()
                }
            }
            .padding(10)
        }
        .defaultScrollAnchor(followTail ? .bottom : .top)
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
        .onAppear { session.watchTranscript(transcript) }
        .onDisappear { session.unwatchTranscript(transcript) }
    }
}

struct TaskStepIcon: View {
    let kind: TranscriptStep.Kind

    var body: some View {
        Image(systemName: symbol).foregroundStyle(color).font(.system(size: 11)).frame(width: 14)
    }

    private var symbol: String {
        switch kind {
        case .text: return "text.bubble"
        case .thinking: return "brain"
        case .tool: return "wrench.and.screwdriver"
        case .error: return "exclamationmark.octagon"
        }
    }

    private var color: Color {
        switch kind {
        case .error: return Theme.destructive
        case .thinking: return .purple
        default: return .secondary
        }
    }
}

/// One step; equatable on the step value so unchanged rows are skipped.
struct TranscriptStepRow: View, Equatable {
    let step: TranscriptStep
    let transcript: TranscriptModel
    @State private var expanded = false

    static func == (a: TranscriptStepRow, b: TranscriptStepRow) -> Bool {
        a.step == b.step && a.transcript === b.transcript
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TaskStepIcon(kind: step.kind)
                switch step.kind {
                case .text:
                    MarkdownView(source: transcript.displayText(for: step, limit: 8000).text, compact: true)
                case .thinking:
                    Text(transcript.displaySummary(for: step, limit: expanded ? 4000 : 240))
                        .font(Theme.Font.body).italic().foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 3)
                        .onTapGesture { expanded.toggle() }
                case .error:
                    Text(transcript.displayText(for: step).text)
                        .font(Theme.Font.body).foregroundStyle(Theme.destructive)
                        .textSelection(.enabled)
                case .tool:
                    Text(transcript.displaySummary(for: step, limit: 200))
                        .font(Theme.Font.mono)
                        .lineLimit(expanded ? nil : 1)
                    if !step.hasResult { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 0)
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            if expanded && step.kind == .tool {
                VStack(alignment: .leading, spacing: 6) {
                    if let input = step.input {
                        Text(input.prettyPrinted)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(40)
                    }
                    if step.hasResult {
                        let out = transcript.displayText(for: step)
                        Divider()
                        Text(out.text + (out.clipped ? "\n…" : ""))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        if step.outputTruncated == true {
                            Text("Output was truncated by the agent runtime.").font(Theme.Font.micro).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                .padding(.leading, 20)
            }
        }
    }
}

/// Header + transcript for one run, in a sheet (upstream AgentTranscriptDialog).
struct TaskTranscriptSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let task: AgentTask

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ActorAvatar(type: "agent", id: task.agentID, size: 22, showName: true, nameFont: Theme.Font.bodyMedium)
                TaskStatusPill(status: task.status)
                if let started = task.startedAt {
                    Text(Formatters.date(started, style: .abbreviated, time: .shortened)).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                if let s = task.startedAt.flatMap(Timestamp.parse), let e = task.completedAt.flatMap(Timestamp.parse) {
                    Text(Formatters.duration(ms: e.timeIntervalSince(s) * 1000)).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if task.status.isActive {
                    Button(role: .destructive) { Task { await session.cancelRun(task) } } label: { Text("Cancel run") }
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if let reason = task.failureReason ?? task.error, !reason.isEmpty {
                Text(reason).font(Theme.Font.caption).foregroundStyle(Theme.destructive).textSelection(.enabled)
            }
            TaskTranscriptView(taskID: task.id, minHeight: 360, maxHeight: .infinity)
        }
        .padding(16)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 640)
    }
}

/// "View transcript" button that opens `TaskTranscriptSheet`.
struct TranscriptButton: View {
    let task: AgentTask
    var label: String = "Transcript"
    @State private var open = false

    var body: some View {
        Button { open = true } label: { Label(label, systemImage: "text.alignleft") }
            .sheet(isPresented: $open) { TaskTranscriptSheet(task: task) }
    }
}

extension JSONValue {
    /// Indented JSON for display.
    var prettyPrinted: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(self), let s = String(data: data, encoding: .utf8) else { return stringValue ?? "" }
        return s
    }
}
