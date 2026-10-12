import Foundation

public enum MembersOwnedAgents {
    /// The member's live agents, most-run (30 days) first, ties by name.
    public static func sorted(_ agents: [AgentRecord], ownerID: String, runCounts: [AgentRunCount]) -> [AgentRecord] {
        let runs = Dictionary(runCounts.map { ($0.agentId, $0.runCount) }, uniquingKeysWith: { a, _ in a })
        return agents
            .filter { $0.ownerId == ownerID && $0.archivedAt == nil }
            .sorted { a, b in
                let ra = runs[a.id] ?? 0, rb = runs[b.id] ?? 0
                if ra != rb { return ra > rb }
                return a.name.localizedCompare(b.name) == .orderedAscending
            }
    }
}

public enum MembersRole {
    /// Catalog key under `members:role.*`; unknown roles read as member.
    public static func key(_ role: String) -> String {
        role == "owner" || role == "admin" ? role : "member"
    }

    public static func isAdmin(_ role: String?) -> Bool { role == "owner" || role == "admin" }
}
