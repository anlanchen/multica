import MulticaCore
import SwiftUI

/// Lifecycle controls for this Mac's daemon, shown in the local machine's
/// header (upstream desktop `DaemonRuntimeActions`).
struct RuntimesDaemonActions: View {
    var body: some View {
        RuntimesDaemonControls(compact: false)
    }
}

struct RuntimesDaemonControls: View {
    @Environment(AppEnvironment.self) private var env
    let compact: Bool
    @State private var loading = false
    @State private var confirmStop = false
    @State private var affected = 0

    var body: some View {
        let status = env.daemonStatus
        let state = status.state
        HStack(spacing: 6) {
            if compact { Spacer(minLength: 0) }
            if state == .running {
                Button { RuntimesDaemonLogWindow.show(env) } label: { Label(tr("settings", "desktop.daemon.view_logs"), systemImage: "scroll") }
                    .buttonStyle(.borderless)
                if status.externallyManaged {
                    Label(tr("settings", "desktop.daemon.managed_externally"), systemImage: "info.circle")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button { Task { await restart() } } label: { Label(tr("settings", "desktop.daemon.restart"), systemImage: "arrow.clockwise") }
                        .disabled(loading)
                    Button(role: .destructive) { stopTapped() } label: { Label(tr("settings", "desktop.daemon.stop"), systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.destructive)
                        .disabled(loading)
                }
            }
            if state.canStart {
                Button { Task { await start() } } label: {
                    Label(tr("settings", "desktop.daemon.start"), systemImage: loading ? "waveform.path.ecg" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading)
            }
            if state == .cliNotFound {
                Button {
                    Task {
                        loading = true
                        await env.runtimesRetryInstall()
                        loading = false
                    }
                } label: { Label(tr("settings", "desktop.daemon.retry_setup"), systemImage: "arrow.clockwise") }
                    .disabled(loading)
            }
            if state == .authExpired {
                Label(tr("settings", "desktop.daemon.signin_expired"), systemImage: "exclamationmark.circle")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.destructive)
                Button {
                    Task {
                        loading = true
                        await env.runtimesReauthenticateDaemon()
                        loading = false
                    }
                } label: { Label(tr("settings", "desktop.daemon.signin_again"), systemImage: loading ? "waveform.path.ecg" : "person.badge.key") }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading)
            }
            if state.isTransitioning {
                Button {} label: { Label(state.label, systemImage: "waveform.path.ecg") }
                    .disabled(true)
            }
        }
        .controlSize(.small)
        .onChange(of: state) { loading = false }
        .alert(tr("settings", "desktop.daemon.stop_confirm_title", ["count": affected]), isPresented: $confirmStop) {
            Button(tr("settings", "desktop.daemon.cancel"), role: .cancel) {}
            Button(tr("settings", "desktop.daemon.stop_daemon"), role: .destructive) { Task { await stop() } }
        } message: {
            Text(tr("settings", "desktop.daemon.stop_confirm_description", ["count": affected]))
        }
    }

    /// Running or dispatched runs on this Mac's runtimes.
    private func affectedTasks() -> Int {
        guard let id = env.daemonStatus.health?.daemonID, let session = env.app.session else { return 0 }
        let local = Set(session.runtimeRecords.items.filter { $0.daemonId == id }.map(\.id))
        let store = session.runtimesStore
        return store.tasks.filter { local.contains($0.runtimeID) && ($0.status == .running || $0.status == .dispatched) }.count
    }

    private func stopTapped() {
        Task {
            if let session = env.app.session { await session.runtimesStore.loadTasksIfNeeded() }
            affected = affectedTasks()
            if affected == 0 {
                await stop()
            } else {
                confirmStop = true
            }
        }
    }

    private func start() async {
        loading = true
        let result = await env.runtimesStartDaemon()
        if !result.success {
            loading = false
            env.toaster.error(tr("settings", "desktop.daemon.start_failed") + (result.error.map { " — \($0)" } ?? ""))
        }
    }

    private func stop() async {
        loading = true
        let result = await env.runtimesStopDaemon()
        loading = false
        if !result.success {
            env.toaster.error(tr("settings", "desktop.daemon.stop_failed") + (result.error.map { " — \($0)" } ?? ""))
        }
    }

    private func restart() async {
        loading = true
        env.toaster.success(tr("settings", "desktop.daemon.restarting") + " — " + tr("settings", "desktop.daemon.restarting_description"))
        let result = await env.runtimesRestartDaemon()
        loading = false
        if !result.success {
            env.toaster.error(tr("settings", "desktop.daemon.restart_failed") + (result.error.map { " — \($0)" } ?? ""))
        }
    }
}
