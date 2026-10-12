import MulticaCore
import SwiftUI

/// Maps a tab's route to its page (apps/desktop/.../routes.tsx).
struct RouteHost: View {
    let route: AppRoute

    var body: some View {
        Group {
            switch route {
            case .issues: IssuesPage()
            case .issue(let id): IssueDetailPage(issueID: id)
            case .projects: ProjectsPage()
            case .project(let id): ProjectDetailPage(projectID: id)
            case .autopilots: AutopilotsPage()
            case .autopilot(let id): AutopilotDetailPage(autopilotID: id)
            case .myIssues: MyIssuesPage()
            case .runtimes: RuntimesPage()
            case .runtime(let id): RuntimeDetailPage(machineID: id)
            case .runtimeSettings(let m, let r): RuntimeSettingsPage(machineID: m, runtimeID: r)
            case .skills: SkillsPage()
            case .skill(let id): SkillDetailPage(skillID: id)
            case .agents: AgentsPage()
            case .newAgent: ChooseCreateAgentMethodPage()
            case .newAgentManual: ManualCreateAgentPage()
            case .newAgentAI: AICreateAgentPage()
            case .newAgentAISession(let id): AIBuilderSessionPage(sessionID: id)
            case .agent(let id): AgentDetailPage(agentID: id)
            case .member(let id): MemberDetailPage(memberID: id)
            case .squads: SquadsPage()
            case .squad(let id): SquadDetailPage(squadID: id)
            case .inbox: InboxPage()
            case .chat: ChatPage()
            case .attachmentPreview(let id): AttachmentPreviewPage(attachmentID: id)
            case .usage: UsagePage()
            case .settings: SettingsPage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
