import AppKit
import MulticaCore
import UserNotifications

/// Native banners for new inbox items and the dock unread badge — the
/// counterparts of the upstream desktop main process `notification:show`
/// and `badge:set` handlers.
@MainActor
final class SystemNotifications: NSObject, UNUserNotificationCenterDelegate {
    /// Called with (workspace slug, inbox item id, issue key) on click.
    var onOpen: ((String, String, String) -> Void)?
    private var shown = Set<String>()
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter needs a real app bundle; `swift run`
        // builds have none and would crash.
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func activate() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Shows a banner unless Multica is frontmost, the item was already
    /// announced, or the workspace muted system notifications.
    func announce(_ item: InboxItem, slug: String?, api: APIClient) {
        guard !NSApp.isActive, !shown.contains(item.id), let center else { return }
        shown.insert(item.id)
        Task {
            if let slug, let prefs = try? await api.getNotificationPreferences(workspaceSlug: slug),
               prefs.preferences["system_notifications"]?.stringValue == "muted" {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body ?? ""
            content.sound = .default
            content.userInfo = ["slug": slug ?? "", "itemId": item.id, "issueKey": item.issueID ?? item.id]
            try? await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
        }
    }

    func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count == 0 ? nil : (count > 99 ? "99+" : String(count))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let slug = info["slug"] as? String ?? ""
        let itemID = info["itemId"] as? String ?? ""
        let issueKey = info["issueKey"] as? String ?? ""
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if !slug.isEmpty { self.onOpen?(slug, itemID, issueKey) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
