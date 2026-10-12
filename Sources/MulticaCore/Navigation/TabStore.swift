import Foundation
import Observation

/// Where a tab points: a route plus view-state query items (`?view=`,
/// `?session=`, `?agent=`, ...). Mirrors the upstream tab URL.
public struct TabLocation: Hashable, Sendable, Codable {
    public var route: AppRoute
    public var query: [String: String]

    public init(_ route: AppRoute, query: [String: String] = [:]) {
        self.route = route
        self.query = query
    }

    public var resourceKey: String { route.resourceKey }

    /// `issues?view=x` style string (query keys sorted for stability).
    public var relativeURL: String {
        guard !query.isEmpty else { return route.relativePath }
        var c = URLComponents()
        c.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        return route.relativePath + "?" + (c.percentEncodedQuery ?? "")
    }

    public init?(relativeURL: String) {
        let parts = relativeURL.split(separator: "?", maxSplits: 1)
        guard let first = parts.first, let route = AppRoute(relativePath: String(first)) else { return nil }
        var q: [String: String] = [:]
        if parts.count > 1 {
            for item in URLComponents(string: "?" + parts[1])?.queryItems ?? [] { q[item.name] = item.value ?? "" }
        }
        self.init(route, query: q)
    }
}

/// One tab: its own back/forward stack and per-route view state.
public struct TabSession: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var title: String
    public var pinned: Bool
    public var history: [TabLocation]
    public var index: Int
    /// Route key → (entry key → value). Views write filters, selections and
    /// scroll anchors here so a tab comes back exactly as it was left.
    public var viewState: [String: [String: String]]

    public var location: TabLocation { history[index] }
    public var route: AppRoute { location.route }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < history.count - 1 }
}

public struct WorkspaceTabGroup: Hashable, Sendable, Codable {
    public var tabs: [TabSession]
    public var activeTabID: String
    /// Most recently visited first; never contains the active tab.
    public var recentTabIDs: [String]
    /// Resources visited in this workspace (any tab), newest first.
    public var browsingHistory: [TabLocation]
    public var browsingTitles: [String: String]
}

/// Browser-style tabs, one independent group per workspace — the native
/// counterpart of apps/desktop/src/renderer/src/stores/tab-store.ts.
///
/// Invariants (same as upstream):
/// - every live workspace group has at least one tab and a valid active tab;
/// - pinned tabs come before unpinned tabs;
/// - opening a route dedupes by resource (path without query);
/// - closing the active tab returns to the most recently used tab.
@MainActor
@Observable
public final class TabStore {
    public static let historyLimit = 50
    public static let browsingLimit = 50

    public private(set) var activeWorkspaceSlug: String?
    public private(set) var groups: [String: WorkspaceTabGroup] = [:]
    /// Bumped by `reloadActiveTab`; the content view keys its subtree on it.
    public private(set) var mountGeneration = 0

    @ObservationIgnored public var onChange: ((Data) -> Void)?
    @ObservationIgnored private var makeID: () -> String

    public init(makeID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.makeID = makeID
    }

    // MARK: Reading

    public var activeGroup: WorkspaceTabGroup? {
        activeWorkspaceSlug.flatMap { groups[$0] }
    }

    public var tabs: [TabSession] { activeGroup?.tabs ?? [] }

    public var activeTab: TabSession? {
        guard let g = activeGroup else { return nil }
        return g.tabs.first { $0.id == g.activeTabID }
    }

    public var activeLocation: TabLocation? { activeTab?.location }

    // MARK: Workspace

    public static let defaultLocation = TabLocation(.issues)

    private func newTab(_ location: TabLocation, title: String) -> TabSession {
        TabSession(id: makeID(), title: title, pinned: false, history: [location], index: 0, viewState: [:])
    }

    private func newGroup(_ location: TabLocation, title: String) -> WorkspaceTabGroup {
        let tab = newTab(location, title: title)
        return WorkspaceTabGroup(tabs: [tab], activeTabID: tab.id, recentTabIDs: [], browsingHistory: [location], browsingTitles: [:])
    }

