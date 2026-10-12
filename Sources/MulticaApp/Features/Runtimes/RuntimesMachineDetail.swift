import MulticaCore
import SwiftUI

/// Machine-level detail. `machineID` is a machine id, or a legacy runtime
/// id that locates its machine.
struct RuntimeDetailPage: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Navigator.self) private var nav
    let machineID: String
    @State private var tick = 0
    @State private var machines: [RuntimesMachine] = []
    @State private var computed = false
    @State private var renaming = false
    @State private var creatingProfile = false

    var body: some View {
        let store = session.runtimesStore
        let local = env.runtimesLocalContext
        let inputs = RuntimesMachineInputs(runtimes: session.runtimeRecords.items, agents: session.agentRecords.items,
                                           tasks: store.tasks, local: local, userID: session.currentUser.id, tick: tick)
        let loading = !(session.runtimeRecords.isLoaded || session.runtimeRecords.error != nil) || !computed
        let locator = machineID.removingPercentEncoding ?? machineID
        let machine = RuntimesKit.findMachine(machines, locator: locator)
        Group {
            if loading {
                RuntimesMachineSkeleton()
            } else if let machine {
                detail(machine, profiles: store.profiles.items, bootstrapping: local.bootstrapping)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 28)).foregroundStyle(Theme.destructive)
                    Text(tr("runtimes", "machine.not_found_title")).font(Theme.Font.bodyMedium)
                    Text(tr("runtimes", "machine.not_found_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    Button(tr("runtimes", "detail.all_runtimes")) { nav.push(.runtimes) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(RuntimesLiveData())
        .modifier(RuntimesNowTick(tick: $tick))
        .task(id: inputs) {
            machines = inputs.build()
            computed = true
        }
        .tabTitle(machine?.title ?? tr("runtimes", "page.title"))
    }

    @ViewBuilder
    private func detail(_ machine: RuntimesMachine, profiles: [RuntimeProfile], bootstrapping: Bool) -> some View {
        let isAdmin = session.runtimesIsAdmin
        let runtimes = machine.mode == "local"
            ? RuntimesKit.withPendingRuntimes(machine.runtimes, profiles: profiles, localDaemonID: machine.daemonID,
                                              localMachineName: machine.title, fallbackMachineName: machine.title)
            : machine.runtimes
        let canAddRuntime = isAdmin && machine.mode == "local" && !(machine.daemonID ?? "").isEmpty
        let renameTarget = renameTarget(machine, isAdmin: isAdmin)
        VStack(spacing: 0) {
            header(machine, runtimeCount: runtimes.count, isAdmin: isAdmin, canRename: renameTarget != nil)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("runtimes", "machine.metrics.runtimes")).font(Theme.Font.bodyMedium)
                            Text(tr("runtimes", "machine.select_runtime")).font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if canAddRuntime {
                            Button { creatingProfile = true } label: { Label(tr("runtimes", "profiles.add_custom"), systemImage: "plus") }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                    if runtimes.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "server.rack").font(.system(size: 22)).foregroundStyle(.tertiary)
                            Text(tr("runtimes", bootstrapping ? "page.bootstrapping.title" : "machine.no_runtimes_title"))
                                .font(Theme.Font.bodyMedium).padding(.top, 6)
                            Text(tr("runtimes", bootstrapping ? "page.bootstrapping.hint" : "machine.no_runtimes_hint"))
                                .font(Theme.Font.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                        }
                        .frame(maxWidth: .infinity, minHeight: 192)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Theme.border))
                    } else {
                        RuntimesCard {
                            RuntimesRuntimeList(runtimes: runtimes, machineTitle: machine.title,
                                                route: { .runtimeSettings(machineID: machine.id, runtimeID: $0.id) }, tick: tick)
                        }
                    }
                }
                .pageContent(maxWidth: 1180)
            }
        }
        .sheet(isPresented: $renaming) {
            if let renameTarget {
                RuntimesRenameMachineDialog(runtimeID: renameTarget.runtimeID, currentName: renameTarget.currentName)
            }
        }
        .sheet(isPresented: $creatingProfile) {
            RuntimesProfilesDialog(intent: .create(machineName: machine.title))
        }
    }

    /// Any runtime on the machine the viewer may edit; the server fans the
    /// name out across the daemon.
    private func renameTarget(_ machine: RuntimesMachine, isAdmin: Bool) -> (runtimeID: String, currentName: String)? {
        guard !machine.runtimes.isEmpty else { return nil }
        let editable = isAdmin ? machine.runtimes.first : machine.runtimes.first { $0.ownerId == session.currentUser.id }
        guard let editable else { return nil }
        return (editable.id, RuntimesKit.sharedCustomName(machine.runtimes) ?? "")
    }

    private func header(_ machine: RuntimesMachine, runtimeCount: Int, isAdmin: Bool, canRename: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Button(tr("runtimes", "page.title")) { nav.push(.runtimes) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Text("/").foregroundStyle(.tertiary)
                Text(machine.title).lineLimit(1)
            }
            .font(Theme.Font.caption)
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: machine.section == .cloud ? "cloud" : "desktopcomputer")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 12).fill(RuntimesPalette.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Text(machine.title).font(.system(size: 22, weight: .semibold)).lineLimit(2)
                        HStack(spacing: 6) {
                            RuntimesHealthIcon(health: machine.health)
                            Text(machine.health.label)
                        }
                        .font(Theme.Font.caption)
                        if machine.isCurrent { RuntimesTag(text: tr("runtimes", "machine.this_machine"), filled: true) }
                    }
                    if let subtitle = machine.subtitle {
                        Text(subtitle).font(Theme.Font.body).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 16) {
                        Text(tr("runtimes", "machine.runtime_count", ["count": runtimeCount]))
                        Text(machine.busyCount > 0
                             ? tr("runtimes", "machine.metrics.workload_hint", ["running": machine.runningCount, "queued": machine.queuedCount])
                             : tr("runtimes", "machine.metrics.workload_idle"))
                        RuntimesMachineCLISection(machine: machine, canManagePublicRuntimes: isAdmin)
                        if let seen = machine.lastSeenAt { RelativeTime(timestamp: seen) }
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    if canRename {
                        Button { renaming = true } label: { Label(tr("runtimes", "machine.rename"), systemImage: "pencil") }
                            .controlSize(.small)
                    }
                    if machine.isCurrent { RuntimesDaemonActions() }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .frame(maxWidth: 1180 + Theme.Spacing.page * 2, alignment: .leading)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Machine-wide daemon CLI version and update control.
private struct RuntimesMachineCLISection: View {
    @Environment(WorkspaceSession.self) private var session
    let machine: RuntimesMachine
    let canManagePublicRuntimes: Bool

    var body: some View {
        let updater = RuntimesKit.machineUpdateRuntime(machine, currentUserID: session.currentUser.id, canManagePublicRuntimes: canManagePublicRuntimes)
        if machine.mode != "local" {
            if let v = machine.cliVersion { Text("CLI \(v)").font(.system(size: 11, design: .monospaced)) }
        } else if updater != nil || !machine.runtimes.isEmpty || machine.cliVersion != nil || machine.launchedBy != nil {
            RuntimesUpdateSection(runtimeID: updater?.id, currentVersion: machine.cliVersion,
                                  isOnline: updater?.status == "online", launchedBy: machine.launchedBy)
        }
    }
}

private struct RuntimesMachineSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                RuntimesSkeleton(width: 144, height: 10)
                HStack(alignment: .top, spacing: 16) {
                    RuntimesSkeleton(width: 56, height: 56, radius: 12)
                    VStack(alignment: .leading, spacing: 8) {
                        RuntimesSkeleton(width: 256, height: 26)
                        RuntimesSkeleton(width: 160, height: 14)
                        RuntimesSkeleton(width: 288, height: 10)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, 16)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                RuntimesSkeleton(width: 96, height: 14)
                RuntimesSkeleton(width: 288, height: 10)
                RuntimesCard {
                    VStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { i in
                            if i > 0 { Divider() }
                            RuntimesSkeleton(height: 32).padding(12)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .padding(Theme.Spacing.page)
            Spacer()
        }
    }
}
