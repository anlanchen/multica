import AppKit
import MulticaCore
import Observation
import SwiftUI

/// Per-device persistence for issue surfaces (upstream zustand `persist`
/// stores, workspace-aware).
enum IssueListPrefs {
    private static var defaults: UserDefaults { .standard }

    private static func surfaceKey(_ workspaceID: String, _ surface: String) -> String {
        "multica.issueSurface.\(workspaceID).\(surface)"
    }

    static func loadState(workspaceID: String, surface: String) -> [String: JSONValue]? {
        guard let data = defaults.data(forKey: surfaceKey(workspaceID, surface)),
              let obj = try? JSONCoders.decoder.decode([String: JSONValue].self, from: data) else { return nil }
        return obj
    }

    static func hasState(workspaceID: String, surface: String) -> Bool {
        defaults.data(forKey: surfaceKey(workspaceID, surface)) != nil
    }

    static func saveState(_ json: [String: JSONValue], workspaceID: String, surface: String) {
        guard let data = try? JSONCoders.encoder.encode(json) else { return }
        defaults.set(data, forKey: surfaceKey(workspaceID, surface))
    }

    /// The state a surface opens with: persisted local state, else (for a
    /// saved view's first open) the view's definition, else defaults.
    static func initialState(workspaceID: String, surface: String, seed: [String: JSONValue]?) -> IssueListViewState {
        let base = IssueListViewState.defaults(surfaceKey: surface)
        if let stored = loadState(workspaceID: workspaceID, surface: surface) {
            return IssueListViewState(json: stored, defaults: base)
        }
        if let seed {
            let seeded = IssueListViewState(json: seed, defaults: IssueListViewState())
            saveState(seeded.persistedJSON, workspaceID: workspaceID, surface: surface)
            return seeded
        }
        return base
    }

    // Assignee-type tab per page (`issues` or `project:<id>`).
    static func scopeTab(workspaceID: String, page: String) -> String {
        let all = defaults.dictionary(forKey: "multica.issuesScope.\(workspaceID)") as? [String: String]
        return all?[page] ?? "all"
    }

    static func setScopeTab(_ value: String, workspaceID: String, page: String) {
        var all = defaults.dictionary(forKey: "multica.issuesScope.\(workspaceID)") as? [String: String] ?? [:]
        all[page] = value
        defaults.set(all, forKey: "multica.issuesScope.\(workspaceID)")
    }

    /// My Issues tab: `all` | `assigned` | `created` | `agents`.
    static func myIssuesScope(workspaceID: String) -> String {
        defaults.string(forKey: "multica.myIssuesScope.\(workspaceID)") ?? "assigned"
    }

    static func setMyIssuesScope(_ value: String, workspaceID: String) {
        defaults.set(value, forKey: "multica.myIssuesScope.\(workspaceID)")
    }

    /// Actor issues panel tab: `assigned` | `created`.
    static func actorScope(workspaceID: String) -> String {
        defaults.string(forKey: "multica.actorIssuesScope.\(workspaceID)") ?? "assigned"
    }

    static func setActorScope(_ value: String, workspaceID: String) {
        defaults.set(value, forKey: "multica.actorIssuesScope.\(workspaceID)")
    }

    /// Settings › Preferences "open issues in": `page` | `peek`.
    static var openMode: String {
        defaults.string(forKey: "multica.issueOpenMode") == "peek" ? "peek" : "page"
    }
}

/// Surface-only data for one issue row: the custom property bag and duplicate
/// marker the hand-tuned `Issue` does not carry, and sub-issue progress. Rows
/// observe only their own extras.
@MainActor
@Observable
final class IssueListRowExtras {
    var properties: [String: JSONValue] = [:]
    var duplicateOf: String?
    var childProgress: (done: Int, total: Int)?
    var directChildCount = 0
    @ObservationIgnored var previewSource: String?
    @ObservationIgnored var previewText: String?

    func set(properties: [String: JSONValue], duplicateOf: String?, directChildCount: Int) {
        if self.properties != properties { self.properties = properties }
        if self.duplicateOf != duplicateOf { self.duplicateOf = duplicateOf }
        if self.directChildCount != directChildCount { self.directChildCount = directChildCount }
    }

    func setProgress(_ p: (done: Int, total: Int)?) {
        if childProgress?.done != p?.done || childProgress?.total != p?.total { childProgress = p }
    }
}

/// One independently paged server branch: a status column, a group column,
/// or a swimlane cell.
@MainActor
@Observable
final class IssueListBranch {
    let key: String
    /// Row ids in server order, already narrowed to rows that still match.
    private(set) var ids: [String] = []
    var total = 0
    var nextCursor: String?
    var isLoading = false
    var isLoadingMore = false
    var isError = false
    /// Whether the head page was requested (lazy branches start inactive).
    var activated = false
    var loaded = false
    @ObservationIgnored var rawIDs: [String] = []

    init(key: String) { self.key = key }

    var hasMore: Bool { nextCursor != nil }

    func setIDs(_ next: [String]) {
        if next != ids { ids = next }
    }
}

