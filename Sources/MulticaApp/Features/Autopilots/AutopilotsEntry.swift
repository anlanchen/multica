import MulticaCore
import SwiftUI

struct AutopilotsPage: View {

    var body: some View {
        AutopilotsListScreen()
    }
}

struct AutopilotDetailPage: View {
    let autopilotID: String

    var body: some View {
        AutopilotsDetailScreen(autopilotID: autopilotID)
            .id(autopilotID)
    }
}
