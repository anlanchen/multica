import MulticaCore
import SwiftUI

/// The fields an issue picker row needs, from any of the issue shapes.
struct IssueModalPickedIssue: Identifiable, Hashable {
    var id: String
    var identifier: String
    var title: String
    var status: IssueStatusKey
    var statusCategory: StatusCategory?
    var duplicateOfID: String?
    var parentIssueID: String?

    init(issue: Issue) {
        id = issue.id
        identifier = issue.identifier
        title = issue.title
        status = issue.status
        statusCategory = issue.statusCategory
        parentIssueID = issue.parentIssueID
    }

    init(search r: SearchIssueResult) {
        id = r.id
        identifier = r.identifier
        title = r.title
        status = IssueStatusKey(rawValue: r.status)
        statusCategory = r.statusCategory.map(StatusCategory.init(rawValue:))
        duplicateOfID = r.duplicateOf?.id
        parentIssueID = r.parentIssueId
    }

    init(record r: IssueRecord) {
        id = r.id
        identifier = r.identifier
        title = r.title
        status = IssueStatusKey(rawValue: r.status)
        statusCategory = r.statusCategory.map(StatusCategory.init(rawValue:))
        duplicateOfID = r.duplicateOf?.id
        parentIssueID = r.parentIssueId
    }

    /// Duplicates cannot be originals (upstream isDuplicateIssue).
    var isDuplicate: Bool { IssueModalDuplicates.isDuplicate(status: status.rawValue, duplicateOfID: duplicateOfID) }
}

/// Issues offered before the user types, under a heading.
struct IssueModalSuggestionGroup: Identifiable {
    var id: String
    var heading: String
    var issues: [IssueModalPickedIssue]
}

/// Search-to-pick dialog shared by set parent, mark duplicate, add
/// sub-issue and the create form's parent/child pickers (upstream
/// IssuePickerModal). Title and description are for assistive tech only,
/// as upstream's CommandDialog renders them screen-reader-only.
struct IssueModalIssuePickerDialog: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let title: String
    let description: String
    var excludeIDs: Set<String>
    var suggestions: [IssueModalSuggestionGroup] = []
    var isSelectable: (IssueModalPickedIssue) -> Bool = { _ in true }
    let onSelect: (IssueModalPickedIssue) -> Void

    @State private var query = ""
    @State private var results: [IssueModalPickedIssue] = []
    @State private var loading = false
    @State private var highlighted: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private func selectable(_ i: IssueModalPickedIssue) -> Bool { !excludeIDs.contains(i.id) && isSelectable(i) }

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = trimmed.isEmpty
            ? suggestions.map { IssueModalSuggestionGroup(id: $0.id, heading: $0.heading, issues: $0.issues.filter(selectable)) }.filter { !$0.issues.isEmpty }
            : []
        let shown = results.filter(selectable)
        let rows = trimmed.isEmpty ? groups.flatMap(\.issues) : (loading ? [] : shown)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(tr("modals", "issue_picker.search_placeholder"), text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .focused($focused)
                    .onSubmit { pick(highlighted.flatMap { h in rows.first { $0.id == h } } ?? rows.first) }
                    .onKeyPress(.downArrow) { move(1, rows); return .handled }
                    .onKeyPress(.upArrow) { move(-1, rows); return .handled }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if loading {
                            message(tr("modals", "issue_picker.searching"))
                        } else if !trimmed.isEmpty && shown.isEmpty {
                            message(tr("modals", "issue_picker.no_results"))
                        } else if trimmed.isEmpty && groups.isEmpty {
                            message(tr("modals", "issue_picker.prompt_to_search"))
                        }
                        if trimmed.isEmpty {
                            ForEach(groups) { g in
                                Text(g.heading)
                                    .font(Theme.Font.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                                ForEach(g.issues) { row($0, rows: rows) }
                            }
                        } else if !loading {
                            ForEach(shown) { row($0, rows: rows) }
                        }
                    }
                    .padding(4)
                }
                .onChange(of: highlighted) { if let h = highlighted { proxy.scrollTo(h) } }
            }
            .frame(height: 300)
        }
        .frame(width: 512)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityHint(description)
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
        .onChange(of: query) { search(query) }
        .onDisappear { searchTask?.cancel() }
    }

    private func message(_ s: String) -> some View {
        Text(s)
            .font(Theme.Font.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private func row(_ issue: IssueModalPickedIssue, rows: [IssueModalPickedIssue]) -> some View {
        let isHighlighted = (highlighted ?? rows.first?.id) == issue.id
        return Button { pick(issue) } label: {
            HStack(spacing: 8) {
                StatusIcon(status: issue.status, entry: session.issues.catalog.entry(for: issue.status))
                Text(issue.identifier).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Text(issue.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Theme.Font.body)
        }
        .buttonStyle(HoverRowButtonStyle(selected: isHighlighted))
        .id(issue.id)
        .onHover { if $0 { highlighted = issue.id } }
    }

    private func move(_ delta: Int, _ rows: [IssueModalPickedIssue]) {
        guard !rows.isEmpty else { return }
        let i = rows.firstIndex { $0.id == (highlighted ?? rows.first?.id) } ?? 0
        highlighted = rows[max(0, min(rows.count - 1, i + delta))].id
    }

    private func pick(_ issue: IssueModalPickedIssue?) {
        guard let issue else { return }
        onSelect(issue)
        dismiss()
    }

    private func search(_ q: String) {
        searchTask?.cancel()
        highlighted = nil
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            loading = false
            return
        }
        loading = true
        let api = session.api
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let res = try await api.searchIssues(q: trimmed, limit: 20, includeClosed: true)
                guard !Task.isCancelled else { return }
                results = res.issues.map(IssueModalPickedIssue.init(search:))
            } catch {
                guard !Task.isCancelled else { return }
            }
            loading = false
        }
    }
}

