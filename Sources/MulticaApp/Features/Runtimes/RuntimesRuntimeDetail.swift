import MulticaCore
import SwiftUI

/// One runtime under its machine (`/runtimes/:machine/runtime/:runtime`).
struct RuntimeSettingsPage: View {
    @Environment(WorkspaceSession.self) private var session
    let machineID: String
    let runtimeID: String

    var body: some View {
        let records = session.runtimeRecords
        let machine = machineID.removingPercentEncoding ?? machineID
        let runtime = runtimeID.removingPercentEncoding ?? runtimeID
        Group {
            if !(records.isLoaded || records.error != nil) {
                VStack(alignment: .leading, spacing: 16) {
                    RuntimesSkeleton(width: 360, height: 48)
                    HStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in RuntimesSkeleton(height: 80, radius: 8) }
                    }
                    RuntimesSkeleton(height: 192, radius: 8)
                    Spacer()
                }
                .padding(Theme.Spacing.page)
            } else if let target = RuntimesKit.resolveSettingsTarget(records.items, machineID: machine, runtimeID: runtime) {
                RuntimesRuntimeDetailView(runtime: target.runtime, machineID: machine, machineLabel: target.machine.title,
                                          afterDelete: target.machine.runtimes.count > 1 ? .runtime(machine) : .runtimes)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "server.rack").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(tr("runtimes", "detail_page.not_found_title")).font(Theme.Font.body).padding(.top, 6)
                    Text(tr("runtimes", "detail_page.not_found_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(RuntimesLiveData())
    }
}

struct RuntimesRuntimeDetailView: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let runtime: RuntimeDeviceRecord
    let machineID: String
    let machineLabel: String
    let afterDelete: AppRoute
    @State private var tick = 0
    @State private var deleting = false
    @State private var width: CGFloat = 1200

    var body: some View {
        let userID = session.currentUser.id
        let isAdmin = session.runtimesIsAdmin
        let isOwner = runtime.ownerId == userID
        let canEdit = isAdmin || isOwner
        let profile = runtime.profileId.flatMap { id in session.runtimesStore.profiles.items.first { $0.id == id } }
        let isCustom = !(runtime.profileId ?? "").isEmpty
        let canDelete = isCustom ? isAdmin && profile != nil : canEdit
        let name = RuntimesKit.runtimeRowLabel(runtime, machineTitle: machineLabel)
        VStack(spacing: 0) {
            PageHeader {
                HStack(spacing: 6) {
                    Button(tr("runtimes", "page.title")) { nav.push(.runtimes) }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    Button(machineLabel) { nav.push(.runtime(machineID)) }.buttonStyle(.plain).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    Text(name).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                }
                .font(Theme.Font.body)
            } trailing: {
                if !canEdit {
                    Label(tr("runtimes", "detail.read_only"), systemImage: "lock")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                let wide = width >= 1000
                let rail = VStack(spacing: 16) {
                    RuntimesServingAgentsCard(runtime: runtime, tick: tick)
                    RuntimesDiagnosticsCard(runtime: runtime, canEditVisibility: isOwner, canDelete: canDelete) { deleting = true }
                }
                let main = VStack(alignment: .leading, spacing: 20) {
                    RuntimesHeroCard(runtime: runtime, name: name, tick: tick)
                    if RuntimesKit.isUsable(runtime, by: userID) { RuntimesUsageSection(runtime: runtime) }
                }
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: 16) {
                            main.frame(maxWidth: .infinity, alignment: .topLeading)
                            rail.frame(width: 320)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            main
                            rail
                        }
                    }
                }
                .padding(Theme.Spacing.page)
                .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { width = g.size.width } })
            }
        }
        .modifier(RuntimesNowTick(tick: $tick))
        .tabTitle(RuntimesKit.displayLabel(runtime))
        .sheet(isPresented: $deleting) {
            if isCustom, let profile {
                RuntimesDeleteProfileDialog(profile: profile) {
                    deleting = false
                    nav.replace(afterDelete)
                }
            } else {
                RuntimesDeleteRuntimeDialog(runtime: runtime) {
                    deleting = false
                    nav.replace(afterDelete)
                    toaster.success(tr("runtimes", "detail.toast_deleted"))
                }
            }
        }
    }
}

private struct RuntimesHeroCard: View {
    @Environment(WorkspaceSession.self) private var session
    let runtime: RuntimeDeviceRecord
    let name: String
    let tick: Int
    @State private var showDetails = false