    /// Makes `slug` visible. Restores its last active tab, or opens `location`
    /// (deduped) when given.
    public func switchWorkspace(_ slug: String, open location: TabLocation? = nil, title: String? = nil) {
        if groups[slug] == nil {
            let loc = location ?? Self.defaultLocation
            groups[slug] = newGroup(loc, title: title ?? loc.route.fallbackTitle)
            activeWorkspaceSlug = slug
            persist()
            return
        }
        activeWorkspaceSlug = slug
        if let location {
            openTab(location, title: title)
        } else {
            persist()
        }
    }

    private func mutateActive(_ body: (inout WorkspaceTabGroup) -> Void) {
        guard let slug = activeWorkspaceSlug, var g = groups[slug] else { return }
        body(&g)
        groups[slug] = g
        persist()
    }

    private func setActive(_ id: String, in g: inout WorkspaceTabGroup) {
        guard g.activeTabID != id else { return }
        g.recentTabIDs.removeAll { $0 == id || $0 == g.activeTabID }
        g.recentTabIDs.insert(g.activeTabID, at: 0)
        g.activeTabID = id
    }

    private func recordVisit(_ location: TabLocation, title: String?, in g: inout WorkspaceTabGroup) {
        g.browsingHistory.removeAll { $0.resourceKey == location.resourceKey }
        g.browsingHistory.insert(location, at: 0)
        if g.browsingHistory.count > Self.browsingLimit { g.browsingHistory.removeLast(g.browsingHistory.count - Self.browsingLimit) }
        if let title { g.browsingTitles[location.resourceKey] = title }
        let keep = Set(g.browsingHistory.map(\.resourceKey))
        g.browsingTitles = g.browsingTitles.filter { keep.contains($0.key) }
    }

    // MARK: Tabs

    /// Opens or focuses the tab showing `location`'s resource.
    @discardableResult
    public func openTab(_ location: TabLocation, title: String? = nil, activate: Bool = true) -> String? {
        var opened: String?
        mutateActive { g in
            if let i = g.tabs.firstIndex(where: { $0.location.resourceKey == location.resourceKey }) {
                if g.tabs[i].location != location {
                    g.tabs[i].history[g.tabs[i].index] = location
                }
                opened = g.tabs[i].id
            } else {
                let tab = newTab(location, title: title ?? location.route.fallbackTitle)
                g.tabs.append(tab)
                opened = tab.id
            }
            if activate, let opened { setActive(opened, in: &g) }
            recordVisit(location, title: title, in: &g)
        }
        return opened
    }

    /// Always creates a new tab (⌘T, ⌘-click).
    @discardableResult
    public func addTab(_ location: TabLocation = TabStore.defaultLocation, title: String? = nil, activate: Bool = true) -> String? {
        var id: String?
        mutateActive { g in
            let tab = newTab(location, title: title ?? location.route.fallbackTitle)
            g.tabs.append(tab)
            id = tab.id
            if activate { setActive(tab.id, in: &g) }
            recordVisit(location, title: title, in: &g)
        }
        return id
    }

    private func slugOwning(_ tabID: String) -> String? {
        if let s = activeWorkspaceSlug, groups[s]?.tabs.contains(where: { $0.id == tabID }) == true { return s }
        return groups.first { $0.value.tabs.contains { $0.id == tabID } }?.key
    }

    public func closeTab(_ id: String) {
        guard let slug = slugOwning(id), var g = groups[slug], let i = g.tabs.firstIndex(where: { $0.id == id }) else { return }
        g.tabs.remove(at: i)
        g.recentTabIDs.removeAll { $0 == id }
        if g.tabs.isEmpty {
            let tab = newTab(Self.defaultLocation, title: Self.defaultLocation.route.fallbackTitle)
            g.tabs = [tab]
            g.activeTabID = tab.id
            g.recentTabIDs = []
        } else if g.activeTabID == id {
            if let next = g.recentTabIDs.first(where: { r in g.tabs.contains { $0.id == r } }) {
                g.activeTabID = next
                g.recentTabIDs.removeAll { $0 == next }
            } else {
                g.activeTabID = g.tabs[min(i, g.tabs.count - 1)].id
            }
        }
        groups[slug] = g
        persist()
    }

