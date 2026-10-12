import Foundation
import Observation

/// A conversation-starter click: replaces the composer draft once.
public struct ChatUIStarterRequest: Sendable, Hashable {
    public var id: Int
    public var content: String
}

/// Chat state for one workspace session, shared by the chat tab and the
/// floating window (upstream: the chat zustand store plus the chat query
/// caches and `useRealtimeSync`'s chat handlers).
///
/// Realtime keeps it current while no chat surface is mounted: chat events
/// patch the conversations already held and refetch only what someone is
/// looking at; everything else is marked stale and refetched on next view.
@MainActor
@Observable
public final class ChatUIStore {
    public static let draftNewSession = "__new__"
    public static let minWidth: Double = 360
    public static let minHeight: Double = 480
    public static let defaultWidth: Double = 380
    public static let defaultHeight: Double = 600
    static let quickActionsTimeout: TimeInterval = 12
    static let timelineCapacity = 200

    @ObservationIgnored public private(set) weak var session: WorkspaceSession?
    @ObservationIgnored let api: APIClient
    @ObservationIgnored let storage: ChatUIStorage
    @ObservationIgnored let slug: String
    @ObservationIgnored public let userID: String
    /// Presents a toast (message, isError). Set by the app.
    @ObservationIgnored public var toast: ((String, Bool) -> Void)?

    public private(set) var activeSessionID: String?
    public private(set) var selectedAgentID: String?
    public private(set) var selectedProjectID: String?

    public private(set) var chatWidth: Double
    public private(set) var chatHeight: Double
    public private(set) var isExpanded: Bool
    public private(set) var floatingEnabled: Bool
    public private(set) var openPreference: Bool

    public private(set) var drafts: [String: String]
    public private(set) var draftAttachments: [String: [ChatUIDraftAttachment]]
    public private(set) var uploadsInFlight: [String: Int] = [:]
    public private(set) var restoreRequest: ChatUIRestoreRequest?
    public private(set) var focusRequest = 0
    public private(set) var starterRequest: ChatUIStarterRequest?

    public private(set) var context = ChatUIContext()
    public private(set) var agentsByID: [String: AgentRecord] = [:]
    public private(set) var historySessions: [ChatSession] = []
    public private(set) var archivedSessions: [ChatSession] = []
    public private(set) var pendingBySession: [String: PendingChatTaskItem] = [:]
    public private(set) var hasPendingAny = false
    public private(set) var appActive = true

    @ObservationIgnored private var appliedRestoreIDs: [String]
    @ObservationIgnored private var pendingSendRestores: [String: [ChatUIPendingRestore]]
    @ObservationIgnored private var conversations: [String: ChatUIConversation] = [:]
    @ObservationIgnored private var timelines: [String: ChatUITaskTimeline] = [:]
    @ObservationIgnored private var timelineOrder: [String] = []
    @ObservationIgnored private var surfaces = 0
    @ObservationIgnored private var aggregateDemand = 0
    @ObservationIgnored private var hasAnyDemand = 0
    @ObservationIgnored private var aggregateStale = true
    @ObservationIgnored private var hasAnyStale = true
    @ObservationIgnored private var aggregateTimer: Task<Void, Never>?
    @ObservationIgnored private var sessionsRefresh: Task<Void, Never>?
    @ObservationIgnored private var presenceTicker: Task<Void, Never>?
    @ObservationIgnored private var draftSave: Task<Void, Never>?
    @ObservationIgnored private var sessionCreation: Task<ChatSession, Error>?
    @ObservationIgnored private var reconciling: Set<String> = []
    @ObservationIgnored private var markingRead: Set<String> = []
    @ObservationIgnored private var starterCounter = 0
    private var presenceTick = 0
    private var projectUpdateInFlight = false

    public init(session: WorkspaceSession, storage: ChatUIStorage) {
        self.session = session
        self.api = session.api
        self.storage = storage
        self.slug = session.workspace.slug
        self.userID = session.currentUser.id
        let ws = { (base: String) in "\(base).\(session.workspace.slug)" }
        activeSessionID = storage.string(ws(Keys.activeSession))
        selectedAgentID = storage.string(ws(Keys.selectedAgent))
        selectedProjectID = storage.string(ws(Keys.selectedProject))
        chatWidth = storage.string(Keys.width).flatMap(Double.init) ?? Self.defaultWidth
        chatHeight = storage.string(Keys.height).flatMap(Double.init) ?? Self.defaultHeight
        isExpanded = storage.string(ws(Keys.expanded)) == "true"
        floatingEnabled = storage.string(Keys.floatingEnabled) != "false"
        openPreference = storage.string(Keys.isOpen) == "true"
        drafts = Self.decode([String: String].self, storage.string(ws(Keys.drafts))) ?? [:]
        draftAttachments = Self.decode([String: [ChatUIDraftAttachment]].self, storage.string(ws(Keys.draftAttachments))) ?? [:]
        appliedRestoreIDs = Self.decode([String].self, storage.string(ws(Keys.appliedRestores))) ?? []
        pendingSendRestores = Self.decode([String: [ChatUIPendingRestore]].self, storage.string(ws(Keys.pendingSendRestores))) ?? [:]
        session.addEventTap { [weak self] event in self?.handle(event) }
        trackSessions()
        trackContext()
    }

    enum Keys {
        static let activeSession = "multica.chat.activeSessionId"
        static let selectedAgent = "multica.chat.selectedAgentId"
        static let selectedProject = "multica.chat.selectedProjectId"
        static let drafts = "multica.chat.drafts"
        static let draftAttachments = "multica.chat.draftAttachments"
        static let appliedRestores = "multica.chat.appliedDraftRestores"
        static let pendingSendRestores = "multica.chat.pendingSendRestores"
        static let width = "multica.chat.width"
        static let height = "multica.chat.height"
        static let expanded = "multica.chat.expanded"
        static let isOpen = "multica.chat.isOpen"
        static let floatingEnabled = "multica.chat.floatingChatEnabled"
    }

    private func wsKey(_ base: String) -> String { "\(base).\(slug)" }

    static func decode<T: Decodable>(_ type: T.Type, _ raw: String?) -> T? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func say(_ key: String, error: Bool = true, _ args: [String: CustomStringConvertible] = [:]) {
        toast?(tr("chat", key, args), error)
    }

    // MARK: Derived state

