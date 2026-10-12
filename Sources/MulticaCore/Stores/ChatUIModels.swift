import Foundation
import Observation

/// Key-value persistence for chat preferences and drafts (UserDefaults in
/// the app, memory in tests).
@MainActor
public protocol ChatUIStorage: AnyObject {
    func string(_ key: String) -> String?
    func set(_ value: String?, _ key: String)
}

@MainActor
public final class ChatUIUserDefaultsStorage: ChatUIStorage {
    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(_ key: String) -> String? { defaults.string(forKey: key) }

    public func set(_ value: String?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

@MainActor
public final class ChatUIMemoryStorage: ChatUIStorage {
    public private(set) var values: [String: String] = [:]

    public init() {}

    public func string(_ key: String) -> String? { values[key] }
    public func set(_ value: String?, _ key: String) { values[key] = value }
}

/// A completed upload staged in a draft (the persisted subset of
/// `Attachment`).
public struct ChatUIDraftAttachment: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var filename: String
    public var url: String
    public var downloadUrl: String
    public var markdownUrl: String
    public var contentType: String
    public var sizeBytes: Int

    public init(_ a: Attachment) {
        id = a.id
        filename = a.filename
        url = a.url
        downloadUrl = a.downloadUrl
        markdownUrl = a.markdownUrl
        contentType = a.contentType
        sizeBytes = a.sizeBytes
    }

    public var attachment: Attachment {
        Attachment(id: id, filename: filename, url: url, downloadUrl: downloadUrl, markdownUrl: markdownUrl, contentType: contentType, sizeBytes: sizeBytes)
    }
}

/// A restore with no server copy (a failed send, or a cancel that answered
/// synchronously). Its text exists nowhere else, so it is persisted until a
/// composer applies it.
public struct ChatUIPendingRestore: Codable, Sendable, Hashable {
    public var id: String
    public var content: String
    public var attachments: [ChatUIDraftAttachment]
    public var sessionID: String
}

/// A draft the visible composer is asked to adopt (`RestoreDraftRequest`).
public struct ChatUIRestoreRequest: Sendable, Hashable {
    public var id: String
    public var content: String
    public var attachments: [ChatUIDraftAttachment]
    public var sessionID: String
    /// Set for durable restores: the server row to consume once applied.
    public var serverRestoreID: String?
}

/// Client-only marker: this turn's quick-actions supplement is in flight.
public struct ChatUIQuickActionsMarker: Sendable, Hashable {
    public var messageID: String
    public var taskID: String
    public var expiresAt: Date
}

/// Which surface a chat action comes from; the floating window and the chat
/// tab seed new-session titles differently upstream.
public enum ChatUISurface: Sendable {
    case page, floating
}

/// Everything a chat surface derives from catalogs and selection
/// (`useChatController`), recomputed only when an input changes.
public struct ChatUIContext: Equatable, Sendable {
    public var currentSession: ChatSession?
    public var activeAgent: AgentRecord?
    public var availableAgents: [AgentRecord] = []
    public var agents: [AgentRecord] = []
    public var isSessionArchived = false
    public var isAgentArchived = false
    public var isAgentAccessRevoked = false
    public var isAgentRuntimeBound = false
    public var activeProjectID: String?
    /// Settled and confirmed: no agent this member may chat with.
    public var noAgent = false
    /// Agents and members both loaded (permission verdicts are trustworthy).
    public var agentsSettled = false
    public var memberRole: String?
    /// nil while presence inputs load, so banners stay silent.
    public var availability: String?
    /// The active agent's daemon cannot inject project context (soft gate).
    public var projectContextUnsupported = false
    public var canEditActiveAgent = false
    /// The open session's row has not loaded yet (or its project update is in
    /// flight); project selection stays locked.
    public var isProjectUpdating = false

    public init() {}

    public var inputDisabled: Bool {
        isSessionArchived || isAgentArchived || isAgentAccessRevoked || !isAgentRuntimeBound
    }
}

/// One chat session's transcript, pending task and per-turn markers
/// (upstream: the messages-page, pending-task, quick-actions and
/// draft-restores query caches for that session).
@MainActor
@Observable
public final class ChatUIConversation: Identifiable {
    public let id: String
    public private(set) var messages: [ChatMessage] = []
    /// `messages` minus queued follow-ups (they render in the queue).
    public private(set) var visibleMessages: [ChatMessage] = []
    public private(set) var messagesLoaded = false
    public private(set) var hasOlder = false
    public internal(set) var isFetchingOlder = false
    /// Messages that came from older pages (keeps the scroll anchor).
    public private(set) var olderCount = 0
    public private(set) var pending = ChatUIPending.empty
    public private(set) var pendingLoaded = false
    public internal(set) var quickActionsMarker: ChatUIQuickActionsMarker?
    /// Bumped when an accepted quick-actions refresh later failed.
    public internal(set) var quickActionsFailure = 0
    public private(set) var latestAssistantMessageID: String?
    public private(set) var starterCardsMessageID: String?

    @ObservationIgnored var draftRestores: [ChatDraftRestore] = []
    @ObservationIgnored var olderCursor: ChatMessagesCursor?
    @ObservationIgnored var viewers = 0
    @ObservationIgnored var messagesStale = true
    @ObservationIgnored var pendingStale = true
    @ObservationIgnored var messagesInflight = false
    @ObservationIgnored var messagesRerun = false
    @ObservationIgnored var pendingInflight = false
    @ObservationIgnored var pendingRerun = false
    @ObservationIgnored var stopRequestedBeforeTask = false

