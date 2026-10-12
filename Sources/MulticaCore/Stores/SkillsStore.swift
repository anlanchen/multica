import Foundation
import Observation

/// Skills state that outlives a page: the skill label catalog, the list's
/// persisted view preferences (per workspace) and the runtime local-skill
/// inventories (30 s fresh, like upstream's staleTime).
@MainActor
@Observable
public final class SkillsStore {
    public let labels = CollectionStore<LabelRecord>(sort: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })

    public var viewState: SkillsViewState {
        didSet { if viewState != oldValue { persist() } }
    }

    @ObservationIgnored private weak var session: WorkspaceSession?
    @ObservationIgnored private let defaultsKey: String
    @ObservationIgnored private var inventories: [String: (fetchedAt: Date, inventory: SkillsLocalInventory)] = [:]

    private static var stores: [ObjectIdentifier: SkillsStore] = [:]

    public static func shared(for session: WorkspaceSession) -> SkillsStore {
        let key = ObjectIdentifier(session)
        if let store = stores[key] { return store }
        let store = SkillsStore(session: session)
        stores = stores.filter { $0.value.session != nil }
        stores[key] = store
        return store
    }

    init(session: WorkspaceSession) {
        self.session = session
        defaultsKey = "multica_skills_view:\(session.workspace.id)"
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONCoders.decoder.decode(SkillsViewState.self, from: data) {
            viewState = saved
        } else {
            viewState = SkillsViewState()
        }
        let api = session.api
        labels.configure { try await api.skillsListLabels() }
        observeLabelEvents()
    }

    private func persist() {
        if let data = try? JSONCoders.encoder.encode(viewState) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func observeLabelEvents() {
        guard let session else { return }
        withObservationTracking {
            _ = session.revision("label")
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.labels.refreshIfLoaded()
                self.observeLabelEvents()
            }
        }
    }

    // MARK: Runtime local skills

    public func cachedInventory(_ runtimeID: String) -> SkillsLocalInventory? {
        guard let hit = inventories[runtimeID], Date().timeIntervalSince(hit.fetchedAt) < 30 else { return nil }
        return hit.inventory
    }

    public func inventory(_ runtimeID: String) async throws -> SkillsLocalInventory {
        if let hit = cachedInventory(runtimeID) { return hit }
        guard let session else { throw SkillsError("session closed") }
        let inventory = try await session.api.skillsDiscoverLocalSkills(runtimeID: runtimeID)
        inventories[runtimeID] = (Date(), inventory)
        return inventory
    }

    public func invalidateInventory(_ runtimeID: String) {
        inventories[runtimeID] = nil
    }
}
