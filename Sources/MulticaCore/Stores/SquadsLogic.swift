import Foundation

// MARK: - View state (upstream useSquadsViewStore)

public enum SquadsScope: String, Codable, Sendable, CaseIterable {
    case mine, all
}

public enum SquadsSortDirection: String, Codable, Sendable {
    case asc, desc

    public var toggled: SquadsSortDirection { self == .asc ? .desc : .asc }
}

public enum SquadsSortField: String, Codable, Sendable, CaseIterable {
    case name, members, created

    public var defaultDirection: SquadsSortDirection { self == .name ? .asc : .desc }
}

public enum SquadsColumn: String, Codable, Sendable, CaseIterable {
    case members, creator, created
}

public struct SquadsFilters: Codable, Equatable, Sendable {
    /// Leader agent ids.
    public var leaders: [String] = []
    /// Creator user ids.
    public var creators: [String] = []

    public init(leaders: [String] = [], creators: [String] = []) {
        self.leaders = leaders
        self.creators = creators
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        leaders = (try? c.decodeIfPresent([String].self, forKey: .leaders)) ?? []
        creators = (try? c.decodeIfPresent([String].self, forKey: .creators)) ?? []
    }

    public var activeCount: Int { (leaders.isEmpty ? 0 : 1) + (creators.isEmpty ? 0 : 1) }
}

/// Persisted per workspace, like upstream `multica_squads_view:<slug>`.
public struct SquadsViewState: Codable, Equatable, Sendable {
    public var scope: SquadsScope = .mine
    public var sortField: SquadsSortField = .name
    public var sortDirection: SquadsSortDirection = SquadsSortField.name.defaultDirection
    /// "Created" is opt-in; "Created by" shows by default.
    public var hiddenColumns: [SquadsColumn] = [.created]
    public var filters = SquadsFilters()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SquadsViewState()
        scope = (try? c.decodeIfPresent(SquadsScope.self, forKey: .scope)) ?? d.scope
        sortField = (try? c.decodeIfPresent(SquadsSortField.self, forKey: .sortField)) ?? d.sortField
        sortDirection = (try? c.decodeIfPresent(SquadsSortDirection.self, forKey: .sortDirection)) ?? d.sortDirection
        hiddenColumns = (try? c.decodeIfPresent([String].self, forKey: .hiddenColumns))
            .map { $0.compactMap(SquadsColumn.init(rawValue:)) } ?? d.hiddenColumns
        filters = (try? c.decodeIfPresent(SquadsFilters.self, forKey: .filters)) ?? d.filters
    }

    public func isVisible(_ column: SquadsColumn) -> Bool { !hiddenColumns.contains(column) }

    public mutating func toggleSort(_ field: SquadsSortField) {
        if sortField == field {
            sortDirection = sortDirection.toggled
        } else {
            sortField = field
            sortDirection = field.defaultDirection
        }
    }

    public mutating func setSortField(_ field: SquadsSortField) {
        guard sortField != field else { return }
        sortField = field
        sortDirection = field.defaultDirection
    }

    public mutating func toggleColumn(_ column: SquadsColumn) {
        if let i = hiddenColumns.firstIndex(of: column) {
            hiddenColumns.remove(at: i)
        } else {
            hiddenColumns.append(column)
        }
    }

    public mutating func toggleFilter(_ key: WritableKeyPath<SquadsFilters, [String]>, _ value: String) {
        if let i = filters[keyPath: key].firstIndex(of: value) {
            filters[keyPath: key].remove(at: i)
        } else {
            filters[keyPath: key].append(value)
        }
    }

    public mutating func clearFilters() { filters = SquadsFilters() }
}

// MARK: - List (squads-page.tsx)

public enum SquadsListQuery {
    public struct Option: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var count: Int
    }

    public static func memberCount(_ s: Squad) -> Int { s.memberCount ?? s.memberPreview?.count ?? 0 }

    public static func scopeCounts(_ squads: [Squad], userID: String?) -> [SquadsScope: Int] {
        let mine = userID.map { id in squads.filter { $0.creatorId == id }.count } ?? 0
        return [.mine: mine, .all: squads.count]
    }

    public static func scopeRows(_ squads: [Squad], scope: SquadsScope, userID: String?) -> [Squad] {
        guard scope == .mine else { return squads }
        guard let userID else { return [] }
        return squads.filter { $0.creatorId == userID }
    }

    /// First-seen order; unknown names fall back to the id's first 8 chars.
    public static func options(_ rows: [Squad], key: (Squad) -> String, name: (String) -> String?) -> [Option] {
        var out: [Option] = []
        var index: [String: Int] = [:]
        for s in rows {
            let id = key(s)
            if let i = index[id] {
                out[i].count += 1
            } else {
                index[id] = out.count
                out.append(Option(id: id, name: name(id) ?? String(id.prefix(8)), count: 1))
            }
        }
        return out
    }

    public static func rows(_ scopeRows: [Squad], filters: SquadsFilters, sortField: SquadsSortField,
                            direction: SquadsSortDirection) -> [Squad] {
        let filtered = scopeRows.filter { s in
            (filters.leaders.isEmpty || filters.leaders.contains(s.leaderId))
                && (filters.creators.isEmpty || filters.creators.contains(s.creatorId))
        }
        let dir = direction == .asc ? 1 : -1
        func nameOrder(_ a: Squad, _ b: Squad) -> Int { ProjectsListQuery.order(a.name.localizedCompare(b.name)) }
        func compare(_ a: Squad, _ b: Squad) -> Int {
            switch sortField {
            case .members:
                let d = memberCount(a) - memberCount(b)
                return d != 0 ? d.signum() * dir : nameOrder(a, b)
            case .created:
                let ta = Timestamp.parse(a.createdAt)?.timeIntervalSince1970 ?? 0
                let tb = Timestamp.parse(b.createdAt)?.timeIntervalSince1970 ?? 0
                return ta == tb ? 0 : (ta > tb ? 1 : -1) * dir
            case .name:
                return nameOrder(a, b) * dir
            }
        }
        return filtered.sorted { compare($0, $1) < 0 }
    }

    /// Mirrors `canManageSquad` on the server: workspace owner/admin manage
    /// every squad, the creator manages their own.
    public static func canManage(_ s: Squad, userID: String?, isWorkspaceAdmin: Bool) -> Bool {
        isWorkspaceAdmin || (userID != nil && s.creatorId == userID)
    }
}