    private func trackSessions() {
        guard let session else { return }
        let items = withObservationTracking { session.chatSessions.items } onChange: { [weak self] in
            Task { @MainActor in self?.trackSessions() }
        }
        let history = ChatUISessions.sorted(items.filter { $0.status != "archived" })
        let archived = ChatUISessions.sorted(items.filter { $0.status == "archived" })
        if history != historySessions { historySessions = history }
        if archived != archivedSessions { archivedSessions = archived }
    }

    private func trackContext() {
        let next = withObservationTracking { computeContext() } onChange: { [weak self] in
            Task { @MainActor in self?.trackContext() }
        }
        if next != context {
            if next.agents != context.agents {
                agentsByID = Dictionary(next.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
            context = next
        }
        selfHeal()
    }

    private func computeContext() -> ChatUIContext {
        var c = ChatUIContext()
        guard let s = session else { return c }
        _ = presenceTick
        let agents = s.agentRecords.items
        let role = s.directory.members.first { $0.userID == userID }?.role
        c.memberRole = role
        c.agents = agents
        let available = agents.filter { $0.archivedAt == nil && ChatUIAgents.canInvoke($0, userID: userID, role: role) }
        c.availableAgents = available
        c.agentsSettled = s.agentRecords.isLoaded && (s.isBootstrapped || !s.directory.members.isEmpty)
        let current = activeSessionID.flatMap { id in s.chatSessions.items.first { $0.id == id } }
        c.currentSession = current
        c.isSessionArchived = current?.status == "archived"
        let sessionAgent = current.flatMap { cs in agents.first { $0.id == cs.agentId } }
        c.isAgentArchived = sessionAgent?.archivedAt != nil
        let active = sessionAgent ?? available.first { $0.id == selectedAgentID } ?? available.first
        c.activeAgent = active
        c.isAgentRuntimeBound = active.map(ChatUIAgents.isRuntimeBound) ?? false
        c.isAgentAccessRevoked = active.map { !ChatUIAgents.canInvoke($0, userID: userID, role: role) } ?? false
        c.canEditActiveAgent = active.map { ChatUIAgents.canEdit($0, userID: userID, role: role) } ?? false
        let candidate = current != nil ? current?.projectId : selectedProjectID
        let projectsLoaded = s.projects.isLoaded
        c.activeProjectID = candidate.flatMap { id in (!projectsLoaded || s.projects.items.contains { $0.id == id }) ? id : nil }
        c.noAgent = c.agentsSettled && available.isEmpty
        c.isProjectUpdating = projectUpdateInFlight || (activeSessionID != nil && current == nil)
        if let active, s.runtimeRecords.isLoaded {
            let runtime = active.runtimeId.isEmpty ? nil : s.runtimeRecords.items.first { $0.id == active.runtimeId }
            c.availability = ChatUIAgents.availability(active, runtime: runtime)
            if let runtime {
                c.projectContextUnsupported = !ChatUIAgents.projectContextSupported(cliVersion: runtime.metadata["cli_version"]?.stringValue)
            }
        }
        return c
    }

    /// Drops selections that no longer resolve: a deleted project for the
    /// next chat, or an active session deleted / no longer accessible (unless
    /// it was just created and still awaits the list refetch).
    private func selfHeal() {
        guard let s = session else { return }
        if let p = selectedProjectID, s.projects.isLoaded, !s.projects.items.contains(where: { $0.id == p }) {
            setSelectedProject(nil)
        }
        if let id = activeSessionID, s.chatSessions.isLoaded, s.chatSessions.item(id) == nil, !hasInFlightPending(id) {
            setActiveSession(nil)
        }
    }

    private func hasInFlightPending(_ sessionID: String) -> Bool {
        conversations[sessionID]?.pending.taskId != nil
    }

    // MARK: Surfaces

    var composerEnabled: Bool { surfaces > 0 && appActive }

    /// A chat surface (tab or floating window) came on screen.
    public func attachSurface() {
        surfaces += 1
        if surfaces == 1 { startPresenceTicker() }
        loadCatalogs()
        refreshRestoreRequest()
        if let id = activeSessionID, let c = conversations[id] { refreshDraftRestores(c) }
    }

    public func detachSurface() {
        surfaces = max(0, surfaces - 1)
        if surfaces == 0 {
            presenceTicker?.cancel()
            presenceTicker = nil
        }
        refreshRestoreRequest()
    }

    public func setAppActive(_ active: Bool) {
        guard active != appActive else { return }
        appActive = active
        refreshRestoreRequest()
        if active, let id = activeSessionID, let c = conversations[id] { refreshDraftRestores(c) }
    }

    private func loadCatalogs() {
        guard let s = session else { return }
        Task {
            async let a: Void = s.chatSessions.loadIfNeeded()
            async let b: Void = s.agentRecords.loadIfNeeded()
            async let c: Void = s.runtimeRecords.loadIfNeeded()
            async let d: Void = s.projects.loadIfNeeded()
            _ = await (a, b, c, d)
        }
    }

    private func startPresenceTicker() {
        presenceTicker?.cancel()
        presenceTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.presenceTick += 1
            }
        }
    }

    // MARK: Conversations

    /// The held conversation for a session (created empty on first use).
    public func conversation(_ id: String) -> ChatUIConversation {
        if let c = conversations[id] { return c }
        let c = ChatUIConversation(id: id)
        conversations[id] = c
        return c
    }

    /// A surface shows this conversation: load what is missing or stale.
    public func view(_ id: String) {
        let c = conversation(id)
        c.viewers += 1
        if c.messagesStale || !c.messagesLoaded { refreshMessages(c, force: true) }
        if c.pendingStale || !c.pendingLoaded { refreshPending(c, force: true) }
        if composerEnabled, id == activeSessionID { refreshDraftRestores(c) }
    }

    public func leave(_ id: String) {
        guard let c = conversations[id] else { return }
        c.viewers = max(0, c.viewers - 1)
    }

    func refreshMessages(_ c: ChatUIConversation, force: Bool = false) {
        guard force || c.viewers > 0 else {
            c.messagesStale = true
            return
        }
        c.messagesStale = false
        if c.messagesInflight {
            c.messagesRerun = true
            return
        }
        c.messagesInflight = true
        let id = c.id
        Task { [weak self, api] in
            let page = try? await api.listChatMessagesPage(sessionId: id, limit: 50)
            guard let self else { return }
            c.messagesInflight = false
            if let page {
                c.setPage(page)
            } else if !c.messagesLoaded {
                c.setMessages([], loaded: true)
            }
            if c.messagesRerun {
                c.messagesRerun = false
                self.refreshMessages(c, force: true)
            }
        }
    }

