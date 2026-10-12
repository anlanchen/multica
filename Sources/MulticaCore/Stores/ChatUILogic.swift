import Foundation

// Pure chat logic shared by the chat store and both chat surfaces. Each
// function mirrors the upstream helper named in its doc comment.

/// Pending-task queue transitions (packages/core/chat/pending.ts).
public enum ChatUIPending {
    public static let empty = ChatPendingTask()

    static func compare(_ a: ChatQueuedTask, _ b: ChatQueuedTask) -> Bool {
        if let l = Timestamp.parse(a.createdAt), let r = Timestamp.parse(b.createdAt), l != r {
            return l < r
        }
        return a.taskId < b.taskId
    }

    /// The send response carries the message preview while `task:queued` is
    /// sparse; keep whichever observation is rich regardless of arrival order.
    static func unique(_ tasks: [ChatQueuedTask]) -> [ChatQueuedTask] {
        var order: [String] = []
        var byID: [String: ChatQueuedTask] = [:]
        for t in tasks {
            if byID[t.taskId] == nil {
                order.append(t.taskId)
                byID[t.taskId] = t
            } else if t.messageId != nil {
                byID[t.taskId] = t
            }
        }
        return order.compactMap { byID[$0] }
    }

    static func normalize(_ tasks: [ChatQueuedTask]) -> [ChatQueuedTask] {
        unique(tasks).sorted(by: compare)
    }

    static func summary(_ task: ChatPendingTask) -> ChatQueuedTask? {
        guard let id = task.taskId else { return nil }
        return ChatQueuedTask(taskId: id, status: task.status ?? "queued", createdAt: task.createdAt ?? "")
    }

    static func head(_ task: ChatQueuedTask, supportsQueue: Bool?, queue: [ChatQueuedTask]) -> ChatPendingTask {
        ChatPendingTask(taskId: task.taskId, status: task.status, createdAt: task.createdAt, supportsQueue: supportsQueue, queuedTasks: queue)
    }

    /// `enqueuePendingChatTask`: records an accepted send as the head (idle
    /// session) or behind the in-flight head (queued follow-up).
    public static func enqueue(_ current: ChatPendingTask?, _ task: ChatQueuedTask, queued: Bool? = nil) -> ChatPendingTask {
        let queued = queued ?? (current?.taskId != nil && current?.taskId != task.taskId)
        guard let current, let headID = current.taskId else {
            let existing = current?.queuedTasks ?? []
            if queued {
                return ChatPendingTask(supportsQueue: current?.supportsQueue, queuedTasks: normalize(existing + [task]))
            }
            return head(task, supportsQueue: current?.supportsQueue, queue: normalize(existing.filter { $0.taskId != task.taskId }))
        }
        if headID == task.taskId {
            var next = current
            if let s = current.status, s != "queued" { next.status = s } else { next.status = task.status }
            next.createdAt = (current.createdAt ?? "").isEmpty ? task.createdAt : current.createdAt
            next.queuedTasks = (current.queuedTasks ?? []).filter { $0.taskId != task.taskId }
            return next
        }
        if !queued {
            return head(task, supportsQueue: current.supportsQueue, queue: [])
        }
        var next = current
        next.queuedTasks = normalize((current.queuedTasks ?? []) + [task])
        return next
    }

    /// A hold explanation outlives the hold: only the waiting status keeps it.
    static func waitReason(_ status: String, _ incoming: String?, _ existing: String?) -> String? {
        status == "waiting_local_directory" ? (incoming ?? existing) : nil
    }