    init(id: String) {
        self.id = id
    }

    public var pendingTaskID: String? { pending.taskId }

    /// The assistant reply for the pending task already landed; it owns the
    /// rendering and the live row/pill step aside.
    public var pendingAlreadyPersisted: Bool {
        guard let id = pending.taskId else { return false }
        return visibleMessages.contains { $0.role == "assistant" && $0.taskId == id }
    }

    public var hasContent: Bool { !visibleMessages.isEmpty || pending.taskId != nil }

    func setMessages(_ list: [ChatMessage], loaded: Bool = true) {
        if list != messages { messages = list }
        if loaded && !messagesLoaded { messagesLoaded = true }
        recompute()
    }

    func setPage(_ page: ChatMessagesPage) {
        let merged = ChatUIMessages.reconcile(held: messages, page: page)
        if olderCount == 0 {
            olderCursor = page.nextCursor
            if hasOlder != page.hasMore { hasOlder = page.hasMore }
        }
        setMessages(merged)
    }

    func prependOlder(_ page: ChatMessagesPage) {
        let next = ChatUIMessages.prepend(messages, older: page.messages)
        olderCount += next.count - messages.count
        olderCursor = page.nextCursor
        hasOlder = page.hasMore
        setMessages(next)
    }

    func upsert(_ message: ChatMessage, seedIfMissing: Bool) {
        guard messagesLoaded || seedIfMissing else { return }
        setMessages(ChatUIMessages.upsert(messages, message))
    }

    func remove(messageID: String) {
        guard messages.contains(where: { $0.id == messageID }) else { return }
        setMessages(messages.filter { $0.id != messageID }, loaded: messagesLoaded)
    }

    func patchQuickActions(messageID: String, actions: [ChatQuickAction]) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        var next = messages
        next[i].quickActions = actions
        setMessages(next, loaded: messagesLoaded)
    }

    func setPending(_ p: ChatPendingTask, loaded: Bool = true) {
        if p != pending { pending = p }
        if loaded && !pendingLoaded { pendingLoaded = true }
        recompute()
    }

    private func recompute() {
        let visible = ChatUIPending.hideQueued(messages, pending: pending)
        if visible != visibleMessages { visibleMessages = visible }
        let latest = visible.last { $0.role == "assistant" && $0.taskId != nil }?.id
        if latest != latestAssistantMessageID { latestAssistantMessageID = latest }
        let starter = visible.first { $0.role == "assistant" && $0.messageKind == "onboarding_opening" }?.id
        if starter != starterCardsMessageID { starterCardsMessageID = starter }
    }
}

/// The process timeline of one chat task. A live task follows the shared
/// transcript (realtime frames, backfill, repair); a settled one is fetched
/// once and cached.
@MainActor
@Observable
public final class ChatUITaskTimeline: Identifiable {
    public let id: String
    public private(set) var items: [ChatUITimelineItem] = []
    public private(set) var preface: [ChatUITimelineItem] = []
    public private(set) var middle: [ChatUITimelineItem] = []
    public private(set) var final: [ChatUITimelineItem] = []
    /// Joined, protocol-stripped text of `preface` / `final`.
    public private(set) var prefaceText = ""
    public private(set) var finalText = ""
    public private(set) var isLoaded = false
    public private(set) var hasMessages = false
    /// Newest message that is neither an error nor a tool result (drives the
    /// status pill stage).
    public private(set) var latestKind: TaskMessageKind?
    public private(set) var latestTool: String?

    @ObservationIgnored var builder = ChatUITimelineBuilder()
    @ObservationIgnored var messages: [TaskMessage] = []
    @ObservationIgnored var transcript: TranscriptModel?
    @ObservationIgnored var liveCount = 0
    @ObservationIgnored var loading = false
    @ObservationIgnored var settled = false

    init(id: String) {
        self.id = id
    }

    public var isLive: Bool { liveCount > 0 }

    func apply(_ source: [TaskMessage], generation: Int) {
        messages = source
        guard builder.sync(source, generation: generation) else { return }
        publish(source)
    }

    /// Takes a timeline built off the main actor.
    func adopt(_ built: ChatUITimelineBuilder, messages source: [TaskMessage]) {
        builder = built
        messages = source
        publish(source)
    }

    private func publish(_ source: [TaskMessage]) {
        let next = builder.items
        items = next
        let parts = ChatUITimeline.split(next)
        preface = parts.preface
        middle = parts.middle
        final = parts.final
        prefaceText = ChatUITimeline.stripQuickActionsProtocol(parts.preface.map(\.content).joined())
        finalText = ChatUITimeline.stripQuickActionsProtocol(parts.final.map(\.content).joined())
        hasMessages = !source.isEmpty
        if let latest = source.last(where: { $0.kind != .error && $0.kind != .toolResult }) {
            latestKind = latest.kind
            latestTool = latest.tool
        } else {
            latestKind = nil
            latestTool = nil
        }
    }

    func markLoaded() {
        if !isLoaded { isLoaded = true }
    }
}
