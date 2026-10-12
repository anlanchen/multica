import AppKit
import MulticaCore
import SwiftUI

/// One timeline row. Equatable on its own data, so a WebSocket event in
/// another thread, a streaming run elsewhere or typing in the composer
/// skips this row's body entirely.
struct IssueDetailTimelineRow: View, Equatable {
    let store: IssueDetailStore
    let item: IssueDetailTimelineItem
    let activityExpanded: Bool
    let showOlder: Bool
    let isLastActivity: Bool
    let collapsed: Bool
    let resolvedExpanded: Bool
    let highlightedID: String?
    let canModerate: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.item == b.item && a.activityExpanded == b.activityExpanded && a.showOlder == b.showOlder
            && a.isLastActivity == b.isLastActivity && a.collapsed == b.collapsed && a.resolvedExpanded == b.resolvedExpanded
            && a.highlightedID == b.highlightedID && a.canModerate == b.canModerate && a.store === b.store
    }

    var body: some View {
        switch item {
        case .activities(let id, let entries):
            IssueDetailActivityBlock(entries: entries, expanded: activityExpanded, truncateOlder: isLastActivity, showOlder: showOlder,
                                     onToggle: { store.toggleActivity(id) },
                                     onShowOlder: { store.showOlderActivity.insert(id) })
        case .thread(let thread):
            threadView(thread, standaloneRun: nil)
        case .run(let run, let thread):
            if let thread {
                threadView(thread, standaloneRun: run)
            } else {
                IssueDetailStandaloneRun(store: store, run: run)
            }
        }
    }

    @ViewBuilder private func threadView(_ thread: IssueDetailThread, standaloneRun: IssueDetailRun?) -> some View {
        if thread.root.resolvedAt != nil && !resolvedExpanded {
            IssueDetailResolvedBar(thread: thread) { store.setResolvedExpanded(thread.root.id, true) }
        } else {
            IssueDetailThreadCard(store: store, thread: thread, collapsed: collapsed, resolvedExpanded: resolvedExpanded,
                                  highlightedID: highlightedID, canModerate: canModerate)
        }
    }
}

/// An issue-level run with nothing posted yet, as its own card.
private struct IssueDetailStandaloneRun: View {
    let store: IssueDetailStore
    let run: IssueDetailRun
    @State private var expanded = false

