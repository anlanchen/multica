import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MulticaCore
import SwiftUI

/// The per-agent channel entry point (upstream SlackAgentBindButton,
/// LarkAgentBindButton, DingTalkAgentBindButton, WecomAgentBindButton,
/// TelegramAgentBindButton) for the agent page's Integrations tab: a bind
/// CTA with its install dialog, or the connected badge once a bot exists.
struct ConnectionsAgentChannelBind: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.openURL) private var openURL
    let channel: ConnectionsChannel
    let agentID: String
    var agentName: String? = nil
    /// Lets the agent's owner manage Lark / DingTalk bots (backend canManageAgent).
    var agentOwnerID: String? = nil
    /// Renders the connected state as a compact row that calls this instead.
    var onShowConnectedDetails: (() -> Void)? = nil

    @State private var model = ConnectionsChannelsModel()
    @State private var dialogOpen = false
    @State private var confirm: ConnectionsConfirm?

    private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
        tr("settings", "\(channel.rawValue).\(key)", args)
    }

    private var canManage: Bool {
        let owner = agentOwnerID != nil && agentOwnerID == session.currentUser.id && session.connectionsIsMember
        switch channel {
        case .lark, .dingtalk: return session.connectionsIsManager || owner
        default: return session.connectionsIsManager
        }
    }

    private struct Existing {
        var id: String
        var region: String?
        var appID: String?
        var teamID: String?
        var botID: String?
        var botUsername: String?
    }

    private var state: (existing: Existing?, installSupported: Bool) {
        switch channel {
        case .lark:
            let r = model.lark.value
            let e = r?.installations.first { $0.agentId == agentID && $0.status == "active" }
            return (e.map { Existing(id: $0.id, region: $0.region, appID: $0.appId) }, r?.installSupported == true)
        case .slack:
            let r = model.slack.value
            let e = r?.installations.first { $0.agentId == agentID && $0.status == "active" }
            return (e.map { Existing(id: $0.id, teamID: $0.teamId) }, r?.installSupported == true)
        case .dingtalk:
            let r = model.dingtalk.value
            let e = r?.installations.first { $0.agentId == agentID && $0.status == "active" }
            return (e.map { Existing(id: $0.id) }, r?.installSupported == true)
        case .wecom:
            let r = model.wecom.value
            let e = r?.installations.first { $0.agentId == agentID && $0.status == "active" }
            return (e.map { Existing(id: $0.id, botID: $0.botId) }, r?.installSupported == true)
        case .telegram:
            let r = model.telegram.value
            let e = r?.installations.first { $0.agentId == agentID && $0.status == "active" }
            return (e.map { Existing(id: $0.id, botUsername: $0.botUsername) }, r?.installSupported == true)
        }
    }

    var body: some View {
        Group {
            if canManage {
                let s = state
                if let existing = s.existing {
                    if let onShowConnectedDetails {
                        statusRow(existing, action: onShowConnectedDetails)
                    } else {
                        connectedBadge(existing)
                    }
                } else if s.installSupported {
                    bindButton
                }
            }
        }
        .task(id: session.revision(channel.revisionKey)) { await model.load(channel, session) }
        .sheet(isPresented: $dialogOpen) {
            switch channel {
            case .lark:
                ConnectionsLarkInstallDialog(agentID: agentID, agentName: agentName, region: "feishu") {
                    Task { await model.load(.lark, session) }
                }
            default:
                ConnectionsChannelBYODialog(channel: channel, agentID: agentID) {
                    Task { await model.load(channel, session) }
                }
            }
        }
        .connectionsConfirm($confirm)
    }

    private var bindButton: some View {
        // Upstream hides the international Lark entry (MUL-3083); Feishu stays.
        Button { dialogOpen = true } label: {
            HStack(spacing: 6) {
                if channel == .lark {
                    Image(systemName: "arrow.up.right.square")
                } else {
                    ConnectionsBrandMark(brand: channel.brand, size: channel == .dingtalk ? 16 : 12)
                }
                Text(channel == .lark ? t("bind_button_feishu") : t("bind_button"))
            }
        }
        .controlSize(.small)
        .disabled(agentID.isEmpty)
        .help(agentName.map { channel == .lark ? t("bind_button_feishu_title", ["agent": $0]) : t("bind_button_title", ["agent": $0]) } ?? "")
    }

    private func regionLabel(_ e: Existing) -> String { t(e.region == "lark" ? "region_lark" : "region_feishu") }

    private func statusRow(_ e: Existing, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(Theme.success).frame(width: 6, height: 6)
                if channel == .lark { ConnectionsChip(text: regionLabel(e)) }
                Text(t("agent_bot_connected_label")).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 10))
            }
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }

    private func connectedBadge(_ e: Existing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.success).frame(width: 6, height: 6)
                    if channel == .lark { ConnectionsChip(text: regionLabel(e)) }
                    Text(connectedLabel(e)).lineLimit(1)
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(role: .destructive) { askDisconnect(e.id) } label: { Label(t("disconnect"), systemImage: "trash") }
                    .controlSize(.small)
                    .tint(.red)
                    .help(t("agent_bot_disconnect_tooltip"))
            }
            manageLink(e)
            if channel == .lark {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(t("agent_bot_silent_hint")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(t("agent_bot_silent_hint_link")) { open(docsURL) }.buttonStyle(.link)
                }
                .font(Theme.Font.caption)
            }
        }
    }

    private func connectedLabel(_ e: Existing) -> String {
        switch channel {
        case .wecom: return t("agent_bot_connected_label_with_id", ["botId": e.botID ?? ""])
        case .telegram: return t("agent_bot_connected_label") + (e.botUsername.map { $0.isEmpty ? "" : " · @\($0)" } ?? "")
        default: return t("agent_bot_connected_label")
        }
    }

    @ViewBuilder private func manageLink(_ e: Existing) -> some View {
        switch channel {
        case .slack:
            if let team = e.teamID, !team.isEmpty {
                linkButton(t("agent_bot_manage_link"), help: t("agent_bot_manage_tooltip"), url: "https://app.slack.com/client/\(team)")
            }
        case .telegram:
            if let user = e.botUsername, !user.isEmpty {
                linkButton(t("agent_bot_manage_link"), help: t("agent_bot_manage_tooltip"), url: "https://t.me/\(user)")
            }
        case .lark:
            let lark = e.region == "lark"
            let host = lark ? "https://open.larksuite.com" : "https://open.feishu.cn"
            linkButton(t(lark ? "agent_bot_manage_link_lark" : "agent_bot_manage_link_feishu"),
                       help: t(lark ? "agent_bot_manage_tooltip_lark" : "agent_bot_manage_tooltip_feishu"),
                       url: "\(host)/app/\((e.appID ?? "").pathEscaped)")
        default:
            EmptyView()
        }
    }

    private func linkButton(_ title: String, help: String, url: String) -> some View {
        Button { open(url) } label: { Label(title, systemImage: "arrow.up.right.square").font(Theme.Font.caption) }
            .buttonStyle(.link)
            .foregroundStyle(.secondary)
            .help(help)
    }

    private var docsURL: String { ConnectionsChannelDocs.url(channel) }

    private func open(_ raw: String) {
        if let url = URL(string: raw) { openURL(url) }
    }

    private func askDisconnect(_ id: String) {
        confirm = ConnectionsConfirm(title: t("disconnect_confirm_title"), message: t("disconnect_confirm_description"),
                                     cancel: t("disconnect_confirm_cancel"), confirm: t("disconnect"), pending: t("disconnecting")) {
            do {
                let api = session.api, ws = session.workspace.id
                switch channel {
                case .lark: try await api.deleteLarkInstallation(workspaceId: ws, installationId: id)
                case .slack: try await api.deleteSlackInstallation(workspaceId: ws, installationId: id)
                case .dingtalk: try await api.deleteDingTalkInstallation(workspaceId: ws, installationId: id)
                case .wecom: try await api.deleteWecomInstallation(workspaceId: ws, installationId: id)
                case .telegram: try await api.deleteTelegramInstallation(workspaceId: ws, installationId: id)
                }
                await model.load(channel, session)
                toaster.success(t("toast_disconnected"))
                return true
            } catch {
                toaster.error((error as? APIError)?.message ?? t("toast_disconnect_failed"))
                return false
            }
        }
    }
}

