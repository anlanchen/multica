import Foundation
import Observation

/// A loaded-on-demand list of server records with realtime upsert/remove.
///
/// Used for every workspace catalog that does not need the issue store's
/// per-row machinery (projects, squads, skills, autopilots, pins, labels,
/// chat sessions, ...). Loading is single-flight: concurrent `load` calls
/// share one request, and `loadIfNeeded` is free after the first load.
@MainActor
@Observable
public final class CollectionStore<Item: Identifiable & Sendable & Hashable> where Item.ID == String {
    public private(set) var items: [Item] = []
    public private(set) var isLoaded = false
    public private(set) var isLoading = false
    public private(set) var error: String?

    @ObservationIgnored private var fetcher: (@Sendable () async throws -> [Item])?
    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private let sort: ((Item, Item) -> Bool)?

    public init(sort: ((Item, Item) -> Bool)? = nil) {
        self.sort = sort
    }

    /// Sets how the store fetches; called once by the owning session.
    public func configure(_ fetch: @escaping @Sendable () async throws -> [Item]) {
        fetcher = fetch
    }

    public func loadIfNeeded() async {
        guard !isLoaded else { return }
        await load()
    }

    public func load() async {
        if let inflight {
            await inflight.value
            return
        }
        guard let fetcher else { return }
        isLoading = !isLoaded
        let task = Task { @MainActor in
            do {
                self.setAll(try await fetcher())
                self.error = nil
            } catch {
                self.error = (error as? APIError)?.message ?? error.localizedDescription
            }
            self.isLoading = false
        }
        inflight = task
        await task.value
        inflight = nil
    }

    /// Refetches only if something already showed this collection.
    public func refreshIfLoaded() async {
        if isLoaded { await load() }
    }

    public func setAll(_ list: [Item]) {
        let next = sort.map { list.sorted(by: $0) } ?? list
        if next != items { items = next }
        isLoaded = true
    }

    public func item(_ id: String) -> Item? {
        items.first { $0.id == id }
    }

    public func upsert(_ item: Item) {
        var next = items
        if let i = next.firstIndex(where: { $0.id == item.id }) {
            guard next[i] != item else { return }
            next[i] = item
        } else {
            next.append(item)
        }
        if let sort { next.sort(by: sort) }
        items = next
    }

    public func remove(_ id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
    }
}
