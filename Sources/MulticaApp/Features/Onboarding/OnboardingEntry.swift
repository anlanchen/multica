import MulticaCore
import SwiftUI

// Placeholder entry points for this area; replaced by the full screens.

struct OnboardingFlow: View {

    var body: some View {
        EmptyStateView(icon: "hammer", title: "OnboardingFlow")
    }
}

struct CreateWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("CreateWorkspaceSheet").font(Theme.Font.title)
            Button(tr("common", "cancel")) { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}

struct InvitationsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("InvitationsSheet").font(Theme.Font.title)
            Button(tr("common", "cancel")) { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}

struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("FeedbackSheet").font(Theme.Font.title)
            Button(tr("common", "cancel")) { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
