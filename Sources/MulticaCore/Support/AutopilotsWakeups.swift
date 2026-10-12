import Foundation

/// What a person fills in to add an issue wakeup from the workspace list
/// (upstream issues/components/wakeup-draft.ts), and its mapping onto the
/// wakeup API.
public struct AutopilotsWakeupDraft: Sendable, Hashable {
    public enum Condition: String, Sendable, CaseIterable {
        case at, recurring, reply, field, runEnd = "run_end", children, pullRequest = "pull_request", otherIssue = "other_issue", custom
    }

    public enum Field: String, Sendable, CaseIterable { case status, assignee, label, property }
    public enum AtPreset: String, Sendable, CaseIterable { case tenMinutes = "10m", oneHour = "1h", tomorrow, custom }
    public enum Recurrence: String, Sendable, CaseIterable { case hourly, daily, weekdays }

    public enum DraftError: String, Error, Sendable {
        case missingCondition = "missing_condition"
        case missingValue = "missing_value"
        case missingIssue = "missing_issue"
        case missingAgent = "missing_agent"
        case missingEvents = "missing_events"
        case instructionInvalid = "instruction_invalid"
        case futureTime = "future_time"
        case untilFuture = "until_future"
    }

    public struct Actor: Sendable, Hashable {
        public var type: String
        public var id: String
        public init(type: String, id: String) {
            self.type = type
            self.id = id
        }
    }

    /// The 25 issue-scoped events, in catalog order.
    public static let eventTypes = [
        "task.queued", "task.dispatched", "task.started", "task.deferred", "task.waiting_local_directory",
        "task.completed", "task.failed", "task.cancelled", "issue.updated", "issue.status_changed",
        "issue.assignee_changed", "issue.parent_changed", "issue.project_changed", "issue.labels_changed",
        "issue.properties_changed", "issue.metadata_changed", "comment.created", "comment.updated",
        "comment.deleted", "comment.resolved", "comment.unresolved", "reaction.added", "reaction.removed",
        "attachment.attached", "attachment.detached",
    ]
    public static let runEndEvents = ["task.completed", "task.failed", "task.cancelled"]
    public static let waitDays = [1, 3, 7, 30]
    public static let maxFiresOptions = [5, 10, 20, 50]

    public var condition: Condition?
    public var atPreset: AtPreset = .oneHour
    /// Local date-time picked for a custom one-time wakeup.
    public var atCustom: Date?
    public var recurrence: Recurrence = .daily
    /// The rule ends at the end of this local day.
    public var until: Date
    public var replyActor: Actor?
    public var runAgentID = ""
    public var events: [String] = []
    public var field: Field = .status
    public var fieldTarget = ""
    public var fieldValue = ""
    public var assignee: Actor?
    public var stage: Int?
    public var prEvent = "checks_finished"
    public var otherIssueID: String?
    public var otherIssueIdentifier = ""
    public var otherState = "done"
    public var maxFires = 20
    public var agentID: String
    public var instruction = ""
    public var mode = "once"
    public var waitDays = 7
    public var onTimeout = "wake"
    public var timezone: String

    public init(agentID: String, timezone: String, now: Date = Date(), calendar: Calendar = .current) {
        self.agentID = agentID
        self.timezone = timezone
        until = calendar.date(byAdding: .day, value: 7, to: now) ?? now
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.condition == b.condition && a.atPreset == b.atPreset && a.atCustom == b.atCustom && a.recurrence == b.recurrence
            && a.until == b.until && a.replyActor == b.replyActor && a.runAgentID == b.runAgentID && a.events == b.events
            && a.field == b.field && a.fieldTarget == b.fieldTarget && a.fieldValue == b.fieldValue && a.assignee == b.assignee
            && a.stage == b.stage && a.prEvent == b.prEvent && a.otherIssueID == b.otherIssueID && a.otherState == b.otherState
            && a.maxFires == b.maxFires && a.agentID == b.agentID && a.instruction == b.instruction && a.mode == b.mode
            && a.waitDays == b.waitDays && a.onTimeout == b.onTimeout && a.timezone == b.timezone
    }

    public func hash(into h: inout Hasher) {
        h.combine(condition)
        h.combine(agentID)
        h.combine(instruction)
    }

    /// Conditions that wait for something to happen, with a deadline.
    public static func isEventCondition(_ c: Condition?) -> Bool {
        guard let c else { return false }
        return c != .at && c != .recurring
    }

    /// Whether the rule would wake the issue's agent assignee on members'
    /// comments, which already run it.
    public func wakesAssigneeOnComments(assigneeAgentID: String?) -> Bool {
        guard let assigneeAgentID, agentID == assigneeAgentID else { return false }
        if condition == .reply { return replyActor?.type != "agent" }
        return condition == .custom && events.contains("comment.created")
    }

    /// A property value typed as the property stores it.
    public static func propertyValue(type: String?, raw: String) -> JSONValue {
        if type == "checkbox" { return .bool(raw == "true") }
        if type == "number", !raw.trimmingCharacters(in: .whitespaces).isEmpty, let n = Double(raw), n.isFinite { return .number(n) }
        return .string(raw)
    }