    /// `promotePendingChatTask`: a lifecycle hint moves the head (or a queued
    /// task) into `status`. Unknown tasks never synthesize a new head.
    public static func promote(_ current: ChatPendingTask?, taskID: String, status: String, createdAt: String? = nil, waitReason incoming: String? = nil) -> ChatPendingTask {
        let queue = current?.queuedTasks ?? []
        if let current, current.taskId == taskID {
            var next = current
            next.status = status
            next.waitReason = waitReason(status, incoming, current.waitReason)
            next.queuedTasks = queue.filter { $0.taskId != taskID }
            return next
        }
        guard let current, current.taskId != nil, let promoted = queue.first(where: { $0.taskId == taskID }) else {
            return current ?? empty
        }
        var rest: [ChatQueuedTask] = []
        if let previous = summary(current), previous.status == "queued" { rest.append(previous) }
        rest += queue.filter { $0.taskId != taskID }
        return ChatPendingTask(
            taskId: promoted.taskId,
            status: status,
            createdAt: promoted.createdAt.isEmpty ? (createdAt ?? "") : promoted.createdAt,
            waitReason: waitReason(status, incoming, nil),
            supportsQueue: current.supportsQueue,
            queuedTasks: unique(rest)
        )
    }

    /// `removePendingChatTask`: drops a finished task; the next queued task
    /// becomes the head.
    public static func remove(_ current: ChatPendingTask?, taskID: String) -> ChatPendingTask {
        guard let current, let headID = current.taskId else { return empty }
        if headID != taskID {
            var next = current
            next.queuedTasks = (current.queuedTasks ?? []).filter { $0.taskId != taskID }
            return next
        }
        let remaining = unique((current.queuedTasks ?? []).filter { $0.taskId != taskID })
        guard let first = remaining.first else { return empty }
        return head(first, supportsQueue: current.supportsQueue, queue: Array(remaining.dropFirst()))
    }

    /// `prioritizePendingChatTask`: moves one queued task to the front.
    public static func prioritize(_ current: ChatPendingTask?, taskID: String) -> ChatPendingTask {
        guard let current, current.taskId != nil else { return empty }
        let queue = current.queuedTasks ?? []
        guard let selected = queue.first(where: { $0.taskId == taskID }) else { return current }
        var next = current
        next.queuedTasks = [selected] + queue.filter { $0.taskId != taskID }
        return next
    }

    /// `hideQueuedChatMessages`: a queued follow-up renders in the queue, not
    /// in the transcript, until it starts.
    public static func hideQueued(_ messages: [ChatMessage], pending: ChatPendingTask?) -> [ChatMessage] {
        var hidden: [String: String] = [:]
        for t in pending?.queuedTasks ?? [] {
            if let m = t.messageId { hidden[m] = t.taskId }
        }
        guard !hidden.isEmpty else { return messages }
        return messages.filter { m in
            guard let task = hidden[m.id] else { return true }
            return task != m.taskId
        }
    }

    /// Seeds the head from an accepted send (`seedAcceptedPendingTask`).
    public static func seedAccepted(_ current: ChatPendingTask?, response: SendChatMessageResponse, content: String) -> ChatPendingTask {
        var next = enqueue(current, ChatQueuedTask(taskId: response.taskId, status: "queued", createdAt: response.createdAt, messageId: response.messageId, content: content), queued: response.queued)
        if response.supportsQueue == true || current?.supportsQueue == true { next.supportsQueue = true }
        return next
    }
}

/// Message cache rules (packages/core/chat/message-cache.ts): identity is the
/// id, and on merge the row already held wins every field it defines.
public enum ChatUIMessages {
    public static func merge(_ existing: ChatMessage, _ incoming: ChatMessage) -> ChatMessage {
        var m = existing
        if m.taskId == nil { m.taskId = incoming.taskId }
        if m.attachments == nil { m.attachments = incoming.attachments }
        if m.failureReason == nil { m.failureReason = incoming.failureReason }
        if m.elapsedMs == nil { m.elapsedMs = incoming.elapsedMs }
        if m.messageKind == nil { m.messageKind = incoming.messageKind }
        if m.quickActions == nil { m.quickActions = incoming.quickActions }
        if m.content.isEmpty { m.content = incoming.content }
        if m.createdAt.isEmpty { m.createdAt = incoming.createdAt }
        return m
    }

