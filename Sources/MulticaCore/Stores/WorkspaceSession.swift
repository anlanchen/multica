import Foundation
import Observation

/// Everything scoped to one signed-in workspace: stores, the realtime
/// connection, and the mutations the UI performs.
@MainActor
@Observable
public final class WorkspaceSession {
    public let workspace: Workspace
    public let currentUser: User
    @ObservationIgnored public let api: APIClient
    @ObservationIgnored public let realtime: RealtimeClient

    public let issues = IssueStore()
    public let inbox = InboxStore()
    public let directory = Directory()

    // Catalogs loaded when a screen first needs them, kept live by realtime.
    public let projects = CollectionStore<Project>(sort: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
    public let squads = CollectionStore<Squad>(sort: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    public let skills = CollectionStore<SkillSummary>(sort: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    public let autopilots = CollectionStore<Autopilot>(sort: { $0.createdAt > $1.createdAt })
    public let pins = CollectionStore<PinnedItem>(sort: { $0.position < $1.position })
    public let labels = CollectionStore<IssueLabel>(sort: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    public let properties = CollectionStore<IssueProperty>(sort: { $0.position < $1.position })
    public let quickActions = CollectionStore<QuickAction>(sort: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    public let chatSessions = CollectionStore<ChatSession>(sort: { $0.updatedAt > $1.updatedAt })
    public let agentRecords = CollectionStore<AgentRecord>(sort: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    public let memberRecords = CollectionStore<MemberWithUserRecord>(sort: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    public let runtimeRecords = CollectionStore<RuntimeDeviceRecord>(sort: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    public let issueStatusEntries = CollectionStore<IssueStatusEntry>(sort: { $0.position < $1.position })

    /// Bumped by realtime events a specific detail screen should refetch on
    /// (keyed by resource type, e.g. "pull_request", "subscriber").
    public private(set) var resourceRevision: [String: Int] = [:]

    public private(set) var connection: ConnectionState = .connecting
    public private(set) var lastError: String?
    public private(set) var isBootstrapped = false

    @ObservationIgnored private var details: [String: IssueDetailModel] = [:]
    @ObservationIgnored private var watchedTranscripts: [String: Int] = [:]
    @ObservationIgnored private var standaloneTranscripts: [String: TranscriptModel] = [:]
    @ObservationIgnored private var eventLoop: Task<Void, Never>?
    @ObservationIgnored private var catalogRefresh: [CatalogKind: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextPageOffset = 0
    @ObservationIgnored private var loadingMore = false
    @ObservationIgnored private var eventTaps: [@MainActor (RealtimeEvent) -> Void] = []
    public static let pageSize = 200

    public init(workspace: Workspace, user: User, api: APIClient, realtime: RealtimeClient) {
        self.workspace = workspace
        self.currentUser = user
        self.api = api
        self.realtime = realtime
        issues.currentUserID = user.id
        configureCatalogs()
    }

    private func configureCatalogs() {
        let api = self.api
        let workspaceID = workspace.id
        projects.configure { try await api.listProjects().projects }
        squads.configure { try await api.listSquads() }
        skills.configure { try await api.listSkills() }
        autopilots.configure { try await api.listAutopilots().autopilots }
        pins.configure { try await api.listPins() }
        labels.configure { try await api.listLabels().labels }
        properties.configure { try await api.listProperties(includeArchived: true).properties }
        quickActions.configure { try await api.listQuickActions(includeArchived: true).quickActions }
        chatSessions.configure { try await api.listChatSessions(status: "all") }
        agentRecords.configure { try await api.listAgents(includeArchived: true) }
        memberRecords.configure { try await api.listMembers(workspaceId: workspaceID) }
        runtimeRecords.configure { try await api.listRuntimes() }
        issueStatusEntries.configure { try await api.listIssueStatuses(includeArchived: true).statuses }
    }

    private func bump(_ key: String) {
        resourceRevision[key, default: 0] += 1
    }

    public func revision(_ key: String) -> Int {
        resourceRevision[key] ?? 0
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue?) -> T? {
        guard let value, let data = try? JSONCoders.encoder.encode(value) else { return nil }
        return try? JSONCoders.decoder.decode(T.self, from: data)
    }

    /// Applies an event the realtime layer passed through untyped.
    private func applyResource(type: String, payload: JSONValue) {
        let parts = type.split(separator: ":", maxSplits: 1)
        let kind = parts.first.map(String.init) ?? type
        let verb = parts.count > 1 ? String(parts[1]) : ""
        switch kind {
        case "project":
            if verb == "deleted", let id = payload["project_id"]?.stringValue {
                projects.remove(id)
            } else if let p = decode(Project.self, payload["project"]) {
                projects.upsert(p)
            }
        case "squad":
            Task { await squads.refreshIfLoaded() }
            bump(kind)
        case "skill":
            Task { await skills.refreshIfLoaded() }
            bump(kind)
        case "label":
            Task { await labels.refreshIfLoaded() }
        case "pin":
            Task { await pins.refreshIfLoaded() }
        case "property":
            if let p = decode(IssueProperty.self, payload["property"]) { properties.upsert(p) }
        case "chat":
            if verb == "session_deleted", let id = payload["chat_session_id"]?.stringValue {
                chatSessions.remove(id)
            } else {
                Task { await chatSessions.refreshIfLoaded() }
            }
            bump("chat")
        case "invitation":
            bump("invitation")
            Task { await memberRecords.refreshIfLoaded() }
        case "issue_properties", "issue_metadata", "issue_attachments", "issue_reaction", "subscriber", "reaction":
            if let issueID = payload["issue_id"]?.stringValue, let d = details[issueID] {
                Task { await self.reload(d) }
            }
            bump(kind)
        case "pull_request", "github_installation":
            bump(kind)
        case "issue_status":
            Task { await issueStatusEntries.refreshIfLoaded() }
        default:
            bump(kind)
        }
        lastResourceEvent = type
    }

    /// The type of the latest untyped event (diagnostics).
    public private(set) var lastResourceEvent: String?

    // MARK: Lifecycle

    /// Loads the workspace in parallel and opens the realtime connection.
    /// The socket is opened first so no event is lost between the REST
    /// snapshot and the subscription; events landing before the snapshot are
    /// reconciled by revision.
    public func start() async {
        await api.setWorkspaceSlug(workspace.slug)
        startEventLoop()
        await realtime.start(workspaceSlug: workspace.slug)

        // Issued together; each result is applied as soon as it is awaited.
        let api = self.api
        let workspaceID = workspace.id
        let statuses = Task { try await api.issueStatuses() }
        let page = Task { try await api.listIssues(.init(limit: Self.pageSize)) }
        let members = Task { try await api.members(workspaceID: workspaceID) }
        let agents = Task { try await api.agents() }
        let snapshot = Task { try await api.agentTaskSnapshot() }
        let summary = Task { try await api.inboxUnreadSummary() }

        issues.setCatalog((try? await statuses.value) ?? [])
        directory.setMembers((try? await members.value) ?? [])
        directory.setAgents((try? await agents.value) ?? [])
        switch await page.result {
        case .success(let first):
            issues.merge(page: first.issues, total: first.total, replacing: true)
            nextPageOffset = first.issues.count
            issues.resectionIfNeeded()
        case .failure(let error):
            lastError = describe(error)
        }
        issues.applyTaskSnapshot((try? await snapshot.value) ?? [])
        inbox.setSummary((try? await summary.value) ?? [])
        isBootstrapped = true

        Task { [weak self] in
            guard let self else { return }
            self.directory.setRuntimes((try? await self.api.runtimes()) ?? [])
        }
    }

    public func stop() async {
        eventLoop?.cancel()
        eventLoop = nil
        for t in catalogRefresh.values { t.cancel() }
        catalogRefresh.removeAll()
        await realtime.stop()
    }

    /// Loads the next page when the list scrolls near its end.
    public func loadMoreIfNeeded() async {
        guard !loadingMore, issues.loadedCount < issues.totalOnServer else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await api.listIssues(.init(limit: Self.pageSize, offset: nextPageOffset))
            nextPageOffset += page.issues.count
            issues.merge(page: page.issues, total: page.total, replacing: false)
        } catch {
            lastError = describe(error)
        }
    }

    private func startEventLoop() {
        eventLoop?.cancel()
        let stream = realtime.events
        eventLoop = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.apply(event)
            }
        }
    }

    // MARK: Realtime application

    /// Lets a feature store observe every typed event after the session
    /// applied it (payloads of untyped events included).
    public func addEventTap(_ tap: @escaping @MainActor (RealtimeEvent) -> Void) {
        eventTaps.append(tap)
    }

    public func apply(_ event: RealtimeEvent) {
        defer { for tap in eventTaps { tap(event) } }
        switch event {
        case .issueUpsert(let issue, let flags):
            issues.upsert(issue, isNew: flags.created)
        case .issueDeleted(let id):
            issues.remove(id)
        case .issueLabels(let id, let labels):
            issues.setLabels(id, labels)

        case .commentUpsert(let c):
            details[c.issueID]?.upsertComment(c)
        case .commentDeleted(let commentID, let issueID):
            details[issueID]?.removeComment(commentID)
        case .activity(let issueID, let entry):
            details[issueID]?.appendActivity(entry)

        case .taskLifecycle(let e):
            issues.applyTaskLifecycle(e)
            if let d = details[e.issueID] {
                d.applyLifecycle(e)
                if !e.status.isActive, let t = d.existingTranscript(e.taskID) {
                    // Terminal: pull the authoritative tail once.
                    Task { await self.backfill(t) }
                }
            }

        case .taskMessages(let batch):
            applyTaskMessages(batch)

        case .inboxNew(let item):
            inbox.insert(item)
            refreshCatalog(.other) // unread summary
        case .inboxChanged:
            refreshCatalog(.other)

        case .agentUpsert(let a):
            directory.upsertAgent(a)
            Task { await agentRecords.refreshIfLoaded() }

        case .catalogChanged(let kind):
            refreshCatalog(kind)

        case .workspaceDeleted:
            lastError = "This workspace was deleted."

        case .resource(let type, let payload):
            applyResource(type: type, payload: payload)

        case .connection(let state):
            connection = state
            if case .connected(recovered: true) = state {
                Task { await self.recoverAfterReconnect() }
            }
        }
    }

    private func applyTaskMessages(_ batch: [TaskMessage]) {
        var byTask: [String: [TaskMessage]] = [:]
        for m in batch { byTask[m.taskID, default: []].append(m) }
        for (taskID, messages) in byTask {
            let issueID = messages.first?.issueID ?? ""
            let t: TranscriptModel
            if let detail = details[issueID] ?? details.values.first(where: { $0.existingTranscript(taskID) != nil }) {
                t = detail.transcript(for: taskID)
            } else if let standalone = standaloneTranscripts[taskID] {
                t = standalone
            } else {
                continue
            }
            t.merge(messages)
            if t.needsRepair {
                t.needsRepair = false
                Task { await self.backfill(t) }
            }
        }
    }

    /// Reference data changes are answered with a debounced refetch, never
    /// by merging event payloads into a cache.
    private func refreshCatalog(_ kind: CatalogKind) {
        catalogRefresh[kind]?.cancel()
        catalogRefresh[kind] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            switch kind {
            case .members:
                if let m = try? await self.api.members(workspaceID: self.workspace.id) { self.directory.setMembers(m) }
                await self.memberRecords.refreshIfLoaded()
            case .agents:
                if let a = try? await self.api.agents() { self.directory.setAgents(a) }
                await self.agentRecords.refreshIfLoaded()
            case .statuses:
                if let s = try? await self.api.issueStatuses() { self.issues.setCatalog(s) }
                await self.issueStatusEntries.refreshIfLoaded()
            case .runtimes:
                if let r = try? await self.api.runtimes() { self.directory.setRuntimes(r) }
                await self.runtimeRecords.refreshIfLoaded()
            case .labels:
                self.bump("label")
                await self.labels.refreshIfLoaded()
                await self.skills.refreshIfLoaded()
            case .workspace:
                self.bump("workspace")
            case .other:
                if let s = try? await self.api.inboxUnreadSummary() { self.inbox.setSummary(s) }
                if self.inbox.isLoaded, let items = try? await self.api.inbox() { self.inbox.setItems(items) }
            }
        }
    }

    /// After a dropped connection, refetch only what is on screen: the first
    /// issue page, open issue details, watched transcripts, and the badge.
    /// Upstream invalidated broad query families on reconnect.
    private func recoverAfterReconnect() async {
        let api = self.api
        let page = Task { try await api.listIssues(.init(limit: Self.pageSize)) }
        let snapshot = Task { try await api.agentTaskSnapshot() }
        let summary = Task { try await api.inboxUnreadSummary() }
        if let p = try? await page.value { issues.merge(page: p.issues, total: p.total, replacing: false) }
        if let s = try? await snapshot.value { issues.applyTaskSnapshot(s) }
        if let s = try? await summary.value { inbox.setSummary(s) }
        for d in details.values {
            await reload(d)
        }
    }

    // MARK: Issue detail

    /// Opens (or re-opens) the detail model for an issue. Balanced by
    /// `closeIssue`.
    public func openIssue(_ issueID: String) -> IssueDetailModel {
        let d = details[issueID] ?? IssueDetailModel(issueID: issueID)
        details[issueID] = d
        if d.issue == nil { d.issue = issues.model(issueID) }
        d.openCount += 1
        if d.openCount == 1 {
            realtime.watchIssue(issueID)
            Task { await self.reload(d) }
        }
        return d
    }

    public func closeIssue(_ issueID: String) {
        guard let d = details[issueID] else { return }
        d.openCount -= 1
        if d.openCount <= 0 {
            details[issueID] = nil
            realtime.unwatchIssue(issueID)
        }
    }

    public func reload(_ d: IssueDetailModel) async {
        d.isLoading = d.entries.isEmpty
        let api = self.api
        let issueID = d.id
        let issue = Task { try await api.issue(issueID) }
        let timeline = Task { try await api.timeline(issueID: issueID) }
        let runs = Task { try await api.taskRuns(issueID: issueID) }
        do {
            issues.upsert(try await issue.value)
            if d.issue == nil { d.issue = issues.model(issueID) }
            d.setTimeline(try await timeline.value)
            d.setRuns((try? await runs.value) ?? [])
            d.loadError = nil
        } catch {
            d.loadError = describe(error)
        }
        d.isLoading = false
        for run in d.activeRuns {
            await backfill(d.transcript(for: run.id))
        }
        for (id, t) in d.transcripts where watchedTranscripts[id] != nil && !d.activeRuns.contains(where: { $0.id == id }) {
            await backfill(t)
        }
    }

    /// Fetches the persisted transcript and merges it with whatever live
    /// frames already arrived (merge is by `seq`, so order does not matter).
    public func backfill(_ t: TranscriptModel) async {
        t.isLoading = t.buffer.isEmpty
        if let messages = try? await api.taskMessages(taskID: t.id) {
            t.merge(await Redactor.shared.redactedInBackground(messages))
        }
        t.isLoading = false
    }

    /// The transcript of any agent task (agent activity, autopilot runs,
    /// chat), shared with an open issue detail when there is one. Live while
    /// a view watches it.
    public func transcript(taskID: String) -> TranscriptModel {
        for d in details.values {
            if let t = d.existingTranscript(taskID) { return t }
        }
        if let t = standaloneTranscripts[taskID] { return t }
        let t = TranscriptModel(taskID: taskID)
        standaloneTranscripts[taskID] = t
        return t
    }

    public func watchTranscript(_ t: TranscriptModel) {
        watchedTranscripts[t.id, default: 0] += 1
        if watchedTranscripts[t.id] == 1 {
            Task {
                await realtime.watchTask(t.id)
                await backfill(t)
            }
        }
    }

    public func unwatchTranscript(_ t: TranscriptModel) {
        guard let n = watchedTranscripts[t.id] else { return }
        if n <= 1 {
            watchedTranscripts[t.id] = nil
            standaloneTranscripts[t.id] = nil
            Task { await realtime.unwatchTask(t.id) }
        } else {
            watchedTranscripts[t.id] = n - 1
        }
    }

    // MARK: Mutations

    /// Optimistic field update: snapshot, patch, roll back on failure, and
    /// adopt the server's answer on success.
    public func updateIssue(_ issueID: String, _ request: UpdateIssueRequest) async {
        let previous = issues.patch(issueID) { request.applied(to: $0) }
        issues.resectionIfNeeded()
        do {
            let updated = try await api.updateIssue(id: issueID, request)
            issues.upsert(updated)
        } catch {
            if let previous { issues.restore(previous) }
            lastError = describe(error)
        }
    }

    /// Creation waits for the server before the issue appears.
    public func createIssue(_ request: CreateIssueRequest) async throws -> Issue {
        let issue = try await api.createIssue(request)
        issues.upsert(issue, isNew: true)
        return issue
    }

    /// Sends a comment with visible pending state; a failure stays visible
    /// with a retry instead of disappearing.
    public func postComment(issueID: String, content: String, parentID: String? = nil) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let d = details[issueID] else { return }
        let pending = PendingComment(id: UUID().uuidString, content: trimmed, parentID: parentID, state: .sending)
        d.pendingComments.append(pending)
        await send(pending, in: d)
    }

    public func retryComment(_ pendingID: String, issueID: String) async {
        guard let d = details[issueID], let i = d.pendingComments.firstIndex(where: { $0.id == pendingID }) else { return }
        d.pendingComments[i].state = .sending
        await send(d.pendingComments[i], in: d)
    }

    public func discardComment(_ pendingID: String, issueID: String) {
        details[issueID]?.pendingComments.removeAll { $0.id == pendingID }
    }

    private func send(_ pending: PendingComment, in d: IssueDetailModel) async {
        do {
            let comment = try await api.createComment(issueID: d.id, content: pending.content, parentID: pending.parentID)
            d.pendingComments.removeAll { $0.id == pending.id }
            d.upsertComment(comment)
        } catch {
            if let i = d.pendingComments.firstIndex(where: { $0.id == pending.id }) {
                d.pendingComments[i].state = .failed(describe(error))
            }
        }
    }

    public func cancelRun(_ task: AgentTask) async {
        do {
            _ = try await api.cancelTask(issueID: task.issueID, taskID: task.id)
        } catch {
            lastError = describe(error)
        }
    }

    // MARK: Inbox

    public func loadInbox() async {
        do {
            inbox.setItems(try await api.inbox())
        } catch {
            lastError = describe(error)
        }
    }

    public func markInboxRead(_ item: InboxItem) async {
        guard let before = inbox.markRead(item.id) else { return }
        do {
            try await api.markInboxRead(id: item.id)
        } catch {
            inbox.restore(before)
        }
        refreshCatalog(.other)
    }

    public func archiveInbox(_ item: InboxItem) async {
        // Archive waits for the server: it removes the row.
        do {
            try await api.archiveInbox(id: item.id)
            inbox.archive(item.id)
        } catch {
            lastError = describe(error)
        }
        refreshCatalog(.other)
    }

    public func markAllInboxRead() async {
        do {
            try await api.markAllInboxRead()
            inbox.markAllRead()
        } catch {
            lastError = describe(error)
        }
        refreshCatalog(.other)
    }

    public func dismissError() { lastError = nil }

    func describe(_ error: Error) -> String {
        if let e = error as? APIError { return e.message }
        return error.localizedDescription
    }
}
