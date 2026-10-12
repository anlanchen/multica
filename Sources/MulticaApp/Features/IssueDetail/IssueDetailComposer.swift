import AppKit
import MulticaCore
import SwiftUI

extension IssueDetailStore {
    /// Scrolls a freshly posted comment into view (no flash, like upstream).
    func reveal(_ commentID: String) {
        let root = layout.replyToRoot[commentID] ?? commentID
        collapsedThreads.remove(root)
        scrollRequest = (commentID, Int.random(in: 1...Int.max))
    }
}

/// What a recipient does with the message (upstream use-recipient-actions).
enum IssueDetailRecipientAction: String {
    case start, skip, steer, afterRun, restart, join
}

/// The bottom comment composer and the thread reply box (upstream
/// CommentInput / ReplyInput): Markdown editor with @-mentions, file
/// paste/drop/upload, a debounced preview of which agents the message
/// starts, and the per-recipient routing. The text stays until the server
/// accepts the comment; a failure keeps the draft.
struct IssueDetailComposer: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(ShortcutStore.self) private var shortcuts
    let store: IssueDetailStore
    let parentID: String?
    let draftKey: String
    var maxEditorHeight: CGFloat = 400
    var compact = false
    var autofocus = false

    @State private var text = ""
    @State private var uploads = ComposerUploads()
    @State private var submitting = false
    @State private var preview: CommentTriggerPreview?
    @State private var previewFor = ""
    @State private var choices: [String: IssueDetailRecipientAction] = [:]
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if attachmentsBlockSteer {
                Text(tr("issues", "comment.steer_attachment_notice")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
            }
            MarkdownEditor(text: $text,
                           placeholder: tr("issues", compact ? "reply.placeholder" : "comment.leave_comment_placeholder"),
                           minHeight: compact ? 22 : 36, maxHeight: maxEditorHeight, autofocus: autofocus,
                           isEditable: !submitting,
                           onSubmit: submit,
                           onFiles: upload,
                           mentions: { session.mentionCandidates($0, includeIssues: true) })
                .opacity(submitting ? 0.6 : 1)
                .padding(.horizontal, compact ? 0 : 8)
                .padding(.top, compact ? 0 : 8)
            HStack(spacing: 6) {
                IssueDetailRecipientChips(store: store, recipients: recipients, blocked: blocked,
                                          allMembers: text.contains("mention://all/all")) { id, action in choices[id] = action }
                Spacer(minLength: 4)
                Button { upload(IssueDetailFiles.pick()) } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(tr("ui", "attach_file"))
                if !routing.restart.isEmpty {
                    Button(tr("issues", "comment.restart_send"), role: .destructive, action: submit)
                        .controlSize(.small)
                        .disabled(!canSend)
                } else {
                    Button(action: submit) {
                        if submitting {
                            ProgressView().controlSize(.mini).frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(canSend ? Theme.brand : Color.secondary.opacity(0.4)))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help(sendTooltip)
                }
            }
            .padding(.horizontal, compact ? 0 : 8)
            .padding(.vertical, compact ? 4 : 6)
        }
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .overlay {
            if !compact { RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border) }
        }
        .onAppear { text = IssueDetailSessionState.drafts[draftKey] ?? "" }
        .onChange(of: text) {
            if text.isEmpty { IssueDetailSessionState.drafts[draftKey] = nil } else { IssueDetailSessionState.drafts[draftKey] = text }
            schedulePreview()
        }
        .onDisappear { previewTask?.cancel() }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !submitting && !uploads.isUploading
    }

    private var sendTooltip: String {
        if uploads.isUploading { return tr("editor", "upload.in_progress") }
        let chord = shortcuts.chord(for: .send).map { " · " + $0.display.joined() } ?? ""
        return tr("issues", "comment.send_tooltip") + chord
    }

    // MARK: Recipients

    struct Recipient: Identifiable, Hashable {
        enum State: Hashable { case idle, queued(String), running(String, steerable: Bool) }
        var agent: CommentTriggerPreviewAgent
        var state: State
        var action: IssueDetailRecipientAction
        var id: String { agent.id }

        var actions: [IssueDetailRecipientAction] {
            switch state {
            case .idle: return [.start, .skip]
            case .queued: return [.join, .skip]
            case .running(_, let steerable): return (steerable ? [.steer] : []) + [.afterRun, .restart, .skip]
            }
        }
    }

    private var hasAttachments: Bool { !uploads.attachmentIDs.isEmpty }

    private var recipients: [Recipient] {
        guard previewFor == text else { return [] }
        return (preview?.agents ?? []).map { agent in
            let tasks = store.activeTasks.filter { $0.agentId == agent.id }
            let state: Recipient.State
            if let running = tasks.first(where: { $0.status == "running" }) {
                state = .running(running.id, steerable: running.canSupplement == true)
            } else if let queued = tasks.first {
                state = .queued(queued.id)
            } else {
                state = .idle
            }
            let fallback: IssueDetailRecipientAction
            switch state {
            case .idle: fallback = .start
            case .queued: fallback = .join
            case .running(_, let steerable): fallback = steerable && !hasAttachments ? .steer : .afterRun
            }
            var action = choices[agent.id] ?? fallback
            if action == .steer && hasAttachments { action = .afterRun }
            return Recipient(agent: agent, state: state, action: action)
        }
    }

    private var blocked: [CommentTriggerOutcome] { previewFor == text ? (preview?.blocked ?? []) : [] }

    private var attachmentsBlockSteer: Bool {
        hasAttachments && recipients.contains { r in
            if case .running(_, let steerable) = r.state, steerable { return choices[r.id] == .steer || choices[r.id] == nil }
            return false
        }
    }

    private var routing: (suppress: [String], steer: [String], restart: [String]) {
        var out: ([String], [String], [String]) = ([], [], [])
        for r in recipients {
            switch (r.action, r.state) {
            case (.skip, _): out.0.append(r.agent.id)
            case (.steer, .running(let task, _)): out.1.append(task)
            case (.restart, .running(let task, _)): out.2.append(task)
            default: break
            }
        }
        return out
    }

    private func schedulePreview() {
        previewTask?.cancel()
        let content = text
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            preview = nil
            previewFor = content
            return
        }
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let result = try? await session.api.previewCommentTriggers(issueId: store.issueID, content: content, parentId: parentID)
            guard !Task.isCancelled, content == text else { return }
            preview = result
            previewFor = content
            let visible = Set((result?.agents ?? []).map(\.id))
            choices = choices.filter { visible.contains($0.key) }
        }
    }

    // MARK: Submit

    private func upload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        uploads.upload(urls, session: session, issueID: store.issueID, insert: { md in
            text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + md + "\n"
        }, onError: { toaster.error($0) })
    }

    private func submit() {
        guard canSend else { return }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = routing
        let attachmentIDs = uploads.attachmentIDs.filter { content.contains($0) }
        submitting = true
        Task {
            defer { submitting = false }
            for taskID in r.restart {
                do {
                    _ = try await session.api.cancelTask(issueID: store.issueID, taskID: taskID)
                } catch {
                    toaster.error(tr("issues", "comment.restart_failed"))
                    return
                }
            }
            guard let id = await store.postComment(content, parentID: parentID, attachmentIDs: attachmentIDs,
                                                   suppressAgentIDs: r.suppress, steerTaskIDs: r.steer, toaster: toaster) else { return }
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == content {
                text = ""
                IssueDetailSessionState.drafts[draftKey] = nil
            }
            uploads.reset()
            choices = [:]
            preview = nil
            store.reveal(id)
        }
    }
}

