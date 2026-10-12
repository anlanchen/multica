import AppKit
import MulticaCore
import SwiftUI

/// Upstream SourceContextBadge: where an issue created from a comment came
/// from, the source's current state, and the captured snapshot viewer.
struct IssueDetailSourceContextBadge: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let store: IssueDetailStore
    let context: IssueSourceContext
    @State private var viewer = false

    var body: some View {
        let snapshot = context.snapshot
        let parent = store.parentIssue
        let identifier = parent?.identifier ?? snapshot?.sourceIssue?.identifier ?? ""
        let title = parent?.title ?? snapshot?.sourceIssue?.title ?? ""
        HStack(spacing: 8) {
            Text(tr("issues", parent != nil ? "detail.sub_issue_of" : "source_context.created_from")).foregroundStyle(.secondary)
            if let parent {
                Button { nav.push(.issue(parent.id), title: parent.identifier) } label: {
                    HStack(spacing: 5) {
                        session.issues.catalog.icon(for: parent.status)
                        Text(identifier).monospacedDigit()
                        Text(title).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(Theme.Font.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                if !store.parentChildren.isEmpty {
                    let done = store.parentChildren.filter { $0.category(in: session.issues.catalog) == .done }.count
                    IssueDetailProgressChip(done: done, total: store.parentChildren.count)
                }
            } else {
                Text(identifier).fontWeight(.medium).monospacedDigit()
                Text(title).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let state = stateLabel {
                Text(state.text).font(Theme.Font.micro.weight(.medium)).foregroundStyle(state.color)
            }
            Button { viewer = true } label: {
                HStack(spacing: 3) {
                    Text(tr("issues", "source_context.context_snapshot"))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(.borderless)
        }
        .font(Theme.Font.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
        .sheet(isPresented: $viewer) { IssueDetailSourceContextViewer(context: context) }
    }

    private var stateLabel: (text: String, color: Color)? {
        if context.sourceIssueState == "deleted" { return (tr("issues", "source_context.issue_deleted"), Theme.destructive) }
        switch context.displayState {
        case "changed": return (tr("issues", "source_context.summary_changed"), Theme.warning)
        case "unavailable": return (tr("issues", "source_context.summary_unavailable"), .secondary)
        default: return nil
        }
    }
}

/// The captured snapshot: the source issue as it was and the comment
/// thread the agent received.
private struct IssueDetailSourceContextViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let context: IssueSourceContext
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("issues", "source_context.viewer_title")).font(Theme.Font.title)
                    Text(tr("issues", "source_context.agent_received")).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless)
                    .help(tr("issues", expanded ? "source_context.viewer_restore" : "source_context.viewer_expand"))
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help(tr("issues", "source_context.viewer_close"))
            }
            if context.displayState == "changed" || context.sourceIssueState == "deleted" {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("issues", "source_context.change_sentence", ["content": context.sourceIssueState == "deleted"
                        ? tr("issues", "source_context.issue_deleted_after_capture") : tr("issues", "source_context.source_changed")]))
                    if let reasons = context.changeReasons, !reasons.isEmpty {
                        Text(tr("issues", "source_context.changed") + tr("issues", "source_context.label_spacing")
                             + reasons.map(subject).joined(separator: ", "))
                    }
                    Text(tr("issues", "source_context.captured_context_available")).foregroundStyle(.secondary)
                }
                .font(Theme.Font.caption)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.warning.opacity(0.08)))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let issue = context.snapshot?.sourceIssue {
                        HStack(spacing: 6) {
                            Text(issue.identifier).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                            if context.canOpenCurrentSource {
                                Button(tr("issues", "source_context.open_current")) {
                                    dismiss()
                                    nav.push(.issue(issue.id), title: issue.identifier)
                                }
                                .buttonStyle(.link)
                                .font(Theme.Font.caption)
                            }
                        }
                        Text(issue.title).font(Theme.Font.title)
                        if let d = issue.description, !d.isEmpty { MarkdownView(source: d) }
                    }
                    if let thread = context.snapshot?.commentThread, !thread.isEmpty {
                        Text(tr("issues", "source_context.thread_history")).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                        ForEach(thread, id: \.id) { c in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    if let author = c.author {
                                        ActorAvatar(type: author.type, id: author.id, size: 18, showName: true, nameFont: Theme.Font.caption.weight(.medium))
                                    }
                                    Text(Formatters.date(c.createdAt, style: .abbreviated, time: .shortened)).font(Theme.Font.micro).foregroundStyle(.secondary)
                                    if c.id == context.snapshot?.anchorCommentId {
                                        Badge(text: tr("issues", "source_context.source_comment"), color: Theme.brand)
                                    }
                                }
                                MarkdownView(source: c.content).padding(.leading, 24)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(c.id == context.snapshot?.anchorCommentId ? 0.05 : 0.02)))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(width: expanded ? 1100 : 760, height: expanded ? 820 : 600)
    }

    private func subject(_ reason: String) -> String {
        switch reason {
        case "issue_title": return tr("issues", "source_context.change_subject_issue_title")
        case "issue_description": return tr("issues", "source_context.change_subject_issue_description")
        case "issue_attachments": return tr("issues", "source_context.change_subject_issue_attachments")
        case "comment_thread": return tr("issues", "source_context.change_subject_comment_thread")
        default: return reason
        }
    }
}

