import AppKit
import MulticaCore
import Observation
import SwiftUI

/// Inbox filters per workspace, kept in memory for the app's lifetime like
/// upstream's (unpersisted) zustand filter store.
@MainActor
@Observable
final class InboxFilterStore {
    static let shared = InboxFilterStore()
    private(set) var byWorkspace: [String: InboxFilters] = [:]

    func filters(_ wsID: String) -> InboxFilters { byWorkspace[wsID] ?? InboxFilters() }

    func update(_ wsID: String, _ change: (inout InboxFilters) -> Void) {
        var f = filters(wsID)
        change(&f)
        byWorkspace[wsID] = InboxFiltering.isEmpty(f) ? nil : f
    }

    func clear(_ wsID: String) { byWorkspace[wsID] = nil }

    func clearPriorities(_ wsID: String) {
        guard let f = byWorkspace[wsID], !f.priorities.isEmpty else { return }
        update(wsID) { $0.priorities = [] }
    }
}

/// State of the inbox page: which list is showing, the selection, the
/// archived pages, and the derived visible rows. Derivations run here when
/// an input changes, never in `body`.
@MainActor
@Observable
final class InboxPageModel {
    let session: WorkspaceSession
    @ObservationIgnored weak var nav: Navigator?
    @ObservationIgnored weak var toaster: Toaster?

    private(set) var view: InboxView = .inbox
    private(set) var selectedKey = ""

    private(set) var mainLoading = true
    private(set) var mainItems: [InboxItem] = []
    /// Groups archived from here, hidden until the server's list catches up.
    @ObservationIgnored private var hiddenKeys: Set<String> = []

    private(set) var archivedItems: [InboxItem] = []
    @ObservationIgnored private var archivedRaw: [InboxItem] = []
    @ObservationIgnored private var archivedCursor: String?
    private(set) var archivedHasMore = false
    private(set) var archivedLoading = false
    private(set) var archivedError = false
    private(set) var loadingMore = false
    private(set) var loadMoreError = false
    @ObservationIgnored private var archivedGeneration = 0

    private(set) var lookupItems: [InboxItem] = []
    private(set) var lookupLoading = false
    private(set) var lookupError = false
    @ObservationIgnored private var lookupKey = ""

    private(set) var prioritySupport: InboxPrioritySupport = .unknown
    private(set) var effectiveFilters = InboxFilters()
    private(set) var visibleItems: [InboxItem] = []
    private(set) var selectionItems: [InboxItem] = []
    private(set) var selected: InboxItem?

    /// Bumped when the open row is clicked again (re-lands the highlight).
    private(set) var highlightToken = 0
    @ObservationIgnored private var manualUnreadID: String?
    @ObservationIgnored private var lastResolvedKey = ""
    @ObservationIgnored private var markingRead: Set<String> = []

    init(session: WorkspaceSession) {
        self.session = session
    }

    var wsID: String { session.workspace.id }
    var isArchived: Bool { view == .archived }
    var filters: InboxFilters { InboxFilterStore.shared.filters(wsID) }
    var viewItems: [InboxItem] { isArchived ? archivedItems : mainItems }
    var viewLoading: Bool { isArchived ? archivedLoading : mainLoading }
    var hasActiveFilters: Bool { InboxFiltering.count(effectiveFilters) > 0 }
    var needsLookup: Bool { isArchived && !selectedKey.isEmpty && !viewItems.contains { InboxFiltering.key($0) == selectedKey } }

    // MARK: Loading

    func start(urlKey: String, urlView: InboxView) async {
        view = urlView
        selectedKey = urlKey
        if session.inbox.isLoaded {
            syncMain()
            mainLoading = false
        }
        if isArchived { await loadArchived() }
        await loadMain()
    }

    func loadMain() async {
        do {
            try await session.inboxReload()
        } catch {
            if !session.inbox.isLoaded { toaster?.error(error) }
        }
        mainLoading = false
        syncMain()
    }

    /// Re-reads the shared store's rows (kept live by realtime).
    func syncMain() {
        let items = session.inbox.items
        if !hiddenKeys.isEmpty {
            let present = Set(items.map(InboxFiltering.key))
            hiddenKeys.formIntersection(present)
        }
        mainItems = hiddenKeys.isEmpty ? items : items.filter { !hiddenKeys.contains(InboxFiltering.key($0)) }
        recompute()
    }

    func loadArchived() async {
        archivedGeneration += 1
        let generation = archivedGeneration
        archivedLoading = archivedItems.isEmpty
        archivedError = false
        loadMoreError = false
        do {
            let page = try await session.api.listArchivedInboxPage(filters)
            guard generation == archivedGeneration else { return }
            archivedRaw = page.items
            archivedCursor = page.nextCursor
            archivedHasMore = page.hasMore && page.nextCursor != nil
        } catch {
            guard generation == archivedGeneration else { return }
            if archivedRaw.isEmpty { archivedError = true }
        }
        archivedLoading = false
        rebuildArchived()
    }

