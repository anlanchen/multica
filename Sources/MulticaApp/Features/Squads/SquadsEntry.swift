import MulticaCore
import SwiftUI

// Placeholder entry points for this area; replaced by the full screens.

struct SquadsPage: View {

    var body: some View {
        EmptyStateView(icon: "hammer", title: tr("layout", "nav.squads"))
    }
}

struct SquadDetailPage: View {
    let squadID: String

    var body: some View {
        EmptyStateView(icon: "hammer", title: "SquadDetailPage")
    }
}

struct CreateSquadSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("CreateSquadSheet").font(Theme.Font.title)
            Button(tr("common", "cancel")) { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