/// "Create sub-issue from here": an agent files a sub-issue carrying this
/// comment's thread as captured context (upstream quick-create modal with
/// `anchor_comment_id`).
struct IssueDetailCommentSubIssueSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let store: IssueDetailStore
    let anchorCommentID: String
    @State private var preview: SourceContextPreview?
    @State private var failed: String?
    @State private var agentID = ""
    @State private var prompt = ""
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("issues", "source_context.create_action")).font(Theme.Font.title)
            if let identifier = store.issue?.identifier {
                Text(tr("modals", "create_issue.agent.sub_issue_of", ["identifier": identifier])).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Group {
                if let failed {
                    HStack {
                        Text(failed).foregroundStyle(Theme.destructive)
                        Button(tr("issues", "source_context.refresh")) { Task { await load() } }.buttonStyle(.link)
                    }
                } else if let preview {
                    Text(tr("issues", "source_context.preview_summary", [
                        "identifier": preview.sourceIssue?.identifier ?? store.issue?.identifier ?? "",
                        "count": preview.commentThread.count,
                    ]))
                } else {
                    Text(tr("issues", "source_context.preview_loading")).foregroundStyle(.secondary)
                }
            }
            .font(Theme.Font.caption)
            Picker(tr("modals", "create_issue.agent.select_agent_aria"), selection: $agentID) {
                Text(tr("modals", "create_issue.agent.pick_an_agent")).tag("")
                ForEach(session.directory.agents.filter { !$0.runtimeID.isEmpty }) { a in Text(a.name).tag(a.id) }
            }
            MarkdownEditor(text: $prompt, placeholder: tr("modals", "create_issue.agent.source_context_prompt_placeholder"),
                           minHeight: 100, maxHeight: 260, autofocus: true, onSubmit: submit,
                           mentions: { session.mentionCandidates($0, includeIssues: true) })
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
            HStack {
                Spacer()
                Button(tr("common", "cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("modals", sending ? "create_issue.agent.sending" : "create_issue.agent.submit"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || preview == nil || agentID.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520)
        .task {
            if let a = store.issue?.assignee, a.type == "agent" { agentID = a.id }
            await load()
        }
    }

    private func load() async {
        failed = nil
        do {
            preview = try await session.api.getCommentSubIssuePreview(anchorCommentId: anchorCommentID)
        } catch let e as APIError where e.status == 404 || e.status == 410 {
            failed = tr("issues", "source_context.preview_anchor_deleted")
        } catch {
            failed = tr("issues", "source_context.preview_failed")
        }
    }

    private func submit() {
        guard let preview, !agentID.isEmpty else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        Task {
            defer { sending = false }
            var quick: [String: JSONValue] = ["prompt": JSONValue(text), "agent_id": JSONValue(agentID), "parent_issue_id": JSONValue(store.issueID)]
            if let project = store.issue?.projectID { quick["project_id"] = JSONValue(project) }
            do {
                _ = try await session.api.createCommentSubIssue(
                    anchorCommentId: anchorCommentID,
                    agent: CreateCommentSubIssueAgentRequest(mode: "agent", captureToken: preview.captureToken, quickCreate: .object(quick)))
                toaster.success(tr("modals", "create_issue.agent.toast_sent"))
                dismiss()
            } catch let e as APIError {
                toaster.error(e.message.isEmpty ? tr("modals", "create_issue.agent.error_unknown") : e.message)
            } catch {
                toaster.error(tr("modals", "create_issue.agent.error_unknown"))
            }
        }
    }
}
