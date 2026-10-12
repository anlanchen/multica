import MulticaCore
import SwiftUI

/// What a standalone issue window shows (upstream IssueWindowContext).
struct IssueWindowTarget: Codable, Hashable {
    var slug: String
    var issueID: String
}

/// A separate window holding one issue (desktop issue-window.tsx). It shares
/// the signed-in session but has its own navigation, dialogs and toasts.
struct IssueWindowRoot: View {
    @Environment(AppEnvironment.self) private var env
    let target: IssueWindowTarget
    @State private var tabs = TabStore()
    @State private var navigator: Navigator?
    @State private var modals = ModalCenter()
    @State private var toaster = Toaster()
    @State private var shell = ShellState()

    var body: some View {
        Group {
            if let session = env.app.session, session.workspace.slug == target.slug, let navigator {
                VStack(spacing: 0) {
                    if let tab = tabs.activeTab {
                        RouteHost(route: tab.route)
                            .id("\(tab.id)|\(tab.location.resourceKey)")
                    }
                }
                .navigationTitle(tabs.activeTab?.title ?? "Multica")
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button { navigator.back() } label: { Image(systemName: "chevron.left") }
                            .disabled(!navigator.canGoBack)
                        Button { navigator.forward() } label: { Image(systemName: "chevron.right") }
                            .disabled(!navigator.canGoForward)
                    }
                }
                .overlay(alignment: .bottomTrailing) { ToastOverlay() }
                .modifier(ModalHost())
                .connectionsPluginModalHost(issueID: nil)
                .connectionsPluginCatalog()
                .environment(session)
                .environment(navigator)
            } else if env.app.session == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(
                    icon: "macwindow.badge.plus",
                    title: tr("common", "not_found.title"),
                    message: "Switch the main window to this issue's workspace to open it here."
                )
            }
        }
        .environment(toaster)
        .environment(modals)
        .environment(shell)
        .environment(env.shortcuts)
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            guard navigator == nil else { return }
            tabs.switchWorkspace(target.slug, open: TabLocation(.issue(target.issueID)))
            navigator = Navigator(tabs: tabs, slug: target.slug)
        }
    }
}
