import MulticaCore
import SwiftUI

// Placeholder entry points for this area; replaced by the full screens.

struct ProjectsPage: View {

    var body: some View {
        EmptyStateView(icon: "hammer", title: tr("layout", "nav.projects"))
    }
}

struct ProjectDetailPage: View {
    let projectID: String

    var body: some View {
        EmptyStateView(icon: "hammer", title: "ProjectDetailPage")
    }
}

struct CreateProjectSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("CreateProjectSheet").font(Theme.Font.title)
            Button(tr("common", "cancel")) { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
