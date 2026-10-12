import AppKit
import MulticaCore
import SwiftUI

/// Self-hosted Forgejo / Gitea / GitLab connections as rows of the Code
/// hosting card (upstream code-vcs.tsx). Connecting and rotating both end on
/// the one-time webhook secret.
struct ConnectionsVCSRows: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @State private var data: ListVCSConnectionsResponse?
    @State private var connectOpen = false
    @State private var webhook: ConnectVCSResponse?
    @State private var confirm: ConnectionsConfirm?

    static let providers = ["forgejo", "gitea", "gitlab"]
    static func providerLabel(_ p: String) -> String {
        switch p {
        case "forgejo": return "Forgejo"
        case "gitea": return "Gitea"
        case "gitlab": return "GitLab"
        default: return p
        }
    }

    private var connections: [VCSConnection] { data?.connections ?? [] }
    private var configured: Bool { data?.configured == true }
    private var canManage: Bool { data?.canManage == true }

    var body: some View {
        Group {
            ForEach(connections) { c in
                Divider()
                ConnectionsRow(label: {
                    HStack(spacing: 12) {
                        ConnectionsHostMark { Image(systemName: "arrow.triangle.branch").font(.system(size: 13)) }
                        HStack(spacing: 8) {
                            Text("\(Self.providerLabel(c.provider)) · \(c.instanceUrl)").lineLimit(2)
                            ConnectionsHostStatus(connected: true, label: tr("settings", "integrations.status_connected"))
                        }
                    }
                }, descriptionView: AnyView(Text(tr("settings", "vcs.connected_as", ["login": c.accountLogin]))
                    .font(Theme.Font.caption).foregroundStyle(.secondary).padding(.leading, 48))) {
                    if canManage {
                        Menu {
                            Button { askRotate(c.id) } label: { Label(tr("settings", "vcs.regenerate_webhook"), systemImage: "arrow.clockwise") }
                            Divider()
                            Button(role: .destructive) { askDelete(c.id) } label: { Label(tr("settings", "vcs.disconnect"), systemImage: "powerplug") }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(tr("settings", "vcs.connection_actions", ["url": c.instanceUrl]))
                    }
                }
            }
            if canManage || connections.isEmpty {
                Divider()
                ConnectionsRow(label: {
                    HStack(spacing: 12) {
                        ConnectionsHostMark { Image(systemName: "folder.badge.gearshape").font(.system(size: 13)) }
                        HStack(spacing: 8) {
                            Text(tr("settings", "vcs.section_title"))
                            if connections.isEmpty {
                                ConnectionsHostStatus(connected: false, label: tr("settings", "integrations.status_not_connected"))
                            }
                        }
                    }
                }, descriptionView: connectDetail.map { AnyView($0.font(Theme.Font.caption).foregroundStyle(.secondary).padding(.leading, 48)) }) {
                    if canManage {
                        Button(tr("settings", connections.isEmpty ? "vcs.connect" : "vcs.connect_another")) { connectOpen = true }
                            .controlSize(.small)
                            .disabled(!configured)
                    }
                }
            }
        }
        .task(id: session.revision("vcs_connection")) { await load() }
        .sheet(isPresented: $connectOpen) {
            ConnectionsVCSConnectDialog { provider, url, token in
                do {
                    let r = try await session.api.connectVCS(workspaceId: session.workspace.id,
                                                             ConnectVCSRequest(provider: provider, instanceUrl: url, accessToken: token))
                    await load()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        webhook = r
                    }
                    return true
                } catch {
                    toaster.error((error as? APIError)?.message ?? tr("settings", "vcs.toast_connect_failed"))
                    return false
                }
            }
        }
        .sheet(item: Binding(get: { webhook.map(ConnectionsWebhookBox.init) }, set: { webhook = $0?.value })) { box in
            ConnectionsWebhookDialog(webhook: box.value)
        }
        .connectionsConfirm($confirm)
    }

    private var connectDetail: Text? {
        if !canManage { return connections.isEmpty ? Text(tr("settings", "vcs.contact_admin")) : nil }
        if !configured { return Text(tr("settings", "vcs.not_configured")) + Text(" ") + connectionsCode("MULTICA_VCS_SECRET_KEY") }
        return Text(tr("settings", "vcs.hosts_hint"))
    }

    private func load() async {
        if let d = try? await session.api.listVCSConnections(workspaceId: session.workspace.id) { data = d }
    }

    private func askRotate(_ id: String) {
        confirm = ConnectionsConfirm(
            title: tr("settings", "vcs.rotate_confirm_title"),
            message: tr("settings", "vcs.rotate_confirm_description"),
            cancel: tr("settings", "vcs.rotate_confirm_cancel"),
            confirm: tr("settings", "vcs.rotate_confirm_action"),
            pending: tr("settings", "vcs.rotating")) {
                do {
                    let r = try await session.api.rotateVCSWebhook(workspaceId: session.workspace.id, connectionId: id)
                    await load()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        webhook = r
                    }
                    return true
                } catch {
                    toaster.error((error as? APIError)?.message ?? tr("settings", "vcs.toast_rotate_failed"))
                    return false
                }
            }
    }

    private func askDelete(_ id: String) {
        confirm = ConnectionsConfirm(
            title: tr("settings", "vcs.disconnect_confirm_title"),
            message: tr("settings", "vcs.disconnect_confirm_description"),
            cancel: tr("settings", "vcs.disconnect_confirm_cancel"),
            confirm: tr("settings", "vcs.disconnect_confirm_action"),
            pending: tr("settings", "vcs.disconnecting"),
            destructive: true) {
                do {
                    try await session.api.deleteVCSConnection(workspaceId: session.workspace.id, connectionId: id)
                    await load()
                    toaster.success(tr("settings", "vcs.toast_disconnected"))
                    return true
                } catch {
                    toaster.error((error as? APIError)?.message ?? tr("settings", "vcs.toast_disconnect_failed"))
                    return false
                }
            }
    }
}

