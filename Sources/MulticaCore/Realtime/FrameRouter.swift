import Foundation

/// Result of decoding one inbound WebSocket frame.
public enum DecodedFrame: Sendable {
    case event(RealtimeEvent)
    case taskMessage(TaskMessage)
    case control(ControlFrame)
    /// A `task:message` for a run nobody is watching. Its body was skipped,
    /// not decoded.
    case droppedTaskMessage
    /// Unknown, malformed, or deliberately ignored frame.
    case ignored(String)
}

public enum ControlFrame: Sendable, Equatable {
    case authAck
    case authError(String)
    case subscribeAck(scope: String, id: String)
    case subscribeError(scope: String, id: String, error: String)
    case pong
}

/// Decodes WebSocket frames in a single pass.
///
/// The envelope decoder reads `type` first and only then decides how much of
/// `payload` to materialise. For `task:message` it reads `task_id` /
/// `issue_id`, asks the `InterestRegistry`, and stops there when nobody is
/// watching — so the unbounded `input` / `output` strings of other people's
/// runs are never unescaped or allocated.
public final class FrameRouter: @unchecked Sendable {
    private let decoder: JSONDecoder
    private let fastPath: Bool
    public let interest: InterestRegistry

    /// `fastPath: false` exists for benchmarks that compare strategies.
    public init(interest: InterestRegistry, fastPath: Bool = true) {
        self.interest = interest
        self.fastPath = fastPath
        let d = JSONDecoder()
        d.userInfo[FrameRouter.interestKey] = interest
        decoder = d
    }

    static let interestKey = CodingUserInfoKey(rawValue: "multica.interest")!

    public func decode(_ frame: WebSocketFrame) -> DecodedFrame {
        let data: Data
        switch frame {
        case .text(let s): data = Data(s.utf8)
        case .data(let d): data = d
        }
        return decode(data)
    }

    public func decode(_ data: Data) -> DecodedFrame {
        if fastPath, let keys = FastRouting.taskMessageKeys(data), !interest.wants(taskID: keys.taskID, issueID: keys.issueID) {
            return .droppedTaskMessage
        }
        do {
            return try decoder.decode(Envelope.self, from: data).result
        } catch {
            return .ignored("malformed frame")
        }
    }
}

private struct Envelope: Decodable {
    var result: DecodedFrame

    enum CodingKeys: String, CodingKey {
        case type, payload, error
    }

    // Payload shapes, mirroring server/pkg/protocol.
    struct IssuePayload: Decodable {
        var issue: Issue
        var status_changed: Bool?
        var assignee_changed: Bool?
        var project_changed: Bool?
    }
    struct IssueIDPayload: Decodable { var issue_id: String }
    struct IssueLabelsPayload: Decodable { var issue_id: String; var labels: [IssueLabel] }
    struct CommentPayload: Decodable { var comment: Comment }
    struct CommentDeletedPayload: Decodable { var comment_id: String; var issue_id: String }
    struct ActivityPayload: Decodable { var issue_id: String; var entry: TimelineEntry }
    struct InboxNewPayload: Decodable { var item: InboxItem }
    struct AgentPayload: Decodable { var agent: Agent }
    struct WorkspaceDeletedPayload: Decodable { var workspace_id: String }
    struct ScopePayload: Decodable { var scope: String?; var id: String?; var error: String? }

    /// Routing fields only. Decoding this from the payload container reads
    /// two keys and skips everything else.
    struct TaskHead: Decodable {
        var task_id: String
        var issue_id: String?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = try c.decodeIfPresent(String.self, forKey: .type) else {
            // The server answers a failed token handshake with a bare
            // {"error": "..."} frame before closing.
            if let error = try c.decodeIfPresent(String.self, forKey: .error) {
                result = .control(.authError(error))
            } else {
                result = .ignored("frame without type")
            }
            return
        }

        func payload<T: Decodable>(_ t: T.Type) throws -> T {
            try c.decode(T.self, forKey: .payload)
        }

        switch type {
        case "task:message":
            let head = try payload(TaskHead.self)
            let interest = decoder.userInfo[FrameRouter.interestKey] as? InterestRegistry
            if let interest, !interest.wants(taskID: head.task_id, issueID: head.issue_id) {
                result = .droppedTaskMessage
            } else {
                result = .taskMessage(try payload(TaskMessage.self))
            }

        case "issue:created", "issue:updated":
            let p = try payload(IssuePayload.self)
            result = .event(.issueUpsert(p.issue, IssueChangeFlags(
                created: type == "issue:created",
                statusChanged: p.status_changed ?? false,
                assigneeChanged: p.assignee_changed ?? false,
                projectChanged: p.project_changed ?? false)))
        case "issue:deleted":
            result = .event(.issueDeleted(issueID: try payload(IssueIDPayload.self).issue_id))
        case "issue_labels:changed":
            let p = try payload(IssueLabelsPayload.self)
            result = .event(.issueLabels(issueID: p.issue_id, labels: p.labels))

        case "comment:created", "comment:updated", "comment:resolved", "comment:unresolved":
            result = .event(.commentUpsert(try payload(CommentPayload.self).comment))
        case "comment:deleted":
            let p = try payload(CommentDeletedPayload.self)
            result = .event(.commentDeleted(commentID: p.comment_id, issueID: p.issue_id))
        case "activity:created":
            let p = try payload(ActivityPayload.self)
            result = .event(.activity(issueID: p.issue_id, entry: p.entry))

        case "task:queued", "task:dispatch", "task:running", "task:waiting_local_directory",
             "task:completed", "task:failed", "task:cancelled":
            var lifecycle = try payload(TaskLifecycle.self)
            if type == "task:dispatch" && lifecycle.status == .queued {
                lifecycle.status = .dispatched
            }
            result = .event(.taskLifecycle(lifecycle))

        case "inbox:new":
            result = .event(.inboxNew(try payload(InboxNewPayload.self).item))
        case "inbox:read", "inbox:unread", "inbox:archived", "inbox:unarchived",
             "inbox:batch-read", "inbox:batch-archived":
            result = .event(.inboxChanged)

        case "agent:status", "agent:created", "agent:archived", "agent:restored":
            result = .event(.agentUpsert(try payload(AgentPayload.self).agent))

        case "member:added", "member:updated", "member:removed":
            result = .event(.catalogChanged(.members))
        case "issue_status:changed":
            result = .event(.catalogChanged(.statuses))
        case "label:created", "label:updated", "label:deleted":
            result = .event(.catalogChanged(.labels))
        case "daemon:register":
            result = .event(.catalogChanged(.runtimes))
        case "workspace:updated":
            result = .event(.catalogChanged(.workspace))
        case "workspace:deleted":
            result = .event(.workspaceDeleted(workspaceID: try payload(WorkspaceDeletedPayload.self).workspace_id))

        case "auth_ack":
            result = .control(.authAck)
        case "pong":
            result = .control(.pong)
        case "subscribe_ack":
            let p = (try? payload(ScopePayload.self))
            result = .control(.subscribeAck(scope: p?.scope ?? "", id: p?.id ?? ""))
        case "subscribe_error":
            let p = (try? payload(ScopePayload.self))
            result = .control(.subscribeError(scope: p?.scope ?? "", id: p?.id ?? "", error: p?.error ?? ""))

        case "daemon:heartbeat", "task:progress":
            // High-frequency liveness noise; nothing on screen reads it.
            result = .ignored(type)

        default:
            let raw = (try? c.decodeIfPresent(JSONValue.self, forKey: .payload)) ?? .null
            result = .event(.resource(type: type, payload: raw))
        }
    }
}
