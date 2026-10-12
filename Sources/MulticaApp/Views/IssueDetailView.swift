import AppKit
import MulticaCore
import SwiftUI

struct IssueDetailView: View {
    let session: WorkspaceSession
    let issueID: String
    @State private var detail: IssueDetailModel?

    var body: some View {
        Group {
            if let detail {
                IssueDetailContent(session: session, detail: detail)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if detail == nil { detail = session.openIssue(issueID) }
        }
        .onDisappear {
            if detail != nil {
                session.closeIssue(issueID)
                detail = nil
            }
        }
    }
}

/// The scrollable thread and the composer are siblings: typing re-renders
/// only the composer, and streamed agent output re-renders only the run it
/// belongs to. Upstream, typing a comment while three runs streamed took tens
/// of seconds because both shared one render/style pass (MUL-7227).
struct IssueDetailContent: View {
    let session: WorkspaceSession
    let detail: IssueDetailModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let model = detail.issue {
                        IssueHeader(model: model, session: session)
                    } else if detail.isLoading {
                        ProgressView()
                    }
                    if let error = detail.loadError {
                        Text(error).foregroundStyle(.red)
                    }
                    if !detail.runs.isEmpty {
                        RunsSection(session: session, detail: detail)
                    }
                    Divider()
                    TimelineSection(session: session, detail: detail)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            CommentComposer(session: session, issueID: detail.id)
        }
        .navigationTitle(detail.issue?.issue.identifier ?? "Issue")
    }
}

// MARK: - Header

struct IssueHeader: View {
    let model: IssueModel
    let session: WorkspaceSession
    @State private var editingTitle: String?

