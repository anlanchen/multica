import MulticaCore
import SwiftUI

private struct RuntimesRowData: Identifiable, Equatable {
    var runtime: RuntimeDeviceRecord
    var profile: RuntimeProfile?
    var owner: MemberWithUserRecord?
    var workload: RuntimesWorkload
    var canDelete: Bool
    var id: String { runtime.id }
    var isPending: Bool { RuntimesKit.isPending(runtime) }
}

private struct RuntimesListInputs: Equatable {
    var runtimes: [RuntimeDeviceRecord]
    var agents: [AgentRecord]
    var tasks: [AgentTask]
    var members: [MemberWithUserRecord]
    var profiles: [RuntimeProfile]
    var isAdmin: Bool
    var userID: String
}

/// A machine's runtimes (upstream `RuntimeList`). Only a handful of rows,
/// so no sorting, filtering or virtualization — like upstream.
struct RuntimesRuntimeList: View {
    @Environment(WorkspaceSession.self) private var session
    let runtimes: [RuntimeDeviceRecord]
    var machineTitle: String? = nil
    /// Settings route for a row; nil rows (pending profiles) are not navigable.
    var route: ((RuntimeDeviceRecord) -> AppRoute)? = nil
    var tick: Int = 0
    @State private var rows: [RuntimesRowData] = []
    @State private var width: CGFloat = 900

    var body: some View {
        let store = session.runtimesStore
        let inputs = RuntimesListInputs(runtimes: runtimes, agents: session.agentRecords.items, tasks: store.tasks,
                                        members: session.memberRecords.items, profiles: store.profiles.items,
                                        isAdmin: session.runtimesIsAdmin, userID: session.currentUser.id)
        let showOwner = Set(runtimes.compactMap(\.ownerId)).count > 1
        let showActions = rows.contains(where: \.canDelete)
        let wide = width >= 672
        VStack(spacing: 0) {
            RuntimesListHeader(wide: wide, showOwner: showOwner, showActions: showActions)
            Divider()
            ForEach(rows) { row in
                RuntimesRuntimeRow(row: row, machineTitle: machineTitle, route: row.isPending ? nil : route?(row.runtime) ?? .runtime(row.runtime.id),
                                   wide: wide, showOwner: showOwner, showActions: showActions, tick: tick)
                if row.id != rows.last?.id { Divider() }
            }
        }
        .background(GeometryReader { g in Color.clear.preference(key: RuntimesWidthKey.self, value: g.size.width) })
        .onPreferenceChange(RuntimesWidthKey.self) { width = $0 }
        .task(id: inputs) { rows = Self.buildRows(inputs) }
    }

    private static func buildRows(_ i: RuntimesListInputs) -> [RuntimesRowData] {
        let workload = RuntimesKit.workloadIndex(agents: i.agents, tasks: i.tasks)
        let members = Dictionary(i.members.map { ($0.userId, $0) }, uniquingKeysWith: { a, _ in a })
        let profiles = Dictionary(i.profiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return i.runtimes.map { r in
            let profile = r.profileId.flatMap { profiles[$0] }
            let isCustom = !(r.profileId ?? "").isEmpty
            let canDelete = isCustom
                ? i.isAdmin && profile != nil
                : !RuntimesKit.isPending(r) && (i.isAdmin || r.ownerId == i.userID)
            return RuntimesRowData(runtime: r, profile: profile, owner: r.ownerId.flatMap { members[$0] },
                                   workload: workload[r.id] ?? RuntimesWorkload(), canDelete: canDelete)
        }
    }
}

private struct RuntimesWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 900
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private enum RuntimesColumns {
    static let health: CGFloat = 176
    static let owner: CGFloat = 96
    static let agents: CGFloat = 92
    static let cost: CGFloat = 96
    static let cli: CGFloat = 112
    static let kebab: CGFloat = 28
}

private struct RuntimesListHeader: View {
    let wide: Bool
    let showOwner: Bool
    let showActions: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(tr("runtimes", "list.col_runtime")).frame(maxWidth: .infinity, alignment: .leading)
            Text(tr("runtimes", "list.col_health")).frame(width: RuntimesColumns.health, alignment: .leading)
            if wide {
                if showOwner { Text(tr("runtimes", "list.col_owner")).frame(width: RuntimesColumns.owner, alignment: .leading) }
                Text(tr("runtimes", "list.col_agents")).frame(width: RuntimesColumns.agents, alignment: .leading)
                Text(tr("runtimes", "list.col_cost")).frame(width: RuntimesColumns.cost, alignment: .trailing)
                Text(tr("runtimes", "list.col_cli")).frame(width: RuntimesColumns.cli, alignment: .leading)
            }
            if showActions { Color.clear.frame(width: RuntimesColumns.kebab, height: 1) }
        }
        .font(Theme.Font.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 32)
    }
}