    func refreshPending(_ c: ChatUIConversation, force: Bool = false) {
        guard force || c.viewers > 0 else {
            c.pendingStale = true
            return
        }
        c.pendingStale = false
        if c.pendingInflight {
            c.pendingRerun = true
            return
        }
        c.pendingInflight = true
        let id = c.id
        Task { [weak self, api] in
            let pending = try? await api.getPendingChatTask(sessionId: id)
            guard let self else { return }
            c.pendingInflight = false
            if c.pendingRerun {
                c.pendingRerun = false
                self.refreshPending(c, force: true)
                return
            }
            if let pending {
                c.setPending(pending)
            } else if !c.pendingLoaded {
                c.setPending(ChatUIPending.empty)
            }
        }
    }

    /// Loads the page of messages before the oldest one held.
    public func fetchOlder(_ id: String) {
        guard let c = conversations[id], c.hasOlder, !c.isFetchingOlder, let cursor = c.olderCursor else { return }
        c.isFetchingOlder = true
        Task { [api] in
            let page = try? await api.listChatMessagesPage(sessionId: id, beforeCreatedAt: cursor.createdAt, beforeId: cursor.id, limit: 50)
            if let page { c.prependOlder(page) }
            c.isFetchingOlder = false
        }
    }

    // MARK: Task timelines

    public func timeline(_ taskID: String) -> ChatUITaskTimeline {
        if let t = timelines[taskID] {
            if timelineOrder.last != taskID {
                timelineOrder.removeAll { $0 == taskID }
                timelineOrder.append(taskID)
            }
            return t
        }
        let t = ChatUITaskTimeline(id: taskID)
        timelines[taskID] = t
        timelineOrder.append(taskID)
        if timelineOrder.count > Self.timelineCapacity, let evict = timelineOrder.first(where: { timelines[$0]?.isLive == false }) {
            timelineOrder.removeAll { $0 == evict }
            timelines[evict] = nil
        }
        return t
    }

    /// Fetches a settled task's transcript once (single-flight, cached).
    public func loadTimeline(_ taskID: String) {
        let t = timeline(taskID)
        guard ChatUIText.isTaskID(taskID), !t.isLive, !t.settled, !t.loading else {
            if !ChatUIText.isTaskID(taskID) { t.markLoaded() }
            return
        }
        t.loading = true
        let held = t.messages
        Task { [api] in
            let fetched = try? await api.taskMessages(taskID: taskID)
            t.loading = false
            guard let fetched else {
                t.markLoaded()
                return
            }
            let redacted = await Redactor.shared.redactedInBackground(fetched)
            let (messages, builder) = await Task.detached(priority: .userInitiated) { () -> ([TaskMessage], ChatUITimelineBuilder) in
                var bySeq: [Int: TaskMessage] = [:]
                for m in held { bySeq[m.seq] = m }
                for m in redacted { bySeq[m.seq] = m }
                let merged = bySeq.values.sorted { $0.seq < $1.seq }
                var b = ChatUITimelineBuilder()
                b.sync(merged, generation: 0)
                return (merged, b)
            }.value
            guard !t.isLive else { return }
            t.adopt(builder, messages: messages)
            t.settled = true
            t.markLoaded()
        }
    }

    /// Follows a running task's transcript while a chat surface shows it.
    public func retainLiveTimeline(_ taskID: String) {
        guard ChatUIText.isTaskID(taskID), let session else { return }
        let t = timeline(taskID)
        t.liveCount += 1
        guard t.liveCount == 1 else { return }
        let transcript = session.transcript(taskID: taskID)
        t.transcript = transcript
        t.settled = false
        session.watchTranscript(transcript)
        syncLive(t)
        trackLive(t, transcript)
    }

    public func releaseLiveTimeline(_ taskID: String) {
        guard let t = timelines[taskID], t.liveCount > 0 else { return }
        t.liveCount -= 1
        guard t.liveCount == 0, let transcript = t.transcript else { return }
        syncLive(t)
        t.transcript = nil
        session?.unwatchTranscript(transcript)
        loadTimeline(taskID)
    }

    private func trackLive(_ t: ChatUITaskTimeline, _ transcript: TranscriptModel) {
        withObservationTracking {
            _ = transcript.version
            _ = transcript.isLoading
        } onChange: { [weak self, weak t] in
            Task { @MainActor in
                guard let self, let t, t.transcript === transcript else { return }
                self.syncLive(t)
                self.trackLive(t, transcript)
            }
        }
    }

    private func syncLive(_ t: ChatUITaskTimeline) {
        guard let transcript = t.transcript else { return }
        t.apply(transcript.buffer.messages, generation: transcript.buffer.rebuildCount + 1)
        if !transcript.isLoading && (transcript.version > 0 || !transcript.buffer.isEmpty || t.hasMessages) { t.markLoaded() }
    }

    // MARK: Selection

    public func setActiveSession(_ id: String?) {
        guard id != activeSessionID else { return }
        activeSessionID = id
        storage.set(id, wsKey(Keys.activeSession))
        refreshRestoreRequest()
    }

    private func setSelectedAgent(_ id: String) {
        guard id != selectedAgentID else { return }
        selectedAgentID = id
        storage.set(id, wsKey(Keys.selectedAgent))
    }

    private func setSelectedProject(_ id: String?) {
        guard id != selectedProjectID else { return }
        selectedProjectID = id
        storage.set(id, wsKey(Keys.selectedProject))
    }

    public func requestFocus() { focusRequest += 1 }

    /// Picking a session from another agent switches the agent too.
    public func selectSession(_ s: ChatSession) {
        if let active = context.activeAgent, s.agentId != active.id { setSelectedAgent(s.agentId) }
        setActiveSession(s.id)
    }

    /// ⊕ without an agent pick: a fresh chat has no project.
    public func newChat() {
        setSelectedProject(nil)
        setActiveSession(nil)
        requestFocus()
    }

    /// ⊕ with an agent pick: always lands on an empty compose for it.
    public func startNewChat(agentID: String) {
        setSelectedAgent(agentID)
        setSelectedProject(nil)
        setActiveSession(nil)
        requestFocus()
    }