    /// Merges into the row with this id, or appends a new one.
    public static func upsert(_ list: [ChatMessage], _ message: ChatMessage) -> [ChatMessage] {
        guard let i = list.firstIndex(where: { $0.id == message.id }) else { return list + [message] }
        let merged = merge(list[i], message)
        if merged == list[i] { return list }
        var next = list
        next[i] = merged
        return next
    }

    /// Reconciles a fresh newest page with what is held: the server is
    /// authoritative inside the page's window, older pages already loaded are
    /// kept, and rows newer than the snapshot (written by a send or a live
    /// event while the request was in flight) survive.
    public static func reconcile(held: [ChatMessage], page: ChatMessagesPage) -> [ChatMessage] {
        let fresh = page.messages
        guard !held.isEmpty else { return fresh }
        let ids = Set(fresh.map(\.id))
        let windowStart = page.hasMore ? fresh.first.flatMap { Timestamp.parse($0.createdAt) } : nil
        let snapshotEnd = fresh.last.flatMap { Timestamp.parse($0.createdAt) }
        var older: [ChatMessage] = []
        var newer: [ChatMessage] = []
        for m in held where !ids.contains(m.id) {
            let at = Timestamp.parse(m.createdAt)
            if let start = windowStart, let at, at < start {
                older.append(m)
            } else if let at, let end = snapshotEnd, at > end {
                newer.append(m)
            } else if fresh.isEmpty {
                newer.append(m)
            }
        }
        return older + fresh + newer
    }

    public static func prepend(_ list: [ChatMessage], older: [ChatMessage]) -> [ChatMessage] {
        let ids = Set(list.map(\.id))
        return older.filter { !ids.contains($0.id) } + list
    }
}

/// One entry of an assistant turn's process timeline (upstream
/// `ChatTimelineItem`): text and thinking fragments are coalesced, tool calls
/// and results stay separate rows.
public struct ChatUITimelineItem: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case toolUse = "tool_use", toolResult = "tool_result", thinking, text, error
    }

    public var seq: Int
    public var kind: Kind
    public var tool: String?
    public var content: String
    public var input: JSONValue?
    public var output: String?

    public var id: Int { seq }

    public init(seq: Int, kind: Kind, tool: String? = nil, content: String = "", input: JSONValue? = nil, output: String? = nil) {
        self.seq = seq
        self.kind = kind
        self.tool = tool
        self.content = content
        self.input = input
        self.output = output
    }
}

/// Builds the coalesced timeline from seq-ordered task messages
/// (`buildTimeline`). Appending messages only touches the tail, so a live
/// run's 100 ms flush costs O(batch) however long the transcript is.
public struct ChatUITimelineBuilder: Sendable {
    public private(set) var items: [ChatUITimelineItem] = []
    private var processedCount = 0
    private var lastSeq: Int?
    private var generation = -1

    public init() {}

    /// Folds `messages` (sorted, unique by seq). `generation` changes when the
    /// source rewrote history; a different generation forces a rebuild.
    @discardableResult
    public mutating func sync(_ messages: [TaskMessage], generation: Int = 0) -> Bool {
        let appendable = generation == self.generation
            && messages.count >= processedCount
            && (processedCount == 0 || messages[processedCount - 1].seq == lastSeq)
        if !appendable {
            items.removeAll(keepingCapacity: true)
            processedCount = 0
            self.generation = generation
        }
        guard messages.count > processedCount else { return !appendable }
        for m in messages[processedCount...] { append(m) }
        processedCount = messages.count
        lastSeq = messages.last?.seq
        return true
    }

    public static func build(_ messages: [TaskMessage]) -> [ChatUITimelineItem] {
        var b = ChatUITimelineBuilder()
        b.sync(messages.sorted { $0.seq < $1.seq })
        return b.items
    }

