import MulticaCore
import SwiftUI

// Route entry points (called by RouteHost).

struct AgentsPage: View {

    var body: some View {
        AgentsUIListPage()
    }
}

struct AgentDetailPage: View {
    let agentID: String

    var body: some View {
        AgentsUIDetailPage(agentID: agentID)
            .id(agentID)
    }
}

struct ChooseCreateAgentMethodPage: View {

    var body: some View {
        AgentsUIChooseMethodPage()
    }
}

struct ManualCreateAgentPage: View {

    var body: some View {
        AgentsUIManualCreatePage()
    }
}

struct AICreateAgentPage: View {

    var body: some View {
        AgentsUIAICreatePage()
    }
}

struct AIBuilderSessionPage: View {
    let sessionID: String

    var body: some View {
        AgentsUIBuilderSessionPage(sessionID: sessionID)
            .id(sessionID)
    }
}
