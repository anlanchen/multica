import Foundation

/// Which of the inbox's two lists is showing (`?view=archived`).
public enum InboxView: String, Sendable, Hashable {
    case inbox
    case archived

    public static let archivedParam = "archived"
}

/// Whether the backend projects `issue_priority` onto inbox rows, inferred
/// from the rows themselves (upstream `InboxPriorityFilterSupport`).
public enum InboxPrioritySupport: Sendable, Hashable {
    case unknown, supported, unsupported
}

/// Filtering, faceting and grouping of inbox rows (upstream
/// inbox/filter-store.ts and inbox/queries.ts).
public enum InboxFiltering {
    /// The row's group key: one row per issue, issue-less rows stand alone.
    public static func key(_ item: InboxItem) -> String { item.issueID ?? item.id }

    /// "Who this notification came from". System rows share one bucket; a
    /// row without usable attribution has no key and never matches.
    public static func actorKey(_ item: InboxItem) -> String? {
        guard let type = item.actorType, !type.isEmpty else { return nil }
        if type == "system" { return "system" }
        guard let id = item.actorID, !id.isEmpty else { return nil }
        return "\(type):\(id)"
    }

    public static func actorKeyParts(_ key: String) -> (type: String, id: String) {
        guard let i = key.firstIndex(of: ":") else { return (key, "") }
        return (String(key[..<i]), String(key[key.index(after: i)...]))
    }

    public static func count(_ f: InboxFilters) -> Int {
        f.statuses.count + f.priorities.count + f.actors.count + (f.unreadOnly ? 1 : 0)
    }

    public static func isEmpty(_ f: InboxFilters) -> Bool { count(f) == 0 }

    public static func prioritySupport(_ items: [InboxItem]) -> InboxPrioritySupport {
        if items.isEmpty { return .unknown }
        return items.allSatisfy(\.issuePriorityPresent) ? .supported : .unsupported
    }

    /// Ignores a priority selection until the backend is known to support it.
    public static func effective(_ f: InboxFilters, support: InboxPrioritySupport) -> InboxFilters {
        guard support != .supported, !f.priorities.isEmpty else { return f }
        var out = f
        out.priorities = []
        return out
    }

    /// OR within a dimension, AND between dimensions, read off the row that
    /// is rendered.
    public static func filter(_ items: [InboxItem], _ f: InboxFilters) -> [InboxItem] {
        if isEmpty(f) { return items }
        let statuses = Set(f.statuses), priorities = Set(f.priorities), actors = Set(f.actors)
        return items.filter { item in
            (statuses.isEmpty || item.issueStatus.map { statuses.contains($0.rawValue) } == true)
                && (priorities.isEmpty || item.issuePriority.map { priorities.contains($0.rawValue) } == true)
                && (actors.isEmpty || actorKey(item).map(actors.contains) == true)
                && (!f.unreadOnly || !item.read)
        }
    }

    public static func toggling(_ value: String, in values: [String]) -> [String] {
        values.contains(value) ? values.filter { $0 != value } : values + [value]
    }

    /// Faceted counts: each dimension counts rows matching every other
    /// active dimension while ignoring its own.
    public struct Facets: Sendable, Hashable {
        public var statuses: [String: Int] = [:]
        public var priorities: [String: Int] = [:]
        public var actors: [String: Int] = [:]
        public var unreadCount = 0

        public init(statuses: [String: Int] = [:], priorities: [String: Int] = [:], actors: [String: Int] = [:], unreadCount: Int = 0) {
            self.statuses = statuses
            self.priorities = priorities
            self.actors = actors
            self.unreadCount = unreadCount
        }

        public init(_ server: ArchivedInboxFacets) {
            statuses = server.statuses.mapValues { Int($0) }
            priorities = server.priorities.mapValues { Int($0) }
            actors = server.actors.mapValues { Int($0) }
            unreadCount = Int(server.unreadCount)
        }
    }

    public static func facets(_ items: [InboxItem], _ f: InboxFilters) -> Facets {
        var out = Facets()
        var noStatus = f; noStatus.statuses = []
        for item in filter(items, noStatus) {
            if let s = item.issueStatus { out.statuses[s.rawValue, default: 0] += 1 }
        }
        var noPriority = f; noPriority.priorities = []
        for item in filter(items, noPriority) {
            if let p = item.issuePriority { out.priorities[p.rawValue, default: 0] += 1 }
        }
        var noActor = f; noActor.actors = []
        for item in filter(items, noActor) {
            if let a = actorKey(item) { out.actors[a, default: 0] += 1 }
        }
        var noUnread = f; noUnread.unreadOnly = false
        out.unreadCount = filter(items, noUnread).filter { !$0.read }.count
        return out
    }