    /// The floating window's agent dropdown: switching agent starts a fresh
    /// chat; re-picking the shown agent is a no-op.
    public func selectAgent(_ agentID: String) {
        if context.activeAgent?.id == agentID { return }
        let keepProject = context.currentSession == nil ? context.activeProjectID : nil
        setSelectedAgent(agentID)
        setSelectedProject(keepProject)
        setActiveSession(nil)
        requestFocus()
    }

    public func changeProject(_ projectID: String?) {
        guard projectID != context.activeProjectID else { return }
        switch ChatUIProjectChange.plan(target: projectID, activeSessionID: activeSessionID, current: context.currentSession) {
        case .awaitSession:
            return
        case .detachCurrent(let sessionID):
            setSessionProject(sessionID, projectID: nil)
        case .startFreshChat(let agentID, let project):
            setSelectedAgent(agentID)
            setSelectedProject(project)
            setActiveSession(nil)
        case .setDraftProject(let project):
            setSelectedProject(project)
        }
        requestFocus()
    }

    /// Archiving the open chat moves to the next one (else the previous, else
    /// none) instead of stranding the composer on a read-only session.
    public func advanceSelectionAfterArchive(_ sessionID: String) {
        guard activeSessionID == sessionID else { return }
        if let next = ChatUISessions.nextAfterArchive(sessionID, history: historySessions) {
            selectSession(next)
        } else {
            setActiveSession(nil)
        }
    }

    public func prefillStarter(_ prompt: String) {
        starterCounter += 1
        starterRequest = ChatUIStarterRequest(id: starterCounter, content: prompt)
        requestFocus()
    }

    /// Applies a pending starter request to the shown draft.
    public func consumeStarter(draftKey: String) {
        guard let r = starterRequest else { return }
        starterRequest = nil
        setDraft(draftKey, r.content)
    }

    // MARK: Floating window

    public func setFloatingSize(width: Double, height: Double) {
        chatWidth = width
        chatHeight = height
        isExpanded = false
        storage.set(String(width), Keys.width)
        storage.set(String(height), Keys.height)
        storage.set(nil, wsKey(Keys.expanded))
    }