    func loadMoreArchived() async {
        guard isArchived, archivedHasMore, !loadingMore, let cursor = archivedCursor else { return }
        let generation = archivedGeneration
        loadingMore = true
        loadMoreError = false
        do {
            let page = try await session.api.listArchivedInboxPage(filters, cursor: cursor)
            guard generation == archivedGeneration else { loadingMore = false; return }
            archivedRaw += page.items
            archivedCursor = page.nextCursor
            archivedHasMore = page.hasMore && page.nextCursor != nil
        } catch {
            loadMoreError = true
        }
        loadingMore = false
        rebuildArchived()
    }

    private func rebuildArchived() {
        archivedItems = InboxFiltering.group(archivedRaw, archived: true)
        recompute()
        Task { await lookupIfNeeded() }
    }

    /// A deep link can point past every loaded archived page: resolve its
    /// group directly.
    func lookupIfNeeded(force: Bool = false) async {
        guard needsLookup, !archivedLoading, !archivedError else {
            if !needsLookup, !lookupItems.isEmpty || lookupError {
                lookupItems = []
                lookupError = false
                recompute()
            }
            return
        }
        guard force || lookupKey != selectedKey else { return }
        let key = selectedKey
        lookupKey = key
        lookupLoading = true
        lookupError = false
        do {
            let page = try await session.api.listArchivedInboxPage(InboxFilters(), groupId: key)
            guard key == selectedKey else { return }
            lookupItems = InboxFiltering.group(page.items, archived: true)
        } catch {
            guard key == selectedKey else { return }
            lookupError = true
        }
        lookupLoading = false
        recompute()
    }

    func retryLookup() {
        Task { await lookupIfNeeded(force: true) }
    }

    /// Inbox events changed what the server holds: both lists refresh.
    func liveRefresh() {
        syncMain()
        if isArchived { Task { await loadArchived() } }
    }

    func filtersChanged() {
        recompute()
        if isArchived { Task { await loadArchived() } }
    }

    // MARK: Derivation

    func recompute() {
        let support: InboxPrioritySupport = isArchived ? .supported : InboxFiltering.prioritySupport(session.inbox.items)
        if support == .unsupported, !filters.priorities.isEmpty {
            InboxFilterStore.shared.clearPriorities(wsID)
        }
        prioritySupport = support
        effectiveFilters = InboxFiltering.effective(filters, support: support)
        let items = viewItems
        visibleItems = InboxFiltering.filter(items, effectiveFilters)
        let onPage = items.contains { InboxFiltering.key($0) == selectedKey }
        selectionItems = (!isArchived || onPage) ? visibleItems : visibleItems + InboxFiltering.filter(lookupItems, effectiveFilters)
        let newSelected = selectedKey.isEmpty ? nil : selectionItems.first { InboxFiltering.key($0) == selectedKey }
        if newSelected != selected { selected = newSelected }
        reconcile(onPage: onPage)
    }

    private func reconcile(onPage: Bool) {
        if let selected {
            lastResolvedKey = selectedKey
            if manualUnreadID != nil, manualUnreadID != selected.id { manualUnreadID = nil }
            if !selected.read, manualUnreadID != selected.id, !markingRead.contains(selected.id) {
                markRead(selected.id)
            }
            return
        }
        manualUnreadID = nil
        guard !selectedKey.isEmpty else { return }
        let inView = onPage || (isArchived && lookupItems.contains { InboxFiltering.key($0) == selectedKey })
        if inView {
            // Filtered out: the notification still exists, just hidden.
            select("")
            return
        }
        let lookupPending = needsLookup && (lookupLoading || lookupKey != selectedKey)
        if viewLoading || lookupPending || (needsLookup && lookupError) || (isArchived && archivedError) { return }
        if lastResolvedKey == selectedKey {
            select("")
            return
        }
        // A shared link to a notification this user doesn't have.
        let key = selectedKey
        selectedKey = ""
        nav?.replace(.issue(key))
    }

    // MARK: Selection & view

    private func writeURL() {
        var query: [String: String] = [:]
        if isArchived { query["view"] = InboxView.archivedParam }
        if !selectedKey.isEmpty { query["issue"] = selectedKey }
        nav?.replace(.inbox, query: query)
    }

    func select(_ key: String) {
        guard key != selectedKey else { return }
        selectedKey = key
        writeURL()
        recompute()
        Task { await lookupIfNeeded() }
    }

    /// A click on a row: a fresh intent, so re-clicking the open row replays
    /// the comment highlight.
    func click(_ item: InboxItem) {
        let key = InboxFiltering.key(item)
        if key == selectedKey, item.issueID != nil { highlightToken += 1 }
        select(key)
    }

    /// Syncs from the tab's URL (notification click, back/forward).
    func applyURL(key: String, view newView: InboxView) {
        var changed = false
        if newView != view {
            view = newView
            changed = true
            if isArchived { Task { await loadArchived() } }
        }
        if key != selectedKey {
            selectedKey = key
            changed = true
        }
        if changed {
            recompute()
            Task { await lookupIfNeeded() }
        }
    }

    func setView(_ newView: InboxView) {
        view = newView
        selectedKey = ""
        writeURL()
        recompute()
        if isArchived {
            Task { await loadArchived() }
        } else {
            syncMain()
        }
    }