/// A width/height pair for the cropper (Core stays free of CoreGraphics:
/// sharing `CGSize` across the module boundary breaks optimized builds).
public struct SquadsCropSize: Hashable, Sendable {
    public var width: Double
    public var height: Double
    public static let zero = SquadsCropSize(width: 0, height: 0)

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct SquadsCropRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Geometry of the avatar cropper: the image covers a square viewport at
/// zoom 1, pans within bounds, and the visible square maps back to image
/// pixels (upstream avatar-crop-dialog + react-easy-crop).
public enum SquadsAvatarCrop {
    public static let outputSize = 512
    public static let zoomRange: ClosedRange<Double> = 1...3

    /// Image size after a rotation by a multiple of 90°.
    public static func rotatedSize(_ size: SquadsCropSize, quarterTurns: Int) -> SquadsCropSize {
        quarterTurns % 2 == 0 ? size : SquadsCropSize(width: size.height, height: size.width)
    }

    /// Points per image pixel at the given zoom.
    public static func scale(image: SquadsCropSize, viewport: Double, zoom: Double) -> Double {
        let short = min(image.width, image.height)
        guard short > 0 else { return 1 }
        return viewport / short * min(zoomRange.upperBound, max(zoomRange.lowerBound, zoom))
    }

    /// Keeps the viewport covered: the image center may move at most half
    /// the overhang in each direction.
    public static func clampOffset(_ offset: SquadsCropSize, image: SquadsCropSize, viewport: Double, zoom: Double) -> SquadsCropSize {
        let s = scale(image: image, viewport: viewport, zoom: zoom)
        let maxX = max(0, (image.width * s - viewport) / 2)
        let maxY = max(0, (image.height * s - viewport) / 2)
        return SquadsCropSize(width: min(maxX, max(-maxX, offset.width)), height: min(maxY, max(-maxY, offset.height)))
    }

    /// The visible square in image pixels (top-left origin).
    public static func cropRect(image: SquadsCropSize, viewport: Double, zoom: Double, offset: SquadsCropSize) -> SquadsCropRect {
        let s = scale(image: image, viewport: viewport, zoom: zoom)
        let o = clampOffset(offset, image: image, viewport: viewport, zoom: zoom)
        let side = viewport / s
        return SquadsCropRect(x: image.width * 0.5 - o.width / s - side * 0.5, y: image.height * 0.5 - o.height / s - side * 0.5,
                              width: side, height: side)
    }
}

public enum SquadsText {
    /// Upstream initials: first letter of each space-separated word, max 2.
    public static func initials(_ name: String) -> String {
        String(name.split(separator: " ").compactMap(\.first).map(String.init).joined().uppercased().prefix(2))
    }
}

/// Selection state of the create-squad dialog.
public struct SquadsCreateSelection: Equatable, Sendable {
    public struct Pick: Equatable, Sendable, Hashable {
        public var type: String
        public var id: String
        public var name: String

        public init(type: String, id: String, name: String) {
            self.type = type
            self.id = id
            self.name = name
        }
    }

    public var leaderID = ""
    public var members: [Pick] = []

    public init() {}

    /// Promoting an agent to leader drops it from the members — hiding it
    /// would resurrect it as a member when the leader changes again.
    public mutating func setLeader(_ id: String) {
        leaderID = id
        if !id.isEmpty { members.removeAll { $0.type == "agent" && $0.id == id } }
    }

    public func contains(type: String, id: String) -> Bool {
        members.contains { $0.type == type && $0.id == id }
    }

    public mutating func toggle(_ p: Pick) {
        if contains(type: p.type, id: p.id) {
            remove(p)
        } else {
            members.append(p)
        }
    }

    public mutating func remove(_ p: Pick) {
        members.removeAll { $0.type == p.type && $0.id == p.id }
    }
}
