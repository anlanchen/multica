import Foundation

// MARK: - List view state (upstream autopilots/stores/view-store.ts)

/// View preferences of the autopilots list, persisted per workspace.
public struct AutopilotsListState: Codable, Sendable, Hashable {
    /// The promoted status dimension; "all" = active + paused.
    public enum Scope: String, Codable, Sendable, CaseIterable { case all, active, paused }
    public enum SortField: String, Codable, Sendable, CaseIterable { case name, lastRun, nextRun, created }
    public enum SortDirection: String, Codable, Sendable { case asc, desc }
    public enum Column: String, Codable, Sendable, CaseIterable { case assignee, trigger, lastRun, nextRun, mode, creator, created }

    public struct Filters: Codable, Sendable, Hashable {
        public var assignees: [String] = []
        public var modes: [String] = []
        public var triggerKinds: [String] = []
        public var creators: [String] = []

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            assignees = (try? c.decode([String].self, forKey: .assignees)) ?? []
            modes = (try? c.decode([String].self, forKey: .modes)) ?? []
            triggerKinds = (try? c.decode([String].self, forKey: .triggerKinds)) ?? []
            creators = (try? c.decode([String].self, forKey: .creators)) ?? []
        }

        public var activeDimensions: Int {
            [assignees, modes, triggerKinds, creators].filter { !$0.isEmpty }.count
        }
    }

    public enum FilterKey: Sendable { case assignees, modes, triggerKinds, creators }

    public static let defaultDirection: [SortField: SortDirection] = [.name: .asc, .lastRun: .desc, .nextRun: .asc, .created: .desc]
    public static let defaultHiddenColumns: [Column] = [.mode, .creator, .created]

    public var scope: Scope = .all
    public var sortField: SortField = .lastRun
    public var sortDirection: SortDirection = .desc
    public var hiddenColumns: [Column] = AutopilotsListState.defaultHiddenColumns
    public var filters = Filters()

    public init() {}

    /// Lenient: a retired scope or a payload from before a field existed
    /// falls back to the default instead of failing the whole state.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = (try? c.decode(Scope.self, forKey: .scope)) ?? .all
        sortField = (try? c.decode(SortField.self, forKey: .sortField)) ?? .lastRun
        sortDirection = (try? c.decode(SortDirection.self, forKey: .sortDirection)) ?? Self.defaultDirection[sortField] ?? .desc
        if let raw = try? c.decode([String].self, forKey: .hiddenColumns) {
            hiddenColumns = raw.compactMap(Column.init(rawValue:))
        }
        filters = (try? c.decode(Filters.self, forKey: .filters)) ?? Filters()
    }

    public func isVisible(_ column: Column) -> Bool { !hiddenColumns.contains(column) }

    /// Header click: flips the active field, otherwise switches to the field
    /// with its default direction.
    public mutating func toggleSort(_ field: SortField) {
        if sortField == field {
            sortDirection = sortDirection == .asc ? .desc : .asc
        } else {
            sortField = field
            sortDirection = Self.defaultDirection[field] ?? .asc
        }
    }

    /// Display panel select: switches field with its default direction.
    public mutating func setSortField(_ field: SortField) {
        guard sortField != field else { return }
        sortField = field
        sortDirection = Self.defaultDirection[field] ?? .asc
    }

    public mutating func toggleColumn(_ column: Column) {
        if let i = hiddenColumns.firstIndex(of: column) {
            hiddenColumns.remove(at: i)
        } else {
            hiddenColumns.append(column)
        }
    }

    public mutating func toggleFilter(_ key: FilterKey, _ value: String) {
        func toggle(_ list: inout [String]) {
            if let i = list.firstIndex(of: value) { list.remove(at: i) } else { list.append(value) }
        }
        switch key {
        case .assignees: toggle(&filters.assignees)
        case .modes: toggle(&filters.modes)
        case .triggerKinds: toggle(&filters.triggerKinds)
        case .creators: toggle(&filters.creators)
        }
    }

    public mutating func clearFilters() { filters = Filters() }
}

// MARK: - List derivation (upstream autopilots-page.tsx / autopilot-list-toolbar.tsx)

public enum AutopilotsList {
    /// Composite "type:id" value for polymorphic actor filters.
    public static func actorFilterValue(_ type: String, _ id: String) -> String { "\(type):\(id)" }

    /// Per-scope totals from the full set; archived rows are excluded.
    public static func scopeCounts(_ autopilots: [Autopilot]) -> [AutopilotsListState.Scope: Int] {
        var active = 0
        var paused = 0
        for a in autopilots where a.status != "archived" {
            if a.status == "paused" { paused += 1 } else { active += 1 }
        }
        return [.all: active + paused, .active: active, .paused: paused]
    }

    public static func scopeRows(_ autopilots: [Autopilot], scope: AutopilotsListState.Scope) -> [Autopilot] {
        switch scope {
        case .all: return autopilots.filter { $0.status != "archived" }
        case .active: return autopilots.filter { $0.status == "active" }
        case .paused: return autopilots.filter { $0.status == "paused" }
        }
    }