    private mutating func append(_ m: TaskMessage) {
        guard let kind = ChatUITimelineItem.Kind(rawValue: m.kind.rawValue) else { return }
        if (kind == .text || kind == .thinking), let last = items.last, last.kind == kind {
            items[items.count - 1].content += m.content ?? ""
            return
        }
        items.append(ChatUITimelineItem(seq: m.seq, kind: kind, tool: m.tool, content: m.content ?? "", input: m.input, output: m.output))
    }
}

/// Timeline regions and answer text (packages/views/chat/lib/copy-text.ts,
/// quick-actions.ts).
public enum ChatUITimeline {
    /// preface — text before the first non-text item; middle — first through
    /// last non-text item; final — text after the last non-text item.
    public static func split(_ items: [ChatUITimelineItem]) -> (preface: [ChatUITimelineItem], middle: [ChatUITimelineItem], final: [ChatUITimelineItem]) {
        guard let first = items.firstIndex(where: { $0.kind != .text }) else { return ([], [], items) }
        let last = items.lastIndex(where: { $0.kind != .text }) ?? first
        return (Array(items[..<first]), Array(items[first...last]), Array(items[(last + 1)...]))
    }

    /// Hides the reserved trailing ```quick-actions fence while a reply
    /// streams. A fence followed by more prose was an ordinary example.
    public static func stripQuickActionsProtocol(_ content: String) -> String {
        guard content.contains("```quick-actions") else { return content }
        let ns = content as NSString
        guard let opener = try? NSRegularExpression(pattern: "(?:^|\\r?\\n)```quick-actions(?:\\r?\\n|$)"),
              let match = opener.matches(in: content, range: NSRange(location: 0, length: ns.length)).last else {
            return content
        }
        let footerStart = match.range.location
        let bodyStart = match.range.location + match.range.length
        let body = ns.substring(from: bodyStart)
        if let closer = try? NSRegularExpression(pattern: "\\r?\\n```"),
           let fence = closer.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) {
            let after = (body as NSString).substring(from: fence.range.location + fence.range.length)
            if !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return content }
        }
        return trimEnd(ns.substring(to: footerStart))
    }

    static func trimEnd(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            guard s[prev].isWhitespace else { break }
            end = prev
        }
        return String(s[..<end])
    }

    /// The persisted message is authoritative for a completed answer.
    public static func canonicalAnswer(_ message: ChatMessage) -> String {
        stripQuickActionsProtocol(message.content)
    }

    /// Markdown source for Copy; legacy empty rows fall back to the visible
    /// transcript text.
    public static func copyText(_ message: ChatMessage, items: [ChatUITimelineItem]) -> String {
        let canonical = canonicalAnswer(message)
        if !canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return canonical }
        let parts = split(items)
        return (parts.preface + parts.final).map(\.content).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// Status pill stage decision (task-status-pill.tsx `pickStageKeys`).
public struct ChatUIStage: Sendable, Equatable {
    public enum Key: String, Sendable {
        case offline, reconnecting, retrying, queued
        case waitingLocalDirectory = "waiting_local_directory"
        case startingUp = "starting_up"
        case thinking, typing
    }

    public enum Tool: String, Sendable {
        case runningCommand = "running_command", readingFiles = "reading_files", searchingCode = "searching_code"
        case makingEdits = "making_edits", searchingWeb = "searching_web", fallback
    }

    public var key: Key
    public var tool: Tool?
    public var isStatic = false
    public var needsWaitReason = false

    static let toolBySlug: [String: Tool] = [
        "bash": .runningCommand, "exec": .runningCommand,
        "read": .readingFiles, "glob": .readingFiles,
        "grep": .searchingCode,
        "write": .makingEdits, "edit": .makingEdits, "multi_edit": .makingEdits, "multiedit": .makingEdits,
        "web_search": .searchingWeb, "websearch": .searchingWeb,
    ]