private struct RuntimesRuntimeRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let row: RuntimesRowData
    let machineTitle: String?
    let route: AppRoute?
    let wide: Bool
    let showOwner: Bool
    let showActions: Bool
    let tick: Int
    @State private var hovering = false
    @State private var deleting = false
    @State private var editing = false

    private var runtime: RuntimeDeviceRecord { row.runtime }
    private var isCustom: Bool { !(runtime.profileId ?? "").isEmpty }

    var body: some View {
        HStack(spacing: 12) {
            nameCell.frame(maxWidth: .infinity, alignment: .leading)
            RuntimesHealthCell(runtime: runtime, workload: row.workload, tick: tick)
                .frame(width: RuntimesColumns.health, alignment: .leading)
            if wide {
                if showOwner {
                    Group {
                        if let owner = row.owner {
                            HStack(spacing: 6) {
                                ActorAvatar(type: "member", id: owner.userId, size: 18)
                                Text(owner.name).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } else {
                            Text("—").font(Theme.Font.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: RuntimesColumns.owner, alignment: .leading)
                }
                RuntimesAgentStack(agentIDs: row.workload.agentIDs).frame(width: RuntimesColumns.agents, alignment: .leading)
                Group {
                    if row.isPending {
                        Text("—").font(Theme.Font.caption).foregroundStyle(.tertiary)
                    } else {
                        RuntimesCostCell(runtimeID: runtime.id, enabled: RuntimesKit.isUsable(runtime, by: session.currentUser.id))
                    }
                }
                .frame(width: RuntimesColumns.cost, alignment: .trailing)
                RuntimesCLICell(runtime: runtime).frame(width: RuntimesColumns.cli, alignment: .leading)
            }
            if showActions {
                Group {
                    if row.canDelete {
                        Menu { menuItems } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .frame(width: 24, height: 24)
                            .opacity(hovering ? 1 : 0)
                            .help(tr("runtimes", "list.row_actions_aria"))
                    }
                }
                .frame(width: RuntimesColumns.kebab)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .background(hovering && route != nil ? Theme.hover : .clear)
        .onHover { hovering = $0 }
        .onTapGesture {
            if let route { nav.push(route, title: machineTitle.map { RuntimesKit.runtimeRowLabel(runtime, machineTitle: $0) } ?? RuntimesKit.displayName(runtime)) }
        }
        .contextMenu { if row.canDelete || route != nil { menuItems } }
        .sheet(isPresented: $deleting) {
            if isCustom, let profile = row.profile {
                RuntimesDeleteProfileDialog(profile: profile) { deleting = false }
            } else {
                RuntimesDeleteRuntimeDialog(runtime: runtime) {
                    deleting = false
                    toaster.success(tr("runtimes", "detail.toast_deleted"))
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let profile = row.profile { RuntimesProfilesDialog(intent: .edit(profile)) }
        }
    }

    @ViewBuilder private var menuItems: some View {
        if let route {
            Button { nav.openInNewTab(route) } label: { Label(tr("common", "navigation.open_in_new_tab"), systemImage: "arrow.up.forward.square") }
            if row.canDelete { Divider() }
        }
        if row.canDelete {
            if isCustom && row.profile != nil {
                Button { editing = true } label: { Label(tr("runtimes", "list.edit_action"), systemImage: "pencil") }
            }
            Button(role: .destructive) { deleting = true } label: {
                Label(tr("runtimes", isCustom ? "list.delete_profile_action" : "list.delete_action"), systemImage: "trash")
            }
            .help(tr("runtimes", "list.delete_permission_hint"))
        }
    }

    private var nameCell: some View {
        HStack(spacing: 8) {
            RuntimesProviderLogo(provider: runtime.provider, size: 20).frame(width: 32, height: 32)
            HStack(spacing: 6) {
                Text(RuntimesKit.runtimeRowLabel(runtime, machineTitle: machineTitle ?? ""))
                    .font(Theme.Font.bodyMedium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                RuntimesTag(text: tr("runtimes", isCustom ? "list.badge_custom" : "list.badge_builtin"), color: isCustom ? Theme.info : .secondary)
                if RuntimesKit.isPending(runtime) {
                    if RuntimesKit.isDisabledPending(runtime) {
                        RuntimesTag(text: tr("runtimes", "list.badge_disabled"))
                    } else {
                        RuntimesTag(text: tr("runtimes", "list.badge_registering"), color: Theme.warning)
                    }
                }
                if runtime.visibility == "public" {
                    RuntimesTag(text: tr("runtimes", "detail.visibility_label.public"), color: Theme.info, icon: "globe")
                        .help(tr("runtimes", "detail.visibility_hint.public"))
                }
            }
        }
    }
}

/// Health with the active-run count folded in (`Online · 2 runs`), or the
/// registration state of a pending custom runtime.
struct RuntimesHealthCell: View {
    let runtime: RuntimeDeviceRecord
    let workload: RuntimesWorkload
    let tick: Int

    var body: some View {
        if RuntimesKit.isDisabledPending(runtime) {
            Text(tr("runtimes", "list.pending_health_disabled")).font(Theme.Font.caption).foregroundStyle(.secondary)
        } else if let failure = RuntimesKit.registrationFailure(runtime) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.destructive)
                Text(tr("runtimes", "list.pending_health_error")).foregroundStyle(Theme.destructive).lineLimit(1)
            }
            .font(Theme.Font.caption)
            .help(failure)
        } else if RuntimesKit.isPending(runtime) {
            let warning = RuntimesKit.isPendingWarning(runtime, now: Date())
            HStack(spacing: 6) {
                if warning {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(tr("runtimes", warning ? "list.pending_health_warning" : "list.pending_health")).lineLimit(1)
            }
            .font(Theme.Font.caption)
        } else {
            let health = RuntimesHealth.of(runtime, now: Date())
            HStack(spacing: 6) {
                RuntimesHealthIcon(health: health)
                (Text(health.label)
                 + Text(suffix(health)).foregroundStyle(.secondary))
                    .lineLimit(1)
            }
            .font(Theme.Font.caption)
        }
    }

    private func suffix(_ health: RuntimesHealth) -> String {
        var s = ""
        if health != .online, let seen = runtime.lastSeenAt { s += " · " + Formatters.relative(seen) }
        if !health.isOfflineLike, workload.activeCount > 0 {
            s += " · " + tr("agents", "row.task_count", ["count": workload.activeCount])
        }
        return s
    }
}

/// Seven-day cost with the delta against the prior seven days; reads a
/// 14-day window so the list does not pull the detail page's 180 days.
struct RuntimesCostCell: View {
    @Environment(WorkspaceSession.self) private var session
    let runtimeID: String
    let enabled: Bool
    @State private var summary: (cost: Double, delta: Int?)?

    var body: some View {
        let query = session.runtimesStore.usage(runtimeID: runtimeID, days: 14, timeZone: TimeZone.current.identifier)
        let pricer = RuntimesCustomPricing.shared.pricer
        Group {
            if let summary {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(RuntimesFormat.usd(summary.cost)).font(Theme.Font.bodyMedium).monospacedDigit()
                    if let delta = summary.delta {
                        Text(delta == 0 ? tr("runtimes", "list.cost_delta_flat") : "\(delta > 0 ? "↑" : "↓")\(abs(delta))%")
                            .font(Theme.Font.micro.monospacedDigit())
                            .foregroundStyle(delta > 0 ? Theme.warning : delta < 0 ? Theme.success : .secondary)
                    }
                }
            } else {
                Text("—").font(Theme.Font.caption).foregroundStyle(.tertiary)
            }
        }
        .task(id: enabled) { if enabled { await query.load() } }
        .task(id: RuntimesCostKey(rows: query.value, pricings: RuntimesCustomPricing.shared.pricings)) {
            guard let rows = query.value, !rows.isEmpty else {
                summary = nil
                return
            }
            let today = RuntimesCalendar.today(in: .current)
            let current = RuntimesUsageMath.costInWindow(rows, days: 7, today: today, pricer: pricer)
            let previous = RuntimesUsageMath.costInWindow(rows, days: 7, today: today, offset: 7, pricer: pricer)
            summary = (current, RuntimesFormat.pctChange(current, previous))
        }
    }
}

private struct RuntimesCostKey: Equatable {
    var rows: [RuntimeUsage]?
    var pricings: [String: RuntimesModelPrice]
}

/// The agent CLI's own version (not the shared daemon CLI version).
struct RuntimesCLICell: View {
    let runtime: RuntimeDeviceRecord

    var body: some View {
        if let failure = RuntimesKit.registrationFailure(runtime) {
            VStack(alignment: .leading, spacing: 0) {
                if let command = RuntimesKit.pendingCommandName(runtime) {
                    Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).help(command)
                }
                Text(failure).font(Theme.Font.caption).foregroundStyle(Theme.destructive).lineLimit(1).help(failure)
            }
        } else if RuntimesKit.isPending(runtime) {
            if let command = RuntimesKit.pendingCommandName(runtime) {
                Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).help(command)
            } else {
                Text(tr("runtimes", "list.pending_cli_unknown")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        } else if runtime.runtimeMode == "cloud" {
            Text("—").font(Theme.Font.caption).foregroundStyle(.tertiary)
        } else if let version = RuntimesKit.metadataString(runtime, "version"), !version.isEmpty {
            Text(version).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).help(version)
        } else {
            Text("—").font(Theme.Font.caption).foregroundStyle(.tertiary)
        }
    }
}

/// Up to three agent avatars, then `+N`.
struct RuntimesAgentStack: View {
    let agentIDs: [String]

    var body: some View {
        if agentIDs.isEmpty {
            Text("—").font(Theme.Font.caption).foregroundStyle(.tertiary)
        } else {
            HStack(spacing: -6) {
                ForEach(agentIDs.prefix(3), id: \.self) { id in
                    ActorAvatar(type: "agent", id: id, size: 22)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.canvas, lineWidth: 2))
                }
                if agentIDs.count > 3 {
                    Text("+\(agentIDs.count - 3)")
                        .font(Theme.Font.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(RuntimesPalette.muted))
                        .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: 2))
                }
            }
        }
    }
}