/// A single-issue write that hands work to an agent (`runConfirmIntent`).
struct IssueListRunConfirm: Identifiable {
    enum Mode { case assign, promote }
    var issueIDs: [String]
    var mode: Mode
    var status: IssueStatusKey?
    var assignee: ActorRef
    var id: String { issueIDs.joined(separator: ",") + "\(mode)" }
}

enum IssueListField<Value> {
    case unchanged
    case set(Value)
    case clear

    init(_ value: Value?) {
        self = value.map { .set($0) } ?? .clear
    }
}

/// A field write (`UpdateIssueRequest` subset) with explicit clears.
struct IssueListPatch {
    var title: String?
    var status: IssueStatusKey?
    var priority: IssuePriority?
    var assignee: IssueListField<ActorRef> = .unchanged
    var startDate: IssueListField<String> = .unchanged
    var dueDate: IssueListField<String> = .unchanged
    var projectID: IssueListField<String> = .unchanged
    var parentIssueID: IssueListField<String> = .unchanged
    var position: Double?
    var suppressRun = false

    var json: [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        if let title { o["title"] = .string(title) }
        if let status { o["status"] = .string(status.rawValue) }
        if let priority { o["priority"] = .string(priority.rawValue) }
        switch assignee {
        case .set(let a): o["assignee_type"] = .string(a.type); o["assignee_id"] = .string(a.id)
        case .clear: o["assignee_type"] = .null; o["assignee_id"] = .null
        case .unchanged: break
        }
        func put(_ p: IssueListField<String>, _ key: String) {
            switch p {
            case .set(let v): o[key] = .string(v)
            case .clear: o[key] = .null
            case .unchanged: break
            }
        }
        put(startDate, "start_date")
        put(dueDate, "due_date")
        put(projectID, "project_id")
        put(parentIssueID, "parent_issue_id")
        if case .clear = parentIssueID { o["stage"] = .null }
        if let position { o["position"] = .number(position) }
        if suppressRun { o["suppress_run"] = .bool(true) }
        return o
    }

    func applied(to issue: Issue) -> Issue {
        var out = issue
        if let title { out.title = title }
        if let status {
            out.status = status
            out.statusCategory = status.builtInCategory ?? out.statusCategory
        }
        if let priority { out.priority = priority }
        switch assignee {
        case .set(let a): out.assignee = a
        case .clear: out.assignee = nil
        case .unchanged: break
        }
        func val(_ p: IssueListField<String>, _ current: String?) -> String? {
            switch p {
            case .set(let v): return v
            case .clear: return nil
            case .unchanged: return current
            }
        }
        out.startDate = val(startDate, out.startDate)
        out.dueDate = val(dueDate, out.dueDate)
        out.projectID = val(projectID, out.projectID)
        out.parentIssueID = val(parentIssueID, out.parentIssueID)
        if let position { out.position = position }
        return out
    }
}

/// Lookups shared by the issue surfaces.
extension WorkspaceSession {
    /// Every status entry (archived included) when the full catalog is
    /// loaded, else the active catalog.
    var issueListStatusEntries: [IssueStatusEntry] {
        issueStatusEntries.isLoaded ? issueStatusEntries.items : issues.catalog.entries
    }

    func issueListStatusEntry(_ key: IssueStatusKey) -> IssueStatusEntry? {
        issues.catalog.entry(for: key) ?? issueStatusEntries.items.first { $0.key == key }
    }

    func issueListStatusLabel(_ key: IssueStatusKey) -> String {
        if let e = issueListStatusEntry(key), !e.isSystem { return e.name }
        return key.localizedBuiltInName ?? issues.catalog.displayName(for: key)
    }

    func issueListStatusCategory(_ key: IssueStatusKey) -> StatusCategory {
        issueListStatusEntry(key)?.category ?? key.builtInCategory ?? .unstarted
    }

    func issueListMemberRole(_ userID: String) -> String? {
        directory.member(userID: userID)?.role
    }
}

enum IssueListFormat {
    /// `formatDateOnly(…, { month: "short", day: "numeric" })`.
    static func shortDay(_ s: String?) -> String {
        guard let s, let d = IssueListQuery.parseDay(s) else { return "" }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    static func isPast(_ s: String?) -> Bool {
        guard let s, let d = IssueListQuery.parseDay(s) else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }

    static func projectStatusLabel(_ status: String) -> String {
        tr("projects", "status.\(status)")
    }

    static func projectStatusColor(_ status: String) -> Color {
        switch status {
        case "in_progress": return Theme.warning
        case "completed": return Theme.info
        case "cancelled": return Theme.destructive
        default: return .secondary
        }
    }

    /// Board column tint (`STATUS_CONFIG[category].columnBg`).
    static func columnBackground(_ category: StatusCategory?) -> Color {
        switch category {
        case .started?: return Theme.warning.opacity(0.05)
        case .done?: return Theme.info.opacity(0.05)
        default: return Color.primary.opacity(0.035)
        }
    }

    static func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}
