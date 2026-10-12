import AppKit
import MulticaCore
import SwiftUI

/// Detail views (upstream agent-overview-pane DetailTab).
enum AgentsUIDetailView: String, CaseIterable {
    case overview, work
    case instructions, skills, mcpConfig = "mcp_config", composioMcp = "composio_mcp", integrations
    case general, access, env, customArgs = "custom_args", runtimeConfig = "runtime_config"

    enum Section: String, CaseIterable { case overview, work, capabilities, settings }

    static let capabilities: [AgentsUIDetailView] = [.instructions, .skills, .mcpConfig, .composioMcp, .integrations]
    static let settings: [AgentsUIDetailView] = [.general, .access, .env, .customArgs, .runtimeConfig]

    var section: Section {
        switch self {
        case .overview: return .overview
        case .work: return .work
        default: return Self.capabilities.contains(self) ? .capabilities : .settings
        }
    }

    var label: String {
        switch self {
        case .env: return tr("agents", "tabs.environment")
        default: return tr("agents", "tabs.\(rawValue)")
        }
    }
}

struct AgentsUIDetailPage: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let agentID: String

    @State private var fetched: AgentRecord?
    @State private var fetchStatus: Int?
    @State private var fetchMessage: String?
    @State private var fetching = false

    var body: some View {
        Group {
            if let agent = resolvedAgent {
                AgentsUIDetailContent(agent: agent)
            } else if !session.agentRecords.isLoaded || fetching {
                AgentsUIDetailSkeleton()
            } else if fetchStatus == 403 {
                failure(icon: "lock", tint: .secondary, title: tr("agents", "detail.no_access_title"), message: tr("agents", "detail.no_access_hint"), retry: false)
            } else {
                failure(icon: "exclamationmark.circle", tint: Theme.destructive,
                        title: fetchStatus == 404 ? tr("agents", "detail.not_found_title") : tr("agents", "detail.load_failed_title"),
                        message: fetchStatus == 404 ? tr("agents", "detail.not_found_default")
                            : (fetchMessage ?? session.agentRecords.error ?? tr("agents", "detail.load_failed_default")),
                        retry: true)
            }
        }
        .task(id: agentID) { await resolve() }
        .task(id: session.agentsUISyncKey) { session.agentsUISync() }
    }

    private var resolvedAgent: AgentRecord? {
        if let a = session.agentRecords.item(agentID) { return a }
        if fetchStatus == 403 || fetchStatus == 404 { return nil }
        return fetched
    }

    private func resolve() async {
        async let a: Void = session.agentRecords.loadIfNeeded()
        async let r: Void = session.runtimeRecords.loadIfNeeded()
        async let p: Void = session.agentsUIStore.loadProjectionsIfNeeded()
        _ = await (a, r, p)
        guard session.agentRecords.item(agentID) == nil else { return }
        fetching = true
        defer { fetching = false }
        do {
            let a = try await session.api.getAgent(agentID)
            fetched = a
            fetchStatus = nil
            session.agentRecords.upsert(a)
        } catch {
            fetchStatus = (error as? APIError)?.status
            fetchMessage = (error as? APIError)?.message ?? error.localizedDescription
        }
    }

    private func failure(icon: String, tint: Color, title: String, message: String, retry: Bool) -> some View {
        VStack(spacing: 0) {
            PageHeader {
                Button { nav.push(.agents) } label: { Label(tr("agents", "detail.back_to_agents"), systemImage: "arrow.left") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 28)).foregroundStyle(tint)
                VStack(spacing: 4) {
                    Text(title).font(Theme.Font.bodyMedium)
                    Text(message).font(Theme.Font.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                HStack(spacing: 8) {
                    if retry {
                        Button(tr("agents", "detail.try_again")) {
                            Task {
                                await session.agentRecords.load()
                                await resolve()
                            }
                        }
                    }
                    Button(tr("agents", "detail.back_to_agents_full")) { nav.push(.agents) }.buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AgentsUIDetailSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)).frame(width: 192, height: 12)
            HStack(alignment: .top, spacing: 16) {
                Circle().fill(Color.primary.opacity(0.07)).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)).frame(width: 256, height: 22)
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.05)).frame(maxWidth: 520).frame(height: 12)
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.05)).frame(maxWidth: 440).frame(height: 12)
                }
            }
            Spacer()
        }
        .padding(Theme.Spacing.page)
    }
}

