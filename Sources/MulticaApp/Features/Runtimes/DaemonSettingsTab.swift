import MulticaCore
import SwiftUI

/// The desktop "Daemon" settings tab: start/stop preferences, CLI status
/// and diagnostics for this Mac's daemon.
struct DaemonSettingsTab: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage(RuntimesDaemonPrefs.autoStopKey) private var autoStop = false
    @State private var cliInstalled: Bool?
    @State private var reauthLoading = false

    var body: some View {
        @Bindable var settings = env
        let status = env.daemonStatus
        let external = status.externallyManaged
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(tr("settings", "desktop.daemon.title")).font(Theme.Font.pageTitle)
                if status.state == .authExpired {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.destructive)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("settings", "desktop.daemon.signin_expired")).font(Theme.Font.bodyMedium).foregroundStyle(Theme.destructive)
                            Text(tr("settings", "desktop.daemon.signin_expired_description")).font(Theme.Font.body).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task {
                                reauthLoading = true
                                await env.runtimesReauthenticateDaemon()
                                reauthLoading = false
                            }
                        } label: { Label(tr("settings", "desktop.daemon.signin_again"), systemImage: "person.badge.key") }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(reauthLoading)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.destructive.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.destructive.opacity(0.4)))
                }
                if external {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        (Text(tr("settings", "desktop.daemon.external_description_before") + " ")
                         + Text("multica daemon start").font(.system(size: 11, design: .monospaced))
                         + Text(" / ")
                         + Text("multica daemon stop").font(.system(size: 11, design: .monospaced))
                         + Text(tr("settings", "desktop.daemon.external_description_after")))
                            .font(Theme.Font.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                }
                card {
                    row(tr("settings", "desktop.daemon.auto_start_title"), tr("settings", "desktop.daemon.auto_start_description")) {
                        Toggle("", isOn: Binding(get: { settings.autoStartDaemon }, set: {
                            settings.autoStartDaemon = $0
                            saved()
                        }))
                        .toggleStyle(.switch).labelsHidden().disabled(external)
                    }
                    Divider()
                    row(tr("settings", "desktop.daemon.auto_stop_title"), tr("settings", "desktop.daemon.auto_stop_description")) {
                        Toggle("", isOn: Binding(get: { autoStop }, set: {
                            autoStop = $0
                            saved()
                        }))
                        .toggleStyle(.switch).labelsHidden().disabled(external)
                    }
                    Divider()
                    row(tr("settings", "desktop.daemon.cli_status"),
                        cliInstalled == nil ? tr("settings", "desktop.daemon.cli_checking")
                            : cliInstalled == true ? tr("settings", "desktop.daemon.cli_installed") : tr("settings", "desktop.daemon.cli_missing")) {
                        if cliInstalled == false {
                            Link(tr("settings", "desktop.daemon.installation_guide"), destination: URL(string: "https://github.com/multica-ai/multica#cli-installation")!)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("settings", "desktop.daemon.diagnostics_title")).font(Theme.Font.title)
                    card {
                        VStack(spacing: 0) {
                            diagnostic(tr("settings", "desktop.daemon.state")) {
                                HStack(spacing: 6) {
                                    RuntimesDaemonStateDot(state: status.state)
                                    Text(status.state.label)
                                }
                            }
                            diagnostic(tr("settings", "desktop.daemon.uptime"), status.health?.uptime.map(RuntimesFormat.uptime) ?? "—")
                            diagnostic("PID", status.health?.pid.map(String.init) ?? "—", mono: status.health?.pid != nil)
                            diagnostic(tr("settings", "desktop.daemon.daemon_id"), status.health?.daemonID ?? "—", mono: status.health?.daemonID != nil)
                            diagnostic(tr("settings", "desktop.daemon.profile"), env.daemon?.profile.name ?? "default")
                            diagnostic(tr("settings", "desktop.daemon.server_url"), status.health?.serverURL ?? "—", mono: status.health?.serverURL != nil)
                            diagnostic(tr("settings", "desktop.daemon.device_name"), status.health?.deviceName ?? "—")
                            diagnostic(tr("settings", "desktop.daemon.workspaces"), status.state == .running ? String(status.health?.workspaceCount ?? 0) : "—")
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(Theme.Spacing.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: status.state) { cliInstalled = await env.daemon?.isCLIInstalled }
    }

    private func saved() {
        env.toaster.success(tr("settings", "desktop.daemon.settings_saved"))
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.025)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }

    private func row<C: View>(_ label: String, _ description: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.Font.bodyMedium)
                Text(description).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func diagnostic(_ label: String, _ value: String, mono: Bool = false) -> some View {
        diagnostic(label) {
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : Theme.Font.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
                .textSelection(.enabled)
        }
    }

    private func diagnostic<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(Theme.Font.caption).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}
