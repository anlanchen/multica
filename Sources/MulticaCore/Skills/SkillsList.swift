import Foundation

public enum SkillsSortField: String, Codable, CaseIterable, Sendable, Hashable {
    case name, usedBy, updated, created

    /// Direction applied when switching to this field.
    public var defaultDirection: SkillsSortDirection {
        self == .name ? .asc : .desc
    }
}

public enum SkillsSortDirection: String, Codable, Sendable, Hashable {
    case asc, desc

    public var toggled: SkillsSortDirection { self == .asc ? .desc : .asc }
}

/// User-hideable list columns; name, checkbox and kebab always show.
public enum SkillsColumn: String, Codable, CaseIterable, Sendable, Hashable {
    case usedBy, source, creator, updated, created
}

public enum SkillsUsage: String, Codable, CaseIterable, Sendable, Hashable {
    case used, unused
}

public enum SkillsFilterDimension: Sendable, Hashable {
    case usage, origins, agents, creators, labels
}

/// Multi-select filters; an empty dimension is inactive.
public struct SkillsListFilters: Codable, Sendable, Hashable {
    public var usage: [SkillsUsage] = []
    public var origins: [SkillsOriginType] = []
    public var agents: [String] = []
    public var creators: [String] = []
    public var labels: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usage = c.lossyArray(SkillsUsage.self, .usage)
        origins = c.lossyArray(SkillsOriginType.self, .origins)
        agents = c.lossyArray(String.self, .agents)
        creators = c.lossyArray(String.self, .creators)
        labels = c.lossyArray(String.self, .labels)
    }

    public var activeDimensionCount: Int {
        [usage.isEmpty, origins.isEmpty, agents.isEmpty, creators.isEmpty, labels.isEmpty].filter { !$0 }.count
    }

    public func count(_ dimension: SkillsFilterDimension) -> Int {
        switch dimension {
        case .usage: return usage.count
        case .origins: return origins.count
        case .agents: return agents.count
        case .creators: return creators.count
        case .labels: return labels.count
        }
    }

    public func contains(_ dimension: SkillsFilterDimension, _ value: String) -> Bool {
        switch dimension {
        case .usage: return usage.contains { $0.rawValue == value }
        case .origins: return origins.contains { $0.rawValue == value }
        case .agents: return agents.contains(value)
        case .creators: return creators.contains(value)
        case .labels: return labels.contains(value)
        }
    }

    public mutating func toggle(_ dimension: SkillsFilterDimension, _ value: String) {
        func flip<T: Equatable>(_ list: inout [T], _ v: T?) {
            guard let v else { return }
            if let i = list.firstIndex(of: v) { list.remove(at: i) } else { list.append(v) }
        }
        switch dimension {
        case .usage: flip(&usage, SkillsUsage(rawValue: value))
        case .origins: flip(&origins, SkillsOriginType(rawValue: value))
        case .agents: flip(&agents, value)
        case .creators: flip(&creators, value)
        case .labels: flip(&labels, value)
        }
    }
}

/// Persisted list preferences (upstream skills view store): sort, columns,
/// filters. Search and selection are deliberately session-local.
public struct SkillsViewState: Codable, Sendable, Hashable {
    public var sortField: SkillsSortField = .updated
    public var sortDirection: SkillsSortDirection = .desc
    public var hiddenColumns: [SkillsColumn] = [.source, .created]
    public var filters = SkillsListFilters()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SkillsViewState()
        sortField = (try? c.decode(SkillsSortField.self, forKey: .sortField)) ?? d.sortField
        sortDirection = (try? c.decode(SkillsSortDirection.self, forKey: .sortDirection)) ?? d.sortDirection
        hiddenColumns = c.contains(.hiddenColumns) ? c.lossyArray(SkillsColumn.self, .hiddenColumns) : d.hiddenColumns
        filters = (try? c.decode(SkillsListFilters.self, forKey: .filters)) ?? d.filters
    }

    /// Header click: flips the active field, otherwise switches with the
    /// field's default direction.
    public mutating func toggleSort(_ field: SkillsSortField) {
        if sortField == field {
            sortDirection = sortDirection.toggled
        } else {
            sortField = field
            sortDirection = field.defaultDirection
        }
    }

    /// Display-panel select: switches field, never flips.
    public mutating func setSortField(_ field: SkillsSortField) {
        guard sortField != field else { return }
        sortField = field
        sortDirection = field.defaultDirection
    }

    public func isVisible(_ column: SkillsColumn) -> Bool { !hiddenColumns.contains(column) }

    public mutating func toggleColumn(_ column: SkillsColumn) {
        if let i = hiddenColumns.firstIndex(of: column) { hiddenColumns.remove(at: i) } else { hiddenColumns.append(column) }
    }
}

/// One assembled list row (upstream `SkillRow`).
public struct SkillsListRow: Identifiable, Sendable, Hashable {
    public var skill: SkillSummary
    public var agents: [AgentRecord]
    public var creator: MemberWithUserRecord?
    public var runtime: RuntimeDeviceRecord?
    public var origin: SkillsOrigin
    public var canEdit: Bool
    public var updatedDate: Date
    public var createdDate: Date

    public var id: String { skill.id }

    public init(skill: SkillSummary, agents: [AgentRecord] = [], creator: MemberWithUserRecord? = nil,
                runtime: RuntimeDeviceRecord? = nil, canEdit: Bool = true) {
        self.skill = skill
        self.agents = agents
        self.creator = creator
        self.runtime = runtime
        self.origin = skill.skillsOrigin
        self.canEdit = canEdit
        self.updatedDate = Timestamp.parse(skill.updatedAt) ?? .distantPast
        self.createdDate = Timestamp.parse(skill.createdAt) ?? .distantPast
    }

