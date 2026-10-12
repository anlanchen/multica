import MulticaCore
import Observation
import SwiftUI

struct SearchPaletteCommand: Identifiable {
    var id: String
    var label: String
    var icon: String
    var keywords: [String]
    var checked = false
}

struct SearchPaletteIssueRow: Identifiable, Hashable {
    var id: String
    var number: Int?
    var identifier: String
    var title: String
    var status: IssueStatusKey
    var category: StatusCategory?
    var assignee: ActorRef?
    var descriptionSnippet: String?
    var commentSnippet: String?

    init(issue: Issue) {
        id = issue.id
        number = issue.number
        identifier = issue.identifier
        title = issue.title
        status = issue.status
        category = issue.statusCategory
        assignee = issue.assignee
    }

    init(record r: IssueRecord) {
        id = r.id
        number = r.number
        identifier = r.identifier
        title = r.title
        status = IssueStatusKey(rawValue: r.status)
        category = r.statusCategory.map(StatusCategory.init(rawValue:))
        if let t = r.assigneeType, let i = r.assigneeId, !i.isEmpty { assignee = ActorRef(type: t, id: i) }
    }

    init(search r: SearchIssueResult) {
        id = r.id
        number = r.number
        identifier = r.identifier
        title = r.title
        status = IssueStatusKey(rawValue: r.status)
        category = r.statusCategory.map(StatusCategory.init(rawValue:))
        if let t = r.assigneeType, let i = r.assigneeId, !i.isEmpty { assignee = ActorRef(type: t, id: i) }
        descriptionSnippet = r.matchedDescriptionSnippet.flatMap { $0.isEmpty ? nil : $0 }
        commentSnippet = r.matchedCommentSnippet.flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct SearchPaletteProjectRow: Identifiable, Hashable {
    var id: String
    var title: String
    var icon: String?
    var status: String
    var snippet: String?

    init(_ p: SearchProjectResult) {
        id = p.id
        title = p.title
        icon = p.icon
        status = p.status
        snippet = p.matchSource == "description" ? p.matchedSnippet.flatMap { $0.isEmpty ? nil : $0 } : nil
    }
}

enum SearchPaletteEntry {
    case page(WorkspacePage)
    case command(SearchPaletteCommand)
    case member(Member)
    case workspace(Workspace)
    case project(SearchPaletteProjectRow)
    case issue(SearchPaletteIssueRow)
}

/// One selectable row with its highlighted text precomputed.
struct SearchPaletteItem: Identifiable {
    let id: String
    let entry: SearchPaletteEntry
    var disabled = false
    let title: AttributedString
    var subtitle: AttributedString? = nil
    var snippets: [(icon: String, text: AttributedString)] = []
}

struct SearchPaletteGroup: Identifiable {
    let id: String
    let heading: String
    var icon: String? = nil
    let items: [SearchPaletteItem]
}

/// State of the command palette (upstream SearchCommand): the debounced
/// server search, the client-side groups, and keyboard selection. Groups
/// are rebuilt when the query or the results change, never in `body`.
@MainActor
@Observable
final class SearchPaletteModel {
    struct Inputs {
        var commands: [SearchPaletteCommand] = []
        var members: [Member] = []
        var workspaces: [Workspace] = []
        var recent: [SearchPaletteIssueRow] = []
        var catalog: StatusCatalog = .builtIn
    }

    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    private(set) var groups: [SearchPaletteGroup] = []
    private(set) var loading = false
    private(set) var hasResults = false
    private(set) var pageOrCommandMatches = false
    var selectedID: String?

    @ObservationIgnored private var inputs = Inputs()
    @ObservationIgnored private var resultsQuery = ""
    @ObservationIgnored private var issues: [SearchIssueResult] = []
    @ObservationIgnored private var projects: [SearchProjectResult] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    func setInputs(_ next: Inputs) {
        inputs = next
        rebuild()
    }

    func cancel() {
        searchTask?.cancel()
    }

    /// Enabled rows in display order (keyboard navigation).
    var selectable: [SearchPaletteItem] { groups.flatMap(\.items).filter { !$0.disabled } }

    var selected: SearchPaletteItem? {
        let rows = selectable
        return rows.first { $0.id == selectedID } ?? rows.first
    }

    func move(_ delta: Int) {
        let rows = selectable
        guard !rows.isEmpty else { return }
        let i = rows.firstIndex { $0.id == selected?.id } ?? 0
        selectedID = rows[max(0, min(rows.count - 1, i + delta))].id
    }

    private func queryChanged() {
        selectedID = nil
        searchTask?.cancel()
        let q = trimmed
        if q.isEmpty {
            resultsQuery = ""
            issues = []
            projects = []
            loading = false
            rebuild()
            return
        }
        loading = true
        rebuild()
        let api = api
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            async let i = api.searchIssues(q: q, limit: 20, includeClosed: true)
            async let p = api.searchProjects(q: q, limit: 10, includeClosed: true)
            let issues: [SearchIssueResult]
            let projects: [SearchProjectResult]
            do {
                issues = try await i.issues
                projects = try await p.projects
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.apply(query: q, issues: [], projects: [])
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.apply(query: q, issues: issues, projects: projects)
        }
    }

    private func apply(query q: String, issues: [SearchIssueResult], projects: [SearchProjectResult]) {
        resultsQuery = q
        self.issues = issues
        self.projects = projects
        loading = false
        rebuild()
    }

    private static func highlight(_ text: String, _ query: String) -> AttributedString {
        var out = AttributedString()
        for s in SearchPaletteHighlight.segments(text, query: query) {
            var part = AttributedString(s.text)
            if s.highlight { part.backgroundColor = Color(light: 0xFEF08A, dark: 0x6B4A12) }
            out += part
        }
        return out
    }

    private func matchesName(_ name: String, _ q: String) -> Bool { IssueModalPinyin.matches(name, q) }

    private func rebuild() {
        let q = trimmed.lowercased()
        let raw = trimmed
        var out: [SearchPaletteGroup] = []

        var pages: [SearchPaletteItem] = []
        if !q.isEmpty {
            for page in SearchPalettePages.order {
                let label = page.title
                guard SearchPaletteMatch.row(label: label, keywords: SearchPalettePages.keywords(page), query: q) || matchesName(label, q) else { continue }
                pages.append(SearchPaletteItem(id: "page:\(page.rawValue)", entry: .page(page), title: Self.highlight(label, raw)))
            }
        }
        if !pages.isEmpty { out.append(SearchPaletteGroup(id: "pages", heading: tr("search", "groups.pages"), items: pages)) }

        let commands = q.isEmpty
            ? inputs.commands.filter { $0.id == "new-issue" }
            : inputs.commands.filter { SearchPaletteMatch.row(label: $0.label, keywords: $0.keywords, query: q) || matchesName($0.label, q) }
        if !commands.isEmpty {
            out.append(SearchPaletteGroup(id: "commands", heading: tr("search", "groups.commands"), items: commands.map {
                SearchPaletteItem(id: "command:\($0.id)", entry: .command($0), title: Self.highlight($0.label, raw))
            }))
        }

        var members: [SearchPaletteItem] = []
        if !q.isEmpty {
            let all = SearchPaletteMatch.wantsAllMembers(q)
            for m in inputs.members where all || SearchPaletteMatch.member(name: m.name, email: m.email, role: m.role, query: q) || matchesName(m.name, q) {
                members.append(SearchPaletteItem(id: "member:\(m.userID)", entry: .member(m), title: Self.highlight(m.name, raw),
                                                 subtitle: Self.highlight(m.email, raw)))
                if members.count == 10 { break }
            }
        }
        if !members.isEmpty { out.append(SearchPaletteGroup(id: "members", heading: tr("search", "groups.members"), items: members)) }

        var workspaces: [SearchPaletteItem] = []
        if !q.isEmpty {
            let wantsAll = q.count >= 3 && ["workspaces", "switch", "工作区"].contains { $0.hasPrefix(q) }
            for ws in inputs.workspaces where wantsAll || ws.name.lowercased().contains(q) || ws.slug.lowercased().contains(q) || matchesName(ws.name, q) {
                workspaces.append(SearchPaletteItem(id: "workspace:\(ws.id)", entry: .workspace(ws), title: Self.highlight(ws.name, raw)))
            }
        }
        if !workspaces.isEmpty { out.append(SearchPaletteGroup(id: "workspaces", heading: tr("layout", "sidebar.workspaces_label"), items: workspaces)) }

        let stale = resultsQuery != raw
        let catalog = inputs.catalog
        let projectParts = SearchPaletteRank.partition(projects) {
            $0.status == "cancelled" && !SearchPaletteRank.isProjectDirectHit(title: $0.title, query: resultsQuery)
        }
        let issueParts = SearchPaletteRank.partition(issues) { i in
            IssueModalRunGate.category(statusKey: i.status, carried: i.statusCategory.map(StatusCategory.init(rawValue:)), catalog: catalog) == .closed
                && !SearchPaletteRank.isIssueDirectHit(title: i.title, number: i.number, identifier: i.identifier, query: resultsQuery)
        }
        func projectItem(_ p: SearchProjectResult) -> SearchPaletteItem {
            let row = SearchPaletteProjectRow(p)
            return SearchPaletteItem(id: "project:\(p.id)", entry: .project(row), disabled: stale, title: Self.highlight(row.title, resultsQuery),
                                     snippets: row.snippet.map { [("", Self.highlight($0, resultsQuery))] } ?? [])
        }
        func issueItem(_ i: SearchIssueResult) -> SearchPaletteItem {
            let row = SearchPaletteIssueRow(search: i)
            var snippets: [(icon: String, text: AttributedString)] = []
            if let d = row.descriptionSnippet { snippets.append(("doc.text", Self.highlight(d, resultsQuery))) }
            if let c = row.commentSnippet { snippets.append(("message", Self.highlight(c, resultsQuery))) }
            return SearchPaletteItem(id: "issue:\(i.id)", entry: .issue(row), disabled: stale, title: Self.highlight(row.title, resultsQuery), snippets: snippets)
        }
        if !projectParts.live.isEmpty {
            out.append(SearchPaletteGroup(id: "projects", heading: tr("search", "groups.projects"), items: projectParts.live.map(projectItem)))
        }
        if !issueParts.live.isEmpty {
            out.append(SearchPaletteGroup(id: "issues", heading: tr("search", "groups.issues"), items: issueParts.live.map(issueItem)))
        }
        if !projectParts.cancelled.isEmpty || !issueParts.cancelled.isEmpty {
            out.append(SearchPaletteGroup(id: "cancelled", heading: tr("search", "groups.cancelled"),
                                          items: projectParts.cancelled.map(projectItem) + issueParts.cancelled.map(issueItem)))
        }

        if q.isEmpty && !inputs.recent.isEmpty {
            out.append(SearchPaletteGroup(id: "recent", heading: tr("search", "groups.recent"), icon: "clock", items: inputs.recent.map {
                SearchPaletteItem(id: "recent:\($0.id)", entry: .issue($0), title: AttributedString($0.title))
            }))
        }

        groups = out
        hasResults = !issues.isEmpty || !projects.isEmpty || !members.isEmpty || !workspaces.isEmpty
        pageOrCommandMatches = !pages.isEmpty || !commands.isEmpty
        if let id = selectedID, !selectable.contains(where: { $0.id == id }) { selectedID = nil }
    }
}
