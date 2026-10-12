import Foundation

/// An agent run placed in the issue timeline (upstream comment-runs.ts).
public struct IssueDetailRun: Sendable, Hashable, Identifiable {
    public var task: AgentTaskRecord
    /// The run's published reply, else the input it answers.
    public var commentID: String?
    /// Latest input the run covers; nil for issue-level runs (assignment).
    public var anchorCommentID: String?
    public var hasReply: Bool
    public var id: String { task.id }

    public init(task: AgentTaskRecord, commentID: String?, anchorCommentID: String?, hasReply: Bool) {
        self.task = task
        self.commentID = commentID
        self.anchorCommentID = anchorCommentID
        self.hasReply = hasReply
    }

    public static let activeStatuses: Set<String> = ["queued", "dispatched", "waiting_local_directory", "running"]
    public var isActive: Bool { Self.activeStatuses.contains(task.status) }
    public var isEnded: Bool { task.status == "failed" || task.status == "cancelled" }
    /// A published reply carries its live or completed run in its header.
    public var showsInHeader: Bool { hasReply && (isActive || task.status == "completed") }

    /// The daemon's deliverable for a completed run that posted no comment.
    public var output: String? {
        guard task.status == "completed", let s = task.result["comment"]?.stringValue,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// The platform's failure comment, which the run block stands in for.
    public func isFailureNotice(_ entry: TimelineEntry) -> Bool {
        entry.actorType == "agent" && entry.commentType == "system" && entry.sourceTaskID == task.id && isEnded
    }
}

/// One comment thread: the root, every descendant in chronological order
/// (tombstones included), and the runs that belong to it.
public struct IssueDetailThread: Sendable, Hashable {
    public var root: TimelineEntry
    public var replies: [TimelineEntry]
    public var runs: [IssueDetailRun]

    public init(root: TimelineEntry, replies: [TimelineEntry], runs: [IssueDetailRun]) {
        self.root = root
        self.replies = replies
        self.runs = runs
    }

    public var visibleReplies: [TimelineEntry] { replies.filter { !$0.isDeletedComment } }
    public var resolution: IssueDetailResolution { IssueDetailResolution(root: root, replies: replies) }
}

/// Upstream deriveThreadResolution: root wins, else the reply resolved last.
public enum IssueDetailResolution: Sendable, Hashable {
    case none, root, reply(String)

    public init(root: TimelineEntry, replies: [TimelineEntry]) {
        if root.resolvedAt != nil {
            self = .root
            return
        }
        var chosen: TimelineEntry?
        for r in replies {
            guard let at = r.resolvedAt else { continue }
            if let c = chosen, let cAt = c.resolvedAt, cAt >= at { continue }
            chosen = r
        }
        self = chosen.map { .reply($0.id) } ?? .none
    }

    public var replyID: String? {
        if case .reply(let id) = self { return id }
        return nil
    }
}

public enum IssueDetailThreadRow: Sendable, Hashable, Identifiable {
    case reply(TimelineEntry)
    /// A run slot: its latest comment once posted, else its activity block.
    case run(IssueDetailRun, reply: TimelineEntry?, replyTo: TimelineEntry?)

    public var id: String {
        switch self {
        case .reply(let e): return e.id
        case .run(let r, _, _): return "run:\(r.task.id)"
        }
    }
}

public enum IssueDetailTimelineItem: Sendable, Hashable, Identifiable {
    case thread(IssueDetailThread)
    /// An issue-level run; its published reply heads `thread`.
    case run(IssueDetailRun, thread: IssueDetailThread?)
    case activities(id: String, entries: [TimelineEntry])

    public var id: String {
        switch self {
        case .thread(let t): return t.root.id
        case .run(let r, let t): return t?.root.id ?? "run:\(r.task.id)"
        case .activities(let id, _): return "activities:\(id)"
        }
    }

    /// The comment thread this row renders, if any.
    public var thread: IssueDetailThread? {
        switch self {
        case .thread(let t): return t
        case .run(_, let t): return t
        case .activities: return nil
        }
    }
}

/// The issue timeline as rows: activity blocks, threads and issue-level runs
/// in reading order (upstream issue-detail timelineView + comment-runs).
public struct IssueDetailTimelineLayout: Sendable, Equatable {
    public var items: [IssueDetailTimelineItem] = []
    public var replyToRoot: [String: String] = [:]
    public var lastActivityGroupID: String?
    public var runsByTask: [String: IssueDetailRun] = [:]

    public init() {}

