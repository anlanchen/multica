import MulticaCore
import Observation
import SwiftUI

/// Defaults for the create-issue dialog (upstream `create-issue` modal data).
struct CreateIssueDraft: Hashable {
    var title = ""
    var description = ""
    var status: IssueStatusKey? = nil
    var priority: IssuePriority? = nil
    var assignee: ActorRef? = nil
    var projectID: String? = nil
    var parentIssueID: String? = nil
    var labelIDs: [String] = []
    var dueDate: String? = nil
    var startDate: String? = nil
}

/// App-wide dialogs (upstream packages/views/modals/registry.tsx).
enum AppModal: Identifiable, Hashable {
    case createIssue(CreateIssueDraft)
    /// "Quick create": describe the work, an agent files the issue.
    case quickCreateIssue(CreateIssueDraft)
    case createProject
    case createSquad
    case feedback
    case setParentIssue(issueID: String)
    case markDuplicateIssue(issueID: String)
    case addChildIssue(parentID: String)
    case deleteIssues(issueIDs: [String])
    case runConfirm(issueID: String)
    case issueLimitUpgrade
    case createWorkspace
    case invitations

    var id: String {
        switch self {
        case .createIssue: return "create-issue"
        case .quickCreateIssue: return "quick-create-issue"
        case .createProject: return "create-project"
        case .createSquad: return "create-squad"
        case .feedback: return "feedback"
        case .setParentIssue(let id): return "set-parent-\(id)"
        case .markDuplicateIssue(let id): return "mark-duplicate-\(id)"
        case .addChildIssue(let id): return "add-child-\(id)"
        case .deleteIssues(let ids): return "delete-\(ids.joined(separator: ","))"
        case .runConfirm(let id): return "run-confirm-\(id)"
        case .issueLimitUpgrade: return "issue-limit-upgrade"
        case .createWorkspace: return "create-workspace"
        case .invitations: return "invitations"
        }
    }
}

@MainActor
@Observable
final class ModalCenter {
    var current: AppModal?

    func present(_ modal: AppModal) { current = modal }
    func dismiss() { current = nil }

    /// Upstream `openCreateIssueWithPreference`: manual or agent mode,
    /// whichever the user used last.
    func createIssue(_ draft: CreateIssueDraft = CreateIssueDraft()) {
        if UserDefaults.standard.string(forKey: "multica.createIssue.mode") == "agent" {
            current = .quickCreateIssue(draft)
        } else {
            current = .createIssue(draft)
        }
    }
}

/// Renders the current app modal as a sheet.
struct ModalHost: ViewModifier {
    @Environment(ModalCenter.self) private var modals

    func body(content: Content) -> some View {
        @Bindable var modals = modals
        content.sheet(item: $modals.current) { modal in
            Group {
                switch modal {
                case .createIssue(let draft): CreateIssueSheet(draft: draft, initialMode: .manual)
                case .quickCreateIssue(let draft): CreateIssueSheet(draft: draft, initialMode: .agent)
                case .createProject: CreateProjectSheet()
                case .createSquad: CreateSquadSheet()
                case .feedback: FeedbackSheet()
                case .setParentIssue(let id): SetParentIssueSheet(issueID: id)
                case .markDuplicateIssue(let id): MarkDuplicateIssueSheet(issueID: id)
                case .addChildIssue(let id): AddChildIssueSheet(parentID: id)
                case .deleteIssues(let ids): DeleteIssueConfirmSheet(issueIDs: ids)
                case .runConfirm(let id): RunConfirmSheet(issueID: id)
                case .issueLimitUpgrade: IssueLimitUpgradeSheet()
                case .createWorkspace: CreateWorkspaceSheet()
                case .invitations: InvitationsSheet()
                }
            }
        }
    }
}

enum CreateIssueMode: String {
    case manual, agent
}