    public func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        storage.set(expanded ? "true" : nil, wsKey(Keys.expanded))
    }

    public func setOpenPreference(_ open: Bool) {
        guard open != openPreference else { return }
        openPreference = open
        storage.set(String(open), Keys.isOpen)
    }

    /// Settings → Chat preference; turning it off also closes the window.
    public func setFloatingEnabled(_ enabled: Bool) {
        floatingEnabled = enabled
        storage.set(String(enabled), Keys.floatingEnabled)
        if !enabled { setOpenPreference(false) }
    }

    // MARK: Drafts

    public func draft(_ key: String) -> String { drafts[key] ?? "" }

    /// Writes a draft and drops completed uploads its body no longer
    /// references.
    public func setDraft(_ key: String, _ text: String) {
        if drafts[key] ?? "" != text {
            drafts[key] = text.isEmpty ? nil : text
            scheduleDraftSave()
        }
        if let staged = draftAttachments[key], !staged.isEmpty {
            let kept = staged.filter { ChatUIText.isReferenced($0.attachment, in: text) }
            if kept.count != staged.count { setDraftAttachments(key, kept) }
        }
    }

    public func appendToDraft(_ key: String, _ markdown: String) {
        let existing = drafts[key] ?? ""
        let trimmed = ChatUITimeline.trimEnd(existing)
        setDraft(key, trimmed.isEmpty ? markdown : "\(trimmed)\n\n\(markdown)")
    }

    public func clearDraft(_ key: String) {
        guard drafts[key] != nil || draftAttachments[key] != nil else { return }
        drafts[key] = nil
        draftAttachments[key] = nil
        scheduleDraftSave()
    }

    private func setDraftAttachments(_ key: String, _ list: [ChatUIDraftAttachment]) {
        draftAttachments[key] = list.isEmpty ? nil : list
        scheduleDraftSave()
    }

    public func uploadStarted(_ key: String) {
        uploadsInFlight[key, default: 0] += 1
    }

    /// A finished upload: stage its row and append its markdown to the draft.
    public func uploadFinished(_ key: String, attachment: Attachment, markdown: String) {
        uploadsInFlight[key] = max(0, (uploadsInFlight[key] ?? 1) - 1)
        var staged = draftAttachments[key] ?? []
        staged.removeAll { $0.id == attachment.id }
        staged.append(ChatUIDraftAttachment(attachment))
        draftAttachments[key] = staged
        appendToDraft(key, markdown)
    }

    public func uploadFailed(_ key: String) {
        uploadsInFlight[key] = max(0, (uploadsInFlight[key] ?? 1) - 1)
    }

    private func scheduleDraftSave() {
        draftSave?.cancel()
        draftSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.persistDrafts()
        }
    }

    private func persistDrafts() {
        storage.set(drafts.isEmpty ? nil : Self.encode(drafts), wsKey(Keys.drafts))
        storage.set(draftAttachments.isEmpty ? nil : Self.encode(draftAttachments), wsKey(Keys.draftAttachments))
    }

    // MARK: Draft restores (#5219)

    private func refreshRestoreRequest() {
        guard composerEnabled, let sid = activeSessionID else {
            if restoreRequest != nil { restoreRequest = nil }
            return
        }
        if let r = restoreRequest, r.sessionID == sid { return }
        if let queued = pendingSendRestores[sid]?.first {
            restoreRequest = ChatUIRestoreRequest(id: queued.id, content: queued.content, attachments: queued.attachments, sessionID: sid)
            return
        }
        if let c = conversations[sid], let r = c.draftRestores.first(where: { $0.chatSessionId == sid && !appliedRestoreIDs.contains($0.id) }) {
            c.remove(messageID: r.id)
            restoreRequest = ChatUIRestoreRequest(id: r.id, content: r.content, attachments: (r.attachments ?? []).map(ChatUIDraftAttachment.init), sessionID: sid, serverRestoreID: r.id)
            return
        }
        if restoreRequest != nil { restoreRequest = nil }
    }

    /// Writes the pending restore into its draft when that draft is empty;
    /// work in progress makes it wait. Returns true when applied.
    @discardableResult
    public func applyRestoreIfPossible(draftKey: String) -> Bool {
        guard let r = restoreRequest, r.sessionID == draftKey else { return false }
        let busy = !draft(draftKey).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(draftAttachments[draftKey] ?? []).isEmpty
            || (uploadsInFlight[draftKey] ?? 0) > 0
        guard !busy else { return false }
        setDraft(draftKey, r.content)
        setDraftAttachments(draftKey, r.attachments)
        if let server = r.serverRestoreID {
            if !appliedRestoreIDs.contains(server) {
                appliedRestoreIDs.append(server)
                storage.set(Self.encode(appliedRestoreIDs), wsKey(Keys.appliedRestores))
            }
            consumeRestore(sessionID: r.sessionID, restoreID: server)
        } else {
            dequeuePendingSendRestore(r.sessionID, r.id)
        }
        restoreRequest = nil
        refreshRestoreRequest()
        return true
    }

    private func enqueuePendingSendRestore(_ r: ChatUIPendingRestore) {
        var queue = pendingSendRestores[r.sessionID] ?? []
        guard !queue.contains(where: { $0.id == r.id }) else { return }
        queue.append(r)
        pendingSendRestores[r.sessionID] = queue
        storage.set(Self.encode(pendingSendRestores), wsKey(Keys.pendingSendRestores))
        refreshRestoreRequest()
    }

    private func dequeuePendingSendRestore(_ sessionID: String, _ id: String) {
        guard var queue = pendingSendRestores[sessionID] else { return }
        queue.removeAll { $0.id == id }
        pendingSendRestores[sessionID] = queue.isEmpty ? nil : queue
        storage.set(pendingSendRestores.isEmpty ? nil : Self.encode(pendingSendRestores), wsKey(Keys.pendingSendRestores))
    }

    /// Idempotent server consume with backoff; the ledger entry is dropped
    /// only once the row is confirmed gone.
    private func consumeRestore(sessionID: String, restoreID: String) {
        guard !reconciling.contains(restoreID) else { return }
        reconciling.insert(restoreID)
        if let c = conversations[sessionID] { c.draftRestores.removeAll { $0.id == restoreID } }
        Task { [weak self, api] in
            var ok = false
            for attempt in 0..<4 {
                do {
                    try await api.consumeChatDraftRestore(sessionId: sessionID, restoreId: restoreID)
                    ok = true
                    break
                } catch {
                    if attempt < 3 { try? await Task.sleep(for: .seconds(min(pow(2, Double(attempt + 1)), 8))) }
                }
            }
            guard let self else { return }
            self.reconciling.remove(restoreID)
            if ok, let i = self.appliedRestoreIDs.firstIndex(of: restoreID) {
                self.appliedRestoreIDs.remove(at: i)
                self.storage.set(self.appliedRestoreIDs.isEmpty ? nil : Self.encode(self.appliedRestoreIDs), self.wsKey(Keys.appliedRestores))
            }
        }
    }

    /// Durable restores refetch on every composer mount (the recovery path
    /// for a missed chat:cancel_finalized).
    func refreshDraftRestores(_ c: ChatUIConversation) {
        guard composerEnabled, !c.id.isEmpty else { return }
        let id = c.id
        Task { [weak self, api] in
            guard let response = try? await api.listChatDraftRestores(sessionId: id), let self else { return }
            c.draftRestores = response.restores
            for r in response.restores where r.chatSessionId == id && self.appliedRestoreIDs.contains(r.id) {
                self.consumeRestore(sessionID: id, restoreID: r.id)
            }
            self.refreshRestoreRequest()
        }
    }

    // MARK: Send / stop

    /// The await-then-render send: nothing is written and the draft is kept
    /// until the server accepts. Returns true when accepted.
    @discardableResult
    public func send(_ content: String, attachmentIDs: [String], attachments: [ChatUIDraftAttachment], draftKey: String?, surface: ChatUISurface) async -> Bool {
        let ctx = context
        guard let agent = ctx.activeAgent, !ctx.isAgentArchived, !ctx.isAgentAccessRevoked else { return false }
        let fromSession = activeSessionID
        if let id = fromSession, let c = conversations[id], c.pending.taskId != nil, c.pending.supportsQueue != true { return false }
        guard ctx.isAgentRuntimeBound else {
            say("input.runtime_required_toast")
            return false
        }
        let snapshot = draftKey.flatMap { drafts[$0] }

        let sessionID: String
        do {
            guard let id = try await ensureSession(title: surface == .page ? ChatUIText.deriveTitle(content) : ChatUIText.floatingTitle(content), agentID: agent.id, projectID: ctx.activeProjectID, from: fromSession) else { return false }
            sessionID = id
        } catch {
            sendFailed(error)
            return false
        }

        let result: SendChatMessageResponse
        do {
            result = try await api.sendChatMessage(sessionId: sessionID, content: content, attachmentIds: attachmentIDs.isEmpty ? nil : attachmentIDs)
        } catch {
            sendFailed(error)
            return false
        }

        let c = conversation(sessionID)
        c.upsert(ChatMessage(id: result.messageId, chatSessionId: sessionID, role: "user", content: content, taskId: result.taskId, createdAt: result.createdAt, attachments: attachments.map(\.attachment)), seedIfMissing: true)
        c.setPending(ChatUIPending.seedAccepted(c.pending, response: result, content: content))
        refreshPending(c, force: true)
        if activeSessionID == fromSession { setActiveSession(sessionID) }
        if let draftKey {
            let live = drafts[draftKey]
            if live == nil || live == snapshot { clearDraft(draftKey) }
        }
        if draftKey != sessionID { clearDraft(sessionID) }

        if c.stopRequestedBeforeTask {
            c.stopRequestedBeforeTask = false
            _ = await cancelChatTask(result.taskId, sessionID: sessionID, restoreDraft: true)
            return false
        }
        if !attachmentIDs.isEmpty, let bound = result.attachmentIds {
            let boundSet = Set(bound)
            if attachmentIDs.contains(where: { !boundSet.contains($0) }) { say("input.attachment_bind_failed_toast") }
        }
        refreshMessages(c, force: true)
        refreshAggregate()
        return true
    }

    private func ensureSession(title: String, agentID: String, projectID: String?, from active: String?) async throws -> String? {
        if let id = active, let s = session, !s.chatSessions.isLoaded || s.chatSessions.item(id) != nil || hasInFlightPending(id) {
            return id
        }
        if let inflight = sessionCreation { return try await inflight.value.id }
        let task = Task { [api] in try await api.createChatSession(agentId: agentID, title: title, projectId: projectID) }
        sessionCreation = task
        defer { sessionCreation = nil }
        let created = try await task.value
        session?.chatSessions.upsert(created)
        scheduleSessionsRefresh()
        return created.id
    }

    private func sendFailed(_ error: Error) {
        switch (error as? APIError)?.reasonCode {
        case "invocation_not_allowed": say("input.send_blocked_toast")
        case "agent_runtime_required": say("input.runtime_required_toast")
        case "runtime_access_denied": say("input.runtime_access_denied_toast")
        default: say("input.send_failed_toast")
        }
    }

    /// Stops the active conversation's running task, restoring its prompt.
    public func stop() {
        guard let sid = activeSessionID, let c = conversations[sid], let taskID = c.pending.taskId else { return }
        guard ChatUIText.isTaskID(taskID) else {
            c.stopRequestedBeforeTask = true
            return
        }
        Task { _ = await cancelChatTask(taskID, sessionID: sid, restoreDraft: true) }
    }

    /// `cancelChatTask`: optimistic removal, server cancel (queued-only when
    /// editing/removing a queued follow-up), prompt restore, convergence.
    @discardableResult
    func cancelChatTask(_ taskID: String, sessionID: String, restoreDraft: Bool, queuedAction explicit: String? = nil) async -> CancelTaskResponse? {
        let c = conversation(sessionID)
        let snapshot = c.pending
        let derived = explicit == nil && restoreDraft && snapshot.taskId == taskID && snapshot.status == "queued" && snapshot.supportsQueue == true
        var queuedAction = explicit ?? (derived ? "edit" : nil)
        c.setPending(ChatUIPending.remove(c.pending, taskID: taskID), loaded: c.pendingLoaded)
        defer {
            refreshPending(c, force: true)
            if queuedAction == "edit" { refreshDraftRestores(c) }
            refreshAggregate()
        }
        do {
            let result: CancelTaskResponse
            do {
                result = try await api.cancelTaskById(taskID, queuedAction: queuedAction, sessionId: queuedAction == nil ? nil : sessionID)
            } catch let e as APIError where derived && e.status == 409 {
                queuedAction = nil
                result = try await api.cancelTaskById(taskID)
            }
            if let restored = result.cancelledChatMessage {
                conversations[restored.chatSessionId]?.remove(messageID: restored.messageId)
                if restored.restoreToInput && queuedAction == nil && restoreDraft && restored.chatSessionId == sessionID {
                    enqueuePendingSendRestore(ChatUIPendingRestore(id: restored.messageId, content: restored.content, attachments: (restored.attachments ?? []).map(ChatUIDraftAttachment.init), sessionID: sessionID))
                }
            }
            refreshMessages(c, force: true)
            return result
        } catch {
            c.setPending(snapshot, loaded: c.pendingLoaded)
            refreshMessages(c, force: true)
            return nil
        }
    }

    // MARK: Queue

    public func editQueued(_ taskID: String) async {
        guard let sid = activeSessionID else { return }
        if await cancelChatTask(taskID, sessionID: sid, restoreDraft: true, queuedAction: "edit") == nil { say("queue.action_failed_toast") }
    }

    public func removeQueued(_ taskID: String) async {
        guard let sid = activeSessionID else { return }
        if await cancelChatTask(taskID, sessionID: sid, restoreDraft: false, queuedAction: "remove") == nil { say("queue.action_failed_toast") }
    }

    public func clearQueued() async {
        guard let sid = activeSessionID else { return }
        let c = conversation(sid)
        do {
            try await api.clearQueuedChatTasks(sessionId: sid)
            for t in c.pending.queuedTasks ?? [] {
                if let m = t.messageId { c.remove(messageID: m) }
            }
            var next = c.pending
            for t in c.pending.queuedTasks ?? [] { next = ChatUIPending.remove(next, taskID: t.taskId) }
            c.setPending(next, loaded: c.pendingLoaded)
        } catch {
            say("queue.action_failed_toast")
        }
        refreshPending(c, force: true)
        refreshMessages(c, force: true)
        refreshAggregate()
    }

    /// "Steer": runs a queued follow-up next and stops the current reply.
    public func sendQueuedNow(_ taskID: String) async {
        guard let sid = activeSessionID else { return }
        let c = conversation(sid)
        let snapshot = c.pending
        c.setPending(ChatUIPending.prioritize(c.pending, taskID: taskID), loaded: c.pendingLoaded)
        var prioritized = false
        do {
            let result = try await api.prioritizeQueuedChatTask(sessionId: sid, taskId: taskID)
            guard result.taskId == taskID else { throw APIError(status: 0, message: "invalid prioritize response") }
            prioritized = true
            if let active = result.activeTaskId, await cancelChatTask(active, sessionID: sid, restoreDraft: true) == nil {
                throw APIError(status: 0, message: "current task could not be stopped")
            }
        } catch {
            if !prioritized { c.setPending(snapshot, loaded: c.pendingLoaded) }
            say((error as? APIError)?.status == 409 ? "queue.steer_unavailable_toast" : "queue.action_failed_toast")
        }
        refreshPending(c, force: true)
    }

    /// Stop from a history row (thread list / session dropdown): optimistic,
    /// no draft restore.
    public func stopFromList(sessionID: String, taskID: String) async {
        pendingBySession[sessionID] = nil
        hasPendingAny = !pendingBySession.isEmpty
        let c = conversation(sessionID)
        c.setPending(ChatUIPending.empty, loaded: c.pendingLoaded)
        refreshMessages(c)
        if let result = try? await api.cancelTaskById(taskID), let restored = result.cancelledChatMessage, restored.restoreToInput {
            conversations[restored.chatSessionId]?.remove(messageID: restored.messageId)
        }
        refreshAggregate(debounce: false)
        refreshPending(c)
    }

    // MARK: Quick actions

    /// Refreshes the latest turn's follow-up suggestions. Throws so the
    /// caller can toast; the pending marker rolls back on failure.
    public func regenerateQuickActions(messageID: String) async throws {
        guard let sid = activeSessionID else { return }
        let c = conversation(sid)
        let previous = c.quickActionsMarker
        setMarker(c, ChatUIQuickActionsMarker(messageID: messageID, taskID: "", expiresAt: Date().addingTimeInterval(Self.quickActionsTimeout)))
        do {
            try await api.regenerateChatQuickActions(sessionId: sid, messageId: messageID)
        } catch {
            c.quickActionsMarker = previous
            throw error
        }
    }

    /// Raises a marker and clears it at its own deadline unless a newer turn
    /// replaced it.
    private func setMarker(_ c: ChatUIConversation, _ marker: ChatUIQuickActionsMarker?) {
        c.quickActionsMarker = marker
        guard let marker else { return }
        Task {
            try? await Task.sleep(for: .seconds(max(0, marker.expiresAt.timeIntervalSinceNow)))
            if c.quickActionsMarker?.messageID == marker.messageID { c.quickActionsMarker = nil }
        }
    }

    // MARK: Session mutations

    private func patchSession(_ id: String, _ change: (inout ChatSession) -> Void) -> ChatSession? {
        guard let s = session, let previous = s.chatSessions.item(id) else { return nil }
        var next = previous
        change(&next)
        s.chatSessions.upsert(next)
        return previous
    }

    private func mutateSession(_ id: String, _ change: (inout ChatSession) -> Void, _ request: @escaping @Sendable () async throws -> Void) {
        let previous = patchSession(id, change)
        Task { [weak self] in
            do {
                try await request()
            } catch {
                if let previous { self?.session?.chatSessions.upsert(previous) }
            }
            self?.scheduleSessionsRefresh()
        }
    }

    public func rename(_ id: String, to raw: String) {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != session?.chatSessions.item(id)?.title else { return }
        mutateSession(id, { $0.title = title }) { [api] in _ = try await api.updateChatSession(id, title: title) }
    }

    public func setPinned(_ id: String, _ pinned: Bool) {
        mutateSession(id, { $0.pinned = pinned }) { [api] in _ = try await api.setChatSessionPinned(id, pinned: pinned) }
    }

    /// Archive zeroes unread at once so no badge counts a just-archived chat.
    public func setArchived(_ id: String, _ archived: Bool) {
        let now = Self.isoNow()
        mutateSession(id, { s in
            s.status = archived ? "archived" : "active"
            s.updatedAt = now
            if archived {
                s.unreadCount = 0
                s.hasUnread = false
            }
        }) { [api] in _ = try await api.setChatSessionArchived(id, archived: archived) }
    }

    public func delete(_ id: String) async -> Bool {
        if activeSessionID == id { setActiveSession(nil) }
        let previous = session?.chatSessions.item(id)
        session?.chatSessions.remove(id)
        do {
            try await api.deleteChatSession(id)
            conversations[id] = nil
            scheduleSessionsRefresh()
            return true
        } catch {
            if let previous { session?.chatSessions.upsert(previous) }
            scheduleSessionsRefresh()
            return false
        }
    }

    func setSessionProject(_ id: String, projectID: String?) {
        projectUpdateInFlight = true
        let previous = patchSession(id) { $0.projectId = projectID }
        Task { [weak self, api] in
            do {
                _ = try await api.updateChatSession(id, projectId: projectID)
            } catch {
                if let previous { self?.session?.chatSessions.upsert(previous) }
            }
            self?.projectUpdateInFlight = false
            self?.scheduleSessionsRefresh()
        }
    }

    /// Clears unread for the session the user is looking at.
    public func markRead(_ id: String) {
        guard !markingRead.contains(id), let current = session?.chatSessions.item(id), current.hasUnread || (current.unreadCount ?? 0) > 0 else { return }
        markingRead.insert(id)
        let previous = patchSession(id) {
            $0.hasUnread = false
            $0.unreadCount = 0
        }
        Task { [weak self, api] in
            do {
                try await api.markChatSessionRead(sessionId: id)
            } catch {
                if let previous { self?.session?.chatSessions.upsert(previous) }
            }
            self?.markingRead.remove(id)
            self?.scheduleSessionsRefresh()
        }
    }

    nonisolated static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private func scheduleSessionsRefresh() {
        sessionsRefresh?.cancel()
        sessionsRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.session?.chatSessions.refreshIfLoaded()
        }
    }

    // MARK: Pending aggregate

    /// The thread list / history dropdown show per-session running state.
    public func retainAggregate() {
        aggregateDemand += 1
        if aggregateDemand == 1 && aggregateStale { refreshAggregate(debounce: false) }
    }

    public func releaseAggregate() { aggregateDemand = max(0, aggregateDemand - 1) }

    /// The minimised launcher only needs a boolean.
    public func retainHasPending() {
        hasAnyDemand += 1
        if hasAnyDemand == 1 && hasAnyStale { refreshAggregate(debounce: false) }
    }

    public func releaseHasPending() { hasAnyDemand = max(0, hasAnyDemand - 1) }

    /// Authoritative refetch (never patched from fan-out events, which carry
    /// no creator visibility), debounced across lifecycle bursts.
    func refreshAggregate(debounce: Bool = true) {
        aggregateStale = true
        hasAnyStale = true
        guard aggregateDemand > 0 || hasAnyDemand > 0 else { return }
        aggregateTimer?.cancel()
        aggregateTimer = Task { [weak self, api] in
            if debounce { try? await Task.sleep(for: .milliseconds(750)) }
            guard !Task.isCancelled, let self else { return }
            if self.aggregateDemand > 0 {
                guard let response = try? await api.listPendingChatTasks() else { return }
                let map = Dictionary(response.tasks.map { ($0.chatSessionId, $0) }, uniquingKeysWith: { a, _ in a })
                if map != self.pendingBySession { self.pendingBySession = map }
                self.hasPendingAny = !map.isEmpty
                self.aggregateStale = false
                self.hasAnyStale = false
            } else {
                guard let response = try? await api.hasAnyPendingChatTasks() else { return }
                self.hasPendingAny = response.hasPending
                self.hasAnyStale = false
            }
        }
    }

    // MARK: Realtime

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) -> T? {
        guard let data = try? JSONCoders.encoder.encode(value) else { return nil }
        return try? JSONCoders.decoder.decode(T.self, from: data)
    }

    func handle(_ event: RealtimeEvent) {
        switch event {
        case .resource(let type, let payload) where type.hasPrefix("chat:"):
            handleChat(type, payload)
        case .taskLifecycle(let e):
            if let sid = e.chatSessionID, !sid.isEmpty { handleLifecycle(e, sessionID: sid) }
        case .connection(.connected(recovered: true)):
            recoverAfterReconnect()
        default:
            break
        }
    }

    private func handleChat(_ type: String, _ payload: JSONValue) {
        switch type {
        case "chat:message":
            guard let p = decode(ChatMessageEventPayload.self, payload) else { return }
            guard let c = conversations[p.chatSessionId] else { return }
            if p.role == "user" && !p.messageId.isEmpty {
                c.upsert(ChatMessage(id: p.messageId, chatSessionId: p.chatSessionId, role: "user", content: p.content, taskId: p.taskId, createdAt: p.createdAt.isEmpty ? Self.isoNow() : p.createdAt), seedIfMissing: false)
            }
            refreshMessages(c)
            refreshPending(c)
        case "chat:done":
            guard let p = decode(ChatDonePayload.self, payload) else { return }
            applyDone(p)
        case "chat:quick_actions":
            guard let p = decode(ChatQuickActionsPayload.self, payload), let c = conversations[p.chatSessionId] else { return }
            let actions = p.quickActions ?? []
            if !actions.isEmpty {
                c.patchQuickActions(messageID: p.messageId, actions: actions)
                refreshMessages(c)
            }
            if c.quickActionsMarker == nil || c.quickActionsMarker?.messageID == p.messageId { c.quickActionsMarker = nil }
            if p.failed == true { c.quickActionsFailure += 1 }
        case "chat:cancel_finalized":
            guard let p = decode(ChatCancelFinalizedPayload.self, payload), !p.chatSessionId.isEmpty else { return }
            if p.outcome == "stopped" {
                applyDone(ChatDonePayload(chatSessionId: p.chatSessionId, taskId: p.taskId, messageId: p.messageId, content: p.content, elapsedMs: p.elapsedMs, createdAt: p.createdAt, messageKind: p.messageKind))
            } else if p.outcome == "restored", let c = conversations[p.chatSessionId] {
                if let m = p.messageId { c.remove(messageID: m) }
                c.setPending(ChatUIPending.remove(c.pending, taskID: p.taskId), loaded: c.pendingLoaded)
                refreshMessages(c)
                refreshPending(c)
                if let initiator = p.initiatorUserId, initiator == userID { refreshDraftRestores(c) }
            }
        case "chat:session_updated":
            guard let id = payload["chat_session_id"]?.stringValue else { return }
            _ = patchSession(id) { s in
                if let t = payload["title"]?.stringValue { s.title = t }
                if let p = payload["project_id"] { s.projectId = p.stringValue }
                if case .bool(let pinned)? = payload["pinned"] { s.pinned = pinned }
                if let status = payload["status"]?.stringValue {
                    s.status = status
                    if status == "archived" {
                        s.unreadCount = 0
                        s.hasUnread = false
                    }
                }
                if let at = payload["updated_at"]?.stringValue { s.updatedAt = at }
            }
        case "chat:session_deleted":
            guard let id = payload["chat_session_id"]?.stringValue else { return }
            conversations[id] = nil
            if activeSessionID == id { setActiveSession(nil) }
            refreshAggregate()
        default:
            break
        }
    }

    private func applyDone(_ p: ChatDonePayload) {
        guard let c = conversations[p.chatSessionId] else { return }
        if let messageID = p.messageId, p.content != nil || !(p.quickActions ?? []).isEmpty {
            c.upsert(ChatMessage(id: messageID, chatSessionId: p.chatSessionId, role: "assistant", content: p.content ?? "", taskId: p.taskId, createdAt: p.createdAt ?? Self.isoNow(), elapsedMs: p.elapsedMs, messageKind: p.messageKind ?? "message", quickActions: p.quickActions), seedIfMissing: false)
        }
        c.setPending(ChatUIPending.remove(c.pending, taskID: p.taskId), loaded: c.pendingLoaded)
        if p.quickActionsPending == true, let messageID = p.messageId {
            setMarker(c, ChatUIQuickActionsMarker(messageID: messageID, taskID: p.taskId, expiresAt: Date().addingTimeInterval(Self.quickActionsTimeout)))
        } else {
            c.quickActionsMarker = nil
        }
        refreshMessages(c)
        refreshPending(c)
    }

    private func handleLifecycle(_ e: TaskLifecycle, sessionID: String) {
        let c = conversations[sessionID]
        switch e.status {
        case .queued:
            if let c { refreshPending(c) }
        case .dispatched, .running, .waitingLocalDirectory:
            if let c {
                let status = e.status == .waitingLocalDirectory ? "waiting_local_directory" : "running"
                c.setPending(ChatUIPending.promote(c.pending, taskID: e.taskID, status: status, waitReason: e.waitReason), loaded: c.pendingLoaded)
                refreshMessages(c)
                refreshPending(c)
            }
        case .completed:
            if let c {
                c.setPending(ChatUIPending.remove(c.pending, taskID: e.taskID), loaded: c.pendingLoaded)
                refreshPending(c)
            }
        case .failed, .cancelled:
            if let c {
                c.setPending(ChatUIPending.remove(c.pending, taskID: e.taskID), loaded: c.pendingLoaded)
                refreshPending(c)
                refreshMessages(c)
            }
            scheduleSessionsRefresh()
        default:
            if let c { refreshPending(c) }
        }
        refreshAggregate()
    }

    /// Refetch only what is on screen; everything else goes stale.
    private func recoverAfterReconnect() {
        scheduleSessionsRefresh()
        for c in conversations.values {
            refreshMessages(c)
            refreshPending(c)
            if c.viewers > 0 { refreshDraftRestores(c) }
        }
        if let session {
            for t in timelines.values where t.isLive {
                if let transcript = t.transcript { Task { await session.backfill(transcript) } }
            }
        }
        refreshAggregate(debounce: false)
    }
}

extension ChatUIStore {
    private static var instances: [ObjectIdentifier: ChatUIStore] = [:]

    static func shared(for session: WorkspaceSession) -> ChatUIStore {
        let key = ObjectIdentifier(session)
        if let s = instances[key], s.session === session { return s }
        instances = instances.filter { $0.value.session != nil }
        let s = ChatUIStore(session: session, storage: ChatUIUserDefaultsStorage())
        instances[key] = s
        return s
    }
}

extension WorkspaceSession {
    /// The chat store of this workspace session, created on first use.
    public var chatUI: ChatUIStore { ChatUIStore.shared(for: self) }
}
