import AppKit
import MulticaCore
import SwiftUI
import UserNotifications

/// Settings › Notifications (upstream notifications-tab.tsx): per-event inbox
/// muting and system notifications for this workspace, plus the macOS
/// permission banners need (the native counterpart of the web-only
/// browser-notification-setting.tsx).
struct SettingsNotificationsTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @State private var preferences: [String: String] = [:]

    static let inboxGroups = ["assignments", "status_changes", "comments", "mentions", "updates", "agent_activity"]

    var body: some View {
        SettingsTabView(title: tr("settings", "page.tabs.notifications"), scope: .workspaceOnly) {
            SettingsSectionView(title: tr("settings", "notifications.title"), description: tr("settings", "notifications.description"), anchor: "inbox") {
                SettingsCardView {
                    ForEach(Self.inboxGroups, id: \.self) { key in
                        SettingsRowView(tr("settings", "notifications.groups.\(key).label"),
                                        description: tr("settings", "notifications.groups.\(key).description"), anchor: key) {
                            toggle(key)
                        }
                    }
                }
            }
            SettingsSectionView(title: tr("settings", "notifications.system.title"), description: tr("settings", "notifications.system.description")) {
                VStack(spacing: 12) {
                    SettingsCardView {
                        SettingsRowView(tr("settings", "notifications.system.label"), anchor: "system") {
                            toggle("system_notifications")
                        }
                    }
                    SettingsNotificationPermissionRow()
                }
            }
        }
        .task {
            do {
                let r = try await session.api.getNotificationPreferences()
                preferences = (r.preferences.objectValue ?? [:]).compactMapValues(\.stringValue)
            } catch {
                toaster.error(error)
            }
        }
    }

    private func toggle(_ key: String) -> some View {
        Toggle("", isOn: Binding(get: { preferences[key] != "muted" }, set: { set(key, enabled: $0) }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel(key == "system_notifications" ? tr("settings", "notifications.system.label") : tr("settings", "notifications.groups.\(key).label"))
    }

    /// "all" is the default, so enabling drops the key instead of storing it.
    private func set(_ key: String, enabled: Bool) {
        let previous = preferences
        var updated = preferences
        updated[key] = enabled ? nil : "muted"
        preferences = updated
        Task {
            do {
                let r = try await session.api.updateNotificationPreferences(updated.mapValues { JSONValue.string($0) })
                preferences = (r.preferences.objectValue ?? [:]).compactMapValues(\.stringValue)
            } catch {
                preferences = previous
                toaster.show((error as? APIError)?.message ?? tr("settings", "notifications.toast_failed"), kind: .error)
            }
        }
    }
}

/// macOS notification permission for this app: request it, or point at
/// System Settings once it was denied.
private struct SettingsNotificationPermissionRow: View {
    enum Permission { case unknown, notDetermined, denied, authorized, unavailable }
    @State private var state: Permission = .unknown

    var body: some View {
        VStack(spacing: 0) {
            if state != .unknown && state != .unavailable {
                SettingsCardView {
                    SettingsRowView(trd("settings", "notifications.macos.label", "macOS notifications"), description: hint, anchor: "browser") {
                        switch state {
                        case .notDetermined:
                            Button(tr("settings", "notifications.browser.enable")) { Task { await request() } }
                                .controlSize(.small)
                        case .denied:
                            Button(trd("settings", "notifications.macos.open_settings", "Open System Settings")) { openSystemSettings() }
                                .controlSize(.small)
                        case .authorized:
                            Text(tr("settings", "notifications.browser.enabled_badge"))
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        default:
                            EmptyView()
                        }
                    }
                }
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var hint: String {
        switch state {
        case .authorized: return trd("settings", "notifications.macos.granted", "Multica can show notification banners.")
        case .denied: return trd("settings", "notifications.macos.denied", "Notifications are turned off for Multica in System Settings › Notifications.")
        default: return trd("settings", "notifications.macos.hint", "Allow Multica to show notification banners for new inbox items.")
        }
    }

    /// UNUserNotificationCenter needs a real app bundle (not `swift run`).
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    private func refresh() async {
        guard let center else { state = .unavailable; return }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: state = .notDetermined
        case .denied: state = .denied
        default: state = .authorized
        }
    }

    private func request() async {
        guard let center else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refresh()
    }

    private func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}