    /// `latest` is the newest message that is neither an error nor a tool
    /// result.
    public static func pick(status: String?, latest: (kind: TaskMessageKind, tool: String?)?, availability: String?) -> ChatUIStage {
        if status == "deferred" { return ChatUIStage(key: .retrying) }
        let waiting = status == "queued" || status == "dispatched"
        if waiting && availability == "offline" { return ChatUIStage(key: .offline, isStatic: true) }
        if waiting && availability == "unstable" { return ChatUIStage(key: .reconnecting) }
        if status == "waiting_local_directory" {
            return ChatUIStage(key: .waitingLocalDirectory, isStatic: true, needsWaitReason: true)
        }
        if status == "queued" { return ChatUIStage(key: .queued) }
        if status == "dispatched" { return ChatUIStage(key: .startingUp) }
        guard let latest else { return ChatUIStage(key: .thinking) }
        switch latest.kind {
        case .text: return ChatUIStage(key: .typing)
        case .toolUse: return ChatUIStage(key: .thinking, tool: toolBySlug[(latest.tool ?? "").lowercased()] ?? .fallback)
        default: return ChatUIStage(key: .thinking)
        }
    }

    /// Streamed messages prove a task started, unless the server has since
    /// moved it into retry backoff.
    public static func effectiveStatus(_ status: String?, hasMessages: Bool) -> String? {
        if status == "deferred" { return status }
        return hasMessages ? "running" : status
    }
}

/// Agent gates shared by every chat surface.
public enum ChatUIAgents {
    /// `isAgentRuntimeBound`.
    public static func isRuntimeBound(_ a: AgentRecord) -> Bool {
        a.runtimeBound != false && !a.runtimeId.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func normalizedRole(_ role: String?) -> String? {
        ["owner", "admin", "member"].contains(role ?? "") ? role : nil
    }

    /// `canAssignAgentToIssue` — the invoke gate the server re-checks on
    /// every send (owner always; private: owner only; public_to: workspace or
    /// member grants).
    public static func canInvoke(_ a: AgentRecord, userID: String?, role: String?) -> Bool {
        guard let userID else { return false }
        if let owner = a.ownerId, owner == userID { return true }
        if a.permissionMode == "private" { return false }
        if a.invocationTargets.contains(where: { $0.targetType == "workspace" }) {
            return normalizedRole(role) != nil
        }
        return a.invocationTargets.contains { $0.targetType == "member" && $0.targetId == userID }
    }

    /// `canEditAgent`.
    public static func canEdit(_ a: AgentRecord, userID: String?, role: String?) -> Bool {
        guard let userID else { return false }
        if role == "owner" || role == "admin" { return true }
        return a.ownerId == userID
    }

    /// Agent availability (`deriveAgentPresenceDetail().availability`):
    /// online / unstable (lost < 5 min ago) / offline / archived.
    public static func availability(_ a: AgentRecord, runtime: RuntimeDeviceRecord?, now: Date = Date()) -> String {
        if a.archivedAt != nil { return "archived" }
        guard let runtime else {
            let fromAgent = a.runtimeAvailability ?? ""
            return ["online", "unstable", "offline"].contains(fromAgent) ? fromAgent : "offline"
        }
        if runtime.status == "online" { return "online" }
        let lastSeen = runtime.lastSeenAt.flatMap(Timestamp.parse) ?? .distantPast
        return now.timeIntervalSince(lastSeen) < 300 ? "unstable" : "offline"
    }

    /// `selectConversationStarters`: configured starters with both fields,
    /// or the fallback set.
    public static func starters(_ configured: [AgentConversationStarter]?, fallback: [AgentConversationStarter]) -> [AgentConversationStarter] {
        let complete = (configured ?? []).filter {
            !$0.label.trimmingCharacters(in: .whitespaces).isEmpty && !$0.prompt.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return complete.isEmpty ? fallback : complete
    }

    /// `chatProjectContextSupported`: daemon CLI ≥ 0.4.10; git-describe dev
    /// builds always pass; missing or unparsable fails closed.
    public static func projectContextSupported(cliVersion: String?) -> Bool {
        let v = (cliVersion ?? "").trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return false }
        if v.range(of: #"^v?\d+\.\d+\.\d+-\d+-g[0-9a-fA-F]+"#, options: .regularExpression) != nil { return true }
        guard let r = v.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return false }
        let parts = v[r].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        return parts.lexicographicallyPrecedes([0, 4, 10]) == false
    }

    /// `resolveFailureReasonKey`: exact reason, then its family
    /// (`agent_error.x` → `agent_error`), else nil.
    public static func failureKey(_ reason: String?, known: Set<String>) -> String? {
        guard let reason, !reason.isEmpty else { return nil }
        if known.contains(reason) { return reason }
        if let dot = reason.firstIndex(of: "."), dot > reason.startIndex {
            let family = String(reason[..<dot])
            if known.contains(family) { return family }
        }
        return nil
    }
}

/// Session list helpers (queries.ts, unread.ts, chat-thread-list.tsx).
public enum ChatUISessions {
    static func activity(_ s: ChatSession) -> Date {
        Timestamp.parse(s.lastMessage?.createdAt ?? s.updatedAt) ?? Timestamp.parse(s.updatedAt) ?? .distantPast
    }

