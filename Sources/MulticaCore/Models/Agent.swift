import Foundation

public struct AgentStatus: OpenEnum {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let idle = AgentStatus(rawValue: "idle")
    public static let working = AgentStatus(rawValue: "working")
    public static let blocked = AgentStatus(rawValue: "blocked")
    public static let error = AgentStatus(rawValue: "error")
    public static let offline = AgentStatus(rawValue: "offline")
}

public struct Agent: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var workspaceID: String
    public var runtimeID: String
    public var name: String
    public var description: String
    public var avatarURL: String?
    public var status: AgentStatus
    public var model: String
    public var archivedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, status, model
        case workspaceID = "workspace_id"
        case runtimeID = "runtime_id"
        case avatarURL = "avatar_url"
        case archivedAt = "archived_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workspaceID = c.lossy(String.self, .workspaceID, default: "")
        runtimeID = c.lossy(String.self, .runtimeID, default: "")
        name = c.lossy(String.self, .name, default: "Agent")
        description = c.lossy(String.self, .description, default: "")
        avatarURL = c.lossy(String.self, .avatarURL)
        status = c.lossy(AgentStatus.self, .status, default: .idle)
        model = c.lossy(String.self, .model, default: "")
        archivedAt = c.lossy(String.self, .archivedAt)
    }
}

public struct TaskStatus: OpenEnum {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let queued = TaskStatus(rawValue: "queued")
    public static let dispatched = TaskStatus(rawValue: "dispatched")
    public static let waitingLocalDirectory = TaskStatus(rawValue: "waiting_local_directory")
    public static let deferred = TaskStatus(rawValue: "deferred")
    public static let running = TaskStatus(rawValue: "running")
    public static let completed = TaskStatus(rawValue: "completed")
    public static let failed = TaskStatus(rawValue: "failed")
    public static let cancelled = TaskStatus(rawValue: "cancelled")

    /// Active (non-terminal) states. Unknown future states count as active so
    /// a run never silently disappears from the "working" indicators.
    public var isActive: Bool {
        switch self {
        case .completed, .failed, .cancelled: return false
        default: return true
        }
    }
}

public struct AgentTask: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var agentID: String
    public var runtimeID: String
    public var issueID: String
    public var status: TaskStatus
    public var priority: Int
    public var dispatchedAt: String?
    public var startedAt: String?
    public var completedAt: String?
    public var error: String?
    public var failureReason: String?
    public var createdAt: String
    public var chatSessionID: String?
    public var attempt: Int?
    public var triggerCommentID: String?

    enum CodingKeys: String, CodingKey {
        case id, status, priority, error, attempt
        case agentID = "agent_id"
        case runtimeID = "runtime_id"
        case issueID = "issue_id"
        case dispatchedAt = "dispatched_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case failureReason = "failure_reason"
        case createdAt = "created_at"
        case chatSessionID = "chat_session_id"
        case triggerCommentID = "trigger_comment_id"
    }

    public init(id: String, agentID: String, issueID: String, status: TaskStatus, createdAt: String = "") {
        self.id = id
        self.agentID = agentID
        self.runtimeID = ""
        self.issueID = issueID
        self.status = status
        self.priority = 0
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agentID = c.lossy(String.self, .agentID, default: "")
        runtimeID = c.lossy(String.self, .runtimeID, default: "")
        issueID = c.lossy(String.self, .issueID, default: "")
        status = c.lossy(TaskStatus.self, .status, default: .queued)
        priority = c.lossy(Int.self, .priority, default: 0)
        dispatchedAt = c.lossy(String.self, .dispatchedAt)
        startedAt = c.lossy(String.self, .startedAt)
        completedAt = c.lossy(String.self, .completedAt)
        error = c.lossy(String.self, .error)
        failureReason = c.lossy(String.self, .failureReason)
        createdAt = c.lossy(String.self, .createdAt, default: "")
        chatSessionID = c.lossy(String.self, .chatSessionID)
        attempt = c.lossy(Int.self, .attempt)
        triggerCommentID = c.lossy(String.self, .triggerCommentID)
    }
}

/// A runtime (one agent CLI on one daemon machine).
public struct RuntimeDevice: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var name: String
    public var customName: String?
    public var provider: String
    public var status: String
    public var runtimeMode: String
    public var deviceInfo: String
    public var daemonID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, provider, status
        case customName = "custom_name"
        case runtimeMode = "runtime_mode"
        case deviceInfo = "device_info"
        case daemonID = "daemon_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lossy(String.self, .name, default: "")
        customName = c.lossy(String.self, .customName)
        provider = c.lossy(String.self, .provider, default: "")
        status = c.lossy(String.self, .status, default: "offline")
        runtimeMode = c.lossy(String.self, .runtimeMode, default: "local")
        deviceInfo = c.lossy(String.self, .deviceInfo, default: "")
        daemonID = c.lossy(String.self, .daemonID)
    }

    public var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        return name
    }

    public var isOnline: Bool { status == "online" }
}