    public var isRefreshable: Bool { canEdit && origin.isRefreshable }
}

public enum SkillsList {
    /// Active agents per skill id (upstream `selectSkillAssignments`).
    public static func assignments(_ agents: [AgentRecord]) -> [String: [AgentRecord]] {
        var map: [String: [AgentRecord]] = [:]
        for agent in agents where agent.archivedAt == nil {
            for s in agent.skills { map[s.id, default: []].append(agent) }
        }
        return map
    }

    public static func buildRows(skills: [SkillSummary], agents: [AgentRecord], members: [MemberWithUserRecord],
                                 runtimes: [RuntimeDeviceRecord], userID: String?) -> [SkillsListRow] {
        let assigned = assignments(agents)
        let membersByUser = Dictionary(members.map { ($0.userId, $0) }, uniquingKeysWith: { a, _ in a })
        let runtimesByID = Dictionary(runtimes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let role = userID.flatMap { membersByUser[$0]?.role }
        return skills.map { skill in
            let origin = skill.skillsOrigin
            let runtime = origin.type == .runtimeLocal ? origin.runtimeID.flatMap { runtimesByID[$0] } : nil
            return SkillsListRow(
                skill: skill,
                agents: assigned[skill.id] ?? [],
                creator: skill.createdBy.flatMap { membersByUser[$0] },
                runtime: runtime,
                canEdit: SkillsPermissions.canEdit(createdBy: skill.createdBy, userID: userID, role: role)
            )
        }
    }

    /// Name search plus every active filter dimension; labels match
    /// OR-within-dimension like the issue list.
    public static func matches(_ row: SkillsListRow, filters: SkillsListFilters, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty && !row.skill.name.lowercased().contains(q) { return false }
        if !filters.usage.isEmpty && !filters.usage.contains(row.agents.isEmpty ? .unused : .used) { return false }
        if !filters.origins.isEmpty && !filters.origins.contains(row.origin.type) { return false }
        if !filters.agents.isEmpty && !row.agents.contains(where: { filters.agents.contains($0.id) }) { return false }
        if !filters.creators.isEmpty {
            guard let creator = row.skill.createdBy, filters.creators.contains(creator) else { return false }
        }
        if !filters.labels.isEmpty {
            guard let labels = row.skill.labels, labels.contains(where: { filters.labels.contains($0.id) }) else { return false }
        }
        return true
    }

    public static func sorted(_ rows: [SkillsListRow], field: SkillsSortField, direction: SkillsSortDirection) -> [SkillsListRow] {
        let asc = direction == .asc
        func byName(_ a: SkillsListRow, _ b: SkillsListRow) -> ComparisonResult {
            a.skill.name.localizedCompare(b.skill.name)
        }
        return rows.sorted { a, b in
            switch field {
            case .name:
                let r = byName(a, b)
                return asc ? r == .orderedAscending : r == .orderedDescending
            case .usedBy:
                if a.agents.count != b.agents.count { return asc ? a.agents.count < b.agents.count : a.agents.count > b.agents.count }
                return byName(a, b) == .orderedAscending
            case .created:
                return asc ? a.createdDate < b.createdDate : a.createdDate > b.createdDate
            case .updated:
                return asc ? a.updatedDate < b.updatedDate : a.updatedDate > b.updatedDate
            }
        }
    }

    /// Filter-menu options with counts, from the unfiltered rows so one
    /// dimension never hides another's options.
    public struct Options: Sendable, Equatable {
        public var usedCount = 0
        public var unusedCount = 0
        public var originCounts: [SkillsOriginType: Int] = [:]
        public var agents: [(agent: AgentRecord, count: Int)] = []
        public var creators: [(member: MemberWithUserRecord, count: Int)] = []
        public var labelCounts: [String: Int] = [:]

        public init() {}

        public static func == (a: Options, b: Options) -> Bool {
            a.usedCount == b.usedCount && a.unusedCount == b.unusedCount && a.originCounts == b.originCounts
                && a.agents.map(\.agent.id) == b.agents.map(\.agent.id) && a.agents.map(\.count) == b.agents.map(\.count)
                && a.creators.map(\.member.userId) == b.creators.map(\.member.userId) && a.creators.map(\.count) == b.creators.map(\.count)
                && a.labelCounts == b.labelCounts
        }
    }

    public static func options(_ rows: [SkillsListRow]) -> Options {
        var o = Options()
        var agentIndex: [String: Int] = [:]
        var creatorIndex: [String: Int] = [:]
        for row in rows {
            if row.agents.isEmpty { o.unusedCount += 1 } else { o.usedCount += 1 }
            o.originCounts[row.origin.type, default: 0] += 1
            for agent in row.agents {
                if let i = agentIndex[agent.id] { o.agents[i].count += 1 } else {
                    agentIndex[agent.id] = o.agents.count
                    o.agents.append((agent, 1))
                }
            }
            if let creator = row.creator {
                if let i = creatorIndex[creator.userId] { o.creators[i].count += 1 } else {
                    creatorIndex[creator.userId] = o.creators.count
                    o.creators.append((creator, 1))
                }
            }
            for label in row.skill.labels ?? [] { o.labelCounts[label.id, default: 0] += 1 }
        }
        return o
    }
}