/// The recipient chips under a composer (upstream CommentTriggerChips).
struct IssueDetailRecipientChips: View {
    let store: IssueDetailStore
    let recipients: [IssueDetailComposer.Recipient]
    let blocked: [CommentTriggerOutcome]
    let allMembers: Bool
    let onAction: (String, IssueDetailRecipientAction) -> Void

    var body: some View {
        HStack(spacing: 4) {
            if allMembers {
                Text(tr("issues", "comment.all_members_notice")).font(Theme.Font.micro).foregroundStyle(.secondary).lineLimit(1)
            }
            let starting = recipients.filter { $0.action != .skip }
            if !recipients.isEmpty {
                Text(starting.isEmpty ? tr("issues", "comment.trigger_none_will_trigger")
                     : tr("issues", "comment.recipient_count", ["count": starting.count]))
                    .font(Theme.Font.micro).foregroundStyle(.secondary).lineLimit(1)
            }
            ForEach(recipients) { r in chip(r) }
            ForEach(blocked, id: \.targetId) { b in
                Label(IssueDetailPosted.shortReason(b.reasonCode), systemImage: "exclamationmark.triangle")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.warning)
                    .lineLimit(1)
                    .help(blockedReason(b.reasonCode))
            }
        }
    }

    @ViewBuilder private func chip(_ r: IssueDetailComposer.Recipient) -> some View {
        let skipped = r.action == .skip
        Menu {
            ForEach(r.actions, id: \.self) { a in
                Button { onAction(r.id, a) } label: {
                    Text(label(a, r) + (a == r.action ? "  ✓" : ""))
                }
                .help(description(a, r))
            }
        } label: {
            HStack(spacing: 4) {
                AvatarView(name: r.agent.name, url: r.agent.avatarUrl, kind: .agent, size: 14)
                Text(r.agent.name).lineLimit(1).strikethrough(skipped)
                if case .running = r.state { Text("· " + tr("issues", "comment.recipient_state_running")).foregroundStyle(Theme.info) }
                if case .queued = r.state { Text("· " + tr("issues", "comment.recipient_state_queued")).foregroundStyle(.secondary) }
            }
            .font(Theme.Font.micro)
            .opacity(skipped ? 0.5 : 1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .help(tr("issues", "comment.trigger_chip_aria", ["name": r.agent.name, "state": label(r.action, r)]) + " · "
              + tr("issues", r.state == .idle ? (skipped ? "comment.trigger_click_to_restore" : "comment.trigger_click_to_skip") : "comment.trigger_click_to_manage"))
    }

    private func label(_ a: IssueDetailRecipientAction, _ r: IssueDetailComposer.Recipient) -> String {
        switch a {
        case .start: return tr("issues", "comment.trigger_will_start")
        case .skip: return tr("issues", "comment.trigger_skipped_label")
        case .steer: return tr("issues", "comment.recipient_steer")
        case .afterRun: return tr("issues", "comment.recipient_after_run")
        case .restart: return tr("issues", "comment.recipient_restart")
        case .join: return tr("issues", "comment.recipient_join")
        }
    }

    private func description(_ a: IssueDetailRecipientAction, _ r: IssueDetailComposer.Recipient) -> String {
        switch a {
        case .start: return tr("issues", "comment.trigger_starts_now")
        case .skip: return tr("issues", "comment.trigger_wont_trigger")
        case .steer: return tr("issues", "comment.recipient_steer_desc", ["name": r.agent.name])
        case .afterRun: return tr("issues", "comment.recipient_after_run_desc")
        case .restart: return tr("issues", "comment.recipient_restart_desc")
        case .join: return tr("issues", "comment.recipient_join_desc", ["name": r.agent.name])
        }
    }

    private func blockedReason(_ code: String) -> String {
        let key = "comment.trigger_blocked_" + code
        let s = tr("issues", key)
        return s == key ? tr("issues", "comment.trigger_blocked_generic") : s
    }
}

/// The reply box at the bottom of a thread: a one-line placeholder until
/// first use, so a long timeline does not mount one text view per thread.
struct IssueDetailReplyBox: View {
    @Environment(WorkspaceSession.self) private var session
    let store: IssueDetailStore
    let rootID: String
    @State private var active = false

    private var draftKey: String { "reply:\(store.issueID):\(rootID)" }

    var body: some View {
        if active || IssueDetailSessionState.drafts[draftKey] != nil {
            HStack(alignment: .top, spacing: 8) {
                ActorAvatar(type: "member", id: store.currentUserID, size: 22)
                IssueDetailComposer(store: store, parentID: rootID, draftKey: draftKey, maxEditorHeight: 300, compact: true, autofocus: active)
            }
        } else {
            Button { active = true } label: {
                HStack(spacing: 8) {
                    ActorAvatar(type: "member", id: store.currentUserID, size: 22)
                    Text(tr("issues", "reply.placeholder")).font(Theme.Font.body).foregroundStyle(.tertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
