import MulticaCore
import SwiftUI

/// Settings › Messaging › DingTalk: robot installations plus the groups each
/// bot has been observed in (upstream dingtalk-tab.tsx `DingTalkTab`).
struct ConnectionsDingTalkDetail: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let model: ConnectionsChannelsModel
    @State private var groups: ConnectionsLoad<ListDingTalkGroupsResponse> = .pending
    @State private var confirm: ConnectionsConfirm?

    private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
        tr("settings", "dingtalk.\(key)", args)
    }

    private var canManage: Bool { session.connectionsIsManager }

    /// Older servers returned every installation to members; join against
    /// the agents this viewer can see so no row dead-links.
    private func displayed(_ all: [DingTalkInstallation]) -> [DingTalkInstallation] {
        guard !canManage else { return all }
        let visible = Set(session.agentRecords.items.map(\.id))
        return all.filter { $0.agentAvailable != false && visible.contains($0.agentId) }
    }

    var body: some View {
        let listing = model.dingtalk.value
        let installations = displayed(listing?.installations ?? [])
        let hasActive = installations.contains { $0.status == "active" }
        VStack(alignment: .leading, spacing: 32) {
            if case .failed = model.dingtalk {
                notEnabled
            } else if let listing, !listing.configured {
                notEnabled
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text(t("connections_title")).font(.system(size: 13, weight: .semibold))
                    if listing == nil || (!canManage && !session.agentRecords.isLoaded) {
                        ConnectionsCard { Text(t("loading")).font(Theme.Font.body).foregroundStyle(.secondary).padding(16) }
                    } else if installations.isEmpty {
                        ConnectionsMessageCard(title: t("empty_title"), messageView: AnyView(
                            (Text(t("empty_description_prefix")) + Text(" ") + Text(t("empty_description_cta")).fontWeight(.semibold)
                             + Text(" ") + Text(t("empty_description_suffix")))
                                .font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)))
                    } else {
                        ConnectionsCard {
                            ForEach(installations, id: \.id) { inst in
                                if inst.id != installations.first?.id { Divider() }
                                installationRow(inst)
                            }
                        }
                    }
                }
            }
        }
        .task { if !canManage { await session.agentRecords.loadIfNeeded() } }
        .task(id: "\(listing?.configured == true)|\(hasActive)|\(session.revision("dingtalk_installation"))") {
            guard listing?.configured == true, hasActive else { return }
            await loadGroups()
        }
        .connectionsConfirm($confirm)
    }

    private var notEnabled: some View {
        ConnectionsMessageCard(title: t("not_enabled_title"), messageView: AnyView(
            (Text(t("not_enabled_description_prefix")) + Text(" ") + connectionsCode("MULTICA_DINGTALK_SECRET_KEY") + Text(" ")
             + Text(t("not_enabled_description_suffix")) + Text(" ") + Text(t("not_enabled_self_host_hint")))
                .font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)))
    }

    private func loadGroups() async {
        do {
            groups = .loaded(try await session.api.listDingTalkGroups(workspaceId: session.workspace.id))
        } catch {
            if groups.value == nil { groups = .failed }
        }
    }

    private func installationRow(_ inst: DingTalkInstallation) -> some View {
        let active = inst.status == "active"
        let agentAvailable = inst.agentAvailable != false
        let groupsData = groups.value
        let supported = groupsData?.groupDiscoverySupported == true
        let groupsLoading: Bool = { if case .pending = groups { return true }; return false }()
        let groupsFailed: Bool = { if case .failed = groups { return true }; return false }()
        let showDiscovery = supported || groupsLoading || groupsFailed
        let identity = groupsData?.botIdentities?[inst.id]
            ?? ConnectionsChannels.dingTalkBotIdentity(groups: groupsData?.groups ?? [], installationID: inst.id)
        let installed = ConnectionsChannels.installedAt(inst.installedAt).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                HStack(alignment: .top, spacing: 12) {
                    ConnectionsAgentIdentity(agentID: inst.agentId, available: agentAvailable)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(agentAvailable ? session.actorInfo(type: "agent", id: inst.agentId).name : t("deleted_agent"))
                                .font(.system(size: 14, weight: .medium)).lineLimit(1)
                            if !active { ConnectionsChip(text: t("revoked_badge")) }
                        }
                        HStack(spacing: 8) {
                            if active {
                                ConnectionsDingTalkConnectionLabel(
                                    botName: identity?.botName ?? "", issue: identity?.botIdentityIssue ?? "",
                                    linkedIDs: canManage ? (inst.boundDingtalkUserIds ?? []) : [],
                                    showIdentity: supported && !groupsLoading, showPermissionHelp: canManage)
                                Text("·").font(Theme.Font.micro).foregroundStyle(.secondary)
                            }
                            Text(t("installed_at_label", ["when": installed])).font(Theme.Font.micro).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                if canManage && active {
                    Button { askDisconnect(inst.id) } label: { Label(t("disconnect"), systemImage: "trash") }
                        .controlSize(.small)
                }
            }
            if active && showDiscovery {
                ConnectionsDingTalkGroups(installationID: inst.id, groups: groupsData?.groups ?? [],
                                          inactiveCount: groupsData?.inactiveGroupCounts?[inst.id] ?? 0,
                                          canForget: canManage, loading: groupsLoading, failed: groupsFailed,
                                          onRetry: { Task { await loadGroups() } },
                                          onForgot: { Task { await loadGroups() } })
                    .padding(.top, 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
    }

    private func askDisconnect(_ id: String) {
        confirm = ConnectionsConfirm(title: t("disconnect_confirm_title"), message: t("disconnect_confirm_description"),
                                     cancel: t("disconnect_confirm_cancel"), confirm: t("disconnect"), pending: t("disconnecting")) {
            do {
                try await session.api.deleteDingTalkInstallation(workspaceId: session.workspace.id, installationId: id)
                await model.load(.dingtalk, session)
                toaster.success(t("toast_disconnected"))
                return true
            } catch {
                toaster.error((error as? APIError)?.message ?? t("toast_disconnect_failed"))
                return false
            }
        }
    }
}

/// "Connected bot: <name>" with the linked staff IDs on hover and a
/// permission hint when the bot lacks `qyapi_chat_manage`.
private struct ConnectionsDingTalkConnectionLabel: View {
    let botName: String
    let issue: String
    let linkedIDs: [String]
    let showIdentity: Bool
    let showPermissionHelp: Bool
    @State private var permissionOpen = false

    private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
        tr("settings", "dingtalk.\(key)", args)
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.success).frame(width: 6, height: 6)
            Text(t("agent_bot_connected_label"))
            if showIdentity {
                Text(botName.isEmpty ? t("bot_identity_unavailable") : botName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .help(linkedIDs.isEmpty ? "" : t("identity_label", ["identity": linkedIDs.joined(separator: ", ")]))
                if issue == "missing_qyapi_chat_manage" && showPermissionHelp {
                    Button { permissionOpen = true } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("\(t("bot_permission_tooltip_prefix")) qyapi_chat_manage \(t("bot_permission_tooltip_suffix"))")
                        .popover(isPresented: $permissionOpen, arrowEdge: .top) {
                            (Text(t("bot_permission_tooltip_prefix")) + Text(" ")
                             + Text("qyapi_chat_manage").font(.system(size: 10, design: .monospaced)) + Text(" ")
                             + Text(t("bot_permission_tooltip_suffix")))
                                .font(Theme.Font.caption)
                                .frame(width: 300, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(12)
                        }
                }
            }
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
    }
}

/// Groups a DingTalk bot was observed in, active first, with the long
/// inactive tail paged in on demand (upstream `DingTalkBotGroups`).
private struct ConnectionsDingTalkGroups: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let installationID: String
    let groups: [DingTalkGroup]
    let inactiveCount: Int
    let canForget: Bool
    let loading: Bool
    let failed: Bool
    let onRetry: () -> Void
    let onForgot: () -> Void

    @State private var inactiveExpanded = false
    @State private var inactive: [DingTalkGroup] = []
    @State private var inactiveNext: Int? = 0
    @State private var inactiveLoading = false
    @State private var inactiveFailed = false
    @State private var confirm: ConnectionsConfirm?

    private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
        tr("settings", "dingtalk.\(key)", args)
    }

    var body: some View {
        let observed = ConnectionsChannels.observedGroups(groups, installationID: installationID)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(t("groups_title")).font(Theme.Font.bodyMedium)
                if !loading && !failed {
                    Text(t("groups_count", ["count": observed.count]))
                        .font(Theme.Font.micro).monospacedDigit().foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
            if loading {
                Text(t("groups_loading")).font(Theme.Font.caption).foregroundStyle(.secondary)
            } else if failed {
                HStack {
                    Text(t("groups_error")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(t("groups_retry"), action: onRetry).buttonStyle(.link).font(Theme.Font.caption)
                }
            } else if observed.isEmpty {
                Text(t(inactiveCount > 0 ? "groups_no_recent" : "groups_empty")).font(Theme.Font.caption).foregroundStyle(.secondary)
            } else {
                groupList(observed)
            }
            if !loading && !failed && inactiveCount > 0 {
                Divider()
                Button {
                    inactiveExpanded.toggle()
                    if inactiveExpanded && inactive.isEmpty { Task { await loadInactive() } }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: inactiveExpanded ? "chevron.down" : "chevron.right").font(.system(size: 10))
                        Text(t("groups_inactive", ["count": inactiveCount]))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if inactiveExpanded {
                    if inactiveLoading && inactive.isEmpty {
                        Text(t("groups_loading")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    } else if inactiveFailed && inactive.isEmpty {
                        Button(t("groups_retry")) { Task { await loadInactive() } }.buttonStyle(.link).font(Theme.Font.caption)
                    } else {
                        groupList(ConnectionsChannels.observedGroups(inactive, installationID: installationID))
                        if inactiveNext != nil {
                            Button(inactiveLoading ? t("groups_loading") : t("groups_load_more")) { Task { await loadInactive() } }
                                .buttonStyle(.borderless)
                                .disabled(inactiveLoading)
                        }
                    }
                }
            }
        }
        .connectionsConfirm($confirm)
    }

    private func groupList(_ entries: [(group: DingTalkGroup, bot: DingTalkGroupBot)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries, id: \.group.conversationId) { entry in
                Divider()
                ConnectionsDingTalkGroupItem(group: entry.group, bot: entry.bot, canForget: canForget) { askForget(entry.group) }
            }
        }
    }

    private func loadInactive() async {
        guard let offset = inactiveNext, !inactiveLoading else { return }
        inactiveLoading = true
        defer { inactiveLoading = false }
        do {
            let page = try await session.api.listDingTalkGroups(
                workspaceId: session.workspace.id,
                ListDingTalkGroupsParams(activity: "inactive", installationId: installationID, offset: offset))
            inactive += page.groups
            inactiveNext = page.nextOffset
            inactiveFailed = false
        } catch {
            inactiveFailed = true
        }
    }

    private func askForget(_ group: DingTalkGroup) {
        confirm = ConnectionsConfirm(title: t("group_forget_title"), message: t("group_forget_description"),
                                     cancel: t("group_forget_cancel"), confirm: t("group_forget_confirm")) {
            do {
                try await session.api.forgetDingTalkGroup(workspaceId: session.workspace.id, installationId: installationID,
                                                          conversationId: group.conversationId)
                inactive.removeAll { $0.conversationId == group.conversationId }
                onForgot()
                toaster.success(t("group_forget_success"))
                return true
            } catch {
                toaster.error((error as? APIError)?.message ?? t("group_forget_failed"))
                return false
            }
        }
    }
}

private struct ConnectionsDingTalkGroupItem: View {
    let group: DingTalkGroup
    let bot: DingTalkGroupBot
    let canForget: Bool
    let onForget: () -> Void
    @State private var hovering = false

    private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
        tr("settings", "dingtalk.\(key)", args)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(group.conversationTitle.isEmpty ? t("group_untitled") : group.conversationTitle)
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if canForget {
                        Button(t("group_forget"), action: onForget)
                            .buttonStyle(.link)
                            .font(Theme.Font.micro)
                            .foregroundStyle(.secondary)
                            .opacity(hovering ? 1 : 0)
                    }
                }
                Spacer(minLength: 8)
                Text(group.conversationId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(hovering ? .secondary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(t("conversation_id_label"))
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            if let last = bot.lastActiveAt {
                Text("\(t("group_last_active", ["time": Formatters.relative(last)]))  ·  \(t("group_mentions", ["count": bot.mentionCount ?? 0]))")
                    .font(Theme.Font.micro).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