    /// Filters, then sorts, the scope's rows.
    public static func visibleRows(_ rows: [Autopilot], state: AutopilotsListState) -> [Autopilot] {
        let f = state.filters
        var out = rows.filter { a in
            if !f.assignees.isEmpty && !f.assignees.contains(actorFilterValue(a.assigneeType, a.assigneeId)) { return false }
            if !f.modes.isEmpty && !f.modes.contains(a.executionMode) { return false }
            if !f.triggerKinds.isEmpty && !(a.triggerKinds ?? []).contains(where: { f.triggerKinds.contains($0) }) { return false }
            if !f.creators.isEmpty && !f.creators.contains(actorFilterValue(a.createdByType, a.createdById)) { return false }
            return true
        }
        let asc = state.sortDirection == .asc
        func byTitle(_ a: Autopilot, _ b: Autopilot) -> Bool {
            a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        func time(_ s: String?) -> Double? { s.flatMap(Timestamp.parse)?.timeIntervalSince1970 }
        let decorated = out.map { (a: $0, last: time($0.lastRunAt) ?? 0, next: time($0.nextRunAt), created: time($0.createdAt) ?? 0) }
        let sorted: [(a: Autopilot, last: Double, next: Double?, created: Double)]
        switch state.sortField {
        case .name:
            sorted = decorated.sorted { x, y in
                let c = x.a.title.localizedStandardCompare(y.a.title)
                return asc ? c == .orderedAscending : c == .orderedDescending
            }
        case .nextRun:
            // Missing next run sorts last regardless of direction.
            sorted = decorated.sorted { x, y in
                switch (x.next, y.next) {
                case (nil, nil): return byTitle(x.a, y.a)
                case (nil, _): return false
                case (_, nil): return true
                case let (xv?, yv?): return asc ? xv < yv : xv > yv
                }
            }
        case .created:
            sorted = decorated.sorted { x, y in asc ? x.created < y.created : x.created > y.created }
        case .lastRun:
            // Never-ran rows sort as oldest; ties by title.
            sorted = decorated.sorted { x, y in
                if x.last == y.last { return byTitle(x.a, y.a) }
                return asc ? x.last < y.last : x.last > y.last
            }
        }
        out = sorted.map(\.a)
        return out
    }

    public struct ActorOption: Sendable, Hashable, Identifiable {
        public var type: String
        public var id: String
        public var count: Int
        public var value: String { actorFilterValue(type, id) }
    }

    /// Filter option lists with counts, in first-seen order, from the scope's
    /// unfiltered rows.
    public struct Options: Sendable, Hashable {
        public var assignees: [ActorOption] = []
        public var creators: [ActorOption] = []
        public var modeCounts: [String: Int] = [:]
        public var triggerKindCounts: [String: Int] = [:]

        public init() {}
    }

    public static func options(_ rows: [Autopilot]) -> Options {
        var o = Options()
        var assigneeIndex: [String: Int] = [:]
        var creatorIndex: [String: Int] = [:]
        for row in rows {
            let a = actorFilterValue(row.assigneeType, row.assigneeId)
            if let i = assigneeIndex[a] { o.assignees[i].count += 1 } else {
                assigneeIndex[a] = o.assignees.count
                o.assignees.append(ActorOption(type: row.assigneeType, id: row.assigneeId, count: 1))
            }
            let c = actorFilterValue(row.createdByType, row.createdById)
            if let i = creatorIndex[c] { o.creators[i].count += 1 } else {
                creatorIndex[c] = o.creators.count
                o.creators.append(ActorOption(type: row.createdByType, id: row.createdById, count: 1))
            }
            o.modeCounts[row.executionMode, default: 0] += 1
            for kind in row.triggerKinds ?? [] { o.triggerKindCounts[kind, default: 0] += 1 }
        }
        return o
    }
}

// MARK: - Run now (upstream run-now-toast.ts)

public enum AutopilotsRunNow {
    public enum ToastKind: Sendable { case success, warning, error }

    /// Success is a whitelist: only explicit start statuses.
    public static func toastKind(_ status: String?) -> ToastKind {
        switch status {
        case "issue_created", "running": return .success
        case "skipped": return .warning
        default: return .error
        }
    }

    /// The `autopilots:detail.*` key explaining why a run did not trigger.
    public static func blockedKey(_ reasonCode: String?) -> String {
        switch reasonCode {
        case "invocation_not_allowed": return "run_blocked_invocation_not_allowed"
        case "runtime_offline": return "run_blocked_runtime_offline"
        case "agent_runtime_required": return "run_blocked_agent_runtime_required"
        case "runtime_access_denied": return "run_blocked_runtime_access_denied"
        case "target_unavailable": return "run_blocked_target_unavailable"
        case "attribution_blocked": return "run_blocked_attribution"
        case "already_active": return "run_blocked_already_active"
        case "quota_exceeded": return "run_blocked_quota_exceeded"
        case "issue_limit_reached": return "run_blocked_issue_limit_reached"
        default: return "run_blocked_generic"
        }
    }