    public func closeActiveTab() {
        if let id = activeTab?.id { closeTab(id) }
    }

    /// Closes every other unpinned tab in the tab's workspace.
    public func closeOtherTabs(_ id: String) {
        guard let slug = slugOwning(id), var g = groups[slug] else { return }
        g.tabs.removeAll { $0.id != id && !$0.pinned }
        let ids = Set(g.tabs.map(\.id))
        g.recentTabIDs.removeAll { !ids.contains($0) }
        if !ids.contains(g.activeTabID) {
            g.recentTabIDs.removeAll { $0 == id }
            g.activeTabID = id
        }
        groups[slug] = g
        persist()
    }

    public func setActiveTab(_ id: String) {
        guard let slug = slugOwning(id), var g = groups[slug] else { return }
        activeWorkspaceSlug = slug
        setActive(id, in: &g)
        groups[slug] = g
        persist()
    }

    /// Selects the tab at `index` (⌘1…⌘8); ⌘9 picks the last tab.
    public func selectTab(at index: Int) {
        let list = tabs
        guard !list.isEmpty else { return }
        let i = index >= 8 ? list.count - 1 : index
        guard list.indices.contains(i) else { return }
        setActiveTab(list[i].id)
    }

    public func selectAdjacentTab(_ delta: Int) {
        let list = tabs
        guard let current = activeTab, let i = list.firstIndex(where: { $0.id == current.id }), !list.isEmpty else { return }
        setActiveTab(list[(i + delta + list.count) % list.count].id)
    }

    /// Title sync from the page shown in a tab.
    public func setTitle(_ title: String, for id: String) {
        guard let slug = slugOwning(id), var g = groups[slug], let i = g.tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, g.tabs[i].title != trimmed else { return }
        g.tabs[i].title = trimmed
        g.browsingTitles[g.tabs[i].location.resourceKey] = trimmed
        groups[slug] = g
        persist()
    }

    // MARK: In-tab navigation

    /// Navigates the active tab. A pinned tab stays parked on its page: a
    /// push from it opens (or focuses) another tab instead.
    public func navigate(_ location: TabLocation, replace: Bool = false, title: String? = nil) {
        guard let active = activeTab else { return }
        if active.pinned && !replace && active.location.resourceKey != location.resourceKey {
            openTab(location, title: title)
            return
        }
        mutateActive { g in
            guard let i = g.tabs.firstIndex(where: { $0.id == g.activeTabID }) else { return }
            var tab = g.tabs[i]
            if replace || tab.location == location {
                tab.history[tab.index] = location
            } else {
                tab.history.removeSubrange((tab.index + 1)...)
                tab.history.append(location)
                if tab.history.count > Self.historyLimit {
                    tab.history.removeFirst(tab.history.count - Self.historyLimit)
                }
                tab.index = tab.history.count - 1
            }
            if let title { tab.title = title } else if tab.history.count > 1, tab.location.resourceKey != active.location.resourceKey {
                tab.title = g.browsingTitles[location.resourceKey] ?? location.route.fallbackTitle
            }
            g.tabs[i] = tab
            recordVisit(location, title: title, in: &g)
        }
    }

    /// Updates only the query of the active tab's current entry (filters,
    /// selected chat session) without adding history.
    public func setQuery(_ key: String, _ value: String?) {
        guard var loc = activeLocation else { return }
        if loc.query[key] == value { return }
        loc.query[key] = value
        navigate(loc, replace: true)
    }

    public func goBack() { moveHistory(-1) }
    public func goForward() { moveHistory(1) }

    public func goToHistoryIndex(_ index: Int) {
        mutateActive { g in
            guard let i = g.tabs.firstIndex(where: { $0.id == g.activeTabID }), g.tabs[i].history.indices.contains(index) else { return }
            g.tabs[i].index = index
            g.tabs[i].title = g.browsingTitles[g.tabs[i].location.resourceKey] ?? g.tabs[i].location.route.fallbackTitle
        }
    }

    private func moveHistory(_ delta: Int) {
        guard let tab = activeTab else { return }
        goToHistoryIndex(tab.index + delta)
    }