/// The loaded detail page: header, banners, the four-section workbench.
struct AgentsUIDetailContent: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster
    @Environment(ModalCenter.self) private var modals
    let agent: AgentRecord

    @State private var activeDirty = false
    @State private var pendingView: AgentsUIDetailView?
    @State private var confirmArchive = false
    @State private var integrationsConfigured = false

    private var userID: String { session.currentUser.id }
    private var canEdit: Bool { AgentsUI.canEdit(agent, userID: userID, role: session.agentsUIRole) }
    private var runtime: RuntimeDeviceRecord? {
        AgentsUI.isRuntimeBound(agent) ? session.runtimeRecords.item(agent.runtimeId) : nil
    }

    private var visibleCapabilities: [AgentsUIDetailView] {
        let showMcp = runtime.map { AgentsUI.providerSupportsMcp($0.provider) } ?? true
        let composio = (env.appConfig?.featureFlags?["composio_mcp_apps"] ?? false) && agent.ownerId == userID
        return AgentsUIDetailView.capabilities.filter {
            switch $0 {
            case .mcpConfig: return showMcp
            case .composioMcp: return composio
            case .integrations: return integrationsConfigured
            default: return true
            }
        }
    }

    private var visibleSettings: [AgentsUIDetailView] {
        AgentsUIDetailView.settings.filter {
            switch $0 {
            case .env: return canEdit
            case .runtimeConfig: return runtime?.provider == "openclaw"
            default: return true
            }
        }
    }

    private var effectiveView: AgentsUIDetailView {
        guard let raw = nav.query("view"), let v = AgentsUIDetailView(rawValue: raw) else { return .overview }
        let visible: Set<AgentsUIDetailView> = Set([.overview, .work] + visibleCapabilities + visibleSettings)
        return visible.contains(v) ? v : .overview
    }

    var body: some View {
        let view = effectiveView
        VStack(spacing: 0) {
            AgentsUIDetailHeader(agent: agent, runtime: runtime, canEdit: canEdit, onArchive: { confirmArchive = true })
            if !canEdit {
                capabilityBanner
            }
            if agent.archivedAt != nil {
                banner(icon: "exclamationmark.circle", text: tr("agents", "detail.archived_banner"), tint: .secondary,
                       background: Color.primary.opacity(0.04), actionTitle: canEdit ? tr("agents", "detail.restore") : nil) {
                    let id = agent.id
                    Task { await session.agentsUIRestore(id, toaster: toaster, toast: tr("agents", "detail.agent_restored_toast")) }
                }
            } else if !AgentsUI.isRuntimeBound(agent) {
                banner(icon: "server.rack", text: tr("agents", "detail.runtime_required_banner"), tint: Theme.warning,
                       background: Theme.warning.opacity(0.1), actionTitle: canEdit ? tr("agents", "detail.bind_runtime") : nil) {
                    request(.general)
                }
            }
            topTabs(current: view.section)
            content(view)
        }
        .tabTitle(agent.name)
        .task(id: session.workspace.id) { await loadIntegrations() }
        .alert(tr("agents", "tabs.discard_dialog_title"), isPresented: Binding(get: { pendingView != nil }, set: { if !$0 { pendingView = nil } })) {
            Button(tr("agents", "tabs.discard_keep"), role: .cancel) { pendingView = nil }
            Button(tr("agents", "tabs.discard_confirm"), role: .destructive) {
                if let v = pendingView { commit(v) }
                activeDirty = false
                pendingView = nil
            }
        } message: {
            Text(tr("agents", "tabs.discard_dialog_description"))
        }
        .alert(tr("agents", "detail.archive_dialog_title"), isPresented: $confirmArchive) {
            Button(tr("agents", "detail.archive_dialog_cancel"), role: .cancel) {}
            Button(tr("agents", "detail.archive_dialog_confirm"), role: .destructive) {
                let id = agent.id
                Task { await session.agentsUIArchive(id, toaster: toaster, toast: tr("agents", "detail.agent_archived_toast")) }
                nav.push(.agents)
            }
        } message: {
            Text(tr("agents", "detail.archive_dialog_description", ["name": agent.name]))
        }
    }

    private var capabilityBanner: some View {
        let ownerName = agent.ownerId.flatMap { session.directory.member(userID: $0)?.name }
        let message = ownerName.map { "View only — only \($0) and workspace admins can edit this agent." }
            ?? "View only — only the agent owner and workspace admins can edit this agent."
        return HStack(spacing: 8) {
            Image(systemName: "lock").font(.system(size: 11))
            Text(message)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, 12)
        .frame(maxWidth: 1200)
    }

    private func banner(icon: String, text: String, tint: Color, background: Color, actionTitle: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
        .font(Theme.Font.caption)
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.vertical, 8)
        .background(background)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func topTabs(current: AgentsUIDetailView.Section) -> some View {
        HStack(spacing: 24) {
            ForEach(AgentsUIDetailView.Section.allCases, id: \.self) { s in
                Button { requestSection(s) } label: {
                    Text(tr("agents", "tabs.\(s.rawValue)"))
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(current == s ? .primary : .secondary)
                        .padding(.vertical, 11)
                        .overlay(alignment: .bottom) {
                            if current == s { Rectangle().fill(Color.primary).frame(height: 2) }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.page)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func requestSection(_ s: AgentsUIDetailView.Section) {
        switch s {
        case .overview: request(.overview)
        case .work: request(.work)
        case .capabilities:
            let cur = effectiveView
            if let v = visibleCapabilities.contains(cur) ? cur : visibleCapabilities.first { request(v) }
        case .settings:
            let cur = effectiveView
            if let v = visibleSettings.contains(cur) ? cur : visibleSettings.first { request(v) }
        }
    }

    private func request(_ v: AgentsUIDetailView) {
        guard v != effectiveView else { return }
        if activeDirty {
            pendingView = v
            return
        }
        commit(v)
    }

    private func commit(_ v: AgentsUIDetailView) {
        nav.setQuery("view", v == .overview ? nil : v.rawValue)
    }

    @ViewBuilder
    private func content(_ view: AgentsUIDetailView) -> some View {
        switch view.section {
        case .overview:
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    AgentsUIActivityTab(agent: agent, showPerformance: false)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    AgentsUIOverviewSummary(agent: agent, runtime: runtime)
                        .frame(width: 320)
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.vertical, 24)
                .frame(maxWidth: 1200)
                .frame(maxWidth: .infinity)
            }
        case .work:
            IssueCollectionView(scope: .actor(type: "agent", id: agent.id), showHeader: false)
                .frame(minHeight: 620)
        case .capabilities, .settings:
            let tabs = view.section == .capabilities ? visibleCapabilities : visibleSettings
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(tabs, id: \.self) { t in
                        Button { request(t) } label: {
                            Text(t.label)
                                .font(Theme.Font.caption.weight(t == view ? .medium : .regular))
                                .foregroundStyle(t == view ? .primary : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(t == view ? Theme.selected : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(width: 208)
                .overlay(alignment: .trailing) { Divider() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(view.label).font(Theme.Font.title)
                        tabBody(view)
                    }
                    .padding(32)
                    .frame(maxWidth: 768, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(view)
            }
            .frame(maxWidth: 1200, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func update(_ patch: [String: JSONValue]) async throws {
        try await session.agentsUIUpdate(agent.id, patch, toaster: toaster)
    }

    @ViewBuilder
    private func tabBody(_ view: AgentsUIDetailView) -> some View {
        let dirty: (Bool) -> Void = { activeDirty = $0 }
        switch view {
        case .instructions:
            AgentsUIInstructionsTab(agent: agent, onDirtyChange: dirty, onSave: update)
        case .skills:
            AgentsUISkillsTab(agent: agent, runtime: runtime, canEdit: canEdit)
        case .mcpConfig:
            AgentsUIMcpConfigTab(agent: agent, runtime: runtime, canEdit: canEdit, onSave: update)
        case .composioMcp:
            AgentsUIComposioTab(agent: agent)
        case .integrations:
            AgentsUIIntegrationsTab(agent: agent)
        case .general:
            AgentsUIGeneralTab(agent: agent, runtime: runtime, canEdit: canEdit, onUpdate: update)
        case .access:
            AgentsUIAccessSettings(agent: agent, onDirtyChange: dirty, onUpdate: update)
        case .env:
            AgentsUIEnvTab(agent: agent, onDirtyChange: dirty)
        case .customArgs:
            AgentsUICustomArgsTab(agent: agent, runtime: runtime, onDirtyChange: dirty, onSave: update)
        case .runtimeConfig:
            AgentsUIRuntimeConfigTab(agent: agent, onDirtyChange: dirty, onSave: update)
        case .overview, .work:
            EmptyView()
        }
    }

    private func loadIntegrations() async {
        let api = session.api
        let ws = session.workspace.id
        async let lark = try? api.listLarkInstallations(workspaceId: ws)
        async let slack = try? api.listSlackInstallations(workspaceId: ws)
        async let ding = try? api.listDingTalkInstallations(workspaceId: ws)
        async let wecom = try? api.listWecomInstallations(workspaceId: ws)
        async let tg = try? api.listTelegramInstallations(workspaceId: ws)
        let (l, s, d, w, t) = await (lark, slack, ding, wecom, tg)
        integrationsConfigured = l?.configured == true || s?.configured == true || d?.configured == true
            || w?.configured == true || t?.configured == true
    }
}

/// Breadcrumb, identity, meta line and primary actions.
struct AgentsUIDetailHeader: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    @Environment(ModalCenter.self) private var modals
    let agent: AgentRecord
    let runtime: RuntimeDeviceRecord?
    let canEdit: Bool
    let onArchive: () -> Void
    @State private var expanded = false

    var body: some View {
        let archived = agent.archivedAt != nil
        let presence = AgentsUI.presence(agent: agent, runtime: session.runtimeRecords.item(agent.runtimeId),
                                         tasks: session.agentsUIStore.snapshot.filter { $0.agentId == agent.id }, now: Date())
        let denial = AgentsUI.assignDenial(agent, userID: session.currentUser.id, role: session.agentsUIRole)
        let permissionsLoading = !session.agentsUIMembersLoaded
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Button(tr("agents", "page.title")) { nav.push(.agents) }.buttonStyle(.plain).foregroundStyle(.secondary)
                Text("/").foregroundStyle(.tertiary)
                Text(agent.name).lineLimit(1)
            }
            .font(Theme.Font.caption)
            HStack(alignment: .top, spacing: 16) {
                AgentsUIAvatar(name: agent.name, avatarURL: agent.avatarUrl, size: 56)
                    .overlay(RoundedRectangle(cornerRadius: 56 * 0.28, style: .continuous).strokeBorder(Theme.border))
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(agent.name).font(.system(size: 22, weight: .semibold)).lineLimit(2)
                        AgentsUIPresenceIndicator(presence: session.agentsUIStore.snapshotLoaded ? presence : nil)
                    }
                    description
                    HStack(spacing: 16) {
                        Label(agent.model.isEmpty ? tr("agents", "pickers.model_default") : agent.model, systemImage: "cpu").lineLimit(1)
                        Label(runtime.map(AgentsUI.runtimeDisplayLabel) ?? tr("agents", "pickers.runtime_none"), systemImage: "server.rack").lineLimit(1)
                        AgentsUIVisibilityBadge(visibility: agent.visibility)
                        Label(tr("agents", "detail.updated", ["when": Formatters.relative(agent.updatedAt)]), systemImage: "clock")
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(AgentsUICompactLabelStyle())
                }
                Spacer(minLength: 16)
                HStack(spacing: 8) {
                    if !archived {
                        Button {
                            if permissionsLoading { return }
                            if denial != nil { toaster.error(tr("agents", "detail.dm_no_permission_toast")); return }
                            if !AgentsUI.isRuntimeBound(agent) { toaster.error(tr("agents", "detail.runtime_required_toast")); return }
                            nav.push(.chat, query: ["agent": agent.id])
                        } label: { Label(tr("agents", "detail.dm"), systemImage: "bubble.left") }
                            .disabled(permissionsLoading)
                    }
                    if !archived && denial == nil {
                        Button {
                            if !AgentsUI.isRuntimeBound(agent) { toaster.error(tr("agents", "detail.runtime_required_toast")); return }
                            var draft = CreateIssueDraft()
                            draft.assignee = ActorRef(type: "agent", id: agent.id)
                            modals.present(.quickCreateIssue(draft))
                        } label: { Label(tr("agents", "detail.assign_work"), systemImage: "plus") }
                            .buttonStyle(.borderedProminent)
                    }
                    if !archived && canEdit && agent.systemKey == nil {
                        Menu {
                            Button(role: .destructive, action: onArchive) { Label(tr("agents", "detail.more_archive"), systemImage: "trash") }
                        } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help(tr("agents", "detail.more_actions_aria"))
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var description: some View {
        let text = agent.description.isEmpty ? tr("agents", "inspector.no_description_placeholder") : agent.description
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(Theme.Font.body)
                .foregroundStyle(agent.description.isEmpty ? .tertiary : .secondary)
                .lineLimit(expanded ? nil : 2)
                .textSelection(.enabled)
                .frame(maxWidth: 680, alignment: .leading)
            if agent.description.count > 180 {
                Button(expanded ? tr("common", "expandable_description.collapse") : tr("common", "expandable_description.expand")) { expanded.toggle() }
                    .buttonStyle(.link).font(Theme.Font.caption)
            }
        }
    }
}

struct AgentsUICompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 10))
            configuration.title
        }
    }
}
