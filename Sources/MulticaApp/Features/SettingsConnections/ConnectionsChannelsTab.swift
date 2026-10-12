import MulticaCore
import SwiftUI

enum ConnectionsChannel: String, CaseIterable, Identifiable {
    case lark, slack, dingtalk, wecom, telegram

    var id: String { rawValue }
    var label: String { tr("settings", "\(rawValue).section_title") }
    var description: String { tr("settings", "\(rawValue).page_description") }

    var brand: ConnectionsBrand {
        switch self {
        case .lark: return .lark
        case .slack: return .slack
        case .dingtalk: return .dingtalk
        case .wecom: return .wecom
        case .telegram: return .telegram
        }
    }

    var markSize: CGFloat { self == .dingtalk ? 20 : 16 }
    var revisionKey: String { "\(rawValue)_installation" }
}

enum ConnectionsLoad<Value> {
    case pending
    case failed
    case loaded(Value)

    var value: Value? {
        if case .loaded(let v) = self { return v }
        return nil
    }
}

/// Installation listings for every channel, shared by the directory and
/// the detail pages (upstream reuses one query cache per channel).
@MainActor
@Observable
final class ConnectionsChannelsModel {
    var lark: ConnectionsLoad<ListLarkInstallationsResponse> = .pending
    var slack: ConnectionsLoad<ListSlackInstallationsResponse> = .pending
    var dingtalk: ConnectionsLoad<ListDingTalkInstallationsResponse> = .pending
    var wecom: ConnectionsLoad<ListWecomInstallationsResponse> = .pending
    var telegram: ConnectionsLoad<ListTelegramInstallationsResponse> = .pending

    func load(_ channel: ConnectionsChannel, _ session: WorkspaceSession) async {
        let api = session.api
        let ws = session.workspace.id
        switch channel {
        case .lark: lark = await Self.fetch(previous: lark) { try await api.listLarkInstallations(workspaceId: ws) }
        case .slack: slack = await Self.fetch(previous: slack) { try await api.listSlackInstallations(workspaceId: ws) }
        case .dingtalk: dingtalk = await Self.fetch(previous: dingtalk) { try await api.listDingTalkInstallations(workspaceId: ws) }
        case .wecom: wecom = await Self.fetch(previous: wecom) { try await api.listWecomInstallations(workspaceId: ws) }
        case .telegram: telegram = await Self.fetch(previous: telegram) { try await api.listTelegramInstallations(workspaceId: ws) }
        }
    }

    /// A failed refetch keeps the last good listing.
    private static func fetch<T>(previous: ConnectionsLoad<T>, _ op: () async throws -> T) async -> ConnectionsLoad<T> {
        do { return .loaded(try await op()) } catch { return previous.value.map { .loaded($0) } ?? .failed }
    }

    /// nil while pending, or after a failure (never reported as disconnected).
    func connected(_ channel: ConnectionsChannel) -> ConnectionsLoad<Bool> {
        func map<T>(_ l: ConnectionsLoad<T>, _ statuses: (T) -> [String]) -> ConnectionsLoad<Bool> {
            switch l {
            case .pending: return .pending
            case .failed: return .failed
            case .loaded(let v): return .loaded(ConnectionsChannels.hasActive(statuses(v)))
            }
        }
        switch channel {
        case .lark: return map(lark) { $0.installations.map(\.status) }
        case .slack: return map(slack) { $0.installations.map(\.status) }
        case .dingtalk: return map(dingtalk) { $0.installations.map(\.status) }
        case .wecom: return map(wecom) { $0.installations.map(\.status) }
        case .telegram: return map(telegram) { $0.installations.map(\.status) }
        }
    }
}

