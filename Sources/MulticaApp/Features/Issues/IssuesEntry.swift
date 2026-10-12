import MulticaCore
import SwiftUI

// Placeholder entry points for this area; replaced by the full screens.

struct IssuesPage: View {

    var body: some View {
        EmptyStateView(icon: "hammer", title: tr("layout", "nav.issues"))
    }
}

struct IssueDetailPage: View {
    let issueID: String

    var body: some View {
        EmptyStateView(icon: "hammer", title: "IssueDetailPage")
    }
}

struct MyIssuesPage: View {

    var body: some View {
        EmptyStateView(icon: "hammer", title: tr("layout", "nav.my_issues"))
    }
}

struct CreateIssueSheet: View {
    let draft: CreateIssueDraft
    let initialMode: CreateIssueMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("CreateIssueSheet").font(Theme.Font.title)
            Button(tr("common", "cancel")) { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}

struct SetParentIssueSheet: View {
    let issueID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("SetParentIssueSheet").font(Theme.Font.title)
            Button(tr("common", "cancel")) { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}

struct MarkDuplicateIssueSheet: View {
    let issueID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("MarkDuplicateIssueSheet").font(Theme.Font.title)
            Button(tr("common", "cancel")) { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}

struct AddChildIssueSheet: View {
    let parentID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("AddChildIssueSheet").font(Theme.Font.title)
            Button(tr("common", "cancel")) { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}

struct DeleteIssueConfirmSheet: View {
    let issueIDs: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("DeleteIssueConfirmSheet").font(Theme.Font.title)
            Button(tr("common", "cancel")) { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}

struct RunConfirmSheet: View {
    let issueID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("RunConfirmSheet").font(Theme.Font.title)
            Button(tr("common", "cancel")) { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}

struct IssueLimitUpgradeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("IssueLimitUpgradeSheet").font(Theme.Font.title)
            Button(tr("common", "cancel")) { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
