import MulticaCore
import SwiftUI

// Placeholder entry points for this area; replaced by the full screens.

struct IssuesPage: View {

    var body: some View {
        EmptyStateView(icon: "hammer", title: tr("layout", "nav.issues"))
    }
}

struct MyIssuesPage: View {

    var body: some View {
        EmptyStateView(icon: "hammer", title: tr("layout", "nav.my_issues"))
    }
}

/// Which issues a collection shows (upstream IssuesPage / MyIssuesPage /
/// project detail / actor issues panel all share one list surface).
enum IssueListScope: Hashable {
    case workspace
    case mine
    case project(String)
    /// Issues assigned to a member/agent/squad (member, agent, squad pages).
    case actor(type: String, id: String)
}

/// Embeddable issue list/board with its own header (filters, display).
struct IssueCollectionView: View {
    let scope: IssueListScope
    var showHeader = true

    var body: some View {
        EmptyStateView(icon: "checklist", title: tr("layout", "nav.issues"))
    }
}