    var body: some View {
        let health = RuntimesHealth.of(runtime, now: Date())
        let owner = runtime.ownerId.flatMap { id in session.memberRecords.items.first { $0.userId == id } }
        let device = runtime.deviceInfo.isEmpty ? nil : RuntimesKit.parseDeviceInfo(runtime.deviceInfo)
        let cliVersion = RuntimesKit.cliVersion(runtime)
        let daemonShort = RuntimesKit.compactDaemonID(runtime.daemonId)
        let lastSeen = runtime.lastSeenAt.map(Formatters.relative) ?? tr("runtimes", "detail.never_seen")
        RuntimesCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    RuntimesProviderLogo(provider: runtime.provider, size: 20)
                        .frame(width: 36, height: 36)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                    HStack(spacing: 12) {
                        Text(name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        RuntimesHealthBadge(health: health)
                        Text(tr("runtimes", "detail.last_seen", ["when": lastSeen])).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
                .padding(16)
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    fact(tr("runtimes", "detail.fact_owner")) {
                        if let owner {
                            HStack(spacing: 6) {
                                ActorAvatar(type: "member", id: owner.userId, size: 18)
                                Text(owner.name).font(Theme.Font.body).lineLimit(1)
                            }
                        } else {
                            Text("—").font(Theme.Font.body).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    fact(tr("runtimes", "detail.fact_device")) {
                        if let host = device?.hostname, !host.isEmpty {
                            Text(host).font(.system(size: 11, design: .monospaced)).lineLimit(1).help(host)
                        } else {
                            Text("—").font(Theme.Font.body).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    fact(tr("runtimes", "detail.fact_runtime")) {
                        Text(device?.runtime ?? runtime.provider.capitalized).font(Theme.Font.body).lineLimit(1)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if cliVersion != nil || daemonShort != nil {
                    Divider()
                    Button { withAnimation(.easeOut(duration: 0.15)) { showDetails.toggle() } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(showDetails ? 90 : 0))
                            Text(tr("runtimes", "detail.technical_details"))
                        }
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showDetails {
                        Divider()
                        HStack(alignment: .top, spacing: 24) {
                            if let cliVersion { compactFact(tr("runtimes", "detail.fact_daemon_cli"), cliVersion) }
                            if let daemonShort { compactFact(tr("runtimes", "detail.fact_daemon_id"), daemonShort) }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.primary.opacity(0.025))
                    }
                }
            }
        }
    }

    private func fact<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 10)).tracking(0.6).foregroundStyle(.secondary)
            value()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 10)).tracking(0.6).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
        }
    }
}

