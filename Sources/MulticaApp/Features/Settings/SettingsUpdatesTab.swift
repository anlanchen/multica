import AppKit
import MulticaCore
import SwiftUI

/// Settings › Updates (desktop updates-settings-tab.tsx). This client has no
/// background updater, so it shows the app and server versions and opens the
/// releases page to check for a newer build.
struct SettingsUpdatesTab: View {
    @Environment(AppEnvironment.self) private var env

    static let releasesURL = URL(string: "https://github.com/multica-ai/multica/releases")!

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? MulticaCoreVersion.string
    }

    var body: some View {
        SettingsTabView(title: tr("settings", "desktop.updates.title")) {
            SettingsCardView {
                SettingsRowView(tr("settings", "desktop.updates.current_version")) {
                    Text("v\(appVersion)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let server = env.serverVersion {
                    SettingsRowView(tr("layout", "help.server_version", ["version": ""]).trimmingCharacters(in: .whitespaces)) {
                        Text(server).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                SettingsRowView(tr("settings", "desktop.updates.check_section_title"), align: .top) {
                    Button(tr("settings", "desktop.updates.check_now")) { NSWorkspace.shared.open(Self.releasesURL) }
                        .controlSize(.small)
                }
            }
        }
        .task { if env.appConfig == nil { await env.loadAccountExtras() } }
    }
}