    var body: some View {
        let issue = model.issue
        VStack(alignment: .leading, spacing: 12) {
            if let draft = editingTitle {
                TextField("Title", text: Binding(get: { draft }, set: { editingTitle = $0 }))
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .onSubmit { commitTitle() }
                    .onExitCommand { editingTitle = nil }
            } else {
                Text(issue.title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                    .onTapGesture(count: 2) { editingTitle = issue.title }
                    .help("Double-click to rename")
            }

            HStack(spacing: 8) {
                StatusMenu(model: model, session: session)
                PriorityMenu(model: model, session: session)
                AssigneePicker(model: model, session: session)
                Spacer()
                Text("Updated \(Formatters.relative(issue.updatedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let description = issue.description, !description.isEmpty {
                MarkdownText(source: description)
                    .font(.body)
            } else {
                Text("No description").foregroundStyle(.tertiary)
            }
        }
    }

    private func commitTitle() {
        guard let title = editingTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              title != model.issue.title else {
            editingTitle = nil
            return
        }
        editingTitle = nil
        var r = UpdateIssueRequest()
        r.title = title
        Task { await session.updateIssue(model.id, r) }
    }
}

struct StatusMenu: View {
    let model: IssueModel
    let session: WorkspaceSession

    var body: some View {
        let catalog = session.issues.catalog
        Menu {
            ForEach(catalog.entries) { entry in
                Button(entry.name) {
                    var r = UpdateIssueRequest()
                    r.status = entry.key
                    Task { await session.updateIssue(model.id, r) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                catalog.icon(for: model.issue.status)
                Text(catalog.displayName(for: model.issue.status))
            }
        }
        .menuStyle(.button)
        .fixedSize()
    }
}

struct PriorityMenu: View {
    let model: IssueModel
    let session: WorkspaceSession

    var body: some View {
        Menu {
            ForEach(IssuePriority.allCases, id: \.self) { p in
                Button(p.label) {
                    var r = UpdateIssueRequest()
                    r.priority = p
                    Task { await session.updateIssue(model.id, r) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                PriorityIcon(priority: model.issue.priority)
                Text(model.issue.priority.label)
            }
        }
        .menuStyle(.button)
        .fixedSize()
    }
}

struct AssigneePicker: View {
    let model: IssueModel
    let session: WorkspaceSession

    var body: some View {
        Menu {
            AssigneeMenu(model: model, session: session)
        } label: {
            ActorBadge(ref: model.issue.assignee, directory: session.directory, showName: true)
        }
        .menuStyle(.button)
        .fixedSize()
    }
}

// MARK: - Runs

struct RunsSection: View {
    let session: WorkspaceSession
    let detail: IssueDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent runs").font(.headline)
            ForEach(detail.runs.prefix(6)) { run in
                RunCard(session: session, run: run, transcript: detail.transcript(for: run.id))
            }
        }
    }
}

struct RunCard: View {
    let session: WorkspaceSession
    let run: AgentTask
    let transcript: TranscriptModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Avatar(name: session.directory.name(type: "agent", id: run.agentID), isAgent: true)
                Text(session.directory.name(type: "agent", id: run.agentID)).font(.callout.weight(.medium))
                TaskStatusPill(status: run.status)
                if let reason = run.failureReason, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if run.status.isActive {
                    Button("Cancel") { Task { await session.cancelRun(run) } }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(expanded ? "Hide execution log" : "Show execution log")
            }
            if expanded {
                TranscriptView(session: session, transcript: transcript)
            } else if run.status.isActive, let step = transcript.lastStep {
                // Live one-line summary: a stable row whose text changes.
                HStack(spacing: 6) {
                    StepIcon(kind: step.kind)
                    Text(transcript.displaySummary(for: step))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct TranscriptView: View {
    let session: WorkspaceSession
    let transcript: TranscriptModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if transcript.isLoading && transcript.steps.isEmpty {
                    ProgressView().controlSize(.small)
                }
                ForEach(transcript.steps) { step in
                    StepRow(step: step, transcript: transcript)
                }
            }
            .padding(8)
        }
        .defaultScrollAnchor(.bottom)
        .frame(minHeight: 140, maxHeight: 460)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .onAppear { session.watchTranscript(transcript) }
        .onDisappear { session.unwatchTranscript(transcript) }
    }
}

struct StepIcon: View {
    let kind: TranscriptStep.Kind

    var body: some View {
        Image(systemName: symbol).foregroundStyle(color).imageScale(.small).frame(width: 14)
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
        case .error: return .red
        case .thinking: return .purple
        default: return .secondary
        }
    }
}

/// One transcript step. Its inputs are a value plus a stable model reference,
/// so SwiftUI skips it unless that step itself changed.
struct StepRow: View, Equatable {
    let step: TranscriptStep
    let transcript: TranscriptModel
    @State private var expanded = false

    static func == (a: StepRow, b: StepRow) -> Bool {
        a.step == b.step && a.transcript === b.transcript
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StepIcon(kind: step.kind)
                Text(transcript.displaySummary(for: step, limit: 200))
                    .font(step.kind == .tool ? Font.callout.monospaced() : Font.callout)
                    .foregroundStyle(step.kind == .thinking ? Color.secondary : Color.primary)
                    .lineLimit(expanded ? nil : 2)
                if step.kind == .tool && !step.hasResult {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 0)
                if step.kind == .tool && step.hasResult {
                    Button(expanded ? "Hide" : "Output") { expanded.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if expanded {
                let output = transcript.displayText(for: step)
                Text(output.text + (output.clipped ? "\n…" : ""))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                if step.outputTruncated == true {
                    Text("Output was truncated by the agent runtime.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Timeline

struct TimelineSection: View {
    let session: WorkspaceSession
    let detail: IssueDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Activity").font(.headline)
            ForEach(detail.entries) { entry in
                switch entry.kind {
                case .comment: CommentRow(entry: entry, directory: session.directory)
                case .activity: ActivityRow(entry: entry, directory: session.directory)
                }
            }
            ForEach(detail.pendingComments) { pending in
                PendingCommentRow(pending: pending, session: session, issueID: detail.id)
            }
        }
    }
}

struct CommentRow: View {
    let entry: TimelineEntry
    let directory: Directory

    var body: some View {
        let name = entry.actorName ?? directory.name(type: entry.actorType, id: entry.actorID)
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: name, isAgent: entry.actorType == "agent", size: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name).font(.callout.weight(.semibold))
                    Text(Formatters.relative(entry.createdAt)).font(.caption).foregroundStyle(.secondary)
                    if entry.resolvedAt != nil {
                        Text("Resolved").font(.caption2).foregroundStyle(.green)
                    }
                }
                if entry.isDeletedComment {
                    Text("This comment was deleted.").italic().foregroundStyle(.secondary)
                } else {
                    MarkdownText(source: entry.content ?? "")
                }
                if !entry.reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Dictionary(grouping: entry.reactions, by: \.emoji).sorted { $0.key < $1.key }, id: \.key) { group in
                            Text("\(group.key) \(group.value.count)")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(.leading, entry.parentID == nil ? 0 : 36)
    }
}

struct ActivityRow: View {
    let entry: TimelineEntry
    let directory: Directory

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary)
            Text(description).font(.caption).foregroundStyle(.secondary)
            Text(Formatters.relative(entry.createdAt)).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.leading, 10)
    }

    private var description: String {
        let actor = entry.actorName ?? directory.name(type: entry.actorType, id: entry.actorID)
        let action = (entry.action ?? "updated").replacingOccurrences(of: "_", with: " ")
        if let to = entry.details?["to"]?.stringValue ?? entry.details?["new"]?.stringValue {
            return "\(actor) \(action) → \(to)"
        }
        return "\(actor) \(action)"
    }
}

struct PendingCommentRow: View {
    let pending: PendingComment
    let session: WorkspaceSession
    let issueID: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: session.currentUser.name, size: 26)
            VStack(alignment: .leading, spacing: 4) {
                MarkdownText(source: pending.content).opacity(0.6)
                switch pending.state {
                case .sending:
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Sending…").font(.caption).foregroundStyle(.secondary)
                    }
                case .failed(let reason):
                    HStack(spacing: 8) {
                        Text("Not sent: \(reason)").font(.caption).foregroundStyle(.red)
                        Button("Retry") { Task { await session.retryComment(pending.id, issueID: issueID) } }
                            .buttonStyle(.link)
                        Button("Discard") { session.discardComment(pending.id, issueID: issueID) }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }
}

// MARK: - Composer

struct CommentComposer: View {
    let session: WorkspaceSession
    let issueID: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Leave a comment…  @mention an agent to hand it work", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused($focused)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25)))
            Button("Send", action: send)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send (⌘↩)")
        }
        .padding(12)
    }

    private func send() {
        let content = text
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = ""
        Task { await session.postComment(issueID: issueID, content: content) }
    }
}
