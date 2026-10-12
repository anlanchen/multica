import Foundation

/// Name resolvers the issue-detail copy needs; the app supplies them from
/// its catalogs and formatters.
public struct IssueDetailNames {
    public var actor: (_ type: String, _ id: String) -> String
    public var status: (String) -> String
    public var priority: (String) -> String
    /// Date-only value (`YYYY-MM-DD`) as a short date ("Mar 5").
    public var date: (String) -> String
    /// Timestamp as a short date and time.
    public var time: (String) -> String
    public var label: (String) -> String?
    public var property: (String) -> String?

    public init(actor: @escaping (String, String) -> String, status: @escaping (String) -> String,
                priority: @escaping (String) -> String, date: @escaping (String) -> String,
                time: @escaping (String) -> String, label: @escaping (String) -> String? = { _ in nil },
                property: @escaping (String) -> String? = { _ in nil }) {
        self.actor = actor
        self.status = status
        self.priority = priority
        self.date = date
        self.time = time
        self.label = label
        self.property = property
    }
}

/// The parts of a wakeup rule its one-line description reads, from either a
/// live rule or the snapshot an activity entry stored.
public struct IssueDetailWakeupSpec: Sendable, Hashable {
    public var kind: String
    public var mode: String
    public var eventTypes: [String]
    public var agentID: String
    public var intervalSeconds: Int?
    public var nextFireAt: String?
    public var condition: JSONValue?
    public var filterActorType: String?
    public var filterActorID: String?
    public var filterAgentID: String?
    public var createdBy: String?
    public var createdByAgentID: String?

    public init(kind: String = "event", mode: String = "once", eventTypes: [String] = [], agentID: String = "",
                intervalSeconds: Int? = nil, nextFireAt: String? = nil, condition: JSONValue? = nil,
                filterActorType: String? = nil, filterActorID: String? = nil, filterAgentID: String? = nil) {
        self.kind = kind
        self.mode = mode
        self.eventTypes = eventTypes
        self.agentID = agentID
        self.intervalSeconds = intervalSeconds
        self.nextFireAt = nextFireAt
        self.condition = condition
        self.filterActorType = filterActorType
        self.filterActorID = filterActorID
        self.filterAgentID = filterAgentID
    }