    public func reloadActiveTab() {
        mountGeneration += 1
    }

    // MARK: View state

    public func viewState(_ key: String, tab id: String? = nil) -> String? {
        guard let tab = id.flatMap({ id in tabs.first { $0.id == id } }) ?? activeTab else { return nil }
        return tab.viewState[tab.location.resourceKey]?[key]
    }

    public func setViewState(_ key: String, _ value: String?, tab id: String? = nil) {
        guard let slug = activeWorkspaceSlug, var g = groups[slug] else { return }
        let target = id ?? g.activeTabID
        guard let i = g.tabs.firstIndex(where: { $0.id == target }) else { return }
        let routeKey = g.tabs[i].location.resourceKey
        guard g.tabs[i].viewState[routeKey]?[key] != value else { return }
        g.tabs[i].viewState[routeKey, default: [:]][key] = value
        groups[slug] = g
        persist()
    }

    // MARK: Arrangement

    /// Reorders within the active group, clamped to the pinned/unpinned zone.
    public func moveTab(from: Int, to: Int) {
        mutateActive { g in
            guard g.tabs.indices.contains(from), from != to else { return }
            let pinnedCount = g.tabs.filter(\.pinned).count
            let tab = g.tabs.remove(at: from)
            var target = max(0, min(to, g.tabs.count))
            if tab.pinned { target = min(target, pinnedCount - 1) } else { target = max(target, pinnedCount) }
            g.tabs.insert(tab, at: max(0, min(target, g.tabs.count)))
        }
    }

    public func togglePin(_ id: String) {
        guard let slug = slugOwning(id), var g = groups[slug], let i = g.tabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = g.tabs.remove(at: i)
        tab.pinned.toggle()
        let pinnedCount = g.tabs.filter(\.pinned).count
        g.tabs.insert(tab, at: pinnedCount)
        groups[slug] = g
        persist()
    }

    /// Drops groups for workspaces the user no longer belongs to.
    public func validateWorkspaceSlugs(_ valid: Set<String>) {
        let before = groups.count
        groups = groups.filter { valid.contains($0.key) }
        if let a = activeWorkspaceSlug, !valid.contains(a) {
            activeWorkspaceSlug = groups.keys.sorted().first
        }
        if before != groups.count { persist() }
    }

    /// Renames a group after a workspace slug change.
    public func renameWorkspace(from old: String, to new: String) {
        guard old != new, let g = groups.removeValue(forKey: old) else { return }
        groups[new] = g
        if activeWorkspaceSlug == old { activeWorkspaceSlug = new }
        persist()
    }

    public func reset() {
        groups = [:]
        activeWorkspaceSlug = nil
        persist()
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var version: Int
        var active: String?
        var groups: [String: WorkspaceTabGroup]
    }

    public func snapshot() -> Data {
        (try? JSONEncoder().encode(Snapshot(version: 1, active: activeWorkspaceSlug, groups: groups))) ?? Data()
    }

    /// Restores a snapshot, repairing anything that breaks an invariant.
    public func restore(_ data: Data) {
        guard let s = try? JSONDecoder().decode(Snapshot.self, from: data), s.version == 1 else { return }
        var repaired: [String: WorkspaceTabGroup] = [:]
        for (slug, var g) in s.groups {
            g.tabs = g.tabs.compactMap { t in
                var t = t
                guard !t.history.isEmpty else { return nil }
                t.index = max(0, min(t.index, t.history.count - 1))
                return t
            }
            g.tabs = g.tabs.filter(\.pinned) + g.tabs.filter { !$0.pinned }
            guard !g.tabs.isEmpty else { continue }
            let ids = Set(g.tabs.map(\.id))
            if !ids.contains(g.activeTabID) { g.activeTabID = g.tabs[0].id }
            g.recentTabIDs = g.recentTabIDs.filter { ids.contains($0) && $0 != g.activeTabID }
            repaired[slug] = g
        }
        groups = repaired
        activeWorkspaceSlug = s.active.flatMap { repaired[$0] != nil ? $0 : nil }
    }

    private func persist() {
        onChange?(snapshot())
    }
}
