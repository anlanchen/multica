import MulticaCore
import SwiftUI

/// Settings › API Tokens (upstream tokens-tab.tsx): personal access tokens
/// for the CLI and API — create, list, revoke, and the show-once dialog.
struct SettingsTokensTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @State private var tokens: [PersonalAccessToken] = []
    @State private var loading = true
    @State private var loadFailed = false
    @State private var name = ""
    @State private var expiry = "90"
    @State private var creating = false
    @State private var created: SettingsCreatedToken?
    @State private var revoking: String?
    @State private var revokeConfirm: PersonalAccessToken?

    private static let expiries = ["30", "90", "365", "never"]

    var body: some View {
        SettingsTabView(title: tr("settings", "tokens.title"), description: tr("settings", "tokens.purpose"), scope: .account) {
            SettingsSectionView(description: tr("settings", "tokens.security_note")) {
                VStack(alignment: .leading, spacing: 12) {
                    DisclosureGroup {
                        Text(tr("settings", "tokens.description"))
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        Text(tr("settings", "tokens.usage_help")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }

                    SettingsCardView {
                        HStack(spacing: 12) {
                            TextField(tr("settings", "tokens.name_placeholder"), text: $name)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(create)
                            Picker("", selection: $expiry) {
                                ForEach(Self.expiries, id: \.self) { Text(tr("settings", "tokens.expiry.\($0)")).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                            .accessibilityLabel(tr("settings", "tokens.title"))
                            Button(creating ? tr("settings", "tokens.creating") : tr("settings", "tokens.create"), action: create)
                                .disabled(creating || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(16)
                    }

                    if loading {
                        ForEach(0..<2, id: \.self) { _ in
                            SettingsCardView {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)).frame(width: 128, height: 14)
                                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)).frame(width: 192, height: 10)
                                    }
                                    Spacer()
                                }
                                .padding(16)
                            }
                        }
                    } else if tokens.isEmpty {
                        SettingsCardView {
                            Text(loadFailed ? tr("settings", "tokens.load_failed") : tr("settings", "tokens.empty"))
                                .font(Theme.Font.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(tokens) { token in tokenCard(token) }
                        }
                    }
                }
            }
        }
        .task { await load() }
        .alert(tr("settings", "tokens.revoke_dialog.title"), isPresented: Binding(get: { revokeConfirm != nil }, set: { if !$0 { revokeConfirm = nil } }),
               presenting: revokeConfirm) { token in
            Button(tr("settings", "tokens.revoke_dialog.cancel"), role: .cancel) {}
            Button(tr("settings", "tokens.revoke_dialog.confirm"), role: .destructive) { revoke(token) }
        } message: { _ in
            Text(tr("settings", "tokens.revoke_dialog.description"))
        }
        .sheet(item: $created) { token in
            SettingsCreatedTokenSheet(token: token.value) { created = nil }
        }
    }

    private func tokenCard(_ token: PersonalAccessToken) -> some View {
        SettingsCardView {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(token.name).font(Theme.Font.bodyMedium).lineLimit(1)
                    Text(metadata(token)).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { revokeConfirm = token } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(revoking == token.id)
                    .help(tr("settings", "tokens.revoke_tooltip"))
                    .accessibilityLabel(tr("settings", "tokens.revoke_aria", ["name": token.name]))
            }
            .padding(16)
        }
    }

    private func metadata(_ token: PersonalAccessToken) -> String {
        let lastUsed = token.lastUsedAt.map { tr("settings", "tokens.last_used_with_date", ["date": SettingsDates.short($0)]) }
            ?? tr("settings", "tokens.last_used_never")
        var s = tr("settings", "tokens.metadata_prefix", ["prefix": token.tokenPrefix, "created": SettingsDates.short(token.createdAt), "lastUsed": lastUsed])
        if let expires = token.expiresAt { s += tr("settings", "tokens.expires_with_date", ["date": SettingsDates.short(expires)]) }
        return s
    }

    private func load() async {
        do {
            tokens = try await session.api.listPersonalAccessTokens()
            loadFailed = false
        } catch {
            loadFailed = true
            toaster.show((error as? APIError)?.message ?? tr("settings", "tokens.toast_load_failed"), kind: .error)
        }
        loading = false
    }

    private func create() {
        guard !creating, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        creating = true
        Task {
            defer { creating = false }
            do {
                let result = try await session.api.createPersonalAccessToken(
                    CreatePersonalAccessTokenRequest(name: name, expiresInDays: expiry == "never" ? nil : Int(expiry)))
                created = SettingsCreatedToken(value: result.token)
                name = ""
                expiry = "90"
                await load()
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("settings", "tokens.toast_create_failed"), kind: .error)
            }
        }
    }

    private func revoke(_ token: PersonalAccessToken) {
        revoking = token.id
        Task {
            defer { revoking = nil }
            do {
                try await session.api.revokePersonalAccessToken(token.id)
                await load()
                toaster.success(tr("settings", "tokens.toast_revoked"))
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("settings", "tokens.toast_revoke_failed"), kind: .error)
            }
        }
    }
}

private struct SettingsCreatedToken: Identifiable {
    let id = UUID()
    let value: String
}

/// The token, shown exactly once, with the CLI sign-in command.
private struct SettingsCreatedTokenSheet: View {
    let token: String
    let onDone: () -> Void
    @State private var stored = false

    var body: some View {
        SettingsDialog(title: tr("settings", "tokens.created_dialog.title"), width: 576) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    (Text(tr("settings", "tokens.created_dialog.warning_prefix"))
                        + Text(tr("settings", "tokens.created_dialog.warning_emphasis")).fontWeight(.medium).foregroundColor(.primary)
                        + Text(tr("settings", "tokens.created_dialog.warning_suffix")))
                        .font(Theme.Font.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                codeRow(token, copyHelp: tr("settings", "tokens.created_dialog.copy_tooltip"))
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("settings", "tokens.created_dialog.cli_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    codeRow("multica login --token \(token)", copyHelp: tr("settings", "tokens.created_dialog.copy_command_tooltip"))
                }
            }
        } footer: {
            Toggle(tr("settings", "tokens.created_dialog.confirm_stored"), isOn: $stored).toggleStyle(.checkbox)
            Spacer()
            Button(tr("settings", "tokens.created_dialog.done"), action: onDone)
                .keyboardShortcut(.defaultAction)
                .disabled(!stored)
        }
    }

    private func codeRow(_ text: String, copyHelp: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(Theme.Font.mono)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
            CopyButton(text: text)
                .help(copyHelp)
        }
    }
}