    public init(json v: JSONValue) {
        self.init(
            kind: v["kind"]?.stringValue ?? "event",
            mode: v["mode"]?.stringValue ?? "once",
            eventTypes: v["event_types"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            agentID: v["agent_id"]?.stringValue ?? "",
            intervalSeconds: v["interval_seconds"]?.doubleValue.map { Int($0) },
            nextFireAt: v["next_fire_at"]?.stringValue,
            condition: v["condition"].flatMap { $0.isNull ? nil : $0 },
            filterActorType: v["filter_actor_type"]?.stringValue,
            filterActorID: v["filter_actor_id"]?.stringValue,
            filterAgentID: v["filter_agent_id"]?.stringValue)
        createdBy = v["created_by"]?.stringValue
        createdByAgentID = v["created_by_agent_id"]?.stringValue
    }

    /// Upstream wakeup-presentation `trigger`: what wakes the agent.
    public func describe(_ n: IssueDetailNames) -> String {
        if let c = condition, let s = Self.describe(condition: c, n) { return s }
        switch kind {
        case "at":
            return nextFireAt.map { tr("issues", "wakeups.at_time", ["time": n.time($0)]) } ?? tr("issues", "wakeups.scheduled_time")
        case "every":
            guard let s = intervalSeconds, s > 0 else { return tr("issues", "wakeups.scheduled_time") }
            if s % 3600 == 0 {
                return s == 3600 ? tr("issues", "wakeups.hourly") : tr("issues", "wakeups.every_hours", ["hours": s / 3600])
            }
            if s % 60 == 0 { return tr("issues", "wakeups.every", ["minutes": s / 60]) }
            return tr("issues", "wakeups.every_seconds", ["seconds": s])
        case "cron":
            return tr("issues", "wakeups.scheduled_time")
        default:
            break
        }
        let agent = filterAgentID.map { n.actor("agent", $0) } ?? tr("issues", "wakeups.agent_subject")
        if eventTypes.count == 1, let ev = eventTypes.first {
            let label = Self.eventName(ev, agent: agent)
            let actor = filterActorType.flatMap { t in filterActorID.map { n.actor(t, $0) } } ?? filterAgentID.map { n.actor("agent", $0) }
            if let actor, !ev.hasPrefix("task.") {
                return tr("issues", "wakeups.by_actor", ["condition": label, "agent": actor])
            }
            return label
        }
        let labels = eventTypes.map { ev -> String in
            let key = "wakeups." + Self.eventKey(ev)
            let s = tr("issues", key)
            return s == key ? ev : s
        }
        return labels.isEmpty ? tr("issues", "wakeups.any_event") : tr("issues", "wakeups.any_event") + ": " + labels.joined(separator: ", ")
    }

    /// `task.completed` → `run_completed`, `issue.assignee_changed` →
    /// `assignee_changed`, `comment.created` → `comment_created`.
    static func eventKey(_ event: String) -> String {
        if event.hasPrefix("task.") { return "run_" + event.dropFirst(5) }
        if event.hasPrefix("issue.") {
            let rest = String(event.dropFirst(6))
            return rest == "updated" ? "issue_updated" : rest
        }
        return event.replacingOccurrences(of: ".", with: "_")
    }

    static func eventName(_ event: String, agent: String) -> String {
        let key = "wakeups.conditions." + eventKey(event)
        let s = tr("issues", key, ["agent": agent])
        return s == key ? tr("issues", "wakeups.unknown_event", ["event": event]) : s
    }

    /// What the issue is waiting for, in a few words (upstream `waiting`).
    public func waiting(_ n: IssueDetailNames) -> String {
        if let c = condition, let s = Self.wait(condition: c, n) { return s }
        if kind != "event" {
            guard let next = nextFireAt else { return describe(n) }
            return tr("issues", "wakeups.wait.time", ["time": n.time(next), "agent": n.actor("agent", agentID)])
        }
        if eventTypes == ["comment.created"] {
            if let t = filterActorType, let id = filterActorID {
                return tr("issues", "wakeups.wait.reply_from", ["name": n.actor(t, id)])
            }
            return tr("issues", "wakeups.wait.reply_any")
        }
        let runEnds: Set<String> = ["task.completed", "task.failed", "task.cancelled"]
        if !eventTypes.isEmpty, eventTypes.allSatisfy(runEnds.contains) {
            if let a = filterAgentID { return tr("issues", "wakeups.wait.run_end", ["agent": n.actor("agent", a)]) }
            return tr("issues", "wakeups.wait.run_end_any")
        }
        return tr("issues", "wakeups.waiting_event")
    }

    /// Header chip copy: "<agent>: <what>"; time rules already name the agent.
    public func headline(_ n: IssueDetailNames) -> String {
        if kind != "event" && nextFireAt != nil { return waiting(n) }
        return tr("issues", "wakeups.wait.header", ["agent": n.actor("agent", agentID), "what": waiting(n)])
    }

    static func wait(condition c: JSONValue, _ n: IssueDetailNames) -> String? {
        switch c["type"]?.stringValue {
        case "issue_field":
            switch c["field"]?.stringValue {
            case "status": return tr("issues", "wakeups.wait.status", ["status": n.status(c["value"]?.stringValue ?? "")])
            case "assignee":
                return tr("issues", "wakeups.wait.assignee", ["name": n.actor(c["assignee_type"]?.stringValue ?? "member", c["assignee_id"]?.stringValue ?? "")])
            case "label":
                return tr("issues", "wakeups.wait.label", ["label": c["label_id"]?.stringValue.flatMap(n.label) ?? tr("issues", "wakeups.cond.unknown_label")])
            case "property":
                let name = c["property_id"]?.stringValue.flatMap(n.property) ?? tr("issues", "wakeups.cond.unknown_property")
                return tr("issues", "wakeups.wait.property", ["property": name, "value": c["value"]?.stringValue ?? ""])
            default: return nil
            }
        case "children_done":
            if let stage = c["stage"]?.doubleValue { return tr("issues", "wakeups.wait.children_stage", ["stage": Int(stage)]) }
            return tr("issues", "wakeups.wait.children_all")
        case "pull_request":
            return tr("issues", c["event"]?.stringValue == "merged" ? "wakeups.wait.pr_merged" : "wakeups.wait.pr_checks")
        case "other_issue":
            let issue = c["identifier"]?.stringValue ?? tr("issues", "wakeups.cond.another_issue")
            switch c["state"]?.stringValue {
            case "ended": return tr("issues", "wakeups.wait.other_ended", ["issue": issue])
            case "in_review": return tr("issues", "wakeups.wait.other_in_review", ["issue": issue])
            default: return tr("issues", "wakeups.wait.other_done", ["issue": issue])
            }
        default:
            return nil
        }
    }

    static func describe(condition c: JSONValue, _ n: IssueDetailNames) -> String? {
        switch c["type"]?.stringValue {
        case "issue_field":
            switch c["field"]?.stringValue {
            case "status":
                return tr("issues", "wakeups.cond.status", ["status": n.status(c["value"]?.stringValue ?? "")])
            case "assignee":
                return tr("issues", "wakeups.cond.assignee", ["name": n.actor(c["assignee_type"]?.stringValue ?? "member", c["assignee_id"]?.stringValue ?? "")])
            case "label":
                let name = c["label_id"]?.stringValue.flatMap(n.label) ?? tr("issues", "wakeups.cond.unknown_label")
                return tr("issues", "wakeups.cond.label", ["label": name])
            case "property":
                let name = c["property_id"]?.stringValue.flatMap(n.property) ?? tr("issues", "wakeups.cond.unknown_property")
                let raw = c["value"]
                let value: String
                if let b = raw?.boolValue { value = tr("issues", b ? "wakeups.cond.checked" : "wakeups.cond.unchecked") }
                else { value = raw?.stringValue ?? raw?.preview(limit: 40) ?? "" }
                return tr("issues", "wakeups.cond.property", ["property": name, "value": value])
            default:
                return nil
            }
        case "children_done":
            if let stage = c["stage"]?.doubleValue { return tr("issues", "wakeups.cond.children_stage", ["stage": Int(stage)]) }
            return tr("issues", "wakeups.cond.children_all")
        case "pull_request":
            return tr("issues", c["event"]?.stringValue == "merged" ? "wakeups.cond.pr_merged" : "wakeups.cond.pr_checks")
        case "other_issue":
            let issue = c["identifier"]?.stringValue ?? tr("issues", "wakeups.cond.another_issue")
            let key: String
            switch c["state"]?.stringValue {
            case "ended": key = "wakeups.cond.other_ended"
            case "in_review": key = "wakeups.cond.other_in_review"
            default: key = "wakeups.cond.other_done"
            }
            return tr("issues", key, ["issue": issue])
        default:
            return nil
        }
    }
}

/// Activity-feed copy (upstream issue-detail formatActivity and
/// wakeup-activity formatWakeupActivity).
public enum IssueDetailActivityText {
    public static let wakeupActions: Set<String> = ["wakeup_created", "wakeup_triggered", "wakeup_timed_out", "wakeup_paused", "wakeup_checkin"]