enum ConnectionsChannelDocs {
    /// Docs pages use `/<lang>/` prefixes; English has none.
    static func url(_ channel: ConnectionsChannel) -> String {
        let lang = L10n.shared.language
        let prefix = lang.hasPrefix("zh") ? "/zh" : lang.hasPrefix("ja") ? "/ja" : lang.hasPrefix("ko") ? "/ko" : lang.hasPrefix("fr") ? "/fr" : ""
        return "https://multica.ai/docs\(prefix)/\(channel.rawValue)-bot-integration"
    }
}

/// Bring-your-own-bot credential dialogs (Slack tokens, DingTalk app key,
/// WeCom bot id + secret, Telegram bot token).
private struct ConnectionsChannelBYODialog: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let channel: ConnectionsChannel
    let agentID: String
    let onDone: () -> Void
    @State private var first = ""
    @State private var second = ""
    @State private var third = ""
    @State private var submitting = false

    private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
        tr("settings", "\(channel.rawValue).\(key)", args)
    }

    private var canSubmit: Bool {
        guard !submitting, !first.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return channel == .telegram || !second.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(channel == .telegram ? t("connect_dialog_title") : t("byo_dialog_title")).font(.system(size: 15, weight: .semibold))
            if channel == .telegram {
                Text(t("connect_dialog_description")).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if channel != .wecom {
                Button { if let url = URL(string: ConnectionsChannelDocs.url(channel)) { openURL(url) } } label: {
                    Label(channel == .telegram ? t("connect_docs_link") : t("byo_docs_link"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
            }
            fields
            HStack {
                Spacer()
                Button(channel == .telegram ? t("connect_cancel") : t("byo_cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(submitting)
                Button(submitLabel) { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(submitting)
    }

    private var submitLabel: String {
        if channel == .telegram { return submitting ? t("connect_submitting") : t("connect_submit") }
        return submitting ? t("byo_submitting") : t("byo_submit")
    }

    @ViewBuilder private var fields: some View {
        switch channel {
        case .slack:
            ConnectionsField(label: t("byo_bot_token_label")) {
                TextField("xoxb-…", text: $first).textFieldStyle(.roundedBorder).autocorrectionDisabled().disabled(submitting)
            }
            ConnectionsField(label: t("byo_app_token_label")) {
                TextField("xapp-…", text: $second).textFieldStyle(.roundedBorder).autocorrectionDisabled().disabled(submitting)
            }
        case .dingtalk:
            ConnectionsField(label: t("byo_appkey_label")) {
                SecureField("", text: $first).textFieldStyle(.roundedBorder).disabled(submitting)
            }
            ConnectionsField(label: t("byo_appsecret_label")) {
                SecureField("", text: $second).textFieldStyle(.roundedBorder).disabled(submitting)
            }
        case .wecom:
            ConnectionsField(label: t("byo_bot_id_label")) {
                TextField(t("byo_bot_id_placeholder"), text: $first).textFieldStyle(.roundedBorder).autocorrectionDisabled().disabled(submitting)
            }
            ConnectionsField(label: t("byo_secret_label")) {
                SecureField(t("byo_secret_placeholder"), text: $second).textFieldStyle(.roundedBorder).disabled(submitting)
            }
            ConnectionsField(label: t("byo_bot_name_label"), hint: t("byo_bot_name_hint")) {
                TextField(t("byo_bot_name_placeholder"), text: $third).textFieldStyle(.roundedBorder).disabled(submitting)
            }
        case .telegram:
            ConnectionsField(label: t("bot_token_label")) {
                SecureField("123456789:AA…", text: $first).textFieldStyle(.roundedBorder).disabled(submitting)
            }
        case .lark:
            EmptyView()
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        let a = first.trimmingCharacters(in: .whitespaces)
        let b = second.trimmingCharacters(in: .whitespaces)
        let c = third.trimmingCharacters(in: .whitespaces)
        let api = session.api, ws = session.workspace.id
        submitting = true
        defer { submitting = false }
        do {
            switch channel {
            case .slack:
                _ = try await api.registerSlackBYO(workspaceId: ws, agentId: agentID, RegisterSlackBYORequest(botToken: a, appToken: b))
            case .dingtalk:
                _ = try await api.registerDingTalkBYO(workspaceId: ws, agentId: agentID, RegisterDingTalkBYORequest(clientId: a, clientSecret: b))
            case .wecom:
                _ = try await api.registerWecomBYO(workspaceId: ws, agentId: agentID, RegisterWecomBYORequest(botId: a, secret: b, botName: c.isEmpty ? nil : c))
            case .telegram:
                let inst = try await api.registerTelegramBot(workspaceId: ws, agentId: agentID, RegisterTelegramRequest(botToken: a))
                guard !inst.id.isEmpty, inst.status == "active" else {
                    throw APIError(status: 0, message: "Telegram connection returned an invalid installation")
                }
            case .lark:
                return
            }
            toaster.success(channel == .telegram ? t("connect_success_toast") : t("byo_success_toast"))
            onDone()
            dismiss()
        } catch {
            toaster.error(localizedError(error))
        }
    }

    private func localizedError(_ error: Error) -> String {
        let e = error as? APIError
        if channel == .wecom {
            let key: String? = switch e?.code {
            case "wecom_bot_owned_by_same_workspace": "byo_conflict_same_workspace"
            case "wecom_bot_owned_by_archived_agent": "byo_conflict_archived_agent"
            case "wecom_bot_owned_by_another_workspace": "byo_conflict_other_workspace"
            case "wecom_install_rejected": "byo_rejected"
            case "wecom_credentials_rejected": "byo_credentials_rejected"
            case "wecom_credentials_unverifiable": "byo_credentials_unverifiable"
            case "wecom_install_failed": "byo_install_failed"
            default: nil
            }
            if let key { return t(key) }
        }
        if let message = e?.message ?? (error as NSError?)?.localizedDescription, !message.isEmpty { return message }
        return channel == .telegram ? t("connect_failed_toast") : t("byo_failed_toast")
    }
}

/// Feishu / Lark device-flow install: begin → QR → poll until success,
/// error or expiry; retry always starts a fresh session.
private struct ConnectionsLarkInstallDialog: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let agentID: String
    let agentName: String?
    let region: String
    let onInstalled: () -> Void

    @State private var installSession: BeginLarkInstallResponse?
    @State private var status = "pending"
    @State private var errorReason: String?
    @State private var errorMessage: String?
    @State private var beginning = false
    @State private var attempt = 0

    private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
        tr("settings", "lark.\(key)", args)
    }

    private var lark: Bool { region == "lark" }

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t(lark ? "install_dialog_title_lark" : "install_dialog_title_feishu")).font(.system(size: 15, weight: .semibold))
                Text(agentName.map { t(lark ? "install_dialog_description_for_agent_lark" : "install_dialog_description_for_agent_feishu", ["agent": $0]) }
                     ?? t(lark ? "install_dialog_description_lark" : "install_dialog_description_feishu"))
                    .font(Theme.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 12) {
                if beginning && installSession == nil {
                    Text(t("install_starting")).font(Theme.Font.body).foregroundStyle(.secondary)
                }
                if let s = installSession, status == "pending" {
                    if let image = Self.qrImage(s.qrCodeUrl) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 192, height: 192)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                    }
                    Button(t(lark ? "install_open_link_fallback_lark" : "install_open_link_fallback_feishu")) {
                        if let url = URL(string: s.qrCodeUrl) { openURL(url) }
                    }
                    .buttonStyle(.link)
                    .font(Theme.Font.caption)
                }
                if status == "success" {
                    Text(t("install_success")).font(Theme.Font.bodyMedium)
                }
                if status == "error" {
                    VStack(spacing: 6) {
                        Text(errorText).font(Theme.Font.bodyMedium).foregroundStyle(Theme.destructive).multilineTextAlignment(.center)
                        if let errorMessage, !errorMessage.isEmpty {
                            Text(errorMessage).font(Theme.Font.micro).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            HStack {
                Spacer()
                Button(t("install_close")) { dismiss() }.keyboardShortcut(.cancelAction)
                if status == "error" {
                    Button { attempt += 1 } label: { Label(t("install_retry"), systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderedProminent)
                        .disabled(beginning)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
        .task(id: attempt) { await run() }
    }

    private var errorText: String {
        switch errorReason {
        case "expired": return t("install_error_expired")
        case "access_denied": return t("install_error_access_denied")
        case "lark_protocol_error": return t("install_error_protocol")
        case "bot_info_failed": return t("install_error_bot_info")
        case "installation_conflict": return t("install_error_conflict")
        case "installer_bind_failed": return t("install_error_installer_bind")
        case "session_lost": return t("install_error_session_lost")
        case "forbidden": return t("install_error_forbidden")
        default: return t("install_error_generic")
        }
    }

    private func run() async {
        beginning = true
        status = "pending"
        errorReason = nil
        errorMessage = nil
        installSession = nil
        let api = session.api, ws = session.workspace.id
        let s: BeginLarkInstallResponse
        do {
            s = try await api.beginLarkInstall(workspaceId: ws, agentId: agentID, region: region)
            installSession = s
            beginning = false
        } catch {
            beginning = false
            guard !Task.isCancelled else { return }
            status = "error"
            errorReason = "internal_error"
            errorMessage = (error as? APIError)?.message ?? error.localizedDescription
            return
        }
        let interval = max(2, s.pollIntervalSeconds)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            do {
                let r = try await api.getLarkInstallStatus(workspaceId: ws, sessionId: s.sessionId)
                status = r.status
                if r.status == "success" {
                    onInstalled()
                    toaster.success(t(lark ? "install_success_toast_lark" : "install_success_toast_feishu"))
                    try? await Task.sleep(for: .milliseconds(800))
                    if !Task.isCancelled { dismiss() }
                    return
                }
                if r.status == "error" {
                    errorReason = r.errorReason ?? "internal_error"
                    errorMessage = r.errorMessage
                    return
                }
            } catch let e as APIError where e.status == 404 {
                status = "error"
                errorReason = "session_lost"
                errorMessage = e.message
                return
            } catch let e as APIError where e.status == 403 || e.status == 401 {
                status = "error"
                errorReason = "forbidden"
                errorMessage = e.message
                return
            } catch {
                toaster.show("\(t("install_poll_retry")) — \((error as? APIError)?.message ?? error.localizedDescription)")
            }
        }
    }

    private static func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
