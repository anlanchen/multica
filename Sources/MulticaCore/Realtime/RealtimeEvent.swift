import Foundation

/// Lifecycle transition of an agent task (`task:queued`, `task:running`, ...).
public struct TaskLifecycle: Sendable, Hashable, Decodable {
    public var taskID: String
    public var agentID: String
    public var issueID: String
    public var chatSessionID: String?
    public var status: TaskStatus
    public var failureReason: String?
    public var waitReason: String?

    enum CodingKeys: String, CodingKey {
        case status
        case taskID = "task_id"
        case agentID = "agent_id"
        case issueID = "issue_id"
        case chatSessionID = "chat_session_id"
        case failureReason = "failure_reason"
        case waitReason = "wait_reason"
    }

    public init(taskID: String, agentID: String, issueID: String, status: TaskStatus) {
        self.taskID = taskID
        self.agentID = agentID
        self.issueID = issueID
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try c.decode(String.self, forKey: .taskID)
        agentID = c.lossy(String.self, .agentID, default: "")
        issueID = c.lossy(String.self, .issueID, default: "")
        chatSessionID = c.lossy(String.self, .chatSessionID)
        status = c.lossy(TaskStatus.self, .status, default: .queued)
        failureReason = c.lossy(String.self, .failureReason)
        waitReason = c.lossy(String.self, .waitReason)
    }
}

public struct IssueChangeFlags: Sendable, Hashable {
    public var statusChanged = false
    public var assigneeChanged = false
    public var projectChanged = false

    public init(statusChanged: Bool = false, assigneeChanged: Bool = false, projectChanged: Bool = false) {
        self.statusChanged = statusChanged
        self.assigneeChanged = assigneeChanged
        self.projectChanged = projectChanged
    }
}

/// Reference data whose change is answered by a refetch, never by merging
/// event payloads into a client cache.
public enum CatalogKind: String, Sendable, Hashable {
    case members, agents, statuses, labels, runtimes, workspace, other
}

public enum ConnectionState: Sendable, Equatable {
    case connecting
    case connected(recovered: Bool)
    case disconnected(retryIn: TimeInterval)
    case stopped
}

/// What the realtime layer hands the stores. Task messages arrive batched
/// (one array per flush window), everything else one event per frame.
public enum RealtimeEvent: Sendable {
    case issueUpsert(Issue, IssueChangeFlags)
    case issueDeleted(issueID: String)
    case issueLabels(issueID: String, labels: [Label])
    case commentUpsert(Comment)
    case commentDeleted(commentID: String, issueID: String)
    case activity(issueID: String, entry: TimelineEntry)
    case taskLifecycle(TaskLifecycle)
    case taskMessages([TaskMessage])
    case inboxNew(InboxItem)
    case inboxChanged
    case agentUpsert(Agent)
    case catalogChanged(CatalogKind)
    case workspaceDeleted(workspaceID: String)
    case connection(ConnectionState)
}