/// Settings › Messaging: a directory of the chat apps agents can be reached
/// from, each opening its own detail page (upstream channels-tab.tsx).
struct ConnectionsChannelsTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @State private var model = ConnectionsChannelsModel()

    private var selected: ConnectionsChannel? {
        if let i = nav.query("integration").flatMap(ConnectionsChannel.init(rawValue:)) { return i }
        return nav.query("tab").flatMap(ConnectionsChannel.init(rawValue:))
    }

    var body: some View {
        Group {
            if let channel = selected {
                ConnectionsSettingsPage(title: channel.label, description: channel.description, scope: .workspace,
                                        breadcrumb: AnyView(breadcrumb(channel))) {
                    switch channel {
                    case .dingtalk: ConnectionsDingTalkDetail(model: model)
                    default: ConnectionsChannelDetail(channel: channel, model: model)
                    }
                }
            } else {
                ConnectionsSettingsPage(title: tr("settings", "page.tabs.channels"), scope: .workspace) {
                    ConnectionsCard {
                        ForEach(ConnectionsChannel.allCases) { channel in
                            if channel != .lark { Divider() }
                            directoryRow(channel)
                        }
                    }
                }
            }
        }
        .task(id: session.revision("lark_installation")) { await model.load(.lark, session) }
        .task(id: session.revision("slack_installation")) { await model.load(.slack, session) }
        .task(id: session.revision("dingtalk_installation")) { await model.load(.dingtalk, session) }
        .task(id: session.revision("wecom_installation")) { await model.load(.wecom, session) }
        .task(id: session.revision("telegram_installation")) { await model.load(.telegram, session) }
    }

    private func open(_ channel: ConnectionsChannel?) {
        var query = ["tab": "channels"]
        if let channel { query["integration"] = channel.rawValue }
        nav.push(.settings, query: query)
    }

    private func breadcrumb(_ channel: ConnectionsChannel) -> some View {
        HStack(spacing: 6) {
            Button(tr("settings", "page.tabs.channels")) { open(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            Text(channel.label)
        }
        .font(Theme.Font.caption)
        .accessibilityLabel(tr("settings", "channels.breadcrumb"))
    }

    private func directoryRow(_ channel: ConnectionsChannel) -> some View {
        Button { open(channel) } label: {
            HStack(spacing: 16) {
                ConnectionsHostMark(size: 40) {
                    ConnectionsBrandMark(brand: channel.brand, size: channel.markSize).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Text(channel.label).font(Theme.Font.bodyMedium)
                        ConnectionsConnectionBadge(state: model.connected(channel))
                    }
                    Text(channel.description).font(Theme.Font.caption).foregroundStyle(.secondary).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 0)
    }
}

struct ConnectionsConnectionBadge: View {
    let state: ConnectionsLoad<Bool>

    var body: some View {
        let connected = state.value == true
        let label: String = switch state {
        case .failed: tr("settings", "integrations.status_unknown")
        case .pending: tr("settings", "integrations.status_loading")
        case .loaded(let v): tr("settings", v ? "integrations.status_connected" : "integrations.status_not_connected")
        }
        ConnectionsHostStatus(connected: connected, label: label)
    }
}

/// One bot row for the Slack / Lark / WeCom / Telegram listings.
private struct ConnectionsBotRow: Identifiable {
    var id: String
    var agentID: String
    var active: Bool
    var badge: String?
    var suffix: String?
    var meta: String
}

/// Slack, Lark, WeCom and Telegram share one listing shape: a not-enabled
/// card, a "coming soon" card while install is unwired, else connected bots.
private struct ConnectionsChannelDetail: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let channel: ConnectionsChannel
    let model: ConnectionsChannelsModel
    @State private var confirm: ConnectionsConfirm?

    private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
        tr("settings", "\(channel.rawValue).\(key)", args)
    }

    private static func installedAt(_ raw: String) -> String {
        guard let d = Timestamp.parse(raw) else { return raw }
        return d.formatted(date: .numeric, time: .standard)
    }

    private struct Listing {
        var configured: Bool
        var installSupported: Bool
        var rows: [ConnectionsBotRow]
    }

    private var listing: ConnectionsLoad<Listing> {
        func wrap<T>(_ l: ConnectionsLoad<T>, _ f: (T) -> Listing) -> ConnectionsLoad<Listing> {
            switch l {
            case .pending: return .pending
            case .failed: return .failed
            case .loaded(let v): return .loaded(f(v))
            }
        }
        switch channel {
        case .lark:
            return wrap(model.lark) { r in
                Listing(configured: r.configured, installSupported: r.installSupported == true, rows: r.installations.map { i in
                    ConnectionsBotRow(id: i.id, agentID: i.agentId, active: i.status == "active",
                                      badge: t(i.region == "lark" ? "region_lark" : "region_feishu"), suffix: nil,
                                      meta: t("installed_at_label", ["when": Self.installedAt(i.installedAt)]))
                })
            }
        case .slack:
            return wrap(model.slack) { r in
                Listing(configured: r.configured, installSupported: r.installSupported == true, rows: r.installations.map { i in
                    ConnectionsBotRow(id: i.id, agentID: i.agentId, active: i.status == "active", badge: nil, suffix: nil,
                                      meta: t("installed_at_label", ["when": Self.installedAt(i.installedAt)]))
                })
            }
        case .wecom:
            return wrap(model.wecom) { r in
                Listing(configured: r.configured, installSupported: r.installSupported == true, rows: r.installations.map { i in
                    ConnectionsBotRow(id: i.id, agentID: i.agentId, active: i.status == "active", badge: nil, suffix: nil,
                                      meta: t("bot_id_label", ["botId": i.botId]))
                })
            }
        case .telegram:
            return wrap(model.telegram) { r in
                Listing(configured: r.configured, installSupported: true, rows: r.installations.map { i in
                    ConnectionsBotRow(id: i.id, agentID: i.agentId, active: i.status == "active", badge: nil,
                                      suffix: i.botUsername.isEmpty ? nil : "@\(i.botUsername)",
                                      meta: t("installed_at_label", ["when": Self.installedAt(i.installedAt)]))
                })
            }
        case .dingtalk:
            return .pending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            switch listing {
            case .failed where channel == .telegram:
                ConnectionsCard { Text(t("load_failed")).font(Theme.Font.body).foregroundStyle(.secondary).padding(16) }
            case .pending where channel == .telegram:
                ConnectionsCard { Text(t("loading")).font(Theme.Font.body).foregroundStyle(.secondary).padding(16) }
            case .failed:
                notEnabled
            case .loaded(let l) where !l.configured:
                notEnabled
            case .loaded(let l) where !l.installSupported && l.rows.isEmpty:
                ConnectionsMessageCard(title: t("preview_title"), message: t("preview_description"))
            default:
                VStack(alignment: .leading, spacing: 12) {
                    Text(t("connected_bots")).font(.system(size: 13, weight: .semibold))
                    switch listing {
                    case .loaded(let l) where l.rows.isEmpty:
                        ConnectionsMessageCard(title: t("empty_title"), messageView: AnyView(emptyDescription))
                    case .loaded(let l):
                        ConnectionsCard {
                            ForEach(l.rows) { row in
                                if row.id != l.rows.first?.id { Divider() }
                                botRow(row)
                            }
                        }
                    default:
                        ConnectionsCard { Text(t("loading")).font(Theme.Font.body).foregroundStyle(.secondary).padding(16) }
                    }
                }
            }
        }
        .connectionsConfirm($confirm)
    }

    private var notEnabled: some View {
        let key = "MULTICA_\(channel.rawValue.uppercased())_SECRET_KEY"
        return ConnectionsMessageCard(title: t("not_enabled_title"), messageView: AnyView(
            (Text(t("not_enabled_description_prefix")) + Text(" ") + connectionsCode(key) + Text(" ")
             + Text(t("not_enabled_description_suffix")) + Text(" ") + Text(t("not_enabled_self_host_hint")))
                .font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)))
    }

    private var emptyDescription: some View {
        (Text(t("empty_description_prefix")) + Text(" ") + Text(t("empty_description_cta")).fontWeight(.semibold)
         + Text(" ") + Text(t("empty_description_suffix")))
            .font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func botRow(_ row: ConnectionsBotRow) -> some View {
        HStack(alignment: .top, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ConnectionsAgentIdentity(agentID: row.agentID)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(session.actorInfo(type: "agent", id: row.agentID).name).font(Theme.Font.bodyMedium)
                        if let suffix = row.suffix { Text(suffix).font(Theme.Font.caption).foregroundStyle(.secondary) }
                        if let badge = row.badge { ConnectionsChip(text: badge) }
                        if !row.active { ConnectionsChip(text: t("revoked_badge")) }
                    }
                    Text(row.meta).font(Theme.Font.micro).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if session.connectionsIsManager && row.active {
                Button { askDisconnect(row.id) } label: { Label(t("disconnect"), systemImage: "trash") }
                    .controlSize(.small)
            }
        }
        .padding(16)
    }

    private func askDisconnect(_ id: String) {
        confirm = ConnectionsConfirm(title: t("disconnect_confirm_title"), message: t("disconnect_confirm_description"),
                                     cancel: t("disconnect_confirm_cancel"), confirm: t("disconnect"), pending: t("disconnecting")) {
            do {
                let api = session.api, ws = session.workspace.id
                switch channel {
                case .lark: try await api.deleteLarkInstallation(workspaceId: ws, installationId: id)
                case .slack: try await api.deleteSlackInstallation(workspaceId: ws, installationId: id)
                case .wecom: try await api.deleteWecomInstallation(workspaceId: ws, installationId: id)
                case .telegram: try await api.deleteTelegramInstallation(workspaceId: ws, installationId: id)
                case .dingtalk: try await api.deleteDingTalkInstallation(workspaceId: ws, installationId: id)
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

/// Small muted tag (region, revoked).
struct ConnectionsChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.micro)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
    }
}
