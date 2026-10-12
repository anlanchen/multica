import MulticaCore
import Observation
import SwiftUI

/// Where a new or edited saved view lives (upstream `SaveViewScope`).
enum IssueListSaveScope: Equatable {
    case workspace(actorKind: String)
    case my(variant: String)
    case project(id: String, actorKind: String)

    var scopeType: String {
        switch self {
        case .workspace: return "workspace"
        case .my: return "my"
        case .project: return "project"
        }
    }

    var scopeID: String? {
        if case .project(let id, _) = self { return id }
        return nil
    }
}

/// One entry on the view bar: a built-in tab or a saved view.
struct IssueListBarItem: Identifiable, Hashable {
    var id: String
    var label: String
    var description: String?
    var view: IssueView?
    var canManage = false
    var isBuiltin: Bool { view == nil }
}

/// Saved views and the per-user bar preference for one container
/// (`scope_type`, `scope_id`).
@MainActor
@Observable
final class IssueListViewsModel {
    let session: WorkspaceSession
    let scopeType: String
    let scopeID: String?
    private(set) var views: [IssueView] = []
    private(set) var ready = false
    private(set) var fetching = false
    private(set) var prefs = IssueViewPreference.Prefs()
    @ObservationIgnored private var started = false

    init(session: WorkspaceSession, scopeType: String, scopeID: String?) {
        self.session = session
        self.scopeType = scopeType
        self.scopeID = scopeID
    }

    func start() async {
        guard !started else { return }
        started = true
        await load()
        await session.pins.loadIfNeeded()
    }

    func load() async {
        fetching = true
        defer { fetching = false }
        async let list = try? session.api.listIssueViews(scopeType: scopeType, scopeId: scopeID)
        async let pref = try? session.api.getIssueViewPreference(scopeType: scopeType, scopeId: scopeID)
        if let list = await list {
            views = list
            ready = true
        }
        if let pref = await pref { prefs = pref.prefs }
    }

    func view(_ id: String?) -> IssueView? {
        id.flatMap { id in views.first { $0.id == id } }
    }

    var myRole: String? { session.issueListMemberRole(session.currentUser.id) }

    func canManage(_ view: IssueView) -> Bool {
        IssueListBarPrefs.canManage(ownerID: view.ownerId, visibility: view.visibility, userID: session.currentUser.id, role: myRole)
    }

    func isPinned(_ view: IssueView) -> Bool {
        session.pins.items.contains { $0.itemType == "view" && $0.itemId == view.id }
    }

    func items(builtins: [IssueListBarItem]) -> [IssueListBarItem] {
        builtins + views.map { IssueListBarItem(id: "view:\($0.id)", label: $0.name, view: $0, canManage: canManage($0)) }
    }

    /// Prunes ids that no longer resolve; dropped while the list is still
    /// loading (an empty in-flight list would read as "every view deleted").
    func savePrefs(hidden: [String], order: [String], known: Set<String>) {
        guard ready else { return }
        let next = IssueViewPreference.Prefs(hidden: hidden.filter(known.contains), order: order.filter(known.contains))
        let previous = prefs
        prefs = next
        Task {
            do {
                let saved = try await session.api.putIssueViewPreference(scopeType: scopeType, scopeId: scopeID, hidden: next.hidden, order: next.order)
                prefs = saved.prefs
            } catch {
                prefs = previous
            }
        }
    }

    func create(_ request: CreateIssueViewRequest) async throws -> IssueView? {
        let created = try await session.api.issueListCreateView(request)
        if let created, !views.contains(where: { $0.id == created.id }) { views.append(created) }
        Task { await load() }
        return created
    }

    func update(_ view: IssueView, name: String, visibility: String, scopeVariant: String?,
                query: [String: JSONValue], display: [String: JSONValue]) async throws {
        let updated = try await session.api.issueListUpdateView(view.id, name: name, visibility: visibility, scopeVariant: .some(scopeVariant),
                                                               query: query, display: display, expectedRevision: view.revision)
        if let updated, let i = views.firstIndex(where: { $0.id == updated.id }) { views[i] = updated }
        await load()
    }

    func delete(_ view: IssueView) async throws {
        try await session.api.deleteIssueView(view.id)
        views.removeAll { $0.id == view.id }
        Task { await load() }
    }

    func togglePin(_ view: IssueView) {
        if let pin = session.pins.items.first(where: { $0.itemType == "view" && $0.itemId == view.id }) {
            session.pins.remove(pin.id)
            Task { try? await session.api.deletePin(itemType: "view", itemId: view.id) }
        } else {
            Task {
                if let pin = try? await session.api.createPin(CreatePinRequest(itemType: "view", itemId: view.id)) {
                    session.pins.upsert(pin)
                }
            }
        }
    }
}
