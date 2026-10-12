import MulticaCore
import Observation
import SwiftUI

/// Dialogs the skills list can open.
enum SkillsListSheet: Identifiable {
    case create
    case addToAgent([SkillSummary])
    case refresh(SkillsListRow)
    case delete([SkillsListRow], clearsSelection: Bool)
    case update([SkillsListRow], skipped: Int)
    case manageLabels

    var id: String {
        switch self {
        case .create: return "create"
        case .addToAgent(let s): return "add-\(s.map(\.id).joined(separator: ","))"
        case .refresh(let r): return "refresh-\(r.id)"
        case .delete(let r, _): return "delete-\(r.map(\.id).joined(separator: ","))"
        case .update(let r, _): return "update-\(r.map(\.id).joined(separator: ","))"
        case .manageLabels: return "labels"
        }
    }
}

/// Assembles, filters and sorts the skills list outside `body`. Inputs are
/// the session catalogs (observed directly) plus search and view state.
@MainActor
@Observable
final class SkillsListModel {
    private(set) var allRows: [SkillsListRow] = []
    private(set) var rows: [SkillsListRow] = []
    private(set) var options = SkillsList.Options()
    var search = "" { didSet { if search != oldValue { applyFilters() } } }
    var selection: Set<String> = []
    var sheet: SkillsListSheet?

    @ObservationIgnored let session: WorkspaceSession
    @ObservationIgnored let store: SkillsStore
    @ObservationIgnored private var observing = false

    init(session: WorkspaceSession) {
        self.session = session
        self.store = session.skillsStore
    }

    var view: SkillsViewState {
        get { store.viewState }
        set {
            let old = store.viewState
            store.viewState = newValue
            if old.filters != newValue.filters || old.sortField != newValue.sortField || old.sortDirection != newValue.sortDirection {
                applyFilters()
            }
        }
    }

    var isAdmin: Bool { SkillsPermissions.isAdmin(role: session.skillsMyRole) }

    func start() {
        guard !observing else { return }
        observing = true
        observeInputs()
    }

    private func observeInputs() {
        let session = self.session
        let inputs = withObservationTracking {
            (session.skills.items, session.agentRecords.items, session.memberRecords.items, session.runtimeRecords.items)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeInputs() }
        }
        let next = SkillsList.buildRows(skills: inputs.0, agents: inputs.1, members: inputs.2, runtimes: inputs.3,
                                        userID: session.currentUser.id)
        guard next != allRows else { return }
        allRows = next
        options = SkillsList.options(next)
        let ids = Set(next.map(\.id))
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
        applyFilters()
    }

    private func applyFilters() {
        let v = store.viewState
        let filtered = allRows.filter { SkillsList.matches($0, filters: v.filters, query: search) }
        let sorted = SkillsList.sorted(filtered, field: v.sortField, direction: v.sortDirection)
        if sorted != rows { rows = sorted }
    }

    var isNarrowed: Bool {
        store.viewState.filters.activeDimensionCount > 0 || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Selection

    var selectedRows: [SkillsListRow] { rows.filter { selection.contains($0.id) } }

    func toggleSelected(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func toggleAll() {
        let visible = Set(rows.map(\.id))
        let allSelected = !visible.isEmpty && visible.isSubset(of: selection)
        selection = allSelected ? [] : visible
    }

    // MARK: Mutations

    func toggleFilter(_ dimension: SkillsFilterDimension, _ value: String) {
        var v = view
        v.filters.toggle(dimension, value)
        view = v
    }

    func clearFilters() {
        var v = view
        v.filters = SkillsListFilters()
        view = v
    }

    func didDelete(_ ids: [String]) {
        for id in ids { session.skills.remove(id) }
        selection.subtract(ids)
    }
}
