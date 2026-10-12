import MulticaCore
import SwiftUI

// Placeholder entry points for this area; replaced by the full screens.

struct AutopilotsPage: View {

    var body: some View {
        EmptyStateView(icon: "hammer", title: tr("layout", "nav.autopilots"))
    }
}

struct AutopilotDetailPage: View {
    let autopilotID: String

    var body: some View {
        EmptyStateView(icon: "hammer", title: "AutopilotDetailPage")
    }
}
