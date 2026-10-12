import MulticaCore
import SwiftUI

// Placeholder entry points for this area; replaced by the full screens.

struct AgentsPage: View {

    var body: some View {
        EmptyStateView(icon: "hammer", title: tr("layout", "nav.agents"))
    }
}

struct AgentDetailPage: View {
    let agentID: String

    var body: some View {
        EmptyStateView(icon: "hammer", title: "AgentDetailPage")
    }
}

struct ChooseCreateAgentMethodPage: View {

    var body: some View {
        EmptyStateView(icon: "hammer", title: "ChooseCreateAgentMethodPage")
    }
}

struct ManualCreateAgentPage: View {

    var body: some View {
        EmptyStateView(icon: "hammer", title: "ManualCreateAgentPage")
    }
}

struct AICreateAgentPage: View {

    var body: some View {
        EmptyStateView(icon: "hammer", title: "AICreateAgentPage")
    }
}

struct AIBuilderSessionPage: View {
    let sessionID: String

    var body: some View {
        EmptyStateView(icon: "hammer", title: "AIBuilderSessionPage")
    }
}