    var body: some View {
        IssueDetailRunBlock(store: store, run: run, showIdentity: true, expanded: $expanded)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

/// Upstream ActivityBlock: older blocks fold to "N activities"; the
/// trailing block stays open showing its latest eight entries.
struct IssueDetailActivityBlock: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let entries: [TimelineEntry]
    let expanded: Bool
    let truncateOlder: Bool
    let showOlder: Bool
    let onToggle: () -> Void
    let onShowOlder: () -> Void

    static let visibleLimit = 8

    var body: some View {
        let hidden = expanded && truncateOlder && !showOlder && entries.count > Self.visibleLimit ? entries.count - Self.visibleLimit : 0
        VStack(alignment: .leading, spacing: 10) {
            if !expanded || hidden == 0 {
                toggle(expanded ? "chevron.down" : "chevron.right", tr("issues", "activity.activity_count", ["count": entries.count]), action: onToggle)
            }
            if expanded {
                if hidden > 0 {
                    toggle("chevron.right", tr("issues", "activity.show_more_activities", ["count": hidden]), action: onShowOlder)
                }
                ForEach(hidden > 0 ? Array(entries.suffix(Self.visibleLimit)) : entries, id: \.id) { e in
                    IssueDetailActivityLine(entry: e)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func toggle(_ icon: String, _ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(text)
            }
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct IssueDetailActivityLine: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let entry: TimelineEntry

    var body: some View {
        let names = session.issueDetailNames
        let isWakeup = IssueDetailActivityText.wakeupActions.contains(entry.action ?? "")
        let text = IssueDetailActivityText.format(entry, names)
        let chip = isWakeup ? IssueDetailActivityText.wakeupChip(entry, names) : nil
        HStack(spacing: 6) {
            leadIcon(isWakeup: isWakeup).frame(width: 16)
            if !(isWakeup && entry.actorType == "system") {
                Text(entry.actorName ?? names.actor(entry.actorType, entry.actorID)).fontWeight(.medium).lineLimit(1).layoutPriority(1)
            }
            activityText(text)
            Spacer(minLength: 4)
            if let chip {
                Text(chip).font(Theme.Font.micro).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
                    .frame(maxWidth: 190, alignment: .trailing)
            }
            if let n = entry.coalescedCount, n > 1, entry.action != "task_completed", entry.action != "task_failed" {
                Text(tr("issues", "activity.coalesced_badge", ["count": n])).font(Theme.Font.caption.weight(.medium)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
            }
            RelativeTime(timestamp: entry.createdAt).fixedSize()
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func activityText(_ text: String) -> some View {
        if let link = IssueDetailActivityText.linkTarget(entry), let r = text.range(of: link.identifier) {
            HStack(spacing: 0) {
                Text(String(text[..<r.lowerBound])).lineLimit(1)
                Button(link.identifier) { nav.push(.issue(link.id), title: link.identifier) }
                    .buttonStyle(.plain).foregroundStyle(.primary).fontWeight(.medium)
                Text(String(text[r.upperBound...])).lineLimit(1)
            }
        } else {
            Text(text).lineLimit(1).truncationMode(.tail)
        }
    }

    @ViewBuilder private func leadIcon(isWakeup: Bool) -> some View {
        let to = entry.details?["to"]?.stringValue
        switch entry.action {
        case _ where isWakeup:
            Image(systemName: wakeupSymbol).font(.system(size: 11)).foregroundStyle(entry.action == "wakeup_paused" ? Theme.warning : .secondary)
        case "status_changed" where to != nil, "duplicate_unmarked" where to != nil:
            session.issues.catalog.icon(for: IssueStatusKey(rawValue: to ?? ""))
        case "duplicate_marked":
            session.issues.catalog.icon(for: .cancelled)
        case "priority_changed" where to != nil:
            PriorityIcon(priority: IssuePriority(rawValue: to ?? "") ?? .none)
        case "start_date_changed":
            Image(systemName: "calendar.badge.clock").font(.system(size: 11))
        case "due_date_changed":
            Image(systemName: "calendar").font(.system(size: 11))
        default:
            ActorAvatar(type: entry.actorType, id: entry.actorID, size: 16)
        }
    }

    private var wakeupSymbol: String {
        if entry.details?["rule"]?.stringValue == "child_done" { return "checklist" }
        switch entry.action {
        case "wakeup_timed_out": return "hourglass"
        case "wakeup_paused": return "exclamationmark.triangle"
        case "wakeup_checkin": return "arrow.clockwise"
        default:
            let kind = entry.details?["wakeup"]?["kind"]?.stringValue
            return kind != nil && kind != "event" ? "clock" : "bell"
        }
    }
}

/// Distinct authors label ("Alice", "Alice, Bob", "Alice, Bob and 2 others").
@MainActor
private func issueDetailAuthorsLabel(_ entries: [TimelineEntry], _ session: WorkspaceSession) -> String {
    var seen = Set<String>()
    var names: [String] = []
    for e in entries where !e.isDeletedComment {
        guard seen.insert("\(e.actorType):\(e.actorID)").inserted else { continue }
        names.append(e.actorName ?? session.actorInfo(type: e.actorType, id: e.actorID).name)
    }
    if names.count <= 2 { return names.joined(separator: ", ") }
    return tr("issues", "comment.resolve.bar_authors_more", ["names": names.prefix(2).joined(separator: ", "), "count": names.count - 2])
}

/// Whole-thread fold when the root is resolved (upstream ResolvedThreadBar).
struct IssueDetailResolvedBar: View {
    @Environment(WorkspaceSession.self) private var session
    let thread: IssueDetailThread
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                Text(tr("issues", "comment.resolve.bar", [
                    "count": 1 + thread.visibleReplies.count,
                    "authors": issueDetailAuthorsLabel([thread.root] + thread.replies, session),
                ])).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(Theme.Font.body)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .hoverHighlight(cornerRadius: 12)
    }
}

/// The middle fold when a reply is the resolution (upstream CommentsFoldBar).
private struct IssueDetailFoldBar: View {
    @Environment(WorkspaceSession.self) private var session
    let replies: [TimelineEntry]
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                Text(tr("issues", "comment.resolve.fold", ["count": replies.count, "authors": issueDetailAuthorsLabel(replies, session)])).lineLimit(1)
                Spacer()
            }
            .font(Theme.Font.body)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.045)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct IssueDetailCollapseBar: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                Text(tr("issues", "comment.resolve.collapse"))
                Spacer()
            }
            .font(Theme.Font.body)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.05))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One card per thread (upstream CommentCard): the root, its replies and
/// run slots in reading order, folds for resolutions, and the reply box.
struct IssueDetailThreadCard: View {
    @Environment(WorkspaceSession.self) private var session
    let store: IssueDetailStore
    let thread: IssueDetailThread
    let collapsed: Bool
    let resolvedExpanded: Bool
    let highlightedID: String?
    let canModerate: Bool

    var body: some View {
        let root = thread.root
        let resolution = thread.resolution
        let replyResolutionID = resolution.replyID
        let folded = replyResolutionID != nil && !resolvedExpanded
        let rows: [IssueDetailThreadRow] = folded
            ? thread.rows(replies: thread.replies.filter { $0.id == replyResolutionID },
                          runs: thread.runs.filter { !$0.hasReply && ($0.anchorCommentID == root.id || $0.anchorCommentID == replyResolutionID) })
            : thread.rows(replies: thread.replies, runs: thread.runs)
        let foldedReplies = thread.visibleReplies.filter { $0.id != replyResolutionID }
        let repliedTo = Set(thread.replies.compactMap(\.parentID))
        let rootRuns = thread.runs.filter { $0.commentID == root.id && $0.hasReply }
        VStack(alignment: .leading, spacing: 0) {
            if root.resolvedAt != nil {
                IssueDetailCollapseBar { store.setResolvedExpanded(root.id, false) }
                Divider()
            }
            IssueDetailCommentView(
                store: store, entry: root, isRoot: true, runs: rootRuns, replyCount: thread.visibleReplies.count,
                collapsed: collapsed, isResolution: false, hasReplies: !thread.visibleReplies.isEmpty,
                highlighted: highlightedID == root.id, canModerate: canModerate)
            if !collapsed {
                if folded {
                    if !foldedReplies.isEmpty {
                        IssueDetailFoldBar(replies: foldedReplies) { store.setResolvedExpanded(root.id, true) }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .overlay(alignment: .top) { Divider() }
                    }
                } else if replyResolutionID != nil {
                    Divider()
                    IssueDetailCollapseBar { store.setResolvedExpanded(root.id, false) }
                }
                ForEach(rows) { row in
                    rowView(row, replyResolutionID: replyResolutionID, repliedTo: repliedTo)
                }
                if !folded {
                    Divider()
                    IssueDetailReplyBox(store: store, rootID: root.id)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    @ViewBuilder private func rowView(_ row: IssueDetailThreadRow, replyResolutionID: String?, repliedTo: Set<String>) -> some View {
        switch row {
        case .reply(let e):
            if !e.isDeletedComment {
                Divider().opacity(0.6)
                IssueDetailCommentView(
                    store: store, entry: e, isRoot: false, runs: thread.runs.filter { $0.commentID == e.id && $0.hasReply },
                    replyCount: 0, collapsed: false, isResolution: e.id == replyResolutionID, hasReplies: repliedTo.contains(e.id),
                    highlighted: highlightedID == e.id, canModerate: canModerate)
            }
        case .run(let run, let reply, let replyTo):
            if let reply, !reply.isDeletedComment, !run.isFailureNotice(reply) {
                Divider().opacity(0.6)
                IssueDetailCommentView(
                    store: store, entry: reply, isRoot: false, runs: [run], replyCount: 0, collapsed: false,
                    isResolution: reply.resolvedAt != nil, hasReplies: repliedTo.contains(reply.id),
                    highlighted: highlightedID == reply.id, canModerate: canModerate, replyTo: replyTo)
            } else {
                Divider().opacity(0.6)
                IssueDetailThreadRunSlot(store: store, run: run, replyTo: replyTo,
                                         replacesFailureNotice: reply.map(run.isFailureNotice) ?? false)
                    .background(reply.map { highlightedID == $0.id } == true ? Theme.brand.opacity(0.05) : .clear)
            }
        }
    }
}

private struct IssueDetailThreadRunSlot: View {
    let store: IssueDetailStore
    let run: IssueDetailRun
    let replyTo: TimelineEntry?
    let replacesFailureNotice: Bool
    @State private var expanded = false

    var body: some View {
        IssueDetailRunBlock(store: store, run: run, showIdentity: true, replyTo: replyTo, replacesFailureNotice: replacesFailureNotice,
                            onJump: { store.jump(to: $0) }, expanded: $expanded)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }
}

/// A comment: header (author, time, run, badges, actions), body or editor,
/// attachments, steer receipts, run output and reactions. Used for roots
/// (with the collapse chevron) and replies.
struct IssueDetailCommentView: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    @Environment(AppEnvironment.self) private var env
    let store: IssueDetailStore
    let entry: TimelineEntry
    let isRoot: Bool
    let runs: [IssueDetailRun]
    let replyCount: Int
    let collapsed: Bool
    let isResolution: Bool
    let hasReplies: Bool
    let highlighted: Bool
    let canModerate: Bool
    var replyTo: TimelineEntry? = nil

    @State private var editing = false
    @State private var confirmDelete = false
    @State private var runExpanded = false
    @State private var subIssueOpen = false

    private var isOwn: Bool { entry.actorType == "member" && entry.actorID == store.currentUserID }
    private var canEdit: Bool { entry.supplements.isEmpty && (isOwn || (canModerate && entry.actorType == "member")) }
    private var canDelete: Bool {
        !entry.supplements.contains { $0.status != "delivered" && $0.status != "failed" } && (isOwn || canModerate)
    }
    private var headerRun: IssueDetailRun? { runs.first(where: \.showsInHeader) }
    private var inlineRun: IssueDetailRun? { runs.first { !$0.showsInHeader } }
    private var noticeRun: IssueDetailRun? { runs.first { $0.isFailureNotice(entry) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isRoot && entry.isDeletedComment {
                EmptyView()
            } else if !collapsed {
                VStack(alignment: .leading, spacing: 6) {
                    if let replyTo { IssueDetailReplyToQuote(entry: replyTo) { store.jump(to: $0) } }
                    if editing {
                        IssueDetailCommentEditor(store: store, entry: entry) { editing = false }
                    } else if noticeRun == nil {
                        MarkdownView(source: entry.content ?? "")
                        IssueDetailAttachmentList(attachments: entry.attachments, content: entry.content ?? "")
                        IssueDetailSteerReceipts(store: store, entry: entry)
                        if entry.actorType == "agent" && entry.commentType == "system", let taskID = entry.sourceTaskID, !taskID.isEmpty {
                            IssueDetailRetryButton(store: store, taskID: taskID)
                        }
                    }
                    if let headerRun, runExpanded {
                        IssueDetailRunSteps(store: store, task: headerRun.task) { runExpanded = false }
                    }
                    if let inlineRun {
                        IssueDetailRunBlock(store: store, run: inlineRun, showIdentity: false,
                                            replacesFailureNotice: inlineRun.id == noticeRun?.id, expanded: $runExpanded)
                    }
                    if !editing {
                        IssueDetailReactionBar(groups: IssueDetailReactionGroup.group(entry.reactions.map { ($0.emoji, $0.actorType, $0.actorID) }, me: store.currentUserID)) { emoji in
                            Task { await store.toggleCommentReaction(entry.id, emoji, toaster: toaster) }
                        }
                    }
                }
                .padding(.leading, 48)
                .padding(.trailing, 16)
                .padding(.bottom, 12)
            }
        }
        .background(highlighted ? Theme.brand.opacity(0.06) : .clear)
        .animation(.easeOut(duration: 0.7), value: highlighted)
        .alert(tr("issues", "comment.delete_title"), isPresented: $confirmDelete) {
            Button(tr("issues", "comment.cancel_action"), role: .cancel) {}
            Button(tr("issues", "comment.delete_action"), role: .destructive) {
                Task { await store.deleteComment(entry.id, toaster: toaster) }
            }
        } message: {
            Text(tr("issues", hasReplies ? "comment.delete_desc_replies_kept" : "comment.delete_desc"))
        }
        .sheet(isPresented: $subIssueOpen) { IssueDetailCommentSubIssueSheet(store: store, anchorCommentID: entry.id) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if isRoot && entry.isDeletedComment {
                Text(tr("issues", "comment.deleted_placeholder")).italic().foregroundStyle(.secondary).lineLimit(1)
            } else {
                ActorAvatar(type: entry.actorType, id: entry.actorID, size: 26)
                Text(entry.actorName ?? session.actorInfo(type: entry.actorType, id: entry.actorID).name)
                    .font(Theme.Font.bodyMedium).lineLimit(1)
                RelativeTime(timestamp: entry.createdAt).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize()
                if !entry.supplements.isEmpty {
                    Text(tr("issues", "inline_run.steer_badge", ["names": steerNames]))
                        .font(Theme.Font.micro).foregroundStyle(Theme.brand)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.brand.opacity(0.08)))
                }
                if let headerRun { IssueDetailRunHeader(run: headerRun, expanded: $runExpanded) }
                if entry.actorType == "agent", let run = runs.first, run.task.wakeupId != nil {
                    Label(tr("issues", "wakeups.triggered_by_wakeup"), systemImage: "bell")
                        .font(Theme.Font.micro).foregroundStyle(.secondary)
                }
                if isResolution {
                    Text(tr("issues", "comment.resolve.resolution_badge")).font(Theme.Font.caption.weight(.medium)).foregroundStyle(Theme.success)
                }
            }
            if collapsed {
                Text((entry.content ?? "").replacingOccurrences(of: "\n", with: " ").prefix(80))
                    .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                if replyCount > 0 {
                    Text(tr("issues", "comment.reply_count", ["count": replyCount])).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize()
                }
            }
            Spacer(minLength: 4)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, collapsed ? 12 : 8)
    }

    private var steerNames: String {
        entry.supplements.compactMap { $0.agentId.map { session.actorInfo(type: "agent", id: $0).name } }.joined(separator: ", ")
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if isRoot {
                Button { store.toggleThreadCollapsed(entry.id) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(collapsed ? 0 : 90))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(tr("issues", collapsed ? "comment.expand_thread" : "comment.collapse_thread"))
            }
            if !(isRoot && (collapsed || entry.isDeletedComment)) {
                if !editing {
                    IssueDetailEmojiPicker { emoji in Task { await store.toggleCommentReaction(entry.id, emoji, toaster: toaster) } }
                }
                Menu {
                    if canEdit {
                        Button { editing = true } label: { Label(tr("issues", "comment.edit_action"), systemImage: "pencil") }
                    }
                    if isRoot {
                        Button {
                            Task { await store.setResolved(entry.id, entry.resolvedAt == nil, toaster: toaster) }
                        } label: {
                            entry.resolvedAt == nil
                                ? Label(tr("issues", "comment.resolve.resolve_thread_action"), systemImage: "checkmark.circle")
                                : Label(tr("issues", "comment.resolve.unresolve_thread_action"), systemImage: "arrow.uturn.backward")
                        }
                    } else if isResolution {
                        Button { Task { await store.setResolved(entry.id, false, toaster: toaster) } } label: {
                            Label(tr("issues", "comment.resolve.unresolve_action"), systemImage: "arrow.uturn.backward")
                        }
                    } else {
                        Button { Task { await store.setResolved(entry.id, true, toaster: toaster) } } label: {
                            Label(tr("issues", "comment.resolve.resolve_with_comment_action"), systemImage: "checkmark.circle")
                        }
                    }
                    Divider()
                    Button {
                        IssueDetailFiles.copy(entry.content ?? "")
                        toaster.success(tr("issues", "comment.copied_toast"))
                    } label: { Label(tr("issues", "comment.copy_action"), systemImage: "doc.on.doc") }
                    Button {
                        IssueDetailFiles.copy(store.shareURL(nav: nav, appURL: env.app.config.appURL, commentID: entry.id))
                        toaster.success(tr("issues", "comment.link_copied"))
                    } label: { Label(tr("issues", "comment.copy_link_action"), systemImage: "link") }
                    if entry.commentType == "comment" {
                        Button { subIssueOpen = true } label: { Label(tr("issues", "source_context.create_action"), systemImage: "text.badge.plus") }
                    }
                    if canDelete {
                        Divider()
                        Button(role: .destructive) { confirmDelete = true } label: { Label(tr("issues", "comment.delete_action"), systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("issues", "comment.more_actions"))
            }
        }
    }
}

/// Retry for the platform's failure comment (upstream TaskCommentRetryButton).
private struct IssueDetailRetryButton: View {
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    let taskID: String
    @State private var retrying = false

    var body: some View {
        Button {
            retrying = true
            Task {
                await store.rerun(taskID, toaster: toaster)
                retrying = false
            }
        } label: {
            HStack(spacing: 4) {
                if retrying { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.counterclockwise") }
                Text(tr("issues", "execution_log.retry_task_tooltip"))
            }
        }
        .controlSize(.small)
        .disabled(retrying)
        .help(tr("issues", "execution_log.retry_task_aria"))
    }
}

/// Where a message that steered a running turn stands (upstream
/// SteerReceipts): waiting, read, or not received with a resend.
private struct IssueDetailSteerReceipts: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    let entry: TimelineEntry

    var body: some View {
        if !entry.supplements.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(entry.supplements, id: \.taskId) { r in
                    let name = r.agentId.map { session.actorInfo(type: "agent", id: $0).name } ?? tr("issues", "agent_live.fallback_name")
                    HStack(spacing: 6) {
                        switch r.status {
                        case "delivered":
                            Label(tr("issues", "inline_run.steer_read", ["name": name]), systemImage: "checkmark").foregroundStyle(Theme.success)
                        case "failed":
                            Label(tr("issues", "inline_run.steer_not_received", ["name": name, "reason": reason(r.failureReason)]),
                                  systemImage: "exclamationmark.circle").foregroundStyle(Theme.warning)
                            Button(tr("issues", "inline_run.steer_resend")) {
                                Task {
                                    do {
                                        try await session.api.retryTaskSupplement(issueId: store.issueID, taskId: r.taskId, commentId: entry.id)
                                    } catch {
                                        toaster.error(tr("issues", "inline_run.steer_resend_failed"))
                                    }
                                }
                            }
                            .buttonStyle(.link)
                        default:
                            Label(tr("issues", "inline_run.steer_waiting", ["name": name]), systemImage: "clock").foregroundStyle(.secondary)
                        }
                    }
                    .font(Theme.Font.caption)
                }
            }
        }
    }

    private func reason(_ code: String?) -> String {
        let known: Set<String> = ["turn_ended", "turn_not_started", "provider_rejected", "timeout"]
        return tr("issues", "inline_run.supplement_failure_" + (known.contains(code ?? "") ? code! : "unknown"))
    }
}

/// Inline comment editor with upstream's conflict compare.
private struct IssueDetailCommentEditor: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    let entry: TimelineEntry
    let onDone: () -> Void
    @State private var text = ""
    @State private var base = ""
    @State private var saving = false
    @State private var conflict = false
    @State private var retained: Set<String> = []
    @State private var uploads = ComposerUploads()

    private var draftKey: String { "edit:\(store.issueID):\(entry.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownEditor(text: $text, placeholder: tr("issues", "comment.edit_placeholder"), minHeight: 60, maxHeight: 420,
                           autofocus: true, onSubmit: save, onEscape: cancel,
                           onFiles: { urls in
                               uploads.upload(urls, session: session, issueID: store.issueID, insert: { md in
                                   text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + md
                               }, onError: { toaster.error($0) })
                           },
                           mentions: { session.mentionCandidates($0, includeIssues: true) })
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
            if conflict {
                IssueDetailRevisionCompare(title: tr("issues", "revision.compare_comment"), server: currentServerContent, local: text,
                                           onUseServer: {
                                               text = currentServerContent
                                               base = currentServerContent
                                               conflict = false
                                           },
                                           onKeepLocal: save, saving: saving)
            }
            let standalone = entry.attachments.filter { retained.contains($0.id) }
            if !standalone.isEmpty {
                IssueDetailAttachmentList(attachments: standalone) { retained.remove($0) }
            }
            HStack(spacing: 8) {
                Button { pick() } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless)
                    .help(tr("ui", "attach_file"))
                Spacer()
                Button(tr("issues", "comment.cancel_edit"), action: cancel).disabled(saving)
                Button(action: save) {
                    HStack(spacing: 4) {
                        if saving { ProgressView().controlSize(.mini) }
                        Text(uploads.isUploading ? tr("editor", "upload.in_progress") : tr("issues", "comment.save_action"))
                    }
                }
                .disabled(saving || uploads.isUploading)
            }
            .controlSize(.small)
        }
        .onAppear {
            text = IssueDetailSessionState.drafts[draftKey] ?? entry.content ?? ""
            base = entry.content ?? ""
            let content = entry.content ?? ""
            retained = Set(entry.attachments.filter { !content.contains($0.id) && !(!$0.markdownUrl.isEmpty && content.contains($0.markdownUrl)) }.map(\.id))
        }
        .onChange(of: text) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { IssueDetailSessionState.drafts[draftKey] = nil }
            else { IssueDetailSessionState.drafts[draftKey] = text }
        }
    }

    private var currentServerContent: String {
        store.model.entries.first { $0.id == entry.id }?.content ?? entry.content ?? ""
    }

    private func pick() {
        let urls = IssueDetailFiles.pick()
        guard !urls.isEmpty else { return }
        uploads.upload(urls, session: session, issueID: store.issueID, insert: { md in
            text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + md
        }, onError: { toaster.error($0) })
    }

    private func cancel() {
        IssueDetailSessionState.drafts[draftKey] = nil
        onDone()
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !saving, !uploads.isUploading else { return }
        let all = entry.attachments.map(\.id) + uploads.attachmentIDs
        let active = Array(Set(all.filter { trimmed.contains($0) }).union(retained))
        if trimmed == (entry.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines) && Set(active) == Set(entry.attachments.map(\.id)) {
            cancel()
            return
        }
        saving = true
        Task {
            let result = await store.editComment(entry.id, content: trimmed, attachmentIDs: active, suppressAgentIDs: [], base: base, toaster: toaster)
            saving = false
            switch result {
            case .saved: cancel()
            case .conflict: conflict = true
            case .failed: break
            }
        }
    }
}
