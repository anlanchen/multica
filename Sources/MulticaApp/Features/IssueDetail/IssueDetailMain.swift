import AppKit
import MulticaCore
import SwiftUI

/// The scrolling content column. The timeline rows are direct children of
/// one `LazyVStack`, so a long issue materialises only the visible rows,
/// and each row is equatable on its own data.
struct IssueDetailMainColumn: View {
    static let topID = "issue-detail-top"
    let store: IssueDetailStore
    let find: IssueDetailFindState
    @Binding var runConfirm: IssueDetailRunGate?
    @State private var prefs = SettingsDevicePreferences.shared
    private var sticky: Bool { prefs.stickyCommentBar }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    IssueDetailTopContent(store: store, highlighted: find.currentID == Self.topID, runConfirm: $runConfirm)
                        .id(Self.topID)
                    if store.layout.items.isEmpty && store.model.isLoading {
                        IssueDetailTimelineSkeleton()
                    }
                    ForEach(store.layout.items) { item in
                        let activityID = Self.activityID(item)
                        IssueDetailTimelineRow(
                            store: store,
                            item: item,
                            activityExpanded: activityID.map(store.activityExpanded) ?? false,
                            showOlder: activityID.map(store.showOlderActivity.contains) ?? false,
                            isLastActivity: activityID != nil && activityID == store.layout.lastActivityGroupID,
                            collapsed: item.thread.map { store.collapsedThreads.contains($0.root.id) } ?? false,
                            resolvedExpanded: item.thread.map { store.expandedResolved.contains($0.root.id) } ?? false,
                            highlightedID: highlight(for: item),
                            canModerate: store.canModerate
                        )
                        .equatable()
                        .id(item.id)
                        .padding(.bottom, 12)
                    }
                    if !sticky {
                        IssueDetailComposer(store: store, parentID: nil, draftKey: "new:\(store.issueID)")
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: 896, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, sticky ? 16 : 32)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if sticky {
                    IssueDetailComposer(store: store, parentID: nil, draftKey: "new:\(store.issueID)", maxEditorHeight: 280)
                        .frame(maxWidth: 896)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 16)
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity)
                        .background(alignment: .top) {
                            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor).opacity(0), Color(nsColor: .windowBackgroundColor)],
                                           startPoint: .top, endPoint: .init(x: 0.5, y: 0.25))
                        }
                }
            }
            .onChange(of: store.scrollRequest?.token) {
                guard let id = store.scrollRequest?.id else { return }
                let row = id == Self.topID ? id : rowID(containing: id)
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(row, anchor: .top) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .searchPaletteFoldComments)) { note in
                guard note.userInfo?["issueID"] as? String == store.issueID else { return }
                let fold = note.userInfo?["fold"] as? Bool ?? true
                store.collapsedThreads = fold ? Set(store.layout.items.compactMap { $0.thread?.root.id }) : []
            }
        }
    }

    static func activityID(_ item: IssueDetailTimelineItem) -> String? {
        if case .activities(let id, _) = item { return id }
        return nil
    }

    private func rowID(containing commentID: String) -> String {
        let root = store.layout.replyToRoot[commentID] ?? commentID
        return store.layout.items.first { $0.thread?.root.id == root }?.id ?? root
    }

    private func highlight(for item: IssueDetailTimelineItem) -> String? {
        guard let id = store.highlightedID, let thread = item.thread else { return nil }
        if thread.root.id == id || store.layout.replyToRoot[id] == thread.root.id { return id }
        return nil
    }
}

private struct IssueDetailTimelineSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(Color.primary.opacity(0.07)).frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)).frame(width: 120, height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)).frame(height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)).frame(width: 300, height: 12)
                    }
                }
                .padding(12)
            }
        }
        .padding(.top, 8)
    }
}

/// Everything above the timeline: duplicate banner, title, parent link,
/// source context, description, reactions, sub-issues and the activity
/// header.
struct IssueDetailTopContent: View {
    let store: IssueDetailStore
    let highlighted: Bool
    @Binding var runConfirm: IssueDetailRunGate?

    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster

    var body: some View {
        if let issue = store.issue {
            VStack(alignment: .leading, spacing: 0) {
                IssueDetailDuplicateBanner(store: store)
                IssueDetailTitle(store: store, issue: issue)
                    .background(highlighted ? Theme.warning.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                if store.record?.sourceContext == nil, let parent = store.parentIssue {
                    IssueDetailParentLink(parent: parent, siblings: store.parentChildren).padding(.top, 8)
                }
                if let context = store.record?.sourceContext {
                    IssueDetailSourceContextBadge(store: store, context: context).padding(.top, 8)
                }
                IssueDetailDescription(store: store, issue: issue).padding(.top, 20)
                IssueDetailSubIssues(store: store, parent: issue, runConfirm: $runConfirm)
                Divider().padding(.vertical, 32)
                IssueDetailActivityHeader(store: store)
                    .padding(.bottom, 16)
                IssueDetailLocalDirectoryHint(projectID: issue.projectID)
            }
        }
    }
}

/// Upstream IssueDuplicateBanner: "Duplicate of X" with "Not a duplicate".
struct IssueDetailDuplicateBanner: View {
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore

    var body: some View {
        if let dup = store.record?.duplicateOf {
            HStack(spacing: 8) {
                Image(systemName: "equal.circle").foregroundStyle(.secondary)
                Text(tr("issues", "duplicates.banner_prefix")).foregroundStyle(.secondary)
                Button { nav.push(.issue(dup.id), title: dup.identifier) } label: {
                    HStack(spacing: 4) {
                        Text(dup.identifier).font(Theme.Font.bodyMedium)
                        Text(dup.title).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button(tr("issues", "duplicates.unmark")) {
                    Task {
                        _ = await store.update(["status": "todo"], optimistic: { $0.status = .todo }, toaster: toaster,
                                               success: tr("issues", "duplicates.unmark_toast"))
                        await store.loadDuplicates()
                    }
                }
                .controlSize(.small)
            }
            .font(Theme.Font.body)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
            .padding(.bottom, 16)
        }
    }
}

/// Inline title editor with upstream's revision-conflict compare.
struct IssueDetailTitle: View {
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    let issue: Issue
    @State private var editing = false
    @State private var draft = ""
    @State private var base: String?
    @State private var conflictDraft: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editing {
                TextField(tr("issues", "detail.title_placeholder"), text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .bold))
                    .focused($focused)
                    .onSubmit(commit)
                    .onKeyPress(.escape) {
                        editing = false
                        return .handled
                    }
                    .onChange(of: focused) { if !focused && editing { commit() } }
            } else {
                Text(issue.title.isEmpty ? tr("issues", "detail.title_placeholder") : issue.title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(issue.title.isEmpty ? .tertiary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .textSelection(.enabled)
                    .onTapGesture {
                        draft = conflictDraft ?? issue.title
                        base = issue.title
                        editing = true
                        focused = true
                    }
            }
            if let conflictDraft {
                IssueDetailRevisionCompare(
                    title: tr("issues", "revision.compare_title"), server: issue.title, local: conflictDraft,
                    onUseServer: {
                        self.conflictDraft = nil
                        base = issue.title
                    },
                    onKeepLocal: {
                        let text = conflictDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        Task {
                            if await store.saveTitle(text, base: issue.title, toaster: toaster) { self.conflictDraft = nil }
                        }
                    })
            }
        }
    }

    private func commit() {
        editing = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != issue.title else { return }
        Task {
            let ok = await store.saveTitle(trimmed, base: base, toaster: toaster)
            conflictDraft = ok ? nil : trimmed
        }
    }
}

/// "Sub-issue of <parent>" with the parent's progress (upstream).
struct IssueDetailParentLink: View {
    @Environment(Navigator.self) private var nav
    @Environment(WorkspaceSession.self) private var session
    let parent: Issue
    let siblings: [Issue]

