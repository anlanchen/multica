import AppKit
import Combine
import MulticaCore
import SwiftUI

@main
struct MulticaApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        Window("Multica", id: "main") {
            RootView()
                .environment(env)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unifiedCompact)
        .commands { AppCommands(env: env) }

        WindowGroup("Issue", id: "issue", for: IssueWindowTarget.self) { $target in
            if let target {
                IssueWindowRoot(target: target)
                    .environment(env)
            }
        }
        .defaultSize(width: 980, height: 760)

        MenuBarExtra {
            MenuBarContent()
                .environment(env)
        } label: {
            MenuBarLabel()
                .environment(env)
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            switch env.app.phase {
            case .launching:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                LoginView()
            case .signedIn:
                if let session = env.app.session {
                    AppShell(session: session)
                        .id(session.workspace.id)
                } else {
                    // Zero workspaces: onboarding / create / accept invite
                    // (upstream WindowOverlay).
                    OnboardingFlow()
                }
            }
        }
        .id(env.languageRevision)
        .environment(env.toaster)
        .environment(env.modals)
        .environment(env.shell)
        .environment(env.shortcuts)
        .preferredColorScheme(env.appearance == "dark" ? .dark : env.appearance == "light" ? .light : nil)
        .task { await env.bootstrap() }
        .onOpenURL { url in
            Task { await env.handleOpenURL(url) }
        }
        .onChange(of: env.app.phase) {
            if env.app.phase == .signedIn {
                Task {
                    await env.autoStartIfNeeded()
                    await env.loadAccountExtras()
                }
            }
        }
        .onChange(of: env.app.session?.workspace.id) { env.sessionDidChange() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            env.setAppActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            env.setAppActive(false)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            // A sleeping Mac silently loses its socket; reconnect on wake
            // instead of waiting for the liveness timeout.
            Task { await env.app.session?.realtime.reconnectNow() }
        }
    }
}

/// The signed-in window: sidebar, tab bar, active tab, global overlays.
struct AppShell: View {
    @Environment(AppEnvironment.self) private var env
    let session: WorkspaceSession

    var body: some View {
        @Bindable var shell = env.shell
        let tabs = env.tabs
        NavigationSplitView(columnVisibility: $shell.sidebarVisibility) {
            AppSidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 244, max: 360)
        } detail: {
            VStack(spacing: 0) {
                TabBar()
                if let tab = tabs.activeTab {
                    RouteHost(route: tab.route)
                        .id("\(tab.id)|\(tab.location.resourceKey)|\(tabs.mountGeneration)")
                }
            }
            .background(Theme.canvas)
        }
        .navigationTitle(tabs.activeTab?.title ?? "Multica")
        .overlay(alignment: .bottomTrailing) {
            if shell.chatOpen {
                FloatingChatPanel()
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ChatUIFab().padding(16)
            }
        }
        .overlay(alignment: .bottomTrailing) { ToastOverlay() }
        .modifier(ModalHost())
        .connectionsPluginModalHost(issueID: nil)
        .connectionsPluginCatalog()
        .modifier(OnboardingShellOverlays())
        .sheet(isPresented: $shell.searchOpen) {
            SearchCommandPalette()
        }
        .animation(.snappy, value: shell.chatOpen)
        .environment(session)
        .environment(env.navigator)
        .onReceive(NotificationCenter.default.publisher(for: .multicaOpenInNewTab)) { note in
            if let path = note.object as? String, let loc = TabLocation(relativeURL: path) {
                tabs.openTab(loc, activate: true)
            }
        }
        .onChange(of: session.revision("invitation")) {
            Task { await env.reloadInvitations() }
        }
        .onChange(of: session.inbox.lastArrived?.id) {
            guard let item = session.inbox.lastArrived else { return }
            let slug = env.app.workspaces.first { $0.id == item.workspaceID }?.slug
            env.notifications.announce(item, slug: slug, api: session.api)
        }
        .onChange(of: session.inbox.totalUnread, initial: true) {
            env.notifications.setBadge(session.inbox.totalUnread)
        }
    }
}

/// Menu-bar commands: tabs, navigation, settings (desktop keyboard-shortcuts.ts).
struct AppCommands: Commands {
    let env: AppEnvironment

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Multica") { AboutPanel.show() }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { env.navigator.push(.settings) }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(env.app.session == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { env.tabs.addTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(env.app.session == nil)
            Button("New Issue") { env.modals.createIssue(env.contextualDraft()) }
                .disabled(env.app.session == nil)
            Divider()
            Button("Close Tab") { env.tabs.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(env.app.session == nil)
        }
        CommandMenu("Go") {
            Button("Back") { env.navigator.back() }
            Button("Forward") { env.navigator.forward() }
            Divider()
            ForEach(WorkspacePage.allCases, id: \.self) { page in
                Button(page.title) { env.navigator.push(page.route) }
            }
            Divider()
            Button("Search…") { env.shell.searchOpen = true }
            Button("Toggle Chat") { env.shell.chatOpen.toggle() }
        }
        CommandMenu("Tabs") {
            Button("Show Next Tab") { env.tabs.selectAdjacentTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { env.tabs.selectAdjacentTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Reload Tab") { env.tabs.reloadActiveTab() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            ForEach(1..<10) { n in
                Button("Select Tab \(n)") { env.tabs.selectTab(at: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") { env.shell.toggleSidebar() }
        }
    }
}

/// Standard About panel carrying the Multica name, logo and copyright, as
/// the Multica License (Part I, 1.b) requires of derived user interfaces.
enum AboutPanel {
    static let copyright = "Copyright © 2025-2026 Index Labs (Hong Kong) Limited"

    static func show() {
        let credits = NSMutableAttributedString(
            string: "Multica — native macOS client.\nBased on Multica (https://github.com/multica-ai/multica), distributed under the Multica License. See LICENSE and NOTICE in the application bundle.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Multica",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): copyright,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