    static func detail(_ e: TimelineEntry, _ key: String) -> String? {
        guard let v = e.details?[key], !v.isNull else { return nil }
        return v.stringValue
    }

    public static func format(_ e: TimelineEntry, _ n: IssueDetailNames) -> String {
        let d = { (k: String) in detail(e, k) }
        let status = { (k: String?) in n.status(k ?? "?") }
        switch e.action ?? "" {
        case "created":
            return tr("issues", "activity.created")
        case "status_changed":
            if d("source") == "pr_automation" {
                return tr("issues", "activity.status_changed_pr", ["from": status(d("from")), "to": status(d("to")), "prs": d("pull_requests") ?? ""])
            }
            return tr("issues", "activity.status_changed", ["from": status(d("from")), "to": status(d("to"))])
        case "pr_auto_complete_changed":
            return tr("issues", e.details?["disabled"]?.boolValue == true ? "activity.pr_auto_complete_disabled" : "activity.pr_auto_complete_enabled")
        case "priority_changed":
            return tr("issues", "activity.priority_changed", ["from": n.priority(d("from") ?? "?"), "to": n.priority(d("to") ?? "?")])
        case "assignee_changed":
            if d("to_type") == e.actorType && d("to_id") == e.actorID { return tr("issues", "activity.self_assigned") }
            if let t = d("to_type"), let id = d("to_id"), !id.isEmpty {
                return tr("issues", "activity.assigned_to", ["name": n.actor(t, id)])
            }
            if d("from_id") != nil && d("to_id") == nil { return tr("issues", "activity.removed_assignee") }
            return tr("issues", "activity.changed_assignee")
        case "start_date_changed":
            guard let to = d("to"), !to.isEmpty else { return tr("issues", "activity.start_date_removed") }
            return tr("issues", "activity.start_date_set", ["date": n.date(to)])
        case "due_date_changed":
            guard let to = d("to"), !to.isEmpty else { return tr("issues", "activity.due_date_removed") }
            return tr("issues", "activity.due_date_set", ["date": n.date(to)])
        case "title_changed":
            return tr("issues", "activity.title_renamed", ["from": d("from") ?? "?", "to": d("to") ?? "?"])
        case "description_updated":
            return tr("issues", "activity.description_updated")
        case "duplicate_marked":
            return tr("issues", "activity.duplicate_marked", ["identifier": nonEmpty(d("original_identifier")) ?? "?"])
        case "duplicate_unmarked":
            let identifier = nonEmpty(d("original_identifier")) ?? "?"
            if d("reason") == "original_deleted" {
                return tr("issues", "activity.duplicate_unmarked_original_deleted", ["identifier": identifier])
            }
            if let to = nonEmpty(d("to")) {
                return tr("issues", "activity.duplicate_unmarked_to", ["identifier": identifier, "status": n.status(to)])
            }
            return tr("issues", "activity.duplicate_unmarked", ["identifier": identifier])
        case "duplicate_added":
            return tr("issues", "activity.duplicate_added", ["identifier": nonEmpty(d("duplicate_identifier")) ?? "?"])
        case "duplicate_removed":
            return tr("issues", "activity.duplicate_removed", ["identifier": nonEmpty(d("duplicate_identifier")) ?? "?"])
        case "task_completed":
            return tr("issues", "activity.task_completed", ["count": e.coalescedCount ?? 1])
        case "task_failed":
            return tr("issues", "activity.task_failed", ["count": e.coalescedCount ?? 1])
        case "squad_leader_evaluated":
            let reason = d("reason")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let base: String
            switch d("outcome") {
            case "action": base = "activity.squad_leader_action"
            case "no_action": base = "activity.squad_leader_no_action"
            case "failed": base = "activity.squad_leader_failed"
            default: return tr("issues", "activity.squad_leader_evaluated")
            }
            return reason.isEmpty ? tr("issues", base) : tr("issues", base + "_reason", ["reason": reason])
        case let a where wakeupActions.contains(a):
            return formatWakeup(e, n)
        default:
            return e.action ?? ""
        }
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    static func formatWakeup(_ e: TimelineEntry, _ n: IssueDetailNames) -> String {
        let details = e.details ?? .null
        let spec = details["wakeup"].map(IssueDetailWakeupSpec.init(json:))
        let condition = spec?.describe(n) ?? ""
        let agent = spec.map { $0.agentID.isEmpty ? "" : n.actor("agent", $0.agentID) } ?? ""
        switch e.action {
        case "wakeup_created":
            return tr("issues", "activity.wakeup_created", ["condition": condition, "agent": agent])
        case "wakeup_triggered":
            if details["rule"]?.stringValue == "child_done" {
                let count = details["total"]?.doubleValue.map { Int($0) } ?? 1
                let closed: String
                if let stage = details["stage"]?.doubleValue, stage > 0 {
                    closed = tr("issues", "activity.wakeup_child_done_stage", ["stage": Int(stage), "count": count])
                } else {
                    closed = tr("issues", "activity.wakeup_child_done_all", ["count": count])
                }
                let targetType = details["target_type"]?.stringValue
                let name = targetType.flatMap { t in details["target_id"]?.stringValue.map { n.actor(t, $0) } }
                    ?? tr("issues", "activity.wakeup_assignee")
                switch details["outcome"]?.stringValue ?? (targetType != nil ? "woke" : "none") {
                case "woke": return closed + tr("issues", "activity.wakeup_child_done_woke", ["name": name])
                case "notified": return closed + tr("issues", "activity.wakeup_child_done_notified", ["name": name])
                case "merged": return closed + tr("issues", "activity.wakeup_child_done_merged", ["name": name])
                case "acknowledged": return closed + tr("issues", "activity.wakeup_child_done_acknowledged", ["name": name])
                default: return closed
                }
            }
            let events = details["events"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if events == ["wakeup.manual"], let actor = details["actor_id"]?.stringValue {
                return tr("issues", "activity.wakeup_triggered_manual", ["name": n.actor("member", actor), "agent": agent])
            }
            switch details["outcome"]?.stringValue {
            case "merged": return tr("issues", "activity.wakeup_triggered_merged", ["condition": condition, "agent": agent])
            case "acknowledged": return tr("issues", "activity.wakeup_triggered_acknowledged", ["condition": condition, "agent": agent])
            default: return tr("issues", "activity.wakeup_triggered", ["condition": condition, "agent": agent])
            }
        case "wakeup_timed_out":
            return details["woke"]?.boolValue == true
                ? tr("issues", "activity.wakeup_timed_out_wake", ["condition": condition, "agent": agent])
                : tr("issues", "activity.wakeup_timed_out_end", ["condition": condition])
        case "wakeup_paused":
            let reason = details["reason"]?.stringValue ?? "rate"
            return tr("issues", "wakeups.paused.\(reason)", ["count": details["limit"]?.doubleValue.map { Int($0) } ?? 0])
        case "wakeup_checkin":
            let count = e.coalescedCount ?? 1
            let note = details["note"]?.stringValue ?? ""
            return count > 1
                ? tr("issues", "activity.wakeup_checkin_coalesced", ["count": count, "note": note])
                : tr("issues", "activity.wakeup_checkin", ["note": note])
        default:
            return e.action ?? ""
        }
    }

    /// The small tag naming the rule a wakeup entry came from.
    public static func wakeupChip(_ e: TimelineEntry, _ n: IssueDetailNames) -> String? {
        let details = e.details ?? .null
        if details["rule"]?.stringValue == "child_done" { return tr("issues", "activity.wakeup_chip_system") }
        guard e.action != "wakeup_created", let raw = details["wakeup"] else { return nil }
        let spec = IssueDetailWakeupSpec(json: raw)
        if e.action == "wakeup_checkin" { return spec.describe(n) }
        let creator = spec.createdByAgentID.map { n.actor("agent", $0) } ?? spec.createdBy.map { n.actor("member", $0) }
        return creator.map { tr("issues", "activity.wakeup_chip_created_by", ["name": $0]) }
    }

    /// The issue a duplicate-mark entry names, when it can still be opened.
    public static func linkTarget(_ e: TimelineEntry) -> (id: String, identifier: String)? {
        switch e.action {
        case "duplicate_marked", "duplicate_unmarked":
            if detail(e, "reason") == "original_deleted" { return nil }
            guard let id = nonEmpty(detail(e, "original_id")), let ident = nonEmpty(detail(e, "original_identifier")) else { return nil }
            return (id, ident)
        case "duplicate_added", "duplicate_removed":
            guard let id = nonEmpty(detail(e, "duplicate_id")), let ident = nonEmpty(detail(e, "duplicate_identifier")) else { return nil }
            return (id, ident)
        default:
            return nil
        }
    }
}

/// Upstream run-confirm-gate: the two single-issue writes that can hand
/// work to an agent (assigning an agent/squad owner, promoting an owned
/// issue out of backlog) confirm first.
public enum IssueDetailRunGate: Sendable, Hashable {
    case assign(type: String, id: String)
    case promote(status: String, type: String, id: String)

    public static func intent(currentStatus: String, currentCategory: StatusCategory?, owner: ActorRef?,
                              newAssignee: ActorRef?, newStatus: String?, categoryOf: (String) -> StatusCategory?) -> IssueDetailRunGate? {
        let parked = currentStatus == "backlog"
        if let a = newAssignee, a.type == "agent" || a.type == "squad", !a.id.isEmpty, !parked {
            return .assign(type: a.type, id: a.id)
        }
        let category = currentCategory ?? categoryOf(currentStatus)
        if let status = newStatus, status != currentStatus, parked || category == nil,
           let owner, owner.type == "agent" || owner.type == "squad", !owner.id.isEmpty, status != "backlog" {
            let target = categoryOf(status)
            if target == nil || !(target == .done || target == .closed) {
                return .promote(status: status, type: owner.type, id: owner.id)
            }
        }
        return nil
    }
}

public enum IssueDetailFormat {
    /// Upstream plainTriggerSummary: one-line plain text for a trigger
    /// snapshot (images, links, mentions and entities flattened).
    public static func plainTriggerSummary(_ raw: String, imageLabel: String) -> String {
        var s = raw
        func replace(_ pattern: String, _ template: String) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        let escapedImage = NSRegularExpression.escapedTemplate(for: imageLabel)
        replace(#"\[(@?[^\]]*)\]\(mention://[^)]*\)"#, "$1")
        replace(#"!\[[^\]]*\]\([^)]*\)"#, escapedImage)
        replace(#"!\[[^\]]*(?:\]\([^)]*)?…?$"#, escapedImage)
        replace(#"\[([^\]]*)\]\([^)]*\)"#, "$1")
        replace(#"\[([^\]]*)\]\([^)]*…$"#, "$1…")
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&nbsp;": " "]
        if s.contains("&") {
            guard let re = try? NSRegularExpression(pattern: "&(amp|lt|gt|quot|#39|#x27|nbsp);") else { return s }
            var out = ""
            var last = s.startIndex
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let r = Range(m.range, in: s) else { continue }
                out += s[last..<r.lowerBound]
                out += entities[String(s[r])] ?? ""
                last = r.upperBound
            }
            out += s[last...]
            s = out
        }
        replace(#"\s+"#, " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Upstream descriptionPreview: first meaningful text of a comment.
    public static func preview(_ markdown: String, limit: Int = 80) -> String {
        let flat = plainTriggerSummary(markdown, imageLabel: "[Image]")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// Case-insensitive occurrence count, for the in-page find bar.
    public static func occurrences(of query: String, in text: String) -> Int {
        guard !query.isEmpty, !text.isEmpty else { return 0 }
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let r = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range) {
            count += 1
            range = r.upperBound..<text.endIndex
        }
        return count
    }

    /// Sub-issues grouped by stage ascending, unstaged last.
    public static func groupByStage<T>(_ items: [T], stage: (T) -> Int?) -> [(stage: Int?, items: [T])] {
        var byStage: [Int: [T]] = [:]
        var unstaged: [T] = []
        for item in items {
            if let s = stage(item) { byStage[s, default: []].append(item) } else { unstaged.append(item) }
        }
        var out: [(stage: Int?, items: [T])] = byStage.keys.sorted().map { ($0, byStage[$0]!) }
        if !unstaged.isEmpty { out.append((nil, unstaged)) }
        return out
    }

    public struct WorkdirTarget: Sendable, Hashable {
        public var path: String
        public var branchName: String?
        public var isProjectDirectory: Bool
    }

    /// Upstream resolveWorkdirCopyTarget: the latest run's workdir, or its
    /// durable project directory once it ended.
    public static func workdirTarget(_ tasks: [AgentTaskRecord]) -> WorkdirTarget? {
        let terminal: Set<String> = ["completed", "failed", "cancelled"]
        func trimmed(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        let latest = tasks.filter { t in
            trimmed(t.workDir) != nil || (terminal.contains(t.status) && trimmed(t.durableWorkDir) != nil)
        }.max { $0.createdAt < $1.createdAt }
        guard let task = latest else { return nil }
        if terminal.contains(task.status), let durable = trimmed(task.durableWorkDir) {
            return WorkdirTarget(path: durable, branchName: trimmed(task.branchName), isProjectDirectory: true)
        }
        guard let dir = trimmed(task.workDir) else { return nil }
        return WorkdirTarget(path: dir, branchName: trimmed(task.branchName), isProjectDirectory: false)
    }
}
