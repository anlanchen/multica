import AppKit
import MulticaCore
import Observation
import SwiftUI

/// Per-session view state that outlives a page (upstream's in-memory
/// zustand stores: resolved-thread expansion, thread collapse, sub-issue
/// collapse, composer drafts).
@MainActor
enum IssueDetailSessionState {
    static var expandedResolved: [String: Set<String>] = [:]
    static var collapsedThreads: [String: Set<String>] = [:]
    static var collapsedSubIssues: Set<String> = []
    static var drafts: [String: String] = [:]
}

/// Everything the issue detail page shows beyond the shared detail model:
/// the full issue record, runs with their full shape, subscribers,
/// sub-issues, pull requests and wakeups. Created and closed by the page;
/// realtime keeps it current through the detail model and resource
/// revisions.
@MainActor
@Observable
final class IssueDetailStore {
    let session: WorkspaceSession
    let issueID: String
    let model: IssueDetailModel

    private(set) var record: IssueRecord?
    private(set) var tasks: [AgentTaskRecord] = []
    private(set) var tasksLoaded = false
    private(set) var layout = IssueDetailTimelineLayout()
    /// Files the comments delivered, newest first.
    private(set) var deliverables: [IssueDetailDeliverable] = []
    /// nil until the subscriber list is known (upstream gates every
    /// subscription control on it).
    private(set) var subscribers: [IssueSubscriber]?
    private(set) var children: [Issue]?
    /// Full records of the children (stage, custom properties).
    private(set) var childRecords: [String: IssueRecord] = [:]
    private(set) var parentChildren: [Issue] = []
    private(set) var parentChildStages: [Int] = []
    private(set) var childProgress: [String: ChildProgress] = [:]
    private(set) var attachments: [Attachment] = []
    private(set) var duplicates: IssueDuplicates?
    private(set) var pullRequests: IssuePullRequestsResponse?
    private(set) var prSidebarEnabled = true
    private(set) var wakeups: [IssueWakeup]?
    private(set) var wakeupsFailed = false
    private(set) var systemWakeups: [SystemWakeup] = []
    private(set) var notFound = false
    private(set) var subscriptionPending = false

    var expandedResolved: Set<String> {
        didSet { IssueDetailSessionState.expandedResolved[issueID] = expandedResolved }
    }
    var collapsedThreads: Set<String> {
        didSet { IssueDetailSessionState.collapsedThreads[issueID] = collapsedThreads }
    }
    var subIssuesCollapsed: Bool {
        didSet {
            if subIssuesCollapsed { IssueDetailSessionState.collapsedSubIssues.insert(issueID) }
            else { IssueDetailSessionState.collapsedSubIssues.remove(issueID) }
        }
    }
    var expandedActivity: Set<String> = []
    var collapsedActivity: Set<String> = []
    var showOlderActivity: Set<String> = []
    var highlightedID: String?
    /// Row the timeline should scroll to (consumed by the scroll reader).
    var scrollRequest: (id: String, token: Int)?
    var selectedChildren: Set<String> = []
    /// Bumped when a draft is changed from outside its composer.
    var draftBumps: [String: Int] = [:]

    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var taskRefetch: Task<Void, Never>?
    @ObservationIgnored private var recordRefetch: Task<Void, Never>?
    @ObservationIgnored private var layoutPending = false
    @ObservationIgnored private var highlightClear: Task<Void, Never>?
    @ObservationIgnored private var scrollToken = 0

    init(session: WorkspaceSession, issueID: String) {
        self.session = session
        self.issueID = issueID
        model = session.openIssue(issueID)
        isOpen = true
        expandedResolved = IssueDetailSessionState.expandedResolved[issueID] ?? []
        collapsedThreads = IssueDetailSessionState.collapsedThreads[issueID] ?? []
        subIssuesCollapsed = IssueDetailSessionState.collapsedSubIssues.contains(issueID)
        trackTimeline()
        rebuildLayout()
    }

    /// The issue disappeared from the shared store (deleted elsewhere).
    func markDeleted() {
        notFound = true
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        taskRefetch?.cancel()
        recordRefetch?.cancel()
        session.closeIssue(issueID)
    }

    func reopenIfNeeded() {
        guard !isOpen else { return }
        isOpen = true
        _ = session.openIssue(issueID)
        trackTimeline()
        rebuildLayout()
    }

