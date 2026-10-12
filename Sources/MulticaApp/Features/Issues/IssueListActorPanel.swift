import MulticaCore
import SwiftUI

/// Issues assigned to or created by a member / agent / squad (upstream
/// common/actor-issues-panel.tsx): list-only, server search, two tabs.
struct IssueListActorPanel: View {
    let actorType: String
    let actorID: String
    var showHeader = true

    @Environment(WorkspaceSession.self) private var session
    @State private var relation: String?

    var body: some View {
        let current = relation ?? IssueListPrefs.actorScope(workspaceID: session.workspace.id)
        IssueListSurfaceView(
            session: session,
            scope: .actor(type: actorType, id: actorID, relation: current),
            view: nil,
            modes: [.list],
            header: IssueListHeaderConfig(views: nil, builtins: [], activeBuiltin: nil, selectBuiltin: { _ in },
                                          saveScope: nil, showViewToggle: false, showWorkingChip: false),
            showHeader: showHeader,
            empty: .actor(current),
            batchAlways: true,
            actorHeader: IssueListActorHeader(scope: current) { next in
                relation = next
                IssueListPrefs.setActorScope(next, workspaceID: session.workspace.id)
            }
        )
        .id("\(session.workspace.id)|actor:\(actorType):\(actorID):\(current)")
    }
}

struct IssueListActorHeaderBar: View {
    @Bindable var model: IssueListSurfaceModel
    let header: IssueListActorHeader

    var body: some View {
        HStack(spacing: 12) {
            SearchField(text: $model.search, prompt: tr("issues", "actor_issues.search_placeholder"))
                .frame(width: 256)
            HStack(spacing: 4) {
                ForEach(["assigned", "created"], id: \.self) { value in
                    Button(tr("issues", "actor_issues.scope.\(value).label")) { header.onScopeChange(value) }
                        .buttonStyle(IssueListToolbarButtonStyle(active: header.scope == value))
                        .help(tr("issues", "actor_issues.scope.\(value).description"))
                }
            }
            Spacer()
            IssueListDisplayControls(model: model, showViewToggle: false)
            IssueListRefreshIndicator(active: model.isRefreshing)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .overlay(alignment: .bottom) { Divider() }
        .padding(.bottom, 8)
    }
}
