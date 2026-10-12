import MulticaCore
import SwiftUI

struct AgentsView: View {
    let session: WorkspaceSession

    var body: some View {
        Group {
            if session.directory.agents.isEmpty {
                ContentUnavailableView("No agents", systemImage: "sparkles",
                                       description: Text("Create agents on the web; they appear here instantly."))
            } else {
                List(session.directory.agents) { agent in
                    HStack(spacing: 10) {
                        Avatar(name: agent.name, isAgent: true, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.name).font(.callout.weight(.semibold))
                            Text(agent.description.isEmpty ? agent.model : agent.description)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        AgentStatusLabel(status: agent.status)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Agents")
    }
}

struct AgentStatusLabel: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch status {
        case .working: return .green
        case .idle: return .blue
        case .blocked: return .orange
        case .error: return .red
        default: return .gray
        }
    }
}

struct RuntimesView: View {
    @Environment(AppEnvironment.self) private var env
    let session: WorkspaceSession

    var body: some View {
        List {
            Section("This Mac") {
                DaemonPanel()
            }
            Section("Runtimes in \(session.workspace.name)") {
                if session.directory.runtimes.isEmpty {
                    Text("No runtimes registered yet.").foregroundStyle(.secondary)
                }
                ForEach(session.directory.runtimes) { runtime in
                    HStack {
                        Image(systemName: runtime.runtimeMode == "cloud" ? "cloud" : "desktopcomputer")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(runtime.displayName)
                            Text("\(runtime.provider) · \(runtime.deviceInfo)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(runtime.isOnline ? "Online" : "Offline")
                            .font(.caption)
                            .foregroundStyle(runtime.isOnline ? Color.green : Color.secondary)
                    }
                }
            }
        }
        .navigationTitle("Runtimes")
    }
}

/// Local daemon control. Status comes from the adaptive `/health` poller;
/// the log is followed with a kqueue file watch only while this is visible.
struct DaemonPanel: View {
    @Environment(AppEnvironment.self) private var env
    @State private var busy = false
    @State private var showLog = false

    var body: some View {
        @Bindable var settings = env
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(stateColor).frame(width: 9, height: 9)
                Text(env.daemonStatus.state.label).font(.callout.weight(.semibold))
                if let health = env.daemonStatus.health {
                    Text([health.deviceName, health.uptime.map { "up \($0)" }, health.cliVersion.map { "CLI \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                switch env.daemonStatus.state {
                case .running, .starting:
                    Button("Restart") { run { await env.restartDaemon() } }
                    Button("Stop") { run { await env.stopDaemon() } }
                default:
                    Button("Start") { run { await env.startDaemon() } }
                        .disabled(env.daemonStatus.state == .cliNotFound)
                }
            }
            if let message = env.daemonStatus.message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let agents = env.daemonStatus.health?.agents, !agents.isEmpty {
                Text("Agent CLIs: " + agents.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Start the daemon automatically when signed in", isOn: $settings.autoStartDaemon)
                .font(.callout)
            if let daemon = env.daemon {
                Text("Profile \(daemon.profile.name) · health port \(daemon.profile.healthPort)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            DisclosureGroup("Daemon log", isExpanded: $showLog) {
                if showLog { DaemonLogView() }
            }
        }
        .padding(.vertical, 4)
    }

    private var stateColor: Color {
        switch env.daemonStatus.state {
        case .running: return .green
        case .starting, .stopping, .unknown: return .yellow
        case .stopped: return .gray
        default: return .red
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        busy = true
        Task {
            await action()
            busy = false
        }
    }
}

struct DaemonLogView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(Array(env.daemonLog.enumerated()), id: \.offset) { item in
                    Text(Redactor.shared.redact(item.element))
                        .font(.caption2.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(6)
        }
        .defaultScrollAnchor(.bottom)
        .frame(height: 220)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .onAppear { env.attachLogViewer() }
        .onDisappear { env.detachLogViewer() }
    }
}
