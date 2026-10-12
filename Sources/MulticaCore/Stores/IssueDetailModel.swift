import Foundation
import Observation

/// Live transcript of one agent run.
@MainActor
@Observable
public final class TranscriptModel: Identifiable {
    public let id: String
    @ObservationIgnored public private(set) var buffer = TranscriptBuffer()
    @ObservationIgnored private var clipped: [Int: (revision: Int, limit: Int, text: String, clipped: Bool)] = [:]
    /// Bumped on every change; views read `steps` through it.
    public private(set) var version = 0
    public internal(set) var isLoading = false
    /// The server clipped a broadcast copy; a REST refetch is owed.
    @ObservationIgnored var needsRepair = false

    init(taskID: String) {
        id = taskID
    }

    public var steps: [TranscriptStep] {
        _ = version
        return buffer.steps
    }

    public var lastStep: TranscriptStep? {
        _ = version
        return buffer.steps.last
    }

    public func merge(_ batch: [TaskMessage]) {
        if batch.contains(where: \.truncated) { needsRepair = true }
        if buffer.merge(batch) { version = buffer.version }
    }

    /// Clipped body for one step. Messages are redacted when they enter the
    /// client (whole bodies, before any clip), so this only clips; memoised
    /// by step revision so re-renders do no string work.
    public func displayText(for step: TranscriptStep, limit: Int = 4000) -> (text: String, clipped: Bool) {
        if let c = clipped[step.id], c.revision == step.revision, c.limit == limit {
            return (c.text, c.clipped)
        }
        let raw: String
        switch step.kind {
        case .tool: raw = step.output ?? ""
        default: raw = step.text
        }
        let r = raw.count > limit ? (String(raw.prefix(limit)), true) : (raw, false)
        clipped[step.id] = (step.revision, limit, r.0, r.1)
        return r
    }

    public func displaySummary(for step: TranscriptStep, limit: Int = 160) -> String {
        let firstLine = step.summary.prefix { $0 != "\n" }
        return firstLine.count > limit ? String(firstLine.prefix(limit)) + "…" : String(firstLine)
    }
}

public struct PendingComment: Identifiable, Sendable, Hashable {
    public enum State: Sendable, Hashable { case sending, failed(String) }
    public var id: String
    public var content: String
    public var parentID: String?
    public var state: State
}

/// Everything the issue detail screen shows. Opened and closed by the view;
/// realtime events for this issue are applied while it is open.
@MainActor
@Observable
public final class IssueDetailModel: Identifiable {
    public let id: String
    /// The row model of this issue, once the issue is known locally. Views
    /// observe it for live field changes.
    public internal(set) var issue: IssueModel?
    public internal(set) var entries: [TimelineEntry] = []
    public internal(set) var runs: [AgentTask] = []
    public internal(set) var pendingComments: [PendingComment] = []
    public internal(set) var isLoading = false
    public internal(set) var loadError: String?
    @ObservationIgnored var transcripts: [String: TranscriptModel] = [:]
    @ObservationIgnored var openCount = 0

    init(issueID: String) {
        id = issueID
    }

    public var activeRuns: [AgentTask] { runs.filter { $0.status.isActive } }

    public func transcript(for taskID: String) -> TranscriptModel {
        if let t = transcripts[taskID] { return t }
        let t = TranscriptModel(taskID: taskID)
        transcripts[taskID] = t
        return t
    }

    func existingTranscript(_ taskID: String) -> TranscriptModel? { transcripts[taskID] }

    // MARK: Timeline

    func setTimeline(_ list: [TimelineEntry]) {
        entries = list.sorted(by: Self.order)
    }

    /// Inserts or replaces a comment row, ignoring stale revisions (a REST
    /// response can land after a newer WebSocket echo).
    func upsertComment(_ c: Comment) {
        let row = TimelineEntry(comment: c)
        if let i = entries.firstIndex(where: { $0.id == c.id }) {
            if let old = entries[i].revision, let new = c.revision, new < old { return }
            entries[i] = row
        } else {
            insertSorted(row)
        }
        pendingComments.removeAll { $0.content == c.content && $0.parentID == c.parentID && $0.state == .sending }
    }

    func removeComment(_ id: String) {
        entries.removeAll { $0.id == id }
    }

    func appendActivity(_ e: TimelineEntry) {
        guard !entries.contains(where: { $0.id == e.id }) else { return }
        insertSorted(e)
    }

    private func insertSorted(_ e: TimelineEntry) {
        if let last = entries.last, !Self.order(e, last) {
            entries.append(e)
        } else {
            let idx = entries.firstIndex { Self.order(e, $0) } ?? entries.count
            entries.insert(e, at: idx)
        }
    }

    static func order(_ a: TimelineEntry, _ b: TimelineEntry) -> Bool {
        a.createdAt == b.createdAt ? a.id < b.id : a.createdAt < b.createdAt
    }

    // MARK: Runs

    func setRuns(_ list: [AgentTask]) {
        runs = list.sorted { $0.createdAt > $1.createdAt }
    }

    func applyLifecycle(_ e: TaskLifecycle) {
        if let i = runs.firstIndex(where: { $0.id == e.taskID }) {
            guard runs[i].status != e.status else { return }
            runs[i].status = e.status
            if let r = e.failureReason { runs[i].failureReason = r }
        } else {
            runs.insert(AgentTask(id: e.taskID, agentID: e.agentID, issueID: e.issueID, status: e.status,
                                  createdAt: ISO8601DateFormatter().string(from: Date())), at: 0)
        }
    }
}
