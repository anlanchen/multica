import AppKit
import CoreImage.CIFilterBuiltins
import MulticaCore
import SwiftUI

/// Capabilities › Integrations (upstream tabs/integrations-tab): per-agent
/// Lark/Feishu, Slack, DingTalk, WeCom and Telegram bots, with the same
/// management gates (Lark/DingTalk: agent owner or admin; others: admin).
struct AgentsUIIntegrationsTab: View {
    @Environment(WorkspaceSession.self) private var session
    let agent: AgentRecord

    @State private var lark: ListLarkInstallationsResponse?
    @State private var slack: ListSlackInstallationsResponse?
    @State private var ding: ListDingTalkInstallationsResponse?
    @State private var wecom: ListWecomInstallationsResponse?
    @State private var telegram: ListTelegramInstallationsResponse?
    @State private var dingGroups: ListDingTalkGroupsResponse?
    @State private var dingGroupsLoading = false
    @State private var dingGroupsFailed = false

    private var isAdmin: Bool { session.agentsUIIsAdmin }
    private var isOwner: Bool { session.agentsUIRole != nil && agent.ownerId != nil && agent.ownerId == session.currentUser.id }

    var body: some View {
        let canLark = isAdmin || isOwner
        let canDing = isAdmin || isOwner
        let dingInstall = ding?.installations.first { $0.agentId == agent.id && $0.status == "active" }
        Group {
            if !canLark && !isAdmin && !canDing {
                if let dingInstall {
                    section("D", tr("settings", "dingtalk.section_title"), tr("settings", "dingtalk.agent_page_description")) {
                        dingConnectedLabel(dingInstall)
                    } extra: {
                        dingGroupsView(dingInstall, canManage: false)
                    }
                } else {
                    Text(tr("agents", "tab_body.integrations.members_note")).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    larkSection(canManage: canLark)
                    slackSection
                    dingSection(canManage: canDing, install: dingInstall)
                    wecomSection
                    telegramSection
                }
            }
        }
        .task(id: agent.id) { await load() }
        .task(id: dingInstall?.id) { await loadDingGroups(installed: dingInstall != nil) }
    }

    // MARK: Sections

