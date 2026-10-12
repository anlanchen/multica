import Foundation
import Observation

@MainActor
@Observable
public final class InboxStore {
    /// Unarchived notifications, newest first, collapsed to the newest per
    /// issue (the same rule the server's unread summary applies).
    public private(set) var items: [InboxItem] = []
    public private(set) var isLoaded = false
    /// Unread count per workspace from `GET /api/inbox/unread-summary`. The
    /// badge reads this, so it never requires downloading the inbox.
    public private(set) var unreadByWorkspace: [String: Int] = [:]

    @ObservationIgnored private var raw: [InboxItem] = []

    public init() {}

    public func unread(in workspaceID: String) -> Int { unreadByWorkspace[workspaceID] ?? 0 }

    /// Unread items across every workspace (dock badge).
    public var totalUnread: Int { unreadByWorkspace.values.reduce(0, +) }

    public func setSummary(_ rows: [InboxWorkspaceUnread]) {
        var map: [String: Int] = [:]
        for r in rows { map[r.workspaceID] = r.count }
        if map != unreadByWorkspace { unreadByWorkspace = map }
    }

    public func setItems(_ list: [InboxItem]) {
        raw = list
        isLoaded = true
        rebuild()
    }

    /// The most recent `inbox:new` item (drives system notifications), set
    /// even when the full inbox has not been loaded.
    public private(set) var lastArrived: InboxItem?

    public func insert(_ item: InboxItem) {
        lastArrived = item
        guard isLoaded else { return }
        raw.removeAll { $0.id == item.id }
        raw.append(item)
        rebuild()
    }

    @discardableResult
    public func markRead(_ id: String) -> InboxItem? {
        guard let i = raw.firstIndex(where: { $0.id == id }), !raw[i].read else { return nil }
        let before = raw[i]
        raw[i].read = true
        rebuild()
        return before
    }

    @discardableResult
    public func archive(_ id: String) -> InboxItem? {
        guard let i = raw.firstIndex(where: { $0.id == id }) else { return nil }
        let before = raw[i]
        raw.remove(at: i)
        rebuild()
        return before
    }

    public func restore(_ item: InboxItem) {
        raw.removeAll { $0.id == item.id }
        raw.append(item)
        rebuild()
    }

    public func markAllRead() {
        for i in raw.indices { raw[i].read = true }
        rebuild()
    }

    private func rebuild() {
        let sorted = raw.filter { !$0.archived }.sorted { $0.createdAt > $1.createdAt }
        var seenIssues = Set<String>()
        var out: [InboxItem] = []
        out.reserveCapacity(sorted.count)
        for item in sorted {
            if let issue = item.issueID {
                guard seenIssues.insert(issue).inserted else { continue }
            }
            out.append(item)
        }
        if out != items { items = out }
    }
}

/// Members, agents and runtimes of the workspace, indexed for O(1) actor
/// name lookups from rows.
@MainActor
@Observable
public final class Directory {
    public private(set) var members: [Member] = []
    public private(set) var agents: [Agent] = []
    public private(set) var runtimes: [RuntimeDevice] = []
    /// Bumped whenever names can change; lookups read it so rows that show
    /// names re-render when members/agents load, and only then.
    public private(set) var revision = 0
    @ObservationIgnored private var memberByUser: [String: Member] = [:]
    @ObservationIgnored private var agentByID: [String: Agent] = [:]

    public init() {}

    public func setMembers(_ list: [Member]) {
        members = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        memberByUser = Dictionary(list.map { ($0.userID, $0) }, uniquingKeysWith: { a, _ in a })
        revision &+= 1
    }

    public func setAgents(_ list: [Agent]) {
        agents = list.filter { $0.archivedAt == nil }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        agentByID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        revision &+= 1
    }

    public func upsertAgent(_ a: Agent) {
        agentByID[a.id] = a
        var list = agents.filter { $0.id != a.id }
        if a.archivedAt == nil { list.append(a) }
        setAgents(list)
    }

    public func setRuntimes(_ list: [RuntimeDevice]) {
        runtimes = list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func agent(_ id: String) -> Agent? {
        _ = revision
        return agentByID[id]
    }

    public func member(userID: String) -> Member? {
        _ = revision
        return memberByUser[userID]
    }

    public func name(of ref: ActorRef?) -> String {
        guard let ref else { return "Unassigned" }
        return name(type: ref.type, id: ref.id)
    }

    public func name(type: String, id: String) -> String {
        _ = revision
        switch type {
        case "agent": return agentByID[id]?.name ?? "Agent"
        case "member": return memberByUser[id]?.name ?? "Member"
        case "squad": return "Squad"
        case "system": return "Multica"
        default: return type.capitalized
        }
    }
}