    /// Status keys the menu offers: selected ones, server facets, and every
    /// status present on a row, deduplicated in first-seen order.
    public static func statusKeys(_ items: [InboxItem], selected: [String], facetKeys: [String] = []) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for k in selected + facetKeys.sorted() + items.compactMap({ $0.issueStatus?.rawValue }) where seen.insert(k).inserted {
            out.append(k)
        }
        return out
    }

    /// Actor keys the menu offers: every actor in the view (not the faceted
    /// subset), so picking one never hides the others.
    public static func actorKeys(_ items: [InboxItem], selected: [String] = [], facetKeys: [String] = []) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for k in selected + facetKeys + items.compactMap(actorKey) where seen.insert(k).inserted {
            out.append(k)
        }
        return out
    }

    /// One row per group (newest first), carrying the group's comment id
    /// forward when the newest row has none. `archived` picks which side of
    /// the archive the rows come from.
    public static func group(_ items: [InboxItem], archived: Bool) -> [InboxItem] {
        var groups: [String: [InboxItem]] = [:]
        var order: [String] = []
        for item in items where item.archived == archived {
            let k = key(item)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(item)
        }
        var merged: [InboxItem] = []
        merged.reserveCapacity(order.count)
        for k in order {
            guard let group = groups[k] else { continue }
            let sorted = group.sorted { timestamp($0) > timestamp($1) }
            guard var newest = sorted.first else { continue }
            if newest.details["comment_id"] == nil, let carried = sorted.lazy.compactMap({ $0.details["comment_id"] }).first {
                newest.details["comment_id"] = carried
            }
            merged.append(newest)
        }
        return merged.sorted { timestamp($0) > timestamp($1) }
    }

    private static func timestamp(_ item: InboxItem) -> Date {
        Timestamp.parse(item.createdAt) ?? .distantPast
    }

    /// The key to select after removing `id` from `list`: the next (older)
    /// row, else the previous one, else nothing. Nil when `id` was not the
    /// selected row (selection stays put).
    public static func selectionAfterRemoving(_ id: String, from list: [InboxItem], selectedKey: String) -> String?? {
        guard let i = list.firstIndex(where: { $0.id == id }), key(list[i]) == selectedKey else { return nil }
        if i + 1 < list.count { return .some(key(list[i + 1])) }
        if i > 0 { return .some(key(list[i - 1])) }
        return .some(nil)
    }

    /// Arrow-key navigation: Down enters at the top, Up at the bottom, and
    /// the ends clamp. Nil when nothing changes.
    public static func step(from selectedKey: String, by step: Int, in list: [InboxItem]) -> InboxItem? {
        guard !list.isEmpty else { return nil }
        let current = list.firstIndex { key($0) == selectedKey }
        let next: Int
        if let current {
            next = min(max(current + step, 0), list.count - 1)
            if next == current { return nil }
        } else {
            next = step > 0 ? 0 : list.count - 1
        }
        return list[next]
    }
}

/// Display rules for inbox rows (upstream inbox-display.ts).
public enum InboxDisplay {
    public static let knownTypes: Set<String> = [
        "issue_assigned", "issue_subscribed", "unassigned", "assignee_changed", "status_changed",
        "priority_changed", "start_date_changed", "due_date_changed", "new_comment", "mentioned",
        "review_requested", "task_completed", "task_failed", "agent_blocked", "agent_completed",
        "reaction_added", "quick_create_done", "quick_create_failed", "quick_create_unconfirmed",
        "autopilot_paused", "autopilot_quota_exceeded", "children_done",
    ]

    static func singleLine(_ value: String?) -> String {
        (value ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func stripQuickCreatePrefix(_ title: String, identifier: String? = nil) -> String {
        let normalized = singleLine(title)
        if normalized.isEmpty { return "" }
        if let identifier, !identifier.isEmpty {
            let pattern = "^Created\\s+" + NSRegularExpression.escapedPattern(for: identifier) + ":\\s*"
            let stripped = replacing(pattern, in: normalized)
            if stripped != normalized { return stripped.trimmingCharacters(in: .whitespaces) }
        }
        return replacing("^Created\\s+[A-Z][A-Z0-9]*-\\d+:\\s*", in: normalized).trimmingCharacters(in: .whitespaces)
    }

    private static func replacing(_ pattern: String, in s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    public static func isQuickCreateOutcome(_ type: String) -> Bool {
        type == "quick_create_failed" || type == "quick_create_unconfirmed"
    }

    public static func isAutopilotQuotaNotice(_ type: String) -> Bool {
        type == "autopilot_quota_exceeded"
    }

    public static func title(_ item: InboxItem) -> String {
        if item.type == "quick_create_done" {
            let cleaned = stripQuickCreatePrefix(item.title, identifier: item.details["identifier"])
            if !cleaned.isEmpty { return cleaned }
            let prompt = singleLine(item.details["original_prompt"])
            if !prompt.isEmpty { return prompt }
        }
        if isQuickCreateOutcome(item.type) {
            let prompt = singleLine(item.details["original_prompt"])
            if !prompt.isEmpty { return prompt }
        }
        return item.title
    }

    public static func quickCreateOutcomeDetail(_ item: InboxItem) -> String {
        let error = singleLine(item.details["error"])
        return error.isEmpty ? singleLine(item.body) : error
    }

    /// Upstream `useTimeAgo` buckets: nil means "just now".
    public enum Age: Sendable, Hashable {
        case justNow
        case minutes(Int)
        case hours(Int)
        case days(Int)
    }

    public static func age(of timestamp: String, now: Date = Date()) -> Age {
        let date = Timestamp.parse(timestamp) ?? now
        let minutes = Int(floor(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return .justNow }
        if minutes < 60 { return .minutes(minutes) }
        let hours = minutes / 60
        if hours < 24 { return .hours(hours) }
        return .days(hours / 24)
    }
}