    private func larkSection(canManage: Bool) -> some View {
        let install = lark?.installations.first { $0.agentId == agent.id && $0.status == "active" }
        return section("飞", tr("settings", "lark.section_title"), tr("settings", "lark.page_description")) {
            if lark?.configured != true {
                note(tr("settings", "lark.not_enabled_title"))
            } else if lark?.installSupported != true && install == nil {
                preview(tr("settings", "lark.preview_title"), tr("settings", "lark.preview_description"))
            } else if let install {
                let region = install.region == "lark" ? "lark" : "feishu"
                connected(tr("settings", "lark.agent_bot_connected_label_\(region)"),
                          link: (tr("settings", "lark.agent_bot_manage_link_\(region)"),
                                 URL(string: "\(region == "lark" ? "https://open.larksuite.com" : "https://open.feishu.cn")/app/\(install.appId)")),
                          help: tr("settings", "lark.agent_bot_disconnect_tooltip"),
                          canManage: canManage,
                          confirmTitle: tr("settings", "lark.disconnect_confirm_title"),
                          confirmMessage: tr("settings", "lark.disconnect_confirm_description"),
                          disconnectedToast: tr("settings", "lark.toast_disconnected"),
                          failedToast: tr("settings", "lark.toast_disconnect_failed")) {
                    try await session.api.deleteLarkInstallation(workspaceId: session.workspace.id, installationId: install.id)
                }
            } else if canManage {
                AgentsUIConnectButton(title: tr("settings", "lark.bind_button_feishu"),
                                      help: tr("settings", "lark.bind_button_feishu_title", ["agent": agent.name])) { dismiss in
                    AgentsUILarkInstallSheet(agent: agent, region: "feishu") {
                        dismiss()
                        Task { await load() }
                    }
                }
            }
        }
    }

    private var slackSection: some View {
        let install = slack?.installations.first { $0.agentId == agent.id && $0.status == "active" }
        return section("S", tr("settings", "slack.section_title"), tr("settings", "slack.page_description")) {
            if !isAdmin {
                note(tr("agents", "tab_body.integrations.members_note"))
            } else if slack?.configured != true {
                note(tr("settings", "slack.not_enabled_title"))
            } else if slack?.installSupported != true && install == nil {
                preview(tr("settings", "slack.preview_title"), tr("settings", "slack.preview_description"))
            } else if let install {
                connected(tr("settings", "slack.agent_bot_connected_label"),
                          link: (tr("settings", "slack.agent_bot_manage_link"), URL(string: "https://app.slack.com/client/\(install.teamId)")),
                          help: tr("settings", "slack.agent_bot_disconnect_tooltip"), canManage: true,
                          confirmTitle: tr("settings", "slack.disconnect_confirm_title"),
                          confirmMessage: tr("settings", "slack.disconnect_confirm_description"),
                          disconnectedToast: tr("settings", "slack.toast_disconnected"),
                          failedToast: tr("settings", "slack.toast_disconnect_failed")) {
                    try await session.api.deleteSlackInstallation(workspaceId: session.workspace.id, installationId: install.id)
                }
            } else {
                AgentsUIConnectButton(title: tr("settings", "slack.bind_button"), help: tr("settings", "slack.bind_button_title", ["agent": agent.name])) { dismiss in
                    AgentsUICredentialSheet(
                        title: tr("settings", "slack.byo_dialog_title"),
                        description: nil,
                        docs: (tr("settings", "slack.byo_docs_link"), docsURL("slack-integration")),
                        fields: [.init(label: tr("settings", "slack.byo_bot_token_label"), placeholder: "xoxb-…", secure: true),
                                 .init(label: tr("settings", "slack.byo_app_token_label"), placeholder: "xapp-…", secure: true)],
                        submit: tr("settings", "slack.byo_submit"), submitting: tr("settings", "slack.byo_submitting"),
                        cancel: tr("settings", "slack.byo_cancel"), successToast: tr("settings", "slack.byo_success_toast"),
                        failedToast: tr("settings", "slack.byo_failed_toast")
                    ) { values in
                        _ = try await session.api.registerSlackBYO(workspaceId: session.workspace.id, agentId: agent.id,
                                                                   RegisterSlackBYORequest(botToken: values[0], appToken: values[1]))
                        await load()
                    } onClose: { dismiss() }
                }
            }
        }
    }

    private func dingSection(canManage: Bool, install: DingTalkInstallation?) -> some View {
        section("D", tr("settings", "dingtalk.section_title"), tr("settings", "dingtalk.agent_page_description")) {
            if !canManage {
                if let install { dingConnectedLabel(install) } else { note(tr("agents", "tab_body.integrations.members_note")) }
            } else if ding?.configured != true {
                note(tr("settings", "dingtalk.not_enabled_title"))
            } else if let install {
                VStack(alignment: .leading, spacing: 8) {
                    dingConnectedLabel(install)
                    disconnectButton(help: tr("settings", "dingtalk.agent_bot_disconnect_tooltip"),
                                     confirmTitle: tr("settings", "dingtalk.disconnect_confirm_title"),
                                     confirmMessage: tr("settings", "dingtalk.disconnect_confirm_description"),
                                     disconnectedToast: tr("settings", "dingtalk.toast_disconnected"),
                                     failedToast: tr("settings", "dingtalk.toast_disconnect_failed")) {
                        try await session.api.deleteDingTalkInstallation(workspaceId: session.workspace.id, installationId: install.id)
                    }
                }
            } else {
                AgentsUIConnectButton(title: tr("settings", "dingtalk.bind_button"), help: tr("settings", "dingtalk.bind_button_title", ["agent": agent.name])) { dismiss in
                    AgentsUICredentialSheet(
                        title: tr("settings", "dingtalk.byo_dialog_title"), description: nil,
                        docs: (tr("settings", "dingtalk.byo_docs_link"), docsURL("dingtalk-integration")),
                        fields: [.init(label: tr("settings", "dingtalk.byo_appkey_label"), placeholder: "", secure: false),
                                 .init(label: tr("settings", "dingtalk.byo_appsecret_label"), placeholder: "", secure: true)],
                        submit: tr("settings", "dingtalk.byo_submit"), submitting: tr("settings", "dingtalk.byo_submitting"),
                        cancel: tr("settings", "dingtalk.byo_cancel"), successToast: tr("settings", "dingtalk.byo_success_toast"),
                        failedToast: tr("settings", "dingtalk.byo_failed_toast")
                    ) { values in
                        _ = try await session.api.registerDingTalkBYO(workspaceId: session.workspace.id, agentId: agent.id,
                                                                      RegisterDingTalkBYORequest(clientId: values[0], clientSecret: values[1]))
                        await load()
                    } onClose: { dismiss() }
                }
            }
        } extra: {
            if let install { dingGroupsView(install, canManage: canManage) }
        }
    }

    private var wecomSection: some View {
        let install = wecom?.installations.first { $0.agentId == agent.id && $0.status == "active" }
        return section("W", tr("settings", "wecom.section_title"), tr("settings", "wecom.page_description")) {
            if !isAdmin {
                note(tr("agents", "tab_body.integrations.members_note"))
            } else if wecom?.configured != true {
                note(tr("settings", "wecom.not_enabled_title"))
            } else if wecom?.installSupported != true && install == nil {
                preview(tr("settings", "wecom.preview_title"), tr("settings", "wecom.preview_description"))
            } else if let install {
                connected(install.botId.isEmpty ? tr("settings", "wecom.agent_bot_connected_label")
                          : tr("settings", "wecom.agent_bot_connected_label_with_id", ["botId": install.botId]),
                          link: nil, help: tr("settings", "wecom.agent_bot_disconnect_tooltip"), canManage: true,
                          confirmTitle: tr("settings", "wecom.disconnect_confirm_title"),
                          confirmMessage: tr("settings", "wecom.disconnect_confirm_description"),
                          disconnectedToast: tr("settings", "wecom.toast_disconnected"),
                          failedToast: tr("settings", "wecom.toast_disconnect_failed")) {
                    try await session.api.deleteWecomInstallation(workspaceId: session.workspace.id, installationId: install.id)
                }
            } else {
                AgentsUIConnectButton(title: tr("settings", "wecom.bind_button"), help: tr("settings", "wecom.bind_button_title", ["agent": agent.name])) { dismiss in
                    AgentsUICredentialSheet(
                        title: tr("settings", "wecom.byo_dialog_title"), description: nil, docs: nil,
                        fields: [.init(label: tr("settings", "wecom.byo_bot_id_label"), placeholder: tr("settings", "wecom.byo_bot_id_placeholder"), secure: false),
                                 .init(label: tr("settings", "wecom.byo_secret_label"), placeholder: tr("settings", "wecom.byo_secret_placeholder"), secure: true),
                                 .init(label: tr("settings", "wecom.byo_bot_name_label"), placeholder: tr("settings", "wecom.byo_bot_name_placeholder"),
                                       secure: false, optional: true, hint: tr("settings", "wecom.byo_bot_name_hint"))],
                        submit: tr("settings", "wecom.byo_submit"), submitting: tr("settings", "wecom.byo_submitting"),
                        cancel: tr("settings", "wecom.byo_cancel"), successToast: tr("settings", "wecom.byo_success_toast"),
                        failedToast: tr("settings", "wecom.byo_failed_toast")
                    ) { values in
                        _ = try await session.api.registerWecomBYO(workspaceId: session.workspace.id, agentId: agent.id,
                                                                   RegisterWecomBYORequest(botId: values[0], secret: values[1], botName: values[2].isEmpty ? nil : values[2]))
                        await load()
                    } onClose: { dismiss() }
                }
            }
        }
    }

    private var telegramSection: some View {
        let install = telegram?.installations.first { $0.agentId == agent.id && $0.status == "active" }
        return section("T", tr("settings", "telegram.section_title"), tr("settings", "telegram.page_description")) {
            if !isAdmin {
                note(tr("agents", "tab_body.integrations.members_note"))
            } else if telegram?.configured != true {
                note(tr("settings", "telegram.not_enabled_title"))
            } else if telegram?.installSupported != true && install == nil {
                preview(tr("settings", "telegram.preview_title"), tr("settings", "telegram.preview_description"))
            } else if let install {
                connected(tr("settings", "telegram.agent_bot_connected_label") + (install.botUsername.isEmpty ? "" : " — @\(install.botUsername)"),
                          link: (tr("settings", "telegram.agent_bot_manage_link"), URL(string: "https://t.me/\(install.botUsername)")),
                          help: tr("settings", "telegram.agent_bot_disconnect_tooltip"), canManage: true,
                          confirmTitle: tr("settings", "telegram.disconnect_confirm_title"),
                          confirmMessage: tr("settings", "telegram.disconnect_confirm_description"),
                          disconnectedToast: tr("settings", "telegram.toast_disconnected"),
                          failedToast: tr("settings", "telegram.toast_disconnect_failed")) {
                    try await session.api.deleteTelegramInstallation(workspaceId: session.workspace.id, installationId: install.id)
                }
            } else {
                AgentsUIConnectButton(title: tr("settings", "telegram.bind_button"), help: tr("settings", "telegram.bind_button_title", ["agent": agent.name])) { dismiss in
                    AgentsUICredentialSheet(
                        title: tr("settings", "telegram.connect_dialog_title"), description: tr("settings", "telegram.connect_dialog_description"),
                        docs: (tr("settings", "telegram.connect_docs_link"), docsURL("telegram-integration")),
                        fields: [.init(label: tr("settings", "telegram.bot_token_label"), placeholder: "123456:ABC…", secure: true)],
                        submit: tr("settings", "telegram.connect_submit"), submitting: tr("settings", "telegram.connect_submitting"),
                        cancel: tr("settings", "telegram.connect_cancel"), successToast: tr("settings", "telegram.connect_success_toast"),
                        failedToast: tr("settings", "telegram.connect_failed_toast")
                    ) { values in
                        _ = try await session.api.registerTelegramBot(workspaceId: session.workspace.id, agentId: agent.id,
                                                                      RegisterTelegramRequest(botToken: values[0]))
                        await load()
                    } onClose: { dismiss() }
                }
            }
        }
    }

    // MARK: Pieces

    private func section<C: View, E: View>(_ mark: String, _ title: String, _ description: String,
                                           @ViewBuilder content: () -> C, @ViewBuilder extra: () -> E) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text(mark).font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.Font.bodyMedium)
                    Text(description).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            Divider()
            content().padding(.horizontal, 16).padding(.vertical, 12)
            extra()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
    }