    /// The platform-evaluated predicate for a condition choice, if it is one.
    public func platformCondition(propertyType: String? = nil) -> Result<JSONValue, DraftError>? {
        switch condition {
        case .field:
            switch field {
            case .assignee:
                guard let a = assignee else { return .failure(.missingValue) }
                return .success(["type": "issue_field", "field": "assignee", "assignee_type": .string(a.type), "assignee_id": .string(a.id)])
            case .status:
                guard !fieldTarget.isEmpty else { return .failure(.missingValue) }
                return .success(["type": "issue_field", "field": "status", "value": .string(fieldTarget)])
            case .label:
                guard !fieldTarget.isEmpty else { return .failure(.missingValue) }
                return .success(["type": "issue_field", "field": "label", "label_id": .string(fieldTarget)])
            case .property:
                guard !fieldTarget.isEmpty else { return .failure(.missingValue) }
                let v = fieldValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !v.isEmpty else { return .failure(.missingValue) }
                return .success(["type": "issue_field", "field": "property", "property_id": .string(fieldTarget),
                                 "value": Self.propertyValue(type: propertyType, raw: v)])
            }
        case .children:
            if let stage, stage != 0 { return .success(["type": "children_done", "stage": .number(Double(stage))]) }
            return .success(["type": "children_done"])
        case .pullRequest:
            return .success(["type": "pull_request", "event": .string(prEvent)])
        case .otherIssue:
            guard let id = otherIssueID else { return .failure(.missingIssue) }
            return .success(["type": "other_issue", "issue_id": .string(id), "state": .string(otherState)])
        default:
            return nil
        }
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// Maps the draft onto the wakeup API; the server re-validates.
    public func buildInput(now: Date = Date(), propertyType: String? = nil, calendar: Calendar = .current) -> Result<IssueWakeupInput, DraftError> {
        guard let condition else { return .failure(.missingCondition) }
        guard !agentID.isEmpty else { return .failure(.missingAgent) }
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 12000 else { return .failure(.instructionInvalid) }
        var input = IssueWakeupInput(agentId: agentID, instruction: text)
        switch condition {
        case .at:
            let at: Date?
            switch atPreset {
            case .tenMinutes: at = now.addingTimeInterval(600)
            case .oneHour: at = now.addingTimeInterval(3600)
            case .tomorrow:
                at = calendar.date(byAdding: .day, value: 1, to: now)
                    .flatMap { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
            case .custom: at = atCustom
            }
            guard let at, at > now else { return .failure(.futureTime) }
            input.kind = "at"
            input.mode = "once"
            input.at = Self.iso(at)
        case .recurring:
            guard let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: until), end > now else { return .failure(.untilFuture) }
            if recurrence == .hourly {
                input.kind = "every"
                input.intervalSeconds = 3600
            } else {
                input.kind = "cron"
                input.cronExpression = recurrence == .daily ? "0 9 * * *" : "0 9 * * 1-5"
                input.timezone = timezone
            }
            input.mode = "continuous"
            input.expiresAt = Self.iso(end)
        default:
            input.kind = "event"
            input.mode = .string(mode)
            input.expiresInSeconds = waitDays * 86400
            input.onTimeout = onTimeout
            if mode == "continuous" { input.maxFires = maxFires }
            switch platformCondition(propertyType: propertyType) {
            case .failure(let e)?: return .failure(e)
            case .success(let c)?: input.condition = c
            case nil:
                if condition == .reply {
                    input.eventTypes = ["comment.created"]
                    if let a = replyActor {
                        input.filterActorType = a.type
                        input.filterActorId = a.id
                    }
                } else if condition == .runEnd {
                    input.eventTypes = Self.runEndEvents
                    if !runAgentID.isEmpty { input.filterAgentId = runAgentID }
                } else {
                    guard !events.isEmpty else { return .failure(.missingEvents) }
                    input.eventTypes = events
                }
            }
        }
        return .success(input)
    }
}

/// Lifecycle of a wakeup rule (upstream wakeup-presentation.ts).
public enum AutopilotsWakeupState {
    public static func isActiveRun(_ status: String?) -> Bool {
        guard let status else { return false }
        return ["queued", "deferred", "dispatched", "running", "waiting_local_directory"].contains(status)
    }

    /// The `issues:wakeups.rule_states.*` key of a rule.
    public static func state(_ w: WorkspaceWakeup, closed: Bool = false, now: Date = Date()) -> String {
        if closed { return "issue_closed" }
        if w.enabled { return w.kind == "event" ? "waiting" : "scheduled" }
        if w.pausedReason != nil { return "paused" }
        if w.timedOutAt != nil { return "timed_out" }
        if w.disabledAt != nil { return "disabled" }
        if w.lastTaskId != nil { return "triggered" }
        if w.kind == "at", let next = w.nextFireAt.flatMap(Timestamp.parse), next <= now { return "expired" }
        return "inactive"
    }

    /// What the enable control offers: a switch, withdrawing a queued run,
    /// rescheduling a one-time rule, or re-subscribing a consumed one.
    public enum Control: Equatable, Sendable { case toggle, withdraw, reschedule, resubscribe }

    public static func control(_ w: WorkspaceWakeup, now: Date = Date()) -> (control: Control, canEnable: Bool) {
        let status = w.task?.status.rawValue ?? w.lastTaskStatus
        let canDisable = w.disabledAt == nil && (w.enabled || (["queued", "deferred"].contains(status ?? "") && w.task?.startedAt == nil))
        let consumed = !w.enabled && w.mode == "once" && (w.disabledAt == nil || w.lastTaskId != nil)
        let expired = w.kind == "at" && (w.nextFireAt.flatMap(Timestamp.parse).map { $0 <= now } ?? true)
        let needsRearm = !w.enabled && (consumed || expired)
        let canEnable = !w.issueClosed && (!isActiveRun(status) || w.mode == "continuous")
        if w.enabled || (!needsRearm && !canDisable) { return (.toggle, canEnable) }
        if canDisable { return (.withdraw, canEnable) }
        return (w.kind == "at" ? .reschedule : .resubscribe, canEnable)
    }
}