private struct ConnectionsWebhookBox: Identifiable {
    var value: ConnectVCSResponse
    var id: String { value.id + value.webhookSecret }
}

private struct ConnectionsVCSConnectDialog: View {
    @Environment(\.dismiss) private var dismiss
    let onConnect: (String, String, String) async -> Bool
    @State private var provider = "forgejo"
    @State private var url = ""
    @State private var token = ""
    @State private var connecting = false

    private var canSubmit: Bool {
        !connecting && !url.trimmingCharacters(in: .whitespaces).isEmpty && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("settings", "vcs.connect_title")).font(.system(size: 15, weight: .semibold))
                Text(tr("settings", "vcs.page_description")).font(Theme.Font.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ConnectionsField(label: tr("settings", "vcs.form_provider_label")) {
                Picker("", selection: $provider) {
                    ForEach(ConnectionsVCSRows.providers, id: \.self) { Text(ConnectionsVCSRows.providerLabel($0)).tag($0) }
                }
                .labelsHidden()
                .disabled(connecting)
            }
            ConnectionsField(label: tr("settings", "vcs.form_instance_url_label")) {
                TextField("https://forgejo.example.com", text: $url).textFieldStyle(.roundedBorder).disabled(connecting)
            }
            ConnectionsField(label: tr("settings", "vcs.form_token_label"), hint: tr("settings", "vcs.form_token_hint")) {
                SecureField(tr("settings", "vcs.form_token_placeholder"), text: $token).textFieldStyle(.roundedBorder).disabled(connecting)
            }
            HStack {
                Spacer()
                Button(tr("settings", "vcs.disconnect_confirm_cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(connecting)
                Button(connecting ? tr("settings", "vcs.connecting") : tr("settings", "vcs.connect")) {
                    guard canSubmit else { return }
                    connecting = true
                    Task {
                        let ok = await onConnect(provider, url.trimmingCharacters(in: .whitespaces), token.trimmingCharacters(in: .whitespaces))
                        connecting = false
                        if ok { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(connecting)
    }
}

private struct ConnectionsWebhookDialog: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Toaster.self) private var toaster
    let webhook: ConnectVCSResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("settings", "vcs.webhook_setup_title")).font(.system(size: 15, weight: .semibold))
                Text(tr("settings", "vcs.webhook_setup_description")).font(Theme.Font.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            copyField(tr("settings", "vcs.webhook_url_label"), webhook.webhookUrl.isEmpty ? webhook.webhookPath : webhook.webhookUrl, mono: false)
            copyField(tr("settings", "vcs.webhook_secret_label"), webhook.webhookSecret, mono: true)
            Text(tr("settings", "vcs.webhook_secret_warning")).font(Theme.Font.caption).foregroundStyle(Theme.warning)
            HStack {
                Spacer()
                Button(tr("settings", "vcs.webhook_done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func copyField(_ label: String, _ value: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.Font.caption)
            HStack(spacing: 8) {
                Text(value)
                    .font(mono ? .system(size: 11, design: .monospaced) : Theme.Font.caption)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                Button {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(value, forType: .string) {
                        toaster.success(tr("settings", "vcs.copied"))
                    } else {
                        toaster.error(tr("settings", "vcs.copy_failed"))
                    }
                } label: { Image(systemName: "doc.on.doc") }
                    .help("\(tr("settings", "vcs.copy")): \(label)")
            }
        }
    }
}