    static let coalesceWindow: TimeInterval = 120
    static let noTimeLimitActions: Set<String> = ["task_completed", "task_failed", "wakeup_checkin"]
    static let neverCoalesceActions: Set<String> = [
        "squad_leader_evaluated", "wakeup_created", "wakeup_triggered", "wakeup_timed_out", "wakeup_paused",
        "duplicate_marked", "duplicate_unmarked", "duplicate_added", "duplicate_removed",
    ]

    public static func build(entries: [TimelineEntry], tasks: [AgentTaskRecord]) -> IssueDetailTimelineLayout {
        let placed = placeRuns(tasks: tasks, entries: entries)
        let projected = placed.projected
        var out = IssueDetailTimelineLayout()
        for r in placed.runs { out.runsByTask[r.task.id] = r }

        var comments: [String: TimelineEntry] = [:]
        var repliesByParent: [String: [TimelineEntry]] = [:]
        for e in projected where e.kind == .comment {
            comments[e.id] = e
            if let p = e.parentID { repliesByParent[p, default: []].append(e) }
        }
        var grouped: [String: [IssueDetailRun]] = [:]
        for r in placed.runs {
            guard var root = comments[r.anchorCommentID ?? r.commentID ?? ""] else { continue }
            var seen: Set<String> = [root.id]
            while let p = root.parentID, let parent = comments[p], !seen.contains(p) {
                root = parent
                seen.insert(p)
            }
            grouped[root.id, default: []].append(r)
        }

        func thread(_ root: TimelineEntry) -> IssueDetailThread {
            var replies: [TimelineEntry] = []
            var stack = [root.id]
            var visited: Set<String> = [root.id]
            while let id = stack.popLast() {
                for child in repliesByParent[id] ?? [] where visited.insert(child.id).inserted {
                    replies.append(child)
                    stack.append(child.id)
                }
            }
            replies.sort(by: entryOrder)
            for r in replies { out.replyToRoot[r.id] = root.id }
            return IssueDetailThread(root: root, replies: replies, runs: grouped[root.id] ?? [])
        }

        let topLevel = projected.filter { $0.kind == .activity || $0.parentID == nil }
        let standalone = placed.runs.filter { $0.anchorCommentID == nil }
        let ordered = orderWithRuns(entries: topLevel, runs: standalone, entryByID: comments)

        var coalesced: [Slot] = []
        for slot in ordered {
            guard case .entry(let e) = slot, e.kind == .activity, let action = e.action,
                  !neverCoalesceActions.contains(action),
                  case .entry(let prev)? = coalesced.last, prev.kind == .activity, prev.action == action,
                  prev.actorType == e.actorType, prev.actorID == e.actorID,
                  noTimeLimitActions.contains(action) || withinWindow(prev.createdAt, e.createdAt)
            else {
                coalesced.append(slot)
                continue
            }
            var merged = e
            merged.coalescedCount = (prev.coalescedCount ?? 1) + 1
            coalesced[coalesced.count - 1] = .entry(merged)
        }

        var items: [IssueDetailTimelineItem] = []
        var pendingActivities: [TimelineEntry] = []
        func flushActivities() {
            guard let first = pendingActivities.first else { return }
            items.append(.activities(id: first.id, entries: pendingActivities))
            out.lastActivityGroupID = first.id
            pendingActivities = []
        }
        for slot in coalesced {
            switch slot {
            case .entry(let e) where e.kind == .activity:
                pendingActivities.append(e)
            case .entry(let e):
                flushActivities()
                items.append(.thread(thread(e)))
            case .run(let r):
                flushActivities()
                let reply = r.hasReply ? r.commentID.flatMap { comments[$0] } : nil
                items.append(.run(r, thread: reply.map(thread)))
            }
        }
        flushActivities()
        out.items = items
        return out
    }

    // MARK: Run placement

    struct Placement {
        var runs: [IssueDetailRun]
        var projected: [TimelineEntry]
    }

