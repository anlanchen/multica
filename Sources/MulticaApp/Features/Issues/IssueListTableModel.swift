import MulticaCore
import Observation
import SwiftUI

/// One rendered table row (`IssueTableDisplayRow`).
enum IssueListTableRow: Identifiable {
    case group(key: String, label: String, count: Int, collapsed: Bool)
    case issue(id: String, depth: Int, hasChildren: Bool, collapsed: Bool)
    case loadMore(key: String, branch: String)
    case activate(key: String, branch: String)

    var id: String {
        switch self {
        case .group(let k, _, _, _): return "g:\(k)"
        case .issue(let id, _, _, _): return id
        case .loadMore(let k, _): return "m:\(k)"
        case .activate(let k, _): return "a:\(k)"
        }
    }
}

/// Server-owned Table window (upstream table-view.tsx): optional groups, each
/// a cursor-paged branch; with hierarchy on, every expanded parent owns a
/// child branch.
@MainActor
@Observable
final class IssueListTableModel {
    unowned let surface: IssueListSurfaceModel
    private(set) var groups: [IssueTableGroupDescriptor] = []
    private(set) var groupsLoading = false
    private(set) var groupsError = false
    private(set) var branches: [String: IssueListBranch] = [:]
    private(set) var rowChildCounts: [String: Int] = [:]
    private(set) var loaded = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var fingerprint = ""
    var selectionAnchor: String?
    var editingTitle: String?

    init(surface: IssueListSurfaceModel) {
        self.surface = surface
    }

    var groupSpec: JSONValue {
        let g = surface.state.tableGrouping
        switch g {
        case "status", "assignee", "project": return .object(["kind": .string(g)])
        default:
            if let pid = IssueListOptions.propertyID(fromKey: g), surface.property(pid) != nil {
                return .object(["kind": "property", "property_id": .string(pid)])
            }
            return ["kind": "none"]
        }
    }

    var usesGrouping: Bool { groupSpec["kind"]?.stringValue != "none" }

    static func branchKey(_ group: String?, _ parent: String?) -> String { "\(group ?? "")|\(parent ?? "")" }

    private func request(_ spec: IssueTableQuerySpec, group: String?, parent: String?, cursor: String?, limit: Int) -> IssueTableRowsRequest {
        IssueTableRowsRequest(query: spec, group: groupSpec, groupKey: group,
                              hierarchy: .object(["enabled": .bool(surface.state.tableHierarchy)]),
                              parentId: parent, page: IssueTablePageRequest(limit: limit, cursor: cursor))
    }

    func reload() async {
        let spec = surface.querySpec
        let fp = IssueListQuery.fingerprint(spec) + "|\(surface.state.tableGrouping)|\(surface.state.tableHierarchy)"
        let reset = fp != fingerprint
        if reset {
            fingerprint = fp
            generation += 1
            branches = [:]
            groups = []
            loaded = false
        }
        let gen = generation
        if usesGrouping {
            groupsLoading = groups.isEmpty
            do {
                var all: [IssueTableGroupDescriptor] = []
                var cursor: String?
                repeat {
                    let page = try await surface.session.api.listIssueTableGroups(
                        IssueTableGroupsRequest(query: spec, group: groupSpec, page: IssueTablePageRequest(limit: 100, cursor: cursor)))
                    all += page.groups
                    cursor = page.nextCursor
                } while cursor != nil && all.count < 1000
                guard gen == generation else { return }
                groups = all
                groupsError = false
            } catch {
                guard gen == generation else { return }
                groupsError = true
            }
            groupsLoading = false
            let collapsed = Set(surface.state.tableCollapsedGroups)
            let keys = groups.filter { !collapsed.contains($0.key) }.map { Self.branchKey($0.key, nil) }
            let active = keys.filter { reset ? true : branches[$0]?.activated == true }
            await fetchHeads(active.isEmpty ? Array(keys.prefix(1)) : active, spec: spec, generation: gen)
        } else {
            let key = Self.branchKey(nil, nil)
            var keys = [key]
            if !reset { keys += branches.keys.filter { $0 != key && branches[$0]?.activated == true } }
            await fetchHeads(keys, spec: spec, generation: gen)
        }
        guard gen == generation else { return }
        loaded = true
    }