    /// Only a 4xx message is written for the user; 5xx detail stays internal.
    public static func clientErrorMessage(_ error: Error) -> String? {
        guard let e = error as? APIError, (400..<500).contains(e.status), !e.message.isEmpty else { return nil }
        return e.message
    }
}

// MARK: - Webhooks (upstream core/autopilots/webhook.ts)

public enum AutopilotsWebhook {
    /// Fixed width, so the mask leaks no token length.
    public static let mask = "••••••••••••"

    /// The server's `webhook_url`, else base + `webhook_path` (or the token
    /// path), else the relative path. Nil for non-webhook triggers.
    public static func url(for trigger: AutopilotTrigger, apiBaseURL: String?, currentOrigin: String? = nil) -> String? {
        guard trigger.kind == "webhook" else { return nil }
        if let u = trigger.webhookUrl, !u.isEmpty { return u }
        let path: String? = {
            if let p = trigger.webhookPath, !p.isEmpty { return p }
            if let t = trigger.webhookToken, !t.isEmpty { return "/api/webhooks/autopilots/\(t)" }
            return nil
        }()
        guard let path else { return nil }
        func strip(_ s: String?) -> String {
            guard var s, !s.isEmpty else { return "" }
            if s.hasSuffix("/") { s.removeLast() }
            return s
        }
        let base = strip(apiBaseURL).isEmpty ? strip(currentOrigin) : strip(apiBaseURL)
        return base.isEmpty ? path : base + path
    }

    /// Masks the trailing token segment; the bare mask when there is none.
    public static func masked(_ url: String) -> String {
        guard let cut = url.lastIndex(of: "/"), url.index(after: cut) != url.endIndex else { return mask }
        return String(url[...cut]) + mask
    }

    /// Stable form for dirty checks; missing actions read as [].
    public static func serialize(_ filters: [WebhookEventFilter]) -> String {
        filters.map { "\($0.event)|\(($0.actions ?? []).joined(separator: ","))" }.joined(separator: "\n")
    }

    /// A filter from the two inputs; nil when the event is blank.
    public static func makeFilter(event: String, actions: String) -> WebhookEventFilter? {
        let e = event.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty else { return nil }
        let list = actions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return WebhookEventFilter(event: e, actions: list.isEmpty ? nil : list)
    }

    /// Replay mirrors the server rule: not for an invalid signature, a
    /// rejected delivery, or one still queued.
    public static func canReplay(_ d: WebhookDelivery) -> Bool {
        d.signatureStatus != "invalid" && d.status != "rejected" && d.status != "queued"
    }

    /// The `deliveries.replay.*` key explaining a disabled replay.
    public static func replayHintKey(_ d: WebhookDelivery) -> String? {
        if d.signatureStatus == "invalid" { return "disabled_invalid_signature" }
        if d.status == "rejected" { return "disabled_rejected" }
        if d.status == "queued" { return "disabled_queued" }
        return nil
    }

    public static let displayLimit = 4096

    /// The envelope written by the server's normalizeWebhookPayload; anything
    /// else is shown whole as the payload.
    public struct Envelope: Sendable, Hashable {
        public var event: String?
        public var receivedAt: String?
        public var contentType: String?
        public var fullJSON: String
        public var displayJSON: String
        public var isTruncated: Bool
    }

    public static func envelope(_ payload: JSONValue) -> Envelope {
        var event: String?
        var receivedAt: String?
        var contentType: String?
        var eventPayload: JSONValue?
        if case .object(let obj) = payload {
            event = obj["event"]?.stringValue
            eventPayload = obj["eventPayload"]
            if case .object(let req)? = obj["request"] {
                receivedAt = req["receivedAt"]?.stringValue
                contentType = req["contentType"]?.stringValue
            }
        }
        if eventPayload == nil && !payload.isNull { eventPayload = payload }
        let full = prettyJSON(eventPayload ?? .null)
        let truncated = full.count > displayLimit
        return Envelope(event: event, receivedAt: receivedAt, contentType: contentType, fullJSON: full,
                        displayJSON: truncated ? String(full.prefix(displayLimit)) : full, isTruncated: truncated)
    }

    public static func prettyJSON(_ value: JSONValue) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }
}

// MARK: - Runs

public enum AutopilotsRuns {
    public static let knownStatuses: Set<String> = ["issue_created", "running", "skipped", "completed", "failed"]

    /// Visible runs first, skipped runs folded into one group.
    public static func split(_ runs: [AutopilotRun]) -> (visible: [AutopilotRun], skipped: [AutopilotRun]) {
        (runs.filter { $0.status != "skipped" }, runs.filter { $0.status == "skipped" })
    }

    /// The task status the transcript header shows for a run_only run.
    public static func taskStatus(for runStatus: String) -> TaskStatus {
        switch runStatus {
        case "running": return .running
        case "completed": return .completed
        case "failed": return .failed
        default: return .queued
        }
    }
}