    private func section<C: View>(_ mark: String, _ title: String, _ description: String, @ViewBuilder content: () -> C) -> some View {
        section(mark, title, description, content: content, extra: { EmptyView() })
    }

    private func note(_ s: String) -> some View {
        Text(s).font(Theme.Font.caption).foregroundStyle(.secondary)
    }

    private func preview(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.Font.caption.weight(.medium))
            Text(description).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
    }

    private func connected(_ label: String, link: (String, URL?)?, help: String, canManage: Bool, confirmTitle: String, confirmMessage: String,
                           disconnectedToast: String, failedToast: String, disconnect: @escaping () async throws -> Void) -> some View {
        HStack(spacing: 10) {
            Label(label, systemImage: "checkmark.circle.fill").font(Theme.Font.caption).foregroundStyle(Theme.success)
            if let link, let url = link.1 {
                Link(link.0, destination: url).font(Theme.Font.caption)
            }
            Spacer()
            if canManage {
                disconnectButton(help: help, confirmTitle: confirmTitle, confirmMessage: confirmMessage,
                                 disconnectedToast: disconnectedToast, failedToast: failedToast, action: disconnect)
            }
        }
    }

    private func disconnectButton(help: String, confirmTitle: String, confirmMessage: String, disconnectedToast: String,
                                  failedToast: String, action: @escaping () async throws -> Void) -> some View {
        AgentsUIDisconnectButton(help: help, confirmTitle: confirmTitle, confirmMessage: confirmMessage,
                                 disconnectedToast: disconnectedToast, failedToast: failedToast) {
            try await action()
            await load()
        }
    }

    private func dingConnectedLabel(_ install: DingTalkInstallation) -> some View {
        let identity = dingGroups?.botIdentities?[install.id] ?? dingGroups?.groups.flatMap(\.bots).first { $0.installationId == install.id }
        return HStack(spacing: 6) {
            Text(tr("settings", "dingtalk.agent_bot_connected_label")).foregroundStyle(.secondary)
            if dingGroupsLoading {
                ProgressView().controlSize(.mini)
            } else if let name = identity?.botName, !name.isEmpty {
                Text(name).font(Theme.Font.caption.weight(.medium))
            } else if dingGroups?.groupDiscoverySupported == true {
                Text(tr("settings", "dingtalk.bot_identity_unavailable")).foregroundStyle(.secondary)
            }
        }
        .font(Theme.Font.caption)
    }

    @ViewBuilder
    private func dingGroupsView(_ install: DingTalkInstallation, canManage: Bool) -> some View {
        if dingGroups?.groupDiscoverySupported == true || dingGroupsLoading || dingGroupsFailed {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("settings", "dingtalk.groups_title")).font(Theme.Font.caption.weight(.medium))
                Text(tr("settings", "dingtalk.groups_description")).font(Theme.Font.caption).foregroundStyle(.secondary)
                if dingGroupsLoading {
                    Text(tr("settings", "dingtalk.groups_loading")).font(Theme.Font.caption).foregroundStyle(.secondary)
                } else if dingGroupsFailed {
                    HStack {
                        Text(tr("settings", "dingtalk.groups_error")).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                        Button(tr("settings", "dingtalk.groups_retry")) { Task { await loadDingGroups(installed: true) } }.buttonStyle(.link)
                    }
                } else if let groups = dingGroups?.groups, !groups.isEmpty {
                    ForEach(groups, id: \.conversationId) { g in
                        let bot = g.bots.first { $0.installationId == install.id }
                        HStack(spacing: 8) {
                            Text(g.conversationTitle.isEmpty ? tr("settings", "dingtalk.group_untitled") : g.conversationTitle)
                                .font(Theme.Font.body).lineLimit(1)
                            if let last = bot?.lastActiveAt {
                                Text(tr("settings", "dingtalk.group_last_active", ["time": Formatters.relative(last)]))
                                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                            if let n = bot?.mentionCount {
                                Text(tr("settings", "dingtalk.group_mentions", ["count": n])).font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if canManage {
                                AgentsUIDisconnectButton(title: tr("settings", "dingtalk.group_forget"), help: tr("settings", "dingtalk.group_forget"),
                                                         confirmTitle: tr("settings", "dingtalk.group_forget_title"),
                                                         confirmMessage: tr("settings", "dingtalk.group_forget_description"),
                                                         confirmButton: tr("settings", "dingtalk.group_forget_confirm"),
                                                         disconnectedToast: tr("settings", "dingtalk.group_forget_success"),
                                                         failedToast: tr("settings", "dingtalk.group_forget_failed")) {
                                    try await session.api.forgetDingTalkGroup(workspaceId: session.workspace.id, installationId: install.id, conversationId: g.conversationId)
                                    await loadDingGroups(installed: true)
                                }
                            }
                        }
                    }
                    if let inactive = dingGroups?.inactiveGroupCounts?[install.id], inactive > 0 {
                        Text(tr("settings", "dingtalk.groups_inactive", ["count": inactive])).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(tr("settings", "dingtalk.groups_empty")).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    private func docsURL(_ page: String) -> URL {
        let lang = L10n.shared.language
        let prefix = ["zh", "ja", "ko", "fr"].first { lang.hasPrefix($0) }.map { "/\($0)" } ?? ""
        return URL(string: "https://multica.ai/docs\(prefix)/\(page)")!
    }

    private func load() async {
        let api = session.api
        let ws = session.workspace.id
        async let l = try? api.listLarkInstallations(workspaceId: ws)
        async let s = try? api.listSlackInstallations(workspaceId: ws)
        async let d = try? api.listDingTalkInstallations(workspaceId: ws)
        async let w = try? api.listWecomInstallations(workspaceId: ws)
        async let t = try? api.listTelegramInstallations(workspaceId: ws)
        (lark, slack, ding, wecom, telegram) = await (l, s, d, w, t)
    }

    private func loadDingGroups(installed: Bool) async {
        guard installed else { dingGroups = nil; return }
        dingGroupsLoading = true
        defer { dingGroupsLoading = false }
        do {
            dingGroups = try await session.api.listAgentDingTalkGroups(agentId: agent.id)
            dingGroupsFailed = false
        } catch {
            dingGroupsFailed = true
        }
    }
}

/// A button that opens its own sheet.
struct AgentsUIConnectButton<Sheet: View>: View {
    let title: String
    let help: String
    @ViewBuilder var sheet: (_ dismiss: @escaping () -> Void) -> Sheet
    @State private var open = false

    var body: some View {
        Button { open = true } label: { Label(title, systemImage: "arrow.up.forward.square") }
            .controlSize(.small)
            .help(help)
            .sheet(isPresented: $open) { sheet { open = false } }
    }
}

/// Confirmed destructive action with progress and toasts.
struct AgentsUIDisconnectButton: View {
    @Environment(Toaster.self) private var toaster
    var title: String = tr("settings", "lark.disconnect")
    let help: String
    let confirmTitle: String
    let confirmMessage: String
    var confirmButton: String? = nil
    let disconnectedToast: String
    let failedToast: String
    let action: () async throws -> Void
    @State private var confirming = false
    @State private var busy = false

    var body: some View {
        Button(busy ? tr("settings", "lark.disconnecting") : title) { confirming = true }
            .controlSize(.small)
            .disabled(busy)
            .help(help)
            .alert(confirmTitle, isPresented: $confirming) {
                Button(tr("settings", "lark.disconnect_confirm_cancel"), role: .cancel) {}
                Button(confirmButton ?? title, role: .destructive) {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            try await action()
                            toaster.success(disconnectedToast)
                        } catch {
                            toaster.show((error as? APIError)?.message ?? failedToast, kind: .error)
                        }
                    }
                }
            } message: {
                Text(confirmMessage)
            }
    }
}

/// Bring-your-own bot credentials dialog (Slack, DingTalk, WeCom, Telegram).
struct AgentsUICredentialSheet: View {
    @Environment(Toaster.self) private var toaster
    struct Field {
        var label: String
        var placeholder: String
        var secure: Bool
        var optional = false
        var hint: String? = nil
    }

    let title: String
    let description: String?
    let docs: (String, URL)?
    let fields: [Field]
    let submit: String
    let submitting: String
    let cancel: String
    let successToast: String
    let failedToast: String
    let onSubmit: ([String]) async throws -> Void
    let onClose: () -> Void

    @State private var values: [String] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Theme.Font.title)
            if let description { Text(description).font(Theme.Font.caption).foregroundStyle(.secondary) }
            if let docs { Link(docs.0, destination: docs.1).font(Theme.Font.caption) }
            ForEach(fields.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 5) {
                    Text(fields[i].label).font(Theme.Font.caption.weight(.medium))
                    Group {
                        if fields[i].secure {
                            SecureField(fields[i].placeholder, text: binding(i))
                        } else {
                            TextField(fields[i].placeholder, text: binding(i))
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.mono)
                    if let hint = fields[i].hint { Text(hint).font(Theme.Font.caption).foregroundStyle(.secondary) }
                }
            }
            if let error { Text(error).font(Theme.Font.caption).foregroundStyle(Theme.destructive) }
            HStack {
                Spacer()
                Button(cancel, action: onClose).keyboardShortcut(.cancelAction).disabled(busy)
                Button(busy ? submitting : submit, action: go)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !ready)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { if values.count != fields.count { values = Array(repeating: "", count: fields.count) } }
    }

    private var ready: Bool {
        values.count == fields.count && fields.indices.allSatisfy { fields[$0].optional || !values[$0].trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func binding(_ i: Int) -> Binding<String> {
        Binding(get: { values.indices.contains(i) ? values[i] : "" }, set: { if values.indices.contains(i) { values[i] = $0 } })
    }

    private func go() {
        busy = true
        error = nil
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        Task {
            defer { busy = false }
            do {
                try await onSubmit(trimmed)
                toaster.success(successToast)
                onClose()
            } catch {
                self.error = (error as? APIError)?.message ?? failedToast
            }
        }
    }
}

/// Lark/Feishu device-flow install: show the QR, poll until the bot is
/// created (upstream LarkInstallDialog).
struct AgentsUILarkInstallSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let agent: AgentRecord
    let region: String
    let onDone: () -> Void

    enum Phase: Equatable { case starting, pending(qr: String), success, error(String) }
    @State private var phase: Phase = .starting
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 14) {
            Text(tr("settings", "lark.install_dialog_title_\(region)")).font(Theme.Font.title)
            Text(tr("settings", "lark.install_dialog_description_for_agent_\(region)", ["agent": agent.name]))
                .font(Theme.Font.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            switch phase {
            case .starting:
                ProgressView(tr("settings", "lark.install_starting")).frame(height: 220)
            case .pending(let qr):
                if let image = Self.qrImage(qr) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 200, height: 200)
                        .padding(8).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Text(tr("settings", "lark.install_scan_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                if let url = URL(string: qr) {
                    Link(tr("settings", "lark.install_open_link_fallback_\(region)"), destination: url).font(Theme.Font.caption)
                }
            case .success:
                Label(tr("settings", "lark.install_success"), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success).frame(height: 120)
            case .error(let reason):
                Label(message(reason), systemImage: "exclamationmark.triangle").foregroundStyle(Theme.destructive)
                    .multilineTextAlignment(.center).frame(minHeight: 120)
            }
            HStack {
                if case .error = phase {
                    Button(tr("settings", "lark.install_retry")) { attempt += 1 }
                }
                Spacer()
                Button(tr("settings", "lark.install_close"), action: onDone).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task(id: attempt) { await run() }
    }

    private func message(_ reason: String) -> String {
        switch reason {
        case "expired": return tr("settings", "lark.install_error_expired")
        case "access_denied": return tr("settings", "lark.install_error_access_denied")
        case "lark_protocol_error": return tr("settings", "lark.install_error_protocol")
        case "bot_info_failed": return tr("settings", "lark.install_error_bot_info")
        case "installation_conflict": return tr("settings", "lark.install_error_conflict")
        case "installer_bind_failed": return tr("settings", "lark.install_error_installer_bind")
        case "session_lost": return tr("settings", "lark.install_error_session_lost")
        case "forbidden": return tr("settings", "lark.install_error_forbidden")
        default: return tr("settings", "lark.install_error_generic")
        }
    }

    private func run() async {
        phase = .starting
        let ws = session.workspace.id
        guard let begin = try? await session.api.beginLarkInstall(workspaceId: ws, agentId: agent.id, region: region) else {
            phase = .error("internal_error")
            return
        }
        phase = .pending(qr: begin.qrCodeUrl)
        let interval = max(1, begin.pollIntervalSeconds)
        let deadline = Date().addingTimeInterval(TimeInterval(max(60, begin.expiresInSeconds)))
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled { return }
            if Date() > deadline { phase = .error("expired"); return }
            do {
                let s = try await session.api.getLarkInstallStatus(workspaceId: ws, sessionId: begin.sessionId)
                if s.status == "success" {
                    phase = .success
                    toaster.success(tr("settings", "lark.install_success_toast_\(region)"))
                    try? await Task.sleep(for: .seconds(1))
                    onDone()
                    return
                }
                if s.status == "error" {
                    phase = .error(s.errorReason ?? "internal_error")
                    return
                }
            } catch {
                let status = (error as? APIError)?.status
                if status == 404 { phase = .error("session_lost"); return }
                if status == 403 || status == 401 { phase = .error("forbidden"); return }
            }
        }
    }

    static func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
