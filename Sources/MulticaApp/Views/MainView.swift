import MulticaCore
import SwiftUI

enum SidebarItem: Hashable {
    case inbox, myIssues, issues, agents, runtimes
}

struct IssueRoute: Hashable {
    let id: String
}

struct MainView: View {
    @Environment(AppEnvironment.self) private var env
    let session: WorkspaceSession
    @State private var selection: SidebarItem? = .issues
    @State private var path: [IssueRoute] = []

    var body: some View {
        NavigationSplitView {
            SidebarView(session: session, selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            NavigationStack(path: $path) {
                content
                    .navigationDestination(for: IssueRoute.self) { route in
                        IssueDetailView(session: session, issueID: route.id)
                    }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = session.lastError {
                ErrorBanner(message: error) { session.dismissError() }
            }
        }
        .onChange(of: selection) { path = [] }
    }

    @ViewBuilder private var content: some View {
        switch selection ?? .issues {
        case .inbox:
            InboxView(session: session, path: $path)
        case .myIssues:
            IssuesView(session: session, scope: .mine)
        case .issues:
            IssuesView(session: session, scope: .all)
        case .agents:
            AgentsView(session: session)
        case .runtimes:
            RuntimesView(session: session)
        }
    }
}

struct SidebarView: View {
    @Environment(AppEnvironment.self) private var env
    let session: WorkspaceSession
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section {
                WorkspaceSwitcher(session: session)
            }
            Section("Workspace") {
                SwiftUI.Label("Inbox", systemImage: "tray")
                    .badge(session.inbox.unread(in: session.workspace.id))
                    .tag(SidebarItem.inbox)
                SwiftUI.Label("My Issues", systemImage: "person.crop.circle")
                    .tag(SidebarItem.myIssues)
                SwiftUI.Label("Issues", systemImage: "square.stack.3d.up")
                    .tag(SidebarItem.issues)
            }
            Section("Agents") {
                SwiftUI.Label("Agents", systemImage: "sparkles")
                    .tag(SidebarItem.agents)
                SwiftUI.Label("Runtimes", systemImage: "desktopcomputer")
                    .badge(env.daemonStatus.state == .running ? Text("●") : nil)
                    .tag(SidebarItem.runtimes)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ConnectionFooter(state: session.connection)
        }
    }
}

struct WorkspaceSwitcher: View {
    @Environment(AppEnvironment.self) private var env
    let session: WorkspaceSession

    var body: some View {
        Menu {
            ForEach(env.app.workspaces) { ws in
                Button {
                    Task { await env.app.select(ws) }
                } label: {
                    if ws.id == session.workspace.id {
                        SwiftUI.Label(ws.name, systemImage: "checkmark")
                    } else {
                        let unread = session.inbox.unread(in: ws.id)
                        Text(unread > 0 ? "\(ws.name)  •" : ws.name)
                    }
                }
            }
            Divider()
            Button("Sign Out") { Task { await env.app.signOut() } }
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 22, height: 22)
                    .overlay(Text(String(session.workspace.name.prefix(1))).font(.caption.bold()).foregroundStyle(.white))
                Text(session.workspace.name).font(.headline).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
    }
}

struct ConnectionFooter: View {
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .orange
        case .stopped: return .gray
        }
    }

    private var label: String {
        switch state {
        case .connected: return "Live"
        case .connecting: return "Connecting…"
        case .disconnected(let retry): return "Reconnecting in \(Int(retry.rounded()))s"
        case .stopped: return "Offline"
        }
    }
}