    var body: some View {
        Button { nav.push(.issue(parent.id), title: parent.identifier) } label: {
            HStack(spacing: 6) {
                Text(tr("issues", "detail.sub_issue_of")).font(Theme.Font.caption.weight(.medium))
                session.issues.catalog.icon(for: parent.status)
                Text(parent.identifier).monospacedDigit()
                Text(parent.title).lineLimit(1)
                if !siblings.isEmpty {
                    let done = siblings.filter { $0.category(in: session.issues.catalog) == .done }.count
                    IssueDetailProgressChip(done: done, total: siblings.count)
                }
            }
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

/// Description: rendered Markdown that turns into the Markdown editor on
/// double-click or the edit button, autosaving after 1.5 s idle and when
/// editing ends (upstream ContentEditor debounceMs=1500 + flush on unmount).
struct IssueDetailDescription: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    let issue: Issue
    @State private var editing = false
    @State private var text = ""
    @State private var base = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var uploads = ComposerUploads()
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                if editing {
                    VStack(alignment: .leading, spacing: 6) {
                        MarkdownEditor(text: $text, placeholder: tr("issues", "detail.desc_placeholder"), minHeight: 80, maxHeight: 2000,
                                       fontSize: 14, autofocus: true,
                                       onSubmit: finish, onEscape: finish,
                                       onFiles: { upload($0) },
                                       mentions: { session.mentionCandidates($0, includeIssues: true) })
                        HStack {
                            if uploads.isUploading {
                                ProgressView().controlSize(.mini)
                                Text(tr("editor", "upload.in_progress")).font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(tr("common", "save"), action: finish).controlSize(.small).keyboardShortcut(.return, modifiers: .command)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.02)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.brand.opacity(0.35)))
                    .onChange(of: text) { scheduleSave() }
                } else if let source = issue.description ?? store.record?.description, !source.isEmpty {
                    MarkdownView(source: source, font: .system(size: 14))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: beginEditing)
                        .contextMenu {
                            Button(tr("issues", "comment.edit_action"), action: beginEditing)
                            Button(tr("issues", "reply.annotations.add_comment")) { store.quote(source, into: "new:\(store.issueID)") }
                        }
                    if hovering {
                        Button(action: beginEditing) { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .help(tr("issues", "comment.edit_action"))
                    }
                } else {
                    Text(tr("issues", "detail.desc_placeholder"))
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: beginEditing)
                }
            }
            .onHover { hovering = $0 }
            HStack(spacing: 6) {
                IssueDetailReactionBar(groups: issueReactionGroups, showPicker: true) { emoji in
                    Task { await store.toggleIssueReaction(emoji, toaster: toaster) }
                }
                Button {
                    let urls = IssueDetailFiles.pick()
                    guard !urls.isEmpty else { return }
                    if !editing { beginEditing() }
                    upload(urls)
                } label: { Image(systemName: "paperclip") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(tr("ui", "attach_file"))
            }
        }
        .onDisappear { flush() }
        .onChange(of: store.issueID) { flush() }
    }

    private var issueReactionGroups: [IssueDetailReactionGroup] {
        IssueDetailReactionGroup.group((store.record?.reactions ?? []).map { ($0.emoji, $0.actorType, $0.actorId) }, me: store.currentUserID)
    }

    private func beginEditing() {
        text = issue.description ?? store.record?.description ?? ""
        base = text
        editing = true
    }

    private func finish() {
        flush()
        editing = false
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        if editing { save() }
    }

    private func save() {
        let markdown = text
        guard markdown != base else { return }
        let ids = uploads.attachmentIDs.filter { markdown.contains($0) }
        let previousBase = base
        base = markdown
        Task {
            await store.saveDescription(markdown, base: previousBase, attachmentIDs: ids, toaster: toaster)
            if !ids.isEmpty { uploads.reset() }
        }
    }

    private func upload(_ urls: [URL]) {
        uploads.upload(urls, session: session, insert: { md in
            text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + md + "\n"
        }, onError: { toaster.error($0) })
    }
}

/// Upstream activity header: title, delegated-subscription badge, the
/// subscribe control and the subscriber picker.
struct IssueDetailActivityHeader: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    @State private var pickerOpen = false

    var body: some View {
        HStack(spacing: 8) {
            Text(tr("issues", "detail.activity_section")).font(Theme.Font.title)
            Spacer()
            if store.isSubscribed && store.subscriptionReason == "delegated" {
                Text(tr("issues", "detail.delegated_subscription_badge"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .help(tr("issues", "detail.delegated_subscription_hint"))
            }
            subscribeControl
            Button { pickerOpen.toggle() } label: {
                if let subs = store.subscribers, !subs.isEmpty {
                    IssueDetailAvatarStack(actors: subs.map { ActorRef(type: $0.userType, id: $0.userId) }, max: 4, size: 22)
                } else {
                    Image(systemName: "person.2")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2])).foregroundStyle(.tertiary))
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $pickerOpen, arrowEdge: .bottom) { IssueDetailSubscriberPicker(store: store) }
        }
    }

    @ViewBuilder private var subscribeControl: some View {
        if store.subscribers != nil {
            let childrenKnown = store.children != nil
            if !store.isSubscribed || (childrenKnown && store.children?.isEmpty == true) {
                Button(tr("issues", store.isSubscribed ? "detail.unsubscribe" : "detail.subscribe")) {
                    Task { await store.toggleSubscriber(userID: store.currentUserID, type: "member", subscribed: store.isSubscribed, toaster: toaster) }
                }
                .buttonStyle(.plain)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .disabled(store.subscriptionPending)
            } else {
                Menu(tr("issues", "detail.unsubscribe")) {
                    Button(tr("issues", "detail.unsubscribe_this")) {
                        Task { await store.toggleSubscriber(userID: store.currentUserID, type: "member", subscribed: true, toaster: toaster) }
                    }
                    Button(tr("issues", "detail.unsubscribe_subtree")) { Task { await store.unsubscribeSubtree(toaster: toaster) } }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .disabled(store.subscriptionPending)
            }
        }
    }
}