    /// Anchors each run on its latest covered input and associates replies
    /// by task identity; run replies are re-parented under their anchor
    /// (assignment answers become roots).
    static func placeRuns(tasks: [AgentTaskRecord], entries: [TimelineEntry]) -> Placement {
        let inline = tasks.filter { $0.kind != "quick_create" }
        var comments: [String: TimelineEntry] = [:]
        var order: [String: Int] = [:]
        for (i, e) in entries.enumerated() {
            order[e.id] = i
            if e.kind == .comment { comments[e.id] = e }
        }
        var supplementalByTask: [String: [String]] = [:]
        var replies: [String: TimelineEntry] = [:]
        var topLevelOutputs: [String: [TimelineEntry]] = [:]
        for e in comments.values {
            for receipt in e.supplements { supplementalByTask[receipt.taskId, default: []].append(e.id) }
            guard let task = e.sourceTaskID, e.actorType == "agent" else { continue }
            if replies[task].map({ e.createdAt > $0.createdAt || (e.createdAt == $0.createdAt && e.id > $0.id) }) ?? true {
                replies[task] = e
            }
            if e.parentID == nil { topLevelOutputs[task, default: []].append(e) }
        }
        func threadRoot(_ id: String) -> String? {
            var seen: Set<String> = []
            var e = comments[id]
            while let cur = e, let p = cur.parentID {
                if !seen.insert(cur.id).inserted { return nil }
                e = comments[p]
            }
            return e?.id
        }
        let byTask = Dictionary(inline.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var runs: [IssueDetailRun] = []
        for task in inline.sorted(by: { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }) {
            let reply = replies[task.id]
            if isObsolete(task) && reply == nil { continue }
            var anchor: String?
            var source: AgentTaskRecord? = task
            var visited: Set<String> = []
            while anchor == nil, let s = source, visited.insert(s.id).inserted {
                let planned = s.status == "queued"
                    || (s.status == "dispatched" && (s.deliveredCommentIds ?? []).isEmpty)
                    || ((s.status == "cancelled" || s.status == "failed") && s.dispatchedAt == nil && s.startedAt == nil)
                let base: [String] = !planned && s.deliveredCommentIds != nil
                    ? s.deliveredCommentIds!
                    : [s.triggerCommentId ?? ""] + (s.coalescedCommentIds ?? [])
                var ids: [String] = []
                for id in base + (s.supplementCommentIds ?? []) + (supplementalByTask[s.id] ?? []) where !id.isEmpty && !ids.contains(id) {
                    ids.append(id)
                }
                let candidates = ids.compactMap { comments[$0] }
                let latest = candidates.max { a, b in
                    a.createdAt == b.createdAt ? (order[a.id] ?? -1) < (order[b.id] ?? -1) : a.createdAt < b.createdAt
                }?.id
                if let trigger = s.triggerCommentId, ids.contains(trigger) {
                    anchor = trigger
                } else {
                    anchor = latest ?? ids.first
                }
                if let first = candidates.first, let root = threadRoot(first.id), candidates.count == ids.count,
                   candidates.allSatisfy({ threadRoot($0.id) == root }) {
                    anchor = latest
                }
                source = s.parentTaskId.flatMap { byTask[$0] }
            }
            runs.append(IssueDetailRun(task: task, commentID: reply?.id ?? anchor, anchorCommentID: anchor, hasReply: reply != nil))
        }

        var parents: [String: String?] = [:]
        for r in runs where r.hasReply {
            guard let c = r.commentID, c != r.anchorCommentID else { continue }
            for output in topLevelOutputs[r.task.id] ?? [] { parents[output.id] = r.anchorCommentID }
            parents[c] = r.anchorCommentID
        }
        for id in Array(parents.keys) {
            var seen: Set<String> = [id]
            var parent: String? = parents[id] ?? nil
            while let p = parent {
                if !seen.insert(p).inserted {
                    parents[id] = nil
                    break
                }
                if let next = parents[p] { parent = next } else { parent = comments[p]?.parentID }
            }
        }
        let projected: [TimelineEntry] = parents.isEmpty ? entries : entries.map { e in
            guard let p = parents[e.id], e.parentID != p else { return e }
            var copy = e
            copy.parentID = p
            return copy
        }
        return Placement(runs: runs, projected: projected)
    }

    /// Queued input that a later edit invalidated is history, not a run.
    static func isObsolete(_ t: AgentTaskRecord) -> Bool {
        t.status == "cancelled" && t.cancelledByCommentChange == true && t.dispatchedAt == nil
            && t.startedAt == nil && (t.deliveredCommentIds ?? []).isEmpty
    }

    // MARK: Ordering

    enum Slot {
        case entry(TimelineEntry)
        case run(IssueDetailRun)
    }

    static func time(_ s: String) -> Double {
        Timestamp.parse(s)?.timeIntervalSince1970 ?? 0
    }

    static func withinWindow(_ a: String, _ b: String) -> Bool {
        abs(time(a) - time(b)) <= coalesceWindow
    }

    static func entryOrder(_ a: TimelineEntry, _ b: TimelineEntry) -> Bool {
        a.createdAt == b.createdAt ? a.id < b.id : a.createdAt < b.createdAt
    }

    static func publishedReply(_ r: IssueDetailRun, _ byID: [String: TimelineEntry]) -> TimelineEntry? {
        r.hasReply ? r.commentID.flatMap { byID[$0] } : nil
    }

    /// Once a run publishes a reply the reply's time owns the slot; an active
    /// run keeps its enqueue time, an ended one sorts when it ended.
    static func runSortTime(_ r: IssueDetailRun, _ byID: [String: TimelineEntry]) -> Double {
        if let reply = publishedReply(r, byID) { return time(reply.createdAt) }
        if r.isActive { return time(r.task.createdAt) }
        return time(r.task.completedAt ?? r.task.createdAt)
    }

    /// Runs merged into entries; a run with a published reply replaces it.
    static func orderWithRuns(entries: [TimelineEntry], runs: [IssueDetailRun], entryByID: [String: TimelineEntry]) -> [Slot] {
        let slotted = Set(runs.filter(\.hasReply).compactMap(\.commentID))
        var keyed: [(time: Double, created: String, id: String, slot: Slot)] = []
        keyed.reserveCapacity(entries.count + runs.count)
        for e in entries where !slotted.contains(e.id) {
            keyed.append((time(e.createdAt), e.createdAt, e.id, .entry(e)))
        }
        for r in runs {
            let row = publishedReply(r, entryByID)
            keyed.append((runSortTime(r, entryByID), row?.createdAt ?? r.task.createdAt, row?.id ?? r.task.id, .run(r)))
        }
        keyed.sort { a, b in
            if a.time != b.time { return a.time < b.time }
            return a.created == b.created ? a.id < b.id : a.created < b.created
        }
        return keyed.map(\.slot)
    }
}

extension IssueDetailThread {
    /// Replies and run slots in reading order (upstream orderThreadWithRuns).
    /// A run still working with nothing posted stays right after the input
    /// it answers; a run whose reply is the root heads the thread instead.
    public func rows(replies subset: [TimelineEntry], runs subsetRuns: [IssueDetailRun]) -> [IssueDetailThreadRow] {
        var byID: [String: TimelineEntry] = [root.id: root]
        for r in replies { byID[r.id] = r }
        let threadRuns = subsetRuns.filter { $0.anchorCommentID != nil && !($0.hasReply && $0.commentID == root.id) }
        let working = threadRuns.filter { !$0.hasReply && $0.isActive }
        let workingIDs = Set(working.map(\.id))
        var slots = IssueDetailTimelineLayout.orderWithRuns(
            entries: subset, runs: threadRuns.filter { !workingIDs.contains($0.id) }, entryByID: byID)
        func showsInput(_ slot: IssueDetailTimelineLayout.Slot, _ id: String) -> Bool {
            switch slot {
            case .entry(let e): return e.id == id
            case .run(let r): return IssueDetailTimelineLayout.publishedReply(r, byID)?.id == id
            }
        }
        func slotTime(_ slot: IssueDetailTimelineLayout.Slot) -> Double {
            switch slot {
            case .entry(let e): return IssueDetailTimelineLayout.time(e.createdAt)
            case .run(let r): return IssueDetailTimelineLayout.runSortTime(r, byID)
            }
        }
        for run in working {
            let anchor = run.anchorCommentID ?? root.id
            var index = anchor == root.id ? 0 : (slots.firstIndex { showsInput($0, anchor) }.map { $0 + 1 } ?? slots.count)
            let enqueued = IssueDetailTimelineLayout.time(run.task.createdAt)
            while index < slots.count, slotTime(slots[index]) <= enqueued { index += 1 }
            slots.insert(.run(run), at: index)
        }
        func commentAbove(_ index: Int, _ run: IssueDetailRun) -> String? {
            for slot in slots[..<index].reversed() {
                switch slot {
                case .run(let r):
                    let reply = IssueDetailTimelineLayout.publishedReply(r, byID)
                    return reply.flatMap { $0.isDeletedComment ? nil : $0.id }
                case .entry(let e):
                    if !e.isDeletedComment && e.sourceTaskID != run.task.id { return e.id }
                }
            }
            return root.id
        }
        return slots.enumerated().map { index, slot in
            switch slot {
            case .entry(let e):
                return .reply(e)
            case .run(let r):
                let reply = IssueDetailTimelineLayout.publishedReply(r, byID)
                let anchor = r.anchorCommentID.flatMap { byID[$0] }
                let replyTo = anchor.flatMap { a in
                    a.id != reply?.id && !a.isDeletedComment && a.id != commentAbove(index, r) ? a : nil
                }
                return .run(r, reply: reply, replyTo: replyTo)
            }
        }
    }
}