    private func split(_ key: String) -> (group: String?, parent: String?) {
        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let g = parts.first.flatMap { $0.isEmpty ? nil : $0 }
        let p = parts.count > 1 ? (parts[1].isEmpty ? nil : parts[1]) : nil
        return (g, p)
    }

    private func fetchHeads(_ keys: [String], spec: IssueTableQuerySpec, generation gen: Int) async {
        for k in keys {
            let b = branches[k] ?? IssueListBranch(key: k)
            b.activated = true
            if !b.loaded { b.isLoading = true }
            branches[k] = b
        }
        let api = surface.session.api
        let requests = keys.map { k -> (String, IssueTableRowsRequest, Int) in
            let parts = split(k)
            let keep = max(50, min(100, branches[k]?.rawIDs.count ?? 0))
            return (k, request(spec, group: parts.group, parent: parts.parent, cursor: nil, limit: keep), keep)
        }
        let results = await withTaskGroup(of: (String, IssueListRowsPage?).self) { tg in
            for (k, r, _) in requests {
                tg.addTask { (k, try? await api.issueListRows(r)) }
            }
            var out: [(String, IssueListRowsPage?)] = []
            for await r in tg { out.append(r) }
            return out
        }
        guard gen == generation else { return }
        for (k, page) in results {
            guard let b = branches[k] else { continue }
            b.isLoading = false
            guard let page else {
                b.isError = true
                continue
            }
            absorb(page.rows)
            var seen = Set<String>()
            b.rawIDs = page.rows.map(\.issue.id).filter { seen.insert($0).inserted }
            b.setIDs(b.rawIDs)
            b.nextCursor = page.nextCursor
            b.total = page.branchTotal
            b.isError = false
            b.loaded = true
        }
    }

    private func absorb(_ rows: [IssueListRow]) {
        for row in rows {
            surface.session.issues.upsert(row.issue)
            surface.extras(row.issue.id).set(properties: row.properties, duplicateOf: row.duplicateOfIdentifier, directChildCount: row.directChildCount)
            if rowChildCounts[row.issue.id] != row.directChildCount { rowChildCounts[row.issue.id] = row.directChildCount }
        }
        surface.markSelfInduced()
    }

    func activate(_ key: String) {
        guard branches[key]?.activated != true else { return }
        let gen = generation
        let spec = surface.querySpec
        Task { await fetchHeads([key], spec: spec, generation: gen) }
    }

    func loadMore(_ key: String) {
        guard let b = branches[key], let cursor = b.nextCursor, !b.isLoadingMore else { return }
        b.isLoadingMore = true
        let parts = split(key)
        let r = request(surface.querySpec, group: parts.group, parent: parts.parent, cursor: cursor, limit: 50)
        let gen = generation
        Task {
            defer { b.isLoadingMore = false }
            do {
                let page = try await surface.session.api.issueListRows(r)
                guard gen == generation else { return }
                absorb(page.rows)
                var seen = Set(b.rawIDs)
                b.rawIDs += page.rows.map(\.issue.id).filter { seen.insert($0).inserted }
                b.setIDs(b.rawIDs)
                b.nextCursor = page.nextCursor
                b.isError = false
            } catch {
                b.isError = true
            }
        }
    }

    func retry(_ key: String) {
        branches[key]?.isError = false
        let gen = generation
        let spec = surface.querySpec
        Task { await fetchHeads([key], spec: spec, generation: gen) }
    }

    /// Rows in display order: groups, issues with their nested children, and
    /// branch footers.
    func displayRows() -> [IssueListTableRow] {
        var out: [IssueListTableRow] = []
        var seen = Set<String>()
        let hierarchy = surface.state.tableHierarchy
        let collapsedParents = Set(surface.state.tableCollapsedParents)
        func append(_ group: String?, _ parent: String?, depth: Int) {
            let key = Self.branchKey(group, parent)
            guard let b = branches[key], b.activated else {
                out.append(.activate(key: key, branch: key))
                return
            }
            for id in b.ids where seen.insert(id).inserted {
                let children = hierarchy ? (rowChildCounts[id] ?? 0) : 0
                let collapsed = collapsedParents.contains(id)
                out.append(.issue(id: id, depth: depth, hasChildren: children > 0, collapsed: collapsed))
                if children > 0 && !collapsed { append(group, id, depth: depth + 1) }
            }
            if b.isError || b.hasMore || b.isLoading || (b.loaded && b.total > 50) {
                out.append(.loadMore(key: key, branch: key))
            }
        }
        if usesGrouping {
            let collapsed = Set(surface.state.tableCollapsedGroups)
            for g in groups {
                let isCollapsed = collapsed.contains(g.key)
                out.append(.group(key: g.key, label: groupLabel(g), count: g.count, collapsed: isCollapsed))
                if !isCollapsed { append(g.key, nil, depth: 0) }
            }
        } else {
            append(nil, nil, depth: 0)
        }
        return out
    }