    func step(_ delta: Int) {
        guard let next = InboxFiltering.step(from: selectedKey, by: delta, in: visibleItems) else { return }
        select(InboxFiltering.key(next))
    }

    // MARK: Actions

    private func fail(_ error: Error, _ fallbackKey: String) {
        let message = (error as? APIError)?.message ?? ""
        toaster?.error(message.isEmpty ? tr("inbox", fallbackKey) : message)
    }

    func markRead(_ id: String) {
        if manualUnreadID == id { manualUnreadID = nil }
        markingRead.insert(id)
        patchArchived(id) { $0.read = true }
        Task {
            defer { markingRead.remove(id) }
            do {
                try await session.inboxMarkRead(id)
            } catch {
                patchArchived(id) { $0.read = false }
                fail(error, "errors.mark_read_failed")
            }
            syncMain()
        }
    }

    func markUnread(_ id: String) {
        if selected?.id == id { manualUnreadID = id }
        patchArchived(id) { $0.read = false }
        Task {
            do {
                try await session.inboxMarkUnread(id)
            } catch {
                patchArchived(id) { $0.read = true }
                fail(error, "errors.mark_unread_failed")
            }
            syncMain()
        }
    }

    private func patchArchived(_ id: String, _ change: (inout InboxItem) -> Void) {
        guard isArchived else { return }
        var touched = false
        for i in archivedRaw.indices where archivedRaw[i].id == id {
            change(&archivedRaw[i])
            touched = true
        }
        for i in lookupItems.indices where lookupItems[i].id == id {
            change(&lookupItems[i])
            touched = true
        }
        if touched {
            archivedItems = InboxFiltering.group(archivedRaw, archived: true)
            recompute()
        }
    }

    private func advance(past id: String) {
        if case .some(let next) = InboxFiltering.selectionAfterRemoving(id, from: selectionItems, selectedKey: selectedKey) {
            select(next ?? "")
        }
    }

    /// The row action: archive in the main list, restore in the archive.
    func action(_ id: String) {
        isArchived ? unarchive(id) : archive(id)
    }

    func archive(_ id: String) {
        advance(past: id)
        guard let item = selectionItems.first(where: { $0.id == id }) ?? mainItems.first(where: { $0.id == id }) else { return }
        let key = InboxFiltering.key(item)
        hiddenKeys.insert(key)
        syncMain()
        Task {
            do {
                try await session.inboxArchive(id)
                toaster?.success(tr("inbox", "toasts.archived"))
            } catch {
                hiddenKeys.remove(key)
                fail(error, "errors.archive_failed")
            }
            syncMain()
        }
    }

    func unarchive(_ id: String) {
        advance(past: id)
        let groupKey = (archivedRaw.first { $0.id == id } ?? lookupItems.first { $0.id == id }).map(InboxFiltering.key)
        let snapshot = (archivedRaw, lookupItems)
        if let groupKey {
            archivedRaw.removeAll { InboxFiltering.key($0) == groupKey }
            lookupItems.removeAll { InboxFiltering.key($0) == groupKey }
            archivedItems = InboxFiltering.group(archivedRaw, archived: true)
            recompute()
        }
        Task {
            do {
                try await session.inboxUnarchive(id)
                toaster?.success(tr("inbox", "toasts.unarchived"))
            } catch {
                (archivedRaw, lookupItems) = snapshot
                archivedItems = InboxFiltering.group(archivedRaw, archived: true)
                fail(error, "errors.unarchive_failed")
            }
            syncMain()
            if isArchived { await loadArchived() }
        }
    }

    func markAllRead() {
        Task {
            do { try await session.inboxMarkAllRead() } catch { fail(error, "errors.mark_all_read_failed") }
            syncMain()
        }
    }

    func archiveAll() {
        select("")
        hiddenKeys.formUnion(mainItems.map(InboxFiltering.key))
        syncMain()
        Task {
            do { try await session.inboxArchiveAll() } catch {
                hiddenKeys.removeAll()
                fail(error, "errors.archive_all_failed")
            }
            syncMain()
        }
    }

    func archiveAllRead() {
        let readKeys = mainItems.filter(\.read).map(InboxFiltering.key)
        if readKeys.contains(selectedKey) { select("") }
        Task {
            do { try await session.inboxArchiveAllRead() } catch { fail(error, "errors.archive_all_read_failed") }
            syncMain()
        }
    }

    func archiveCompleted() {
        select("")
        Task {
            do { try await session.inboxArchiveCompleted() } catch { fail(error, "errors.archive_completed_failed") }
            syncMain()
        }
    }

    /// The archive shortcut acts on the open row.
    func actionOnSelected() -> Bool {
        guard let selected else { return false }
        action(selected.id)
        return true
    }

    /// An issue deleted elsewhere cascades its notifications away.
    func issueRemoved() {
        Task {
            try? await session.inboxReload()
            await session.inboxRefreshSummary()
            syncMain()
            if isArchived { await loadArchived() }
        }
    }
}
