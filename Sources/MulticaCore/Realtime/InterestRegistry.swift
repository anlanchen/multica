import Foundation

/// Which tasks and issues a mounted view is currently rendering.
///
/// The server broadcasts every `task:message` of every run to every client in
/// the workspace. Upstream, each client decoded and cached all of it until
/// MUL-6396 started dropping frames for transcripts nobody had open. Here the
/// router consults this registry while decoding, so a frame for an unwatched
/// run never has its (unbounded) tool input/output materialised at all.
///
/// Reads happen on the WebSocket receive path, so this is a lock, not an actor.
public final class InterestRegistry: @unchecked Sendable {
    private struct State {
        var tasks: [String: Int] = [:]
        var issues: [String: Int] = [:]
        var allTasks = 0
    }

    private let state = Locked(State())

    public init() {}

    /// Returns true when this call made the task interesting (0 → 1), which is
    /// when a scope subscription should be sent.
    @discardableResult
    public func retainTask(_ id: String) -> Bool {
        state.withLock { s in
            s.tasks[id, default: 0] += 1
            return s.tasks[id] == 1
        }
    }

    /// Returns true when the task stopped being interesting (1 → 0).
    @discardableResult
    public func releaseTask(_ id: String) -> Bool {
        state.withLock { s in
            guard let n = s.tasks[id] else { return false }
            if n <= 1 {
                s.tasks[id] = nil
                return true
            }
            s.tasks[id] = n - 1
            return false
        }
    }

    public func retainIssue(_ id: String) {
        state.withLock { $0.issues[id, default: 0] += 1 }
    }

    public func releaseIssue(_ id: String) {
        state.withLock { s in
            guard let n = s.issues[id] else { return }
            s.issues[id] = n <= 1 ? nil : n - 1
        }
    }

    /// Diagnostics/bench switch: keep every task message (upstream's
    /// pre-MUL-6396 behaviour).
    public func setRetainAll(_ on: Bool) {
        state.withLock { $0.allTasks = on ? 1 : 0 }
    }

    public func wants(taskID: String, issueID: String?) -> Bool {
        state.withLock { s in
            if s.allTasks > 0 || s.tasks[taskID] != nil { return true }
            if let issueID, !issueID.isEmpty, s.issues[issueID] != nil { return true }
            return false
        }
    }

    public var heldTaskIDs: [String] {
        state.withLock { Array($0.tasks.keys) }
    }
}
