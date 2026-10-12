import AppKit
import MulticaCore
import SwiftUI

/// The Chat tab (upstream ChatPage): thread list on the left, conversation on
/// the right; compact widths toggle between them. Selection is mirrored to
/// `?session=` both ways; `?agent=` starts a fresh chat with that agent once.
struct ChatPage: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster
    @State private var composingNew = false
    @State private var consumedAgentIntent: String?
    @State private var appActive = NSApp.isActive
    @State private var width: CGFloat = 1000

    private var isCompact: Bool { width < 640 }

    var body: some View {
        let store = session.chatUI
        GeometryReader { g in
            Group {
                if g.size.width < 640 {
                    compact(store)
                } else {
                    HSplitView {
                        VStack(spacing: 0) {
                            listHeader(store)
                            list
                        }
                        .frame(minWidth: 240, idealWidth: 260, maxWidth: 480, maxHeight: .infinity)
                        detail(store)
                            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .onAppear { width = g.size.width }
            .onChange(of: g.size.width) { _, w in width = w }
        }
        .onAppear {
            store.toast = { [toaster] message, isError in isError ? toaster.error(message) : toaster.success(message) }
            store.attachSurface()
            store.setAppActive(NSApp.isActive)
            store.setActiveSession(nav.query("session"))
            if store.activeSessionID != nil { composingNew = false }
            env.activeChatSessionID = store.activeSessionID
            consumeAgentIntent()
        }
        .onDisappear {
            store.detachSurface()
            if env.activeChatSessionID == store.activeSessionID { env.activeChatSessionID = nil }
        }
        .onChange(of: nav.query("session")) { _, url in
            if url != store.activeSessionID { store.setActiveSession(url) }
        }
        .onChange(of: store.activeSessionID) { _, id in
            if nav.query("session") != id { nav.setQuery("session", id) }
            if id != nil { composingNew = false }
            env.activeChatSessionID = id
        }
        .onChange(of: nav.query("agent")) { consumeAgentIntent() }
        .onChange(of: store.context.availableAgents) { consumeAgentIntent() }
        .onChange(of: store.context.agentsSettled) { consumeAgentIntent() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appActive = true
            store.setAppActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appActive = false
            store.setAppActive(false)
        }
        .task(id: readKey(store)) {
            // Deferred a tick so a session that is only momentarily active
            // (restored, then cleared by the URL) is never marked read.
            guard appActive, let id = store.activeSessionID, session.chatSessions.item(id)?.hasUnread == true else { return }
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, store.activeSessionID == id else { return }
            store.markRead(id)
        }
    }

    private func readKey(_ store: ChatUIStore) -> String {
        let id = store.activeSessionID ?? ""
        return "\(id)|\(session.chatSessions.item(id)?.hasUnread == true)|\(appActive)"
    }

    private var list: some View {
        ChatUIThreadList(onSelect: select, onArchive: archive)
            .frame(maxHeight: .infinity)
    }

    private func listHeader(_ store: ChatUIStore) -> some View {
        PageHeader {
            Text(tr("chat", "page.title")).font(Theme.Font.bodyMedium)
        } trailing: {
            ChatUINewChatButton(agents: store.context.availableAgents, onStart: startNewChat)
        }
    }

    @ViewBuilder
    private func detail(_ store: ChatUIStore) -> some View {
        if store.activeSessionID != nil || composingNew {
            conversation(store)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "message").font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
                Text(tr("chat", "page.select_prompt")).font(Theme.Font.body).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func conversation(_ store: ChatUIStore) -> some View {
        VStack(spacing: 0) {
            if let current = store.context.currentSession {
                ChatUISessionHeader(chat: current, agent: store.agentsByID[current.agentId], onArchive: archive)
            }
            ChatUIConversationBody(surface: .page, onProjectChange: changeProject)
        }
    }

    @ViewBuilder
    private func compact(_ store: ChatUIStore) -> some View {
        if store.activeSessionID != nil || composingNew {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        store.setActiveSession(nil)
                        composingNew = false
                    } label: {
                        Label(tr("chat", "page.title"), systemImage: "chevron.left").font(Theme.Font.body)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 44)
                .overlay(alignment: .bottom) { Divider() }
                conversation(store)
            }
        } else {
            VStack(spacing: 0) {
                listHeader(store)
                list
            }
        }
    }

    // MARK: Actions

    /// Any explicit user action supersedes a still-pending `?agent=` intent.
    private func supersedeAgentIntent() {
        if let agent = nav.query("agent") { consumedAgentIntent = agent }
    }

    private func select(_ s: ChatSession) {
        supersedeAgentIntent()
        session.chatUI.selectSession(s)
        composingNew = false
    }

    /// Archiving the chat in view advances to the next one; compact widths
    /// drop back to the list instead.
    private func archive(_ s: ChatSession) {
        let store = session.chatUI
        supersedeAgentIntent()
        if s.id == store.activeSessionID {
            if isCompact {
                store.setActiveSession(nil)
                composingNew = false
            } else {
                store.advanceSelectionAfterArchive(s.id)
            }
        }
        store.setArchived(s.id, true)
    }

    private func startNewChat(_ agent: AgentRecord?) {
        supersedeAgentIntent()
        if let agent { session.chatUI.startNewChat(agentID: agent.id) } else { session.chatUI.newChat() }
        composingNew = true
    }

    /// Choosing a project for an existing chat starts a clean session; the
    /// pane stays on the compose box.
    private func changeProject(_ projectID: String?) {
        let store = session.chatUI
        guard projectID != store.context.activeProjectID else { return }
        let hadSession = store.context.currentSession != nil
        store.changeProject(projectID)
        if !hadSession || projectID != nil { composingNew = true }
    }

    /// `?agent=<id>` deep link: consumed once the permission-filtered agent
    /// list resolves; a settled miss explains itself and is dropped.
    private func consumeAgentIntent() {
        guard let wanted = nav.query("agent") else {
            consumedAgentIntent = nil
            return
        }
        guard consumedAgentIntent != wanted else { return }
        let store = session.chatUI
        if let agent = store.context.availableAgents.first(where: { $0.id == wanted }) {
            consumedAgentIntent = wanted
            startNewChat(agent)
            nav.setQuery("agent", nil)
        } else if store.context.agentsSettled {
            consumedAgentIntent = wanted
            toaster.error(tr("chat", "page.agent_link_no_access"))
            nav.setQuery("agent", nil)
        }
    }
}

/// The floating chat overlay shown bottom-right while `shell.chatOpen`
/// (upstream FloatingChat + ChatWindow). Hidden on the Chat tab, which owns
/// the same conversation, and when the floating window is turned off.
struct FloatingChatPanel: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(ShellState.self) private var shell
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster
    @State private var appActive = NSApp.isActive

    var body: some View {
        let store = session.chatUI
        let suppressed = nav.route == .chat || !store.floatingEnabled
        GeometryReader { g in
            ZStack(alignment: .bottomTrailing) {
                Color.clear.allowsHitTesting(false)
                if !suppressed {
                    ChatUIFloatingWindow(container: g.size)
                        .transition(.scale(scale: 0.95, anchor: .bottomTrailing).combined(with: .opacity))
                        .onAppear { attach(store) }
                        .onDisappear { detach(store) }
                }
            }
        }
        .onAppear {
            // ⌘J on the Chat tab is a no-op there, like upstream's gated
            // shortcut, rather than a window that pops up on navigation.
            if nav.route == .chat || !store.floatingEnabled { shell.chatOpen = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appActive = true
            store.setAppActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appActive = false
            store.setAppActive(false)
        }
        .onChange(of: store.activeSessionID) { _, id in
            if !suppressed { env.activeChatSessionID = id }
        }
        .task(id: "\(store.activeSessionID ?? "")|\(store.activeSessionID.flatMap { session.chatSessions.item($0)?.hasUnread } == true)|\(appActive)|\(suppressed)") {
            guard !suppressed, appActive, let id = store.activeSessionID, session.chatSessions.item(id)?.hasUnread == true else { return }
            store.markRead(id)
        }
    }

    private func attach(_ store: ChatUIStore) {
        store.toast = { [toaster] message, isError in isError ? toaster.error(message) : toaster.success(message) }
        store.attachSurface()
        store.setAppActive(NSApp.isActive)
        store.retainAggregate()
        store.setOpenPreference(true)
        env.activeChatSessionID = store.activeSessionID
    }

    private func detach(_ store: ChatUIStore) {
        store.detachSurface()
        store.releaseAggregate()
        if env.activeChatSessionID == store.activeSessionID && nav.route != .chat { env.activeChatSessionID = nil }
    }
}
