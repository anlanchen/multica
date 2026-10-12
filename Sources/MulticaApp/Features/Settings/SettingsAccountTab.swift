import MulticaCore
import SwiftUI

private struct SettingsProfileDraft: Equatable {
    var name: String
    var about: String
}

/// Settings › Profile (upstream account-tab.tsx): avatar, name and the
/// "About you" text included in runs, auto-saved.
struct SettingsAccountTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster
    @State private var record: UserRecord?
    @State private var name = ""
    @State private var about = ""
    @State private var autoSave: SettingsAutoSave<SettingsProfileDraft>?
    @FocusState private var focused: Bool?

    private var draft: SettingsProfileDraft { SettingsProfileDraft(name: name, about: about) }
    private var saved: SettingsProfileDraft { SettingsProfileDraft(name: record?.name ?? "", about: record?.profileDescription ?? "") }
    private var tooLong: Bool { about.utf16.count > SettingsRules.maxProfileDescription }
    private var canSave: Bool { record != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty && !tooLong }

    var body: some View {
        let user = env.app.user
        SettingsTabView(title: tr("settings", "page.tabs.profile"), scope: .account) {
            SettingsSectionView(title: tr("settings", "account.section_profile"), action: {
                SettingsSaveStateView(status: autoSave?.status ?? .idle)
            }) {
                SettingsCardView {
                    SettingsRowView(tr("settings", "account.avatar_label"), description: tr("settings", "account.click_avatar_hint"),
                                    size: SettingsControlSize.none, anchor: "avatar") {
                        SettingsAvatarUploadControl(value: record?.avatarUrl ?? user?.avatarURL, kind: .member, name: user?.name ?? "") { url in
                            await saveAvatar(url)
                        }
                    }
                    SettingsRowView(tr("settings", "account.name_label"), size: .text, anchor: "name") {
                        TextField("", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.name)
                            .focused($focused, equals: true)
                            .onSubmit { autoSave?.flush() }
                            .accessibilityLabel(tr("settings", "account.name_label"))
                    }
                    SettingsRowView(label: tr("settings", "account.profile_description_label"), size: .text, align: .top, anchor: "about",
                                    description: { Text(tr("settings", "account.profile_description_hint")) }) {
                        VStack(alignment: .trailing, spacing: 4) {
                            SettingsTextArea(text: $about, placeholder: tr("settings", "account.profile_description_placeholder"),
                                             minHeight: 100, invalid: tooLong)
                                .focused($focused, equals: false)
                            Text("\(about.utf16.count)/\(SettingsRules.maxProfileDescription)")
                                .font(Theme.Font.caption)
                                .foregroundStyle(tooLong ? Theme.destructive : .secondary)
                                .monospacedDigit()
                            if tooLong {
                                Text(tr("settings", "account.profile_description_too_long",
                                        ["max": SettingsRules.maxProfileDescription, "count": about.utf16.count]))
                                    .font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .task(id: session.currentUser.id) { await load() }
        .onChange(of: draft) { feed() }
        .onChange(of: record) { autoSave?.setSaved(saved) }
        .onChange(of: about) { old, new in
            if new.utf16.count > SettingsRules.maxProfileDescription && old.utf16.count <= SettingsRules.maxProfileDescription { about = old }
        }
        .onChange(of: focused) { old, new in
            if old != nil && new != old { autoSave?.flush() }
        }
        .onDisappear { autoSave?.flush() }
    }

    private func load() async {
        if autoSave == nil {
            name = env.app.user?.name ?? ""
            let api = session.api
            autoSave = SettingsAutoSave(initial: SettingsProfileDraft(name: name, about: ""), save: { next in
                let updated = try await api.updateMe(UpdateMeRequest(name: next.name, profileDescription: next.about))
                record = updated
                env.settingsAdopt(updated)
            }, onError: { error in
                toaster.show((error as? APIError)?.message ?? tr("settings", "account.toast_profile_failed"), kind: .error)
            })
        }
        do {
            let me = try await session.api.getMe()
            let first = record == nil
            if first {
                name = me.name
                about = me.profileDescription
            }
            record = me
            autoSave?.setSaved(saved)
        } catch {
            toaster.error(error)
        }
    }

    private func feed() {
        autoSave?.update(value: draft, enabled: canSave)
    }

    private func saveAvatar(_ url: String) async -> Bool {
        do {
            let updated = try await session.api.updateMe(UpdateMeRequest(avatarUrl: url))
            record = updated
            env.settingsAdopt(updated)
            return true
        } catch {
            toaster.show((error as? APIError)?.message ?? tr("settings", "account.toast_avatar_failed"), kind: .error)
            return false
        }
    }
}
