import AppKit
import MulticaCore
import SwiftUI

extension WorkspaceSession {
    /// The signed-in user's role here (`owner` / `admin` / `member`), nil
    /// until the member directory has loaded.
    var settingsMyRole: String? { directory.member(userID: currentUser.id)?.role }

    var settingsCanManage: Bool { settingsMyRole == "owner" || settingsMyRole == "admin" }
}

extension AppEnvironment {
    /// The current workspace as last saved (the session keeps the copy it
    /// was opened with).
    func settingsWorkspace(_ session: WorkspaceSession) -> Workspace {
        app.workspaces.first { $0.id == session.workspace.id } ?? session.workspace
    }

    func settingsFeatureEnabled(_ key: String) -> Bool {
        appConfig?.featureFlags?[key] ?? false
    }

    /// Mirrors a profile write into the signed-in user.
    func settingsAdopt(_ record: UserRecord) {
        app.setUser(User(id: record.id, name: record.name, email: record.email, avatarURL: record.avatarUrl, language: record.language))
    }

    /// Mirrors a workspace write into the workspace list.
    func settingsAdopt(_ record: WorkspaceRecord) {
        app.replaceWorkspace(Workspace(id: record.id, name: record.name, slug: record.slug, issuePrefix: record.issuePrefix, avatarURL: record.avatarUrl))
    }
}

enum SettingsClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum SettingsDates {
    /// Upstream `new Date(x).toLocaleDateString(locale)`.
    static func short(_ timestamp: String?) -> String {
        guard let timestamp, let d = Timestamp.parse(timestamp) else { return "" }
        return d.formatted(date: .numeric, time: .omitted)
    }
}
