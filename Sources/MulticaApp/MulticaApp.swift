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
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            SidebarCommands()
        }

        Settings {
            SettingsView()
                .environment(env)
        }

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
                    MainView(session: session)
                        .id(session.workspace.id)
                } else {
                    ContentUnavailableView(
                        "No workspace",
                        systemImage: "square.dashed",
                        description: Text("Create a workspace on the web, then reopen Multica.")
                    )
                }
            }
        }
        .task { await env.bootstrap() }
        .onOpenURL { url in
            Task { await env.app.handleDeepLink(url) }
        }
        .onChange(of: env.app.phase) {
            // Covers sign-in through the browser deep link as well.
            if env.app.phase == .signedIn {
                Task { await env.autoStartIfNeeded() }
            }
        }
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