/// Agents bound to this runtime with their presence (availability from
/// runtime reachability, workload from the task snapshot).
private struct RuntimesServingAgentsCard: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let runtime: RuntimeDeviceRecord
    let tick: Int

    var body: some View {
        let agents = session.agentRecords.items.filter { $0.runtimeId == runtime.id && $0.archivedAt == nil }
        let tasks = session.runtimesStore.tasks
        RuntimesCard {
            VStack(spacing: 0) {
                HStack {
                    Text(tr("runtimes", "detail.serving_title")).font(Theme.Font.caption.weight(.semibold))
                    Spacer()
                    Text(tr("runtimes", "detail.serving_count", ["count": agents.count])).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                if agents.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "cpu").foregroundStyle(.tertiary)
                        Text(tr("runtimes", "detail.no_agents")).font(Theme.Font.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 24)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(agents) { agent in
                        RuntimesServingAgentRow(agent: agent, presence: RuntimesPresence(runtime: runtime, tasks: tasks.filter { $0.agentID == agent.id })) {
                            nav.push(.agent(agent.id), title: agent.name)
                        }
                        if agent.id != agents.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

/// Upstream `deriveAgentPresenceDetail` for one runtime.
struct RuntimesPresence: Equatable {
    enum Availability: String { case online, unstable, offline }
    enum Workload: String { case working, queued, idle }

    var availability: Availability
    var workload: Workload
    var running: Int
    var queued: Int

    init(runtime: RuntimeDeviceRecord?, tasks: [AgentTask]) {
        switch runtime.map({ RuntimesHealth.of($0, now: Date()) }) {
        case .online: availability = .online
        case .recentlyLost: availability = .unstable
        default: availability = .offline
        }
        running = tasks.filter { $0.status == .running }.count
        queued = tasks.filter { $0.status == .queued || $0.status == .dispatched || $0.status == .waitingLocalDirectory }.count
        workload = running > 0 ? .working : queued > 0 ? .queued : .idle
    }

    var availabilityColor: Color {
        switch availability {
        case .online: return Theme.success
        case .unstable: return Theme.warning
        case .offline: return .secondary
        }
    }

    var workloadColor: Color {
        switch workload {
        case .working: return Theme.brand
        case .queued: return Theme.warning
        case .idle: return .secondary
        }
    }
}

private struct RuntimesServingAgentRow: View {
    let agent: AgentRecord
    let presence: RuntimesPresence
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                ActorAvatar(type: "agent", id: agent.id, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(Theme.Font.caption.weight(.medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Circle().fill(presence.availability == .offline ? Color.secondary.opacity(0.4) : presence.availabilityColor).frame(width: 6, height: 6)
                            Text(tr("agents", "availability.\(presence.availability.rawValue)")).foregroundStyle(presence.availabilityColor)
                        }
                        if presence.workload != .idle {
                            HStack(spacing: 4) {
                                Text("·").foregroundStyle(.secondary)
                                if presence.workload == .working {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "clock").font(.system(size: 9))
                                }
                                Text(tr("agents", "workload.\(presence.workload.rawValue)"))
                                if presence.running > 0 { Text(tr("runtimes", "detail.running_chip", ["count": presence.running])).foregroundStyle(.secondary) }
                                if presence.queued > 0 { Text(tr("runtimes", "detail.queued_chip", ["count": presence.queued])).foregroundStyle(.secondary) }
                            }
                            .foregroundStyle(presence.workloadColor)
                        }
                    }
                    .font(Theme.Font.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(hovering ? .secondary : .tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(hovering ? Theme.hover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RuntimesDiagnosticsCard: View {
    let runtime: RuntimeDeviceRecord
    let canEditVisibility: Bool
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        RuntimesCard {
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("runtimes", "detail.diagnostics_title")).font(Theme.Font.caption.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("runtimes", "detail.diagnostics_visibility").uppercased())
                            .font(.system(size: 10)).tracking(0.5).foregroundStyle(.secondary)
                        if canEditVisibility {
                            RuntimesVisibilityEditor(runtime: runtime)
                        } else {
                            let visibility = runtime.visibility == "public" ? "public" : "private"
                            Label(tr("runtimes", "detail.visibility_label.\(visibility)"), systemImage: visibility == "public" ? "globe" : "lock")
                                .font(Theme.Font.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                                .help(tr("runtimes", "detail.visibility_hint_readonly.\(visibility)"))
                        }
                    }
                    if canDelete {
                        Divider()
                        Button(role: .destructive, action: onDelete) {
                            Label(tr("runtimes", "detail.delete_button"), systemImage: "trash")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.destructive)
                    }
                }
                .padding(16)
            }
        }
    }
}

/// Owner-only public/private switch (the server refuses admins here).
private struct RuntimesVisibilityEditor: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let runtime: RuntimeDeviceRecord
    @State private var pending = false

    var body: some View {
        let current = runtime.visibility == "public" ? "public" : "private"
        HStack(spacing: 2) {
            choice("private", icon: "lock", active: current == "private")
            choice("public", icon: "globe", active: current == "public")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(RuntimesPalette.muted))
    }

    private func choice(_ value: String, icon: String, active: Bool) -> some View {
        Button { Task { await flip(to: value, current: active) } } label: {
            Label(tr("runtimes", "detail.visibility_label.\(value)"), systemImage: icon)
                .font(Theme.Font.caption.weight(.medium))
                .foregroundStyle(active ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(active ? Color(nsColor: .controlBackgroundColor) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pending)
        .opacity(pending ? 0.6 : 1)
        .help(tr("runtimes", "detail.visibility_hint.\(value)"))
    }

    private func flip(to next: String, current: Bool) async {
        guard !current else { return }
        pending = true
        defer { pending = false }
        do {
            let updated = try await session.api.updateRuntime(runtime.id, visibility: next)
            session.runtimeRecords.upsert(updated)
            toaster.success(tr("runtimes", "detail.visibility_toast_updated", ["visibility": tr("runtimes", "detail.visibility_label.\(next)")]))
        } catch {
            let message = (error as? APIError)?.message ?? ""
            toaster.error(message.isEmpty ? tr("runtimes", "detail.visibility_toast_failed") : message)
        }
        await session.runtimeRecords.load()
    }
}