    var issueModel: IssueModel? { model.issue ?? session.issues.model(issueID) }
    var issue: Issue? { issueModel?.issue }

    /// The parent, once loaded into the shared store (reads the observed
    /// sibling list so views refresh when the parent arrives).
    var parentIssue: Issue? {
        _ = parentChildren
        return issue?.parentIssueID.flatMap { session.issues.model($0)?.issue }
    }

    var currentUserID: String { session.currentUser.id }

    /// Owners and admins moderate any comment (backend comment.go).
    var canModerate: Bool {
        guard let role = session.directory.member(userID: currentUserID)?.role else { return false }
        return role == "owner" || role == "admin"
    }

    // MARK: Loading

    func loadAll() async {
        async let record: Void = loadRecord()
        async let tasks: Void = loadTasks()
        async let subs: Void = loadSubscribers()
        async let attachments: Void = loadAttachments()
        async let duplicates: Void = loadDuplicates()
        async let workspace: Void = loadWorkspaceSettings()
        _ = await (record, tasks, subs, attachments, duplicates, workspace)
        await loadChildren()
        await session.properties.loadIfNeeded()
    }

    func loadRecord() async {
        do {
            let fetched = try await session.api.issueDetailFetch(issueID)
            session.issues.upsert(fetched.issue)
            record = fetched.record
            notFound = false
            await loadParentChildren()
        } catch let e as APIError where e.status == 404 {
            notFound = true
        } catch {}
    }