    /// Visible issue ids in order (shift-click ranges, batch, export).
    func visibleIssueIDs() -> [String] {
        displayRows().compactMap { if case .issue(let id, _, _, _) = $0 { return id } else { return nil } }
    }

    func groupLabel(_ d: IssueTableGroupDescriptor) -> String {
        let session = surface.session
        switch IssueListGroupValue(d.value) {
        case .status(let s): return session.issueListStatusLabel(IssueStatusKey(rawValue: s))
        case .assignee(let ref): return ref.map { session.actorInfo(type: $0.type, id: $0.id).name } ?? tr("issues", "table.unassigned")
        case .project(let pid):
            guard let pid else { return tr("issues", "swimlane.no_project") }
            return surface.project(pid)?.title ?? tr("issues", "table.value_unavailable")
        case .parent(_, _, let title, _, let state):
            if state == "unset" { return tr("issues", "swimlane.no_parent") }
            return title ?? tr("issues", "table.value_unavailable")
        case .property(let pid, let value, let state):
            if state == "unset" { return tr("issues", "table.no_value") }
            if state == "unavailable" { return tr("issues", "table.value_unavailable") }
            if case .bool(let b)? = value {
                return b ? tr("issues", "pickers.custom_property.true_label") : tr("issues", "pickers.custom_property.false_label")
            }
            let raw = value?.stringValue ?? ""
            return surface.property(pid)?.config?.options?.first { $0.id == raw }?.name ?? raw
        case .unknown: return ""
        }
    }

    /// Every issue in the query window, failing closed when paging cannot
    /// prove it collected the complete window.
    func exportAll() async throws -> [Issue] {
        var issues: [Issue] = []
        var seen = Set<String>()
        var cursors = Set<String>()
        var fingerprint: String?
        var expected: Int?
        var cursor: String?
        let spec = surface.querySpec
        repeat {
            if let cursor {
                guard cursors.insert(cursor).inserted else { throw IssueListExportError() }
            }
            let page = try await surface.session.api.issueListRows(
                IssueTableRowsRequest(query: spec, group: ["kind": "none"], groupKey: nil, hierarchy: ["enabled": false],
                                      parentId: nil, page: IssueTablePageRequest(limit: 100, cursor: cursor)))
            guard !page.queryFingerprint.isEmpty else { throw IssueListExportError() }
            if fingerprint == nil { fingerprint = page.queryFingerprint }
            if cursor == nil { expected = page.total }
            guard page.queryFingerprint == fingerprint, page.groupKey == nil, page.parentID == nil else { throw IssueListExportError() }
            for row in page.rows {
                guard seen.insert(row.issue.id).inserted else { throw IssueListExportError() }
                issues.append(row.issue)
                surface.extras(row.issue.id).set(properties: row.properties, duplicateOf: row.duplicateOfIdentifier, directChildCount: row.directChildCount)
            }
            cursor = page.nextCursor
        } while cursor != nil
        guard issues.count == (expected ?? 0) else { throw IssueListExportError() }
        return issues
    }
}

struct IssueListExportError: Error {}

enum IssueListCSV {
    /// Formula-looking strings are prefixed with an apostrophe so exported
    /// user text stays data in spreadsheet apps.
    static func cell(_ value: String) -> String {
        var text = value
        if let first = text.first, "=+-@\t\r".contains(first), Double(text) == nil { text = "'" + text }
        if text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return text
    }

    static func build(headers: [String], rows: [[String]]) -> String {
        ([headers] + rows).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n")
    }
}
