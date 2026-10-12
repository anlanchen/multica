import MulticaCore
import SwiftUI

// Settings › Connections tab bodies, embedded by the Settings page. Each is a
// self-contained scrollable page.

struct ConnectedAppsSettingsTab: View {
    var body: some View { ConnectionsAppsTab() }
}

struct BillingSettingsTab: View {
    var body: some View { ConnectionsBillingTab() }
}

struct CodeSettingsTab: View {
    var body: some View { ConnectionsCodeTab() }
}

struct ChannelsSettingsTab: View {
    var body: some View { ConnectionsChannelsTab() }
}

struct McpSettingsTab: View {
    var body: some View { ConnectionsMcpTab() }
}

struct PluginsSettingsTab: View {
    var body: some View { ConnectionsPluginsTab() }
}
