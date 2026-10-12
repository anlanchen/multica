import Foundation

public struct TaskMessageKind: OpenEnum {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let text = TaskMessageKind(rawValue: "text")
    public static let thinking = TaskMessageKind(rawValue: "thinking")
    public static let toolUse = TaskMessageKind(rawValue: "tool_use")
    public static let toolResult = TaskMessageKind(rawValue: "tool_result")
    public static let error = TaskMessageKind(rawValue: "error")
}

/// One agent execution message. `seq` is the per-task order key; the same
/// message can arrive twice (REST backfill racing a live frame), so merges are
/// keyed by `seq`.
public struct TaskMessage: Sendable, Hashable, Decodable {
    public var taskID: String
    public var issueID: String
    public var chatSessionID: String?
    public var seq: Int
    public var kind: TaskMessageKind
    public var tool: String?
    public var content: String?
    public var input: JSONValue?
    public var output: String?
    public var outputTruncated: Bool?
    public var callID: String?
    public var createdAt: String?
    /// Set by the server when it clipped the broadcast copy (MUL-6396). The
    /// persisted row is complete, so the client repairs from REST.
    public var truncated: Bool

    enum CodingKeys: String, CodingKey {
        case seq, type, tool, content, input, output, truncated
        case taskID = "task_id"
        case issueID = "issue_id"
        case chatSessionID = "chat_session_id"
        case outputTruncated = "output_truncated"
        case callID = "call_id"
        case createdAt = "created_at"
    }

    public init(taskID: String, issueID: String = "", seq: Int, kind: TaskMessageKind, tool: String? = nil,
                content: String? = nil, input: JSONValue? = nil, output: String? = nil, callID: String? = nil) {
        self.taskID = taskID
        self.issueID = issueID
        self.seq = seq
        self.kind = kind
        self.tool = tool
        self.content = content
        self.input = input
        self.output = output
        self.callID = callID
        self.truncated = false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = c.lossy(String.self, .taskID, default: "")
        issueID = c.lossy(String.self, .issueID, default: "")
        chatSessionID = c.lossy(String.self, .chatSessionID)
        seq = try c.decode(Int.self, forKey: .seq)
        kind = c.lossy(TaskMessageKind.self, .type, default: .text)
        tool = c.lossy(String.self, .tool)
        content = c.lossy(String.self, .content)
        input = c.lossy(JSONValue.self, .input)
        output = c.lossy(String.self, .output)
        outputTruncated = c.lossy(Bool.self, .outputTruncated)
        callID = c.lossy(String.self, .callID)
        createdAt = c.lossy(String.self, .createdAt)
        truncated = c.lossy(Bool.self, .truncated, default: false)
    }
}
