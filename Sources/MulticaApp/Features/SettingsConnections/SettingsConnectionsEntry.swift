import MulticaCore
import SwiftUI

// Placeholder entry points for the Settings › Connections and billing tabs;
// replaced by the full screens.

struct ConnectedAppsSettingsTab: View {
    var body: some View { EmptyStateView(icon: "puzzlepiece", title: tr("settings", "page.tabs.apps")) }
}

struct BillingSettingsTab: View {
    var body: some View { EmptyStateView(icon: "creditcard", title: tr("settings", "page.tabs.billing")) }
}

struct CodeSettingsTab: View {
    var body: some View { EmptyStateView(icon: "chevron.left.forwardslash.chevron.right", title: tr("settings", "page.tabs.code")) }
}

struct ChannelsSettingsTab: View {
    var body: some View { EmptyStateView(icon: "bubble.left.and.bubble.right", title: tr("settings", "page.tabs.channels")) }
}

struct McpSettingsTab: View {
    var body: some View { EmptyStateView(icon: "server.rack", title: tr("settings", "page.tabs.mcp")) }
}

struct PluginsSettingsTab: View {
    var body: some View { EmptyStateView(icon: "square.grid.2x2", title: tr("settings", "page.tabs.plugins")) }
}
