import AppKit
import MulticaCore
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let unread = env.app.session.map { $0.inbox.unread(in: $0.workspace.id) } ?? 0
        HStack(spacing: 2) {
            Image(systemName: env.daemonStatus.state == .running ? "circle.hexagongrid.fill" : "circle.hexagongrid")
            if unread > 0 { Text("\(unread)") }
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = env.app.session {
                HStack {
                    Text(session.workspace.name).font(.headline)
                    Spacer()
                    let unread = session.inbox.unread(in: session.workspace.id)
                    Text(unread == 0 ? "Inbox clear" : "\(unread) unread").foregroundStyle(.secondary)
                }
                let running = session.issues.sections.flatMap(\.items).filter { $0.activeRuns > 0 }
                if !running.isEmpty {
                    Text("Agents working").font(.caption).foregroundStyle(.secondary)
                    ForEach(running.prefix(5)) { model in
                        HStack(spacing: 6) {
                            RunningIndicator(count: model.activeRuns)
                            Text(model.issue.identifier).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(model.issue.title).lineLimit(1)
                        }
                    }
                }
                Divider()
            }
            DaemonPanel()
            Divider()
            HStack {
                Button("Open Multica") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}