    /// The shared row model moved past the record (an `issue:updated` from
    /// someone else): refetch the full shape for the fields the row drops.
    func issueRevisionChanged() {
        guard let live = issue?.revision, let have = record?.revision, live > have else { return }
        recordRefetch?.cancel()
        recordRefetch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            let parentBefore = self.record?.parentIssueId
            await self.loadRecord()
            if self.record?.parentIssueId != parentBefore { await self.loadParentChildren() }
        }
    }

    func loadTasks() async {
        guard let list = try? await session.api.issueDetailListTasks(issueId: issueID) else { return }
        tasks = list
        tasksLoaded = true
        rebuildLayout()
    }

    func loadSubscribers() async {
        guard let list = try? await session.api.listIssueSubscribers(issueId: issueID) else { return }
        subscribers = list
    }

    func loadAttachments() async {
        attachments = (try? await session.api.listAttachments(issueId: issueID)) ?? attachments
    }

    func loadDuplicates() async {
        duplicates = try? await session.api.listIssueDuplicates(issueID)
    }

    func loadChildren() async {
        guard let fetched = try? await session.api.issueDetailListChildren(issueID) else { return }
        let list = fetched.map(\.issue)
        for c in list { session.issues.upsert(c) }
        childRecords = Dictionary(fetched.map { ($0.record.id, $0.record) }, uniquingKeysWith: { a, _ in a })
        children = list.sorted { $0.position == $1.position ? $0.number < $1.number : $0.position < $1.position }
        if !list.isEmpty, let progress = try? await session.api.getChildIssueProgress() {
            var map: [String: ChildProgress] = [:]
            for p in progress { map[p.parentIssueId] = p }
            childProgress = map
        }
    }

    func loadParentChildren() async {
        guard let parent = record?.parentIssueId ?? issue?.parentIssueID else {
            parentChildren = []
            parentChildStages = []
            return
        }
        if session.issues.model(parent) == nil, let p = try? await session.api.issueDetailFetch(parent) {
            session.issues.upsert(p.issue)
        }
        guard let fetched = try? await session.api.issueDetailListChildren(parent) else { return }
        parentChildren = fetched.map(\.issue)
        parentChildStages = fetched.compactMap(\.record.stage)
    }

    func loadPullRequests() async {
        pullRequests = try? await session.api.listIssuePullRequests(issueId: issueID)
    }

    func loadWorkspaceSettings() async {
        guard let ws = try? await session.api.getWorkspace(session.workspace.id) else { return }
        let enabled = ws.settings["github_enabled"]?.boolValue != false
        prSidebarEnabled = enabled && ws.settings["github_pr_sidebar_enabled"]?.boolValue != false
    }

    func loadWakeups() async {
        do {
            wakeups = try await session.api.listIssueWakeups(issueId: issueID)
            wakeupsFailed = false
        } catch {
            wakeupsFailed = wakeups == nil
        }
        systemWakeups = (try? await session.api.listIssueSystemWakeups(issueId: issueID)) ?? systemWakeups
    }

    // MARK: Timeline

    private func trackTimeline() {
        withObservationTracking {
            _ = model.entries
            _ = model.runs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isOpen else { return }
                self.mergeLiveRuns()
                self.rebuildLayout()
                self.trackTimeline()
            }
        }
    }

    /// Lifecycle events land on the shared model first; mirror their status
    /// onto the full task records, then refetch the full shape once.
    private func mergeLiveRuns() {
        var changed = false
        for run in model.runs {
            if let i = tasks.firstIndex(where: { $0.id == run.id }) {
                if tasks[i].status != run.status.rawValue {
                    tasks[i].status = run.status.rawValue
                    if let r = run.failureReason { tasks[i].failureReason = r }
                    changed = true
                }
            } else {
                tasks.append(AgentTaskRecord(id: run.id, agentId: run.agentID, runtimeId: run.runtimeID, issueId: run.issueID,
                                             status: run.status.rawValue, createdAt: run.createdAt))
                changed = true
            }
        }
        guard changed else { return }
        taskRefetch?.cancel()
        taskRefetch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            await self.loadTasks()
        }
    }

    func rebuildLayout() {
        guard !layoutPending else { return }
        layoutPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.layoutPending = false
            let next = IssueDetailTimelineLayout.build(entries: self.model.entries, tasks: self.tasks)
            guard next != self.layout else { return }
            self.layout = next
            var files: [IssueDetailDeliverable] = []
            for item in next.items {
                guard let thread = item.thread else { continue }
                for e in [thread.root] + thread.replies where !e.isDeletedComment {
                    for a in e.attachments { files.append(IssueDetailDeliverable(attachment: a, commentID: e.id)) }
                }
            }
            files.sort { $0.attachment.createdAt > $1.attachment.createdAt }
            if files != self.deliverables { self.deliverables = files }
        }
    }

    var activeTasks: [AgentTaskRecord] {
        tasks.filter { IssueDetailRun.activeStatuses.contains($0.status) }
            .sorted { a, b in
                if (a.status == "running") != (b.status == "running") { return a.status == "running" }
                return a.createdAt < b.createdAt
            }
    }

    func task(_ id: String) -> AgentTaskRecord? { tasks.first { $0.id == id } }

    func activityExpanded(_ id: String) -> Bool {
        if expandedActivity.contains(id) { return true }
        if collapsedActivity.contains(id) { return false }
        return id == layout.lastActivityGroupID
    }

    func toggleActivity(_ id: String) {
        if activityExpanded(id) {
            collapsedActivity.insert(id)
            expandedActivity.remove(id)
        } else {
            expandedActivity.insert(id)
            collapsedActivity.remove(id)
        }
    }

    func setResolvedExpanded(_ rootID: String, _ expanded: Bool) {
        if expanded { expandedResolved.insert(rootID) } else { expandedResolved.remove(rootID) }
    }

    func toggleThreadCollapsed(_ rootID: String) {
        if collapsedThreads.contains(rootID) { collapsedThreads.remove(rootID) } else { collapsedThreads.insert(rootID) }
    }

    /// Scrolls to a comment (a reply opens its thread first) and flashes it.
    func jump(to commentID: String) {
        let root = layout.replyToRoot[commentID] ?? commentID
        collapsedThreads.remove(root)
        if let thread = layout.items.first(where: { $0.thread?.root.id == root })?.thread {
            switch thread.resolution {
            case .root: expandedResolved.insert(root)
            case .reply(let id) where id != commentID && commentID != root: expandedResolved.insert(root)
            default: break
            }
        }
        scrollToken += 1
        scrollRequest = (commentID, scrollToken)
        flash(commentID)
    }

    func flash(_ id: String) {
        highlightedID = id
        highlightClear?.cancel()
        highlightClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.highlightedID = nil
        }
    }

    // MARK: Issue mutations

    /// Optimistic issue update through an explicit body (fields may be JSON
    /// null to clear). The shared row adopts the server answer.
    func update(_ fields: [String: JSONValue], optimistic: ((inout Issue) -> Void)? = nil, toaster: Toaster? = nil,
                success: String? = nil) async -> Bool {
        let previous = optimistic.flatMap { change in session.issues.patch(issueID) { var i = $0; change(&i); return i } }
        do {
            let fetched = try await session.api.issueDetailUpdate(issueID, fields: fields)
            session.issues.upsert(fetched.issue)
            record = fetched.record
            if fields.keys.contains("parent_issue_id") { await loadParentChildren() }
            if let success { toaster?.success(success) }
            return true
        } catch {
            if let previous { session.issues.restore(previous) }
            toaster?.error((error as? APIError)?.message ?? tr("issues", "detail.update_failed"))
            return false
        }
    }

    func updateStatus(_ key: IssueStatusKey, toaster: Toaster) async {
        _ = await update(["status": JSONValue(key.rawValue)], optimistic: { i in
            i.status = key
            i.statusCategory = key.builtInCategory ?? self.session.issues.catalog.entry(for: key)?.category
        }, toaster: toaster)
    }

    func updatePriority(_ p: IssuePriority, toaster: Toaster) async {
        _ = await update(["priority": JSONValue(p.rawValue)], optimistic: { $0.priority = p }, toaster: toaster)
    }

    func updateAssignee(_ ref: ActorRef?, toaster: Toaster) async {
        _ = await update(["assignee_type": JSONValue(ref?.type), "assignee_id": JSONValue(ref?.id)],
                         optimistic: { $0.assignee = ref }, toaster: toaster)
    }

    func updateDate(_ field: String, _ value: String?, toaster: Toaster) async {
        _ = await update([field: JSONValue(value)], optimistic: { i in
            if field == "start_date" { i.startDate = value } else { i.dueDate = value }
        }, toaster: toaster)
    }

    func updateProject(_ id: String?, toaster: Toaster) async {
        _ = await update(["project_id": JSONValue(id)], optimistic: { $0.projectID = id }, toaster: toaster)
    }

    func updateStage(_ stage: Int?, toaster: Toaster) async {
        _ = await update(["stage": JSONValue(stage)], toaster: toaster)
    }

    func removeParent(toaster: Toaster) async {
        _ = await update(["parent_issue_id": .null, "stage": .null], optimistic: { $0.parentIssueID = nil },
                         toaster: toaster, success: tr("issues", "actions.remove_parent_issue_success"))
    }

    func toggleLabel(_ label: IssueLabel, on: Bool, toaster: Toaster) async {
        do {
            let res = on
                ? try await session.api.attachLabel(issueId: issueID, labelId: label.id)
                : try await session.api.detachLabel(issueId: issueID, labelId: label.id)
            session.issues.setLabels(issueID, res.labels)
        } catch {
            toaster.error(error)
        }
    }

    func setProperty(_ propertyID: String, _ value: JSONValue?, toaster: Toaster) async {
        do {
            let res: IssuePropertiesResponse
            if let value {
                res = try await session.api.setIssueProperty(issueId: issueID, propertyId: propertyID, value: value)
            } else {
                res = try await session.api.unsetIssueProperty(issueId: issueID, propertyId: propertyID)
            }
            record?.properties = res.properties
            if let rev = res.issueRevision { record?.revision = rev }
        } catch {
            toaster.error(error)
        }
    }

    /// Title save with conflict detection; returns false on a revision
    /// conflict so the page can show both versions.
    func saveTitle(_ title: String, base: String?, toaster: Toaster) async -> Bool {
        var fields: [String: JSONValue] = ["title": JSONValue(title)]
        if let base { fields["title_base"] = JSONValue(base) }
        let previous = session.issues.patch(issueID) { var i = $0; i.title = title; return i }
        do {
            let fetched = try await session.api.issueDetailUpdate(issueID, fields: fields)
            session.issues.upsert(fetched.issue)
            record = fetched.record
            return true
        } catch let e as APIError where e.status == 409 {
            if let previous { session.issues.restore(previous) }
            await loadRecord()
            return false
        } catch {
            if let previous { session.issues.restore(previous) }
            toaster.error(error)
            return true
        }
    }

    func saveDescription(_ markdown: String, base: String, attachmentIDs: [String], toaster: Toaster) async {
        var fields: [String: JSONValue] = ["description": JSONValue(markdown), "description_base": JSONValue(base)]
        if !attachmentIDs.isEmpty { fields["attachment_ids"] = JSONValue(attachmentIDs) }
        _ = await update(fields, optimistic: { $0.description = markdown }, toaster: toaster)
        if !attachmentIDs.isEmpty { await loadAttachments() }
    }

    // MARK: Reactions

    func toggleIssueReaction(_ emoji: String, toaster: Toaster) async {
        let me = currentUserID
        let existing = record?.reactions?.first { $0.emoji == emoji && $0.actorType == "member" && $0.actorId == me }
        do {
            if existing != nil {
                record?.reactions?.removeAll { $0.id == existing?.id }
                try await session.api.removeIssueReaction(issueId: issueID, emoji: emoji)
            } else {
                let r = try await session.api.addIssueReaction(issueId: issueID, emoji: emoji)
                if record?.reactions == nil { record?.reactions = [] }
                if record?.reactions?.contains(where: { $0.id == r.id }) == false { record?.reactions?.append(r) }
            }
        } catch {
            toaster.error(error)
            await loadRecord()
        }
    }

    func toggleCommentReaction(_ commentID: String, _ emoji: String, toaster: Toaster) async {
        let me = currentUserID
        guard let entry = model.entries.first(where: { $0.id == commentID }) else { return }
        let existing = entry.reactions.first { $0.emoji == emoji && $0.actorType == "member" && $0.actorID == me }
        let before = model.issueDetailPatch(commentID) { row in
            if let existing {
                row.reactions.removeAll { $0.id == existing.id }
            } else if let optimistic = IssueDetailReactionFactory.optimistic(commentID: commentID, emoji: emoji, actorID: me) {
                row.reactions.append(optimistic)
            }
        }
        do {
            if existing != nil {
                try await session.api.removeReaction(commentId: commentID, emoji: emoji)
            } else {
                let r = try await session.api.addReaction(commentId: commentID, emoji: emoji)
                model.issueDetailPatch(commentID) { row in
                    row.reactions.removeAll { $0.id.hasPrefix("optimistic-") && $0.emoji == emoji }
                    if !row.reactions.contains(where: { $0.id == r.id }) { row.reactions.append(r) }
                }
            }
        } catch {
            if let before { model.issueDetailRestore(before) }
            toaster.error(error)
        }
    }

    // MARK: Comments

    /// Upstream submitComment/submitReply: the composer keeps its text until
    /// this returns the new id, and a failure toasts and keeps the draft.
    func postComment(_ content: String, parentID: String?, attachmentIDs: [String], suppressAgentIDs: [String],
                     steerTaskIDs: [String], toaster: Toaster) async -> String? {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            let posted = try await session.api.issueDetailCreateComment(
                issueId: issueID, content: content, parentId: parentID, attachmentIds: attachmentIDs,
                suppressAgentIds: suppressAgentIDs, steerTaskIds: steerTaskIDs)
            model.issueDetailApply(posted.comment)
            if let warning = posted.warning { toaster.show(warning) }
            return posted.comment.id
        } catch {
            toaster.error((error as? APIError)?.message ?? tr("issues", parentID == nil ? "comment.send_failed" : "comment.send_reply_failed"))
            return nil
        }
    }

    enum EditResult { case saved, conflict, failed }

    func editComment(_ id: String, content: String, attachmentIDs: [String], suppressAgentIDs: [String],
                     base: String?, toaster: Toaster) async -> EditResult {
        do {
            let posted = try await session.api.issueDetailUpdateComment(
                id, content: content, attachmentIds: attachmentIDs, suppressAgentIds: suppressAgentIDs, contentBase: base)
            model.issueDetailApply(posted.comment)
            if let warning = posted.warning { toaster.show(warning) }
            return .saved
        } catch let e as APIError where e.status == 409 {
            toaster.error(tr("issues", "revision.conflict"))
            await session.reload(model)
            return .conflict
        } catch {
            toaster.error((error as? APIError)?.message ?? tr("issues", "comment.update_failed"))
            return .failed
        }
    }

    func deleteComment(_ id: String, toaster: Toaster) async {
        do {
            try await session.api.deleteComment(id)
            if model.entries.contains(where: { $0.parentID == id }) {
                await session.reload(model)
            } else {
                model.issueDetailRemoveSubtree(id)
            }
        } catch {
            toaster.error((error as? APIError)?.message ?? tr("issues", "comment.delete_failed"))
        }
    }

    func setResolved(_ commentID: String, _ resolved: Bool, toaster: Toaster) async {
        let root = layout.replyToRoot[commentID] ?? commentID
        expandedResolved.remove(root)
        do {
            let c = resolved ? try await session.api.resolveComment(commentID) : try await session.api.unresolveComment(commentID)
            model.issueDetailApply(c)
        } catch {
            toaster.error((error as? APIError)?.message ?? tr("issues", resolved ? "comment.resolve.resolve_failed" : "comment.resolve.unresolve_failed"))
        }
    }

    // MARK: Runs

    func cancelTask(_ taskID: String, toaster: Toaster, failureKey: String = "execution_log.cancel_failed") async {
        do {
            _ = try await session.api.cancelTask(issueID: issueID, taskID: taskID)
        } catch {
            toaster.error((error as? APIError)?.message ?? tr("issues", failureKey))
        }
    }

    func rerun(_ taskID: String?, toaster: Toaster) async {
        do {
            _ = try await session.api.rerunIssue(issueId: issueID, taskId: taskID)
            await loadTasks()
        } catch let e as APIError where e.status == 403 {
            toaster.error(tr("issues", "execution_log.retry_blocked"))
        } catch {
            toaster.error((error as? APIError)?.message ?? tr("issues", "execution_log.retry_failed"))
        }
    }

    // MARK: Subscribers

    var isSubscribed: Bool { subscribers?.contains { $0.userType == "member" && $0.userId == currentUserID } ?? false }
    var subscriptionReason: String? { subscribers?.first { $0.userType == "member" && $0.userId == currentUserID }?.reason }

    func toggleSubscriber(userID: String, type: String, subscribed: Bool, toaster: Toaster) async {
        guard !subscriptionPending, subscribers != nil else { return }
        subscriptionPending = true
        defer { subscriptionPending = false }
        let before = subscribers
        if subscribed {
            subscribers?.removeAll { $0.userId == userID && $0.userType == type }
        } else {
            subscribers?.append(IssueSubscriber(issueId: issueID, userType: type, userId: userID, reason: "manual", createdAt: ""))
        }
        do {
            if subscribed {
                try await session.api.unsubscribeFromIssue(issueId: issueID, userId: userID, userType: type)
            } else {
                try await session.api.subscribeToIssue(issueId: issueID, userId: userID, userType: type)
            }
        } catch {
            subscribers = before
            toaster.error(tr("issues", "detail.subscription_update_failed"))
        }
        await loadSubscribers()
    }

    func unsubscribeSubtree(toaster: Toaster) async {
        guard !subscriptionPending else { return }
        subscriptionPending = true
        defer { subscriptionPending = false }
        do {
            try await session.api.unsubscribeFromIssueSubtree(issueId: issueID, userId: currentUserID, userType: "member")
            toaster.success(tr("issues", "detail.unsubscribe_subtree_succeeded"))
        } catch let e as APIError where e.status == 404 && !e.message.hasPrefix("{") && e.message.hasPrefix("Request failed") {
            toaster.error(tr("issues", "detail.unsubscribe_subtree_unsupported"))
        } catch {
            toaster.error(tr("issues", "detail.unsubscribe_subtree_failed"))
        }
        await loadSubscribers()
    }

    // MARK: Pins

    var isPinned: Bool { session.pins.items.contains { $0.itemType == "issue" && $0.itemId == issueID } }

    func togglePin(toaster: Toaster) async {
        do {
            if isPinned {
                if let pin = session.pins.items.first(where: { $0.itemType == "issue" && $0.itemId == issueID }) {
                    session.pins.remove(pin.id)
                }
                try await session.api.deletePin(itemType: "issue", itemId: issueID)
            } else {
                let pin = try await session.api.createPin(CreatePinRequest(itemType: "issue", itemId: issueID))
                session.pins.upsert(pin)
            }
        } catch {
            toaster.error(error)
            await session.pins.load()
        }
    }
}

struct IssueDetailDeliverable: Hashable {
    var attachment: Attachment
    var commentID: String
}

enum IssueDetailReactionFactory {
    static func optimistic(commentID: String, emoji: String, actorID: String) -> Reaction? {
        let json: JSONValue = ["id": JSONValue("optimistic-\(emoji)"), "comment_id": JSONValue(commentID),
                               "actor_type": "member", "actor_id": JSONValue(actorID), "emoji": JSONValue(emoji)]
        guard let data = try? JSONCoders.encoder.encode(json) else { return nil }
        return try? JSONCoders.decoder.decode(Reaction.self, from: data)
    }
}