/// Upstream LocalDirectoryHint: where this machine's daemon will run the
/// project's agents (in place or in a worktree).
struct IssueDetailLocalDirectoryHint: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    let projectID: String?
    @State private var resources: [ProjectResource] = []

    var body: some View {
        let daemonID = env.daemonStatus.health?.daemonID
        let matches = resources.filter { $0.resourceType == "local_directory" && daemonID != nil && $0.resourceRef["daemon_id"]?.stringValue == daemonID }
        Group {
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(matches) { r in
                        let ref = r.resourceRef
                        let path = ref["local_path"]?.stringValue ?? ""
                        let worktree = ref["execution_mode"]?.stringValue == "worktree"
                        let label = [r.label, ref["label"]?.stringValue, path].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? path
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: worktree ? "arrow.triangle.branch" : "folder").font(.system(size: 10))
                                Text(tr("projects", worktree ? "resources.chat_hint_worktree_prefix" : "resources.chat_hint_prefix"))
                                    + Text(" \(label) ").foregroundColor(.primary).fontWeight(.medium)
                                    + Text("(\(path))").font(Theme.Font.mono)
                            }
                            .lineLimit(1)
                            if worktree {
                                Text(tr("projects", "resources.chat_hint_worktree_note")).padding(.leading, 16)
                            }
                        }
                    }
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(Theme.border))
                .padding(.bottom, 12)
            }
        }
        .task(id: projectID) {
            guard let projectID else {
                resources = []
                return
            }
            resources = (try? await session.api.listProjectResources(projectId: projectID).resources) ?? []
        }
    }
}

/// Upstream SubscriberPopoverContent: search, members and agents with a
/// checkbox each; disabled until the subscriber list is known.
struct IssueDetailSubscriberPicker: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let members = session.directory.members.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        let agents = session.directory.agents.filter { $0.archivedAt == nil && (q.isEmpty || $0.name.lowercased().contains(q)) }
        let disabled = store.subscribers == nil || store.subscriptionPending
        VStack(alignment: .leading, spacing: 0) {
            TextField(tr("issues", "detail.change_subscribers_placeholder"), text: $query)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .focused($focused)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if members.isEmpty && agents.isEmpty {
                        Text(tr("issues", "detail.no_subscribers_results")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(10)
                    }
                    if !members.isEmpty { group(tr("issues", "detail.members_group")) }
                    ForEach(members) { m in row(type: "member", id: m.userID, name: m.name, disabled: disabled) }
                    if !agents.isEmpty { group(tr("issues", "detail.agents_group")) }
                    ForEach(agents) { a in row(type: "agent", id: a.id, name: a.name, disabled: disabled) }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 256)
        .onAppear { focused = true }
    }

    private func group(_ title: String) -> some View {
        Text(title).font(Theme.Font.micro).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
    }

    private func row(type: String, id: String, name: String, disabled: Bool) -> some View {
        let subscribed = store.subscribers?.contains { $0.userType == type && $0.userId == id } ?? false
        return Button {
            Task { await store.toggleSubscriber(userID: id, type: type, subscribed: subscribed, toaster: toaster) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: subscribed ? "checkmark.square.fill" : "square").foregroundStyle(subscribed ? Theme.brand : .secondary)
                ActorAvatar(type: type, id: id, size: 20)
                Text(name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Theme.Font.body)
        }
        .buttonStyle(HoverRowButtonStyle())
        .padding(.horizontal, 4)
        .disabled(disabled)
    }
}