    /// Pinned first, then most recent activity; stable for ties.
    public static func sorted(_ sessions: [ChatSession]) -> [ChatSession] {
        let keyed = sessions.enumerated().map { (offset: $0.offset, pinned: $0.element.pinned == true, at: activity($0.element), s: $0.element) }
        return keyed.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if a.at != b.at { return a.at > b.at }
            return a.offset < b.offset
        }.map(\.s)
    }

    /// FAB badge: sessions with unread, archived excluded.
    public static func unreadSessionCount(_ sessions: [ChatSession]) -> Int {
        sessions.filter { $0.hasUnread && $0.status != "archived" }.count
    }

    /// Aggregate unread messages, excluding the session on screen.
    public static func unreadMessageCount(_ sessions: [ChatSession], excluding: String?) -> Int {
        sessions.reduce(0) { $0 + ($1.id == excluding ? 0 : ($1.unreadCount ?? 0)) }
    }

    /// Next selection after archiving the open chat: the following chat in
    /// history, else the previous one.
    public static func nextAfterArchive(_ id: String, history: [ChatSession]) -> ChatSession? {
        guard let i = history.firstIndex(where: { $0.id == id }) else { return nil }
        if i + 1 < history.count { return history[i + 1] }
        return i > 0 ? history[i - 1] : nil
    }
}

/// Text helpers (use-chat-controller.ts, chat-thread-list.tsx, format.ts).
public enum ChatUIText {
    static let titleMax = 30

