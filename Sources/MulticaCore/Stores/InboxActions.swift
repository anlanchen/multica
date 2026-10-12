import Foundation

/// The inbox mutations upstream exposes (inbox/mutations.ts). Rows flip
/// optimistically where the outcome is predictable; every write then re-reads
/// the list and the unread summary from the server, which owns grouping and
/// the archive split.
extension WorkspaceSession {
    public func inboxReload() async throws {
        inbox.setItems(try await api.inbox())
    }

    public func inboxRefreshSummary() async {
        if let s = try? await api.inboxUnreadSummary() { inbox.setSummary(s) }
    }

    private func inboxSettle(reloadList: Bool) async {
        async let summary: Void = inboxRefreshSummary()
        if reloadList, inbox.isLoaded { try? await inboxReload() }
        await summary
    }

    /// Runs a write and refreshes list and badge whether it succeeded or not.
    private func inboxWrite(_ op: () async throws -> Void) async throws {
        do {
            try await op()
        } catch {
            await inboxSettle(reloadList: true)
            throw error
        }
        await inboxSettle(reloadList: true)
    }

    public func inboxMarkRead(_ id: String) async throws {
        let before = inbox.markRead(id)
        do {
            try await api.markInboxRead(id: id)
        } catch {
            if let before { inbox.restore(before) }
            throw error
        }
        await inboxSettle(reloadList: false)
    }

    public func inboxMarkUnread(_ id: String) async throws {
        let before = inbox.items.first { $0.id == id }
        if var flipped = before, flipped.read {
            flipped.read = false
            inbox.restore(flipped)
        }
        do {
            try await api.markInboxUnread(id)
        } catch {
            if let before { inbox.restore(before) }
            throw error
        }
        await inboxSettle(reloadList: false)
    }

    public func inboxArchive(_ id: String) async throws {
        try await inboxWrite { try await api.archiveInbox(id: id) }
    }

    public func inboxUnarchive(_ id: String) async throws {
        try await inboxWrite { try await api.unarchiveInbox(id) }
    }

    public func inboxMarkAllRead() async throws {
        inbox.markAllRead()
        do {
            try await api.markAllInboxRead()
        } catch {
            await inboxSettle(reloadList: true)
            throw error
        }
        await inboxSettle(reloadList: false)
    }

    public func inboxArchiveAll() async throws {
        try await inboxWrite { _ = try await api.archiveAllInbox() }
    }

    public func inboxArchiveAllRead() async throws {
        try await inboxWrite { _ = try await api.archiveAllReadInbox() }
    }

    public func inboxArchiveCompleted() async throws {
        try await inboxWrite { _ = try await api.archiveCompletedInbox() }
    }

    public func inboxRetrySourceContext(taskID: String) async throws {
        try await inboxWrite { _ = try await api.retrySourceContextQuickCreate(taskId: taskID) }
    }
}
