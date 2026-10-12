import MulticaCore
import SwiftUI

// Placeholder entry points for this area; replaced by the full screens.

struct RuntimesPage: View {

    var body: some View {
        EmptyStateView(icon: "hammer", title: tr("layout", "nav.runtimes"))
    }
}

struct RuntimeDetailPage: View {
    let machineID: String

    var body: some View {
        EmptyStateView(icon: "hammer", title: "RuntimeDetailPage")
    }
}

struct RuntimeSettingsPage: View {
    let machineID: String
    let runtimeID: String

    var body: some View {
        EmptyStateView(icon: "hammer", title: "RuntimeSettingsPage")
    }
}