    /// `deriveChatTitle`: first non-blank line, markdown stripped, collapsed,
    /// capped at 30 characters.
    public static func deriveTitle(_ content: String) -> String {
        let line = content.split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? content
        var s = line.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[#*`>~_]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard s.count > titleMax else { return s }
        return ChatUITimeline.trimEnd(String(s.prefix(titleMax - 1))) + "…"
    }

    /// The floating window seeds titles with the raw first 50 characters.
    public static func floatingTitle(_ content: String) -> String {
        String(content.prefix(50))
    }

    /// One-line preview of a (markdown, multi-line) message.
    public static func preview(_ content: String) -> String {
        var s = content.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[#*`>~]"#, with: "", options: .regularExpression)
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// `formatElapsedSecs`: `Ns`, `Nm`, or `Nm Ss`.
    public static func elapsed(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60, s = seconds % 60
        return s == 0 ? "\(m)m" : "\(m)m \(s)s"
    }

    public static func elapsed(ms: Int) -> String {
        elapsed(seconds: max(0, Int((Double(ms) / 1000).rounded())))
    }

    /// One-line summary of a tool call's input (`traceToolArgSummary`).
    public static func toolSummary(_ input: JSONValue?) -> String {
        guard case .object(let o)? = input else { return "" }
        func str(_ k: String) -> String { o[k]?.stringValue ?? "" }
        func clip(_ s: String, _ max: Int) -> String { s.count > max ? String(s.prefix(max)) + "…" : s }
        func short(_ p: String) -> String {
            let parts = p.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count <= 3 ? p : ".../" + parts.suffix(2).joined(separator: "/")
        }
        if !str("query").isEmpty { return str("query") }
        if !str("file_path").isEmpty { return short(str("file_path")) }
        if !str("path").isEmpty { return short(str("path")) }
        if !str("pattern").isEmpty { return str("pattern") }
        if !str("description").isEmpty { return str("description") }
        let command = str("command").isEmpty ? str("cmd") : str("command")
        if !command.isEmpty { return clip(stripShellWrapper(command), 120) }
        if !str("prompt").isEmpty { return clip(str("prompt"), 120) }
        if !str("skill").isEmpty { return str("skill") }
        for key in o.keys.sorted() {
            if let v = o[key]?.stringValue, !v.isEmpty, v.count < 120 { return v }
        }
        return ""
    }

    /// `<shell> -lc '<cmd>'` → `<cmd>`.
    static func stripShellWrapper(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let re = try? NSRegularExpression(pattern: #"^(?:/[\w./-]*/)?(?:zsh|bash|sh|fish)\s+(?:-[a-z]+\s+)*(['"])([\s\S]+)\1$"#),
              let m = re.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)),
              m.numberOfRanges > 2 else { return command }
        return (trimmed as NSString).substring(with: m.range(at: 2))
    }

    /// `isTaskMessageTaskId`: a real server task id (UUID).
    public static func isTaskID(_ id: String?) -> Bool {
        guard let id else { return false }
        return id.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil
    }

    static func referenceURLs(_ a: Attachment) -> [String] {
        [a.markdownUrl, a.downloadUrl, a.url, a.id.isEmpty ? "" : "/api/attachments/\(a.id)/download"].filter { !$0.isEmpty }
    }

    /// Whether `content` embeds the attachment (its stable or legacy URL).
    public static func isReferenced(_ a: Attachment, in content: String) -> Bool {
        referenceURLs(a).contains { content.contains($0) }
    }

    /// Markdown ready for the native renderer: `!file[name](url)` cards whose
    /// file is attached are lifted out (they render as attachment cards), any
    /// other file card becomes a plain "📎 name".
    public static func displayMarkdown(_ content: String, attachments: [Attachment]?) -> String {
        guard content.contains("!file["),
              let re = try? NSRegularExpression(pattern: #"!file\[((?:\\.|[^\]\\])*)\]\(([^)\s]+)\)"#) else { return content }
        let ns = content as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let url = ns.substring(with: m.range(at: 2))
            let attached = (attachments ?? []).contains { referenceURLs($0).contains(url) }
            if !attached {
                let label = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: #"\\([\[\]\\()])"#, with: "$1", options: .regularExpression)
                out += "📎 \(label)"
            }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Attachments to render as cards: the ones the markdown does not already
    /// show inline (`selectStandaloneAttachments`), deduplicated.
    public static func standaloneAttachments(_ attachments: [Attachment]?, content: String) -> [Attachment] {
        var seen = Set<String>()
        return (attachments ?? []).filter { a in
            guard !isReferenced(a, in: content), seen.insert(a.id).inserted else { return false }
            return true
        }
    }
}

/// What a project-context change should do to the open chat
/// (`planProjectContextChange`).
public enum ChatUIProjectChange: Equatable, Sendable {
    case awaitSession
    case detachCurrent(sessionID: String)
    case startFreshChat(agentID: String, projectID: String)
    case setDraftProject(String?)

    public static func plan(target: String?, activeSessionID: String?, current: ChatSession?) -> ChatUIProjectChange {
        guard activeSessionID != nil else { return .setDraftProject(target) }
        guard let current else { return .awaitSession }
        guard let target else { return .detachCurrent(sessionID: current.id) }
        return .startFreshChat(agentID: current.agentId, projectID: target)
    }
}
