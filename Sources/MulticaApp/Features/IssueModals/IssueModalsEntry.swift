import MulticaCore
import SwiftUI

// Entry points rendered by ModalHost (upstream packages/views/modals/registry.tsx).

struct CreateIssueSheet: View {
    let draft: CreateIssueDraft
    let initialMode: CreateIssueMode

    var body: some View {
        IssueModalCreateDialog(seed: draft, initialMode: initialMode)
    }
}

struct SetParentIssueSheet: View {
    let issueID: String

    var body: some View {
        IssueModalSetParentDialog(issueID: issueID)
    }
}

struct MarkDuplicateIssueSheet: View {
    let issueID: String

    var body: some View {
        IssueModalMarkDuplicateDialog(issueID: issueID)
    }
}

struct AddChildIssueSheet: View {
    let parentID: String

    var body: some View {
        IssueModalAddChildDialog(parentID: parentID)
    }
}

struct DeleteIssueConfirmSheet: View {
    let issueIDs: [String]

    var body: some View {
        IssueModalDeleteConfirm(issueIDs: issueIDs)
    }
}

struct RunConfirmSheet: View {
    let issueID: String

    var body: some View {
        IssueModalRunConfirm(issueID: issueID)
    }
}

struct IssueLimitUpgradeSheet: View {
    var reason: IssueModalLimitReason? = nil
    @State private var pendingReason = IssueModalPending.takeLimitReason()

    var body: some View {
        IssueModalLimitUpgrade(reason: reason ?? pendingReason ?? .issueLimit)
    }
}