/// Upstream SetParentIssueModal: the issue itself and its direct children
/// cannot become its parent.
struct IssueModalSetParentDialog: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let issueID: String
    @State private var childIDs: Set<String> = []

    var body: some View {
        IssueModalIssuePickerDialog(
            title: tr("modals", "set_parent.title"),
            description: tr("modals", "set_parent.description"),
            excludeIDs: childIDs.union([issueID])
        ) { selected in
            let session = session, toaster = toaster, issueID = issueID
            Task {
                do {
                    try await session.issueModalUpdate(issueID, UpdateIssueRequestRecord(parentIssueId: selected.id)) { $0.parentIssueID = selected.id }
                    toaster.success(tr("modals", "set_parent.toast_success", ["identifier": selected.identifier]))
                } catch {
                    toaster.error(IssueModalErrors.message(error, fallback: tr("modals", "set_parent.toast_failed")))
                }
            }
        }
        .task {
            if let children = try? await session.api.listChildIssues(issueID) { childIDs = Set(children.map(\.id)) }
        }
    }
}

/// Upstream AddChildIssueModal: excludes the issue, its parent and its
/// existing children.
struct IssueModalAddChildDialog: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let parentID: String
    @State private var excluded: Set<String> = []

    var body: some View {
        IssueModalIssuePickerDialog(
            title: tr("modals", "add_child.title"),
            description: tr("modals", "add_child.description"),
            excludeIDs: excluded.union([parentID])
        ) { selected in
            let session = session, toaster = toaster, parentID = parentID
            Task {
                do {
                    try await session.issueModalUpdate(selected.id, UpdateIssueRequestRecord(parentIssueId: parentID)) { $0.parentIssueID = parentID }
                    toaster.success(tr("modals", "add_child.toast_success", ["identifier": selected.identifier]))
                } catch {
                    toaster.error(IssueModalErrors.message(error, fallback: tr("modals", "add_child.toast_failed")))
                }
            }
        }
        .task {
            var ids = Set<String>()
            if let p = session.issues.model(parentID)?.issue.parentIssueID { ids.insert(p) }
            excluded = ids
            let api = session.api, parentID = parentID
            async let issue = try? api.issue(parentID)
            async let children = try? api.listChildIssues(parentID)
            if let p = await issue?.parentIssueID { ids.insert(p) }
            for c in await children ?? [] { ids.insert(c.id) }
            excluded = ids
        }
    }
}

/// Upstream MarkDuplicateIssueModal (MUL-7349): opens with candidates —
/// same-title issues and recently viewed ones — and marks the issue as a
/// cancelled duplicate of the pick.
struct IssueModalMarkDuplicateDialog: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster
    let issueID: String
    @State private var excluded: Set<String> = []
    @State private var similar: [IssueModalPickedIssue] = []
    @State private var recent: [IssueModalPickedIssue] = []

    private static let suggestionLimit = 6

    var body: some View {
        let seen = Set(similar.map(\.id))
        IssueModalIssuePickerDialog(
            title: tr("modals", "mark_duplicate.title"),
            description: tr("modals", "mark_duplicate.description"),
            excludeIDs: excluded.union([issueID]),
            suggestions: [
                IssueModalSuggestionGroup(id: "similar", heading: tr("modals", "issue_picker.suggested_similar"), issues: similar),
                IssueModalSuggestionGroup(id: "recent", heading: tr("modals", "issue_picker.suggested_recent"), issues: recent.filter { !seen.contains($0.id) }),
            ],
            isSelectable: { !$0.isDuplicate }
        ) { selected in
            let session = session, toaster = toaster, issueID = issueID
            Task {
                do {
                    try await session.issueModalUpdate(issueID, UpdateIssueRequestRecord(status: "cancelled", duplicateOfIssueId: selected.id)) {
                        $0.status = .cancelled
                        $0.statusCategory = .closed
                    }
                    toaster.success(tr("modals", "mark_duplicate.toast_success", ["identifier": selected.identifier]))
                } catch {
                    switch IssueModalErrors.code(error) {
                    case "duplicate_target_is_duplicate":
                        toaster.error(tr("modals", "mark_duplicate.error_target_is_duplicate", ["identifier": selected.identifier]))
                    case "issue_has_duplicates":
                        toaster.error(tr("modals", "mark_duplicate.error_has_duplicates"))
                    default:
                        toaster.error(IssueModalErrors.message(error, fallback: tr("modals", "mark_duplicate.toast_failed")))
                    }
                }
            }
        }
        .task { await loadCandidates() }
    }

    private func loadCandidates() async {
        let api = session.api, issueID = issueID
        let recentIDs = SearchPalettePages.recentIssueIDs(env.tabs.activeGroup?.browsingHistory ?? [])
            .filter { $0 != issueID }
            .prefix(Self.suggestionLimit)
        async let relations = try? api.listIssueDuplicates(issueID)
        async let recentRecords: [IssueRecord] = withTaskGroup(of: (Int, IssueRecord?).self) { group in
            for (i, id) in recentIDs.enumerated() { group.addTask { (i, try? await api.getIssue(id)) } }
            var out: [(Int, IssueRecord)] = []
            for await (i, r) in group { if let r { out.append((i, r)) } }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var title = session.issues.model(issueID)?.issue.title
        if title == nil { title = try? await api.issue(issueID).title }
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let res = try? await api.searchIssues(q: trimmed, limit: Self.suggestionLimit, includeClosed: true) {
            similar = res.issues.map(IssueModalPickedIssue.init(search:))
        }
        excluded = Set(await relations?.duplicates.map(\.id) ?? [])
        recent = await recentRecords.map(IssueModalPickedIssue.init(record:))
    }
}
