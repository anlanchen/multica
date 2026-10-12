import MulticaCore
import SwiftUI

/// Settings › Preferences (upstream preferences-tab.tsx). Settings stored on
/// the account (language, time zone), this device (theme, composer, chat,
/// issue opening) and this device per workspace (create-dialog fields), each
/// section badged with its scope.
struct SettingsPreferencesTab: View {
    var body: some View {
        SettingsTabView(title: tr("settings", "page.tabs.preferences")) {
            SettingsSectionView(title: tr("settings", "preferences.region_title"), scope: .account, anchor: "region") {
                SettingsCardView {
                    SettingsLanguageRow()
                    SettingsTimezoneRow()
                }
            }
            SettingsSectionView(title: tr("settings", "preferences.appearance_title"), scope: .device, anchor: "appearance") {
                SettingsCardView { SettingsThemeRow() }
            }
            SettingsSectionView(title: tr("settings", "preferences.comments_title"), scope: .device, anchor: "comments") {
                SettingsComposerRows()
            }
            SettingsSectionView(title: tr("settings", "issue.opening.title"), scope: .device, anchor: "issue-opening") {
                SettingsIssueOpeningRow()
            }
            SettingsSectionView(title: tr("settings", "preferences.issue_fields_title"), description: tr("settings", "issue.description"),
                                scope: .deviceWorkspace, anchor: "issue") {
                SettingsIssueFieldsMatrix()
            }
        }
    }
}

private struct SettingsThemeRow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        SettingsRowView(tr("settings", "preferences.theme.title"), anchor: "theme") {
            SegmentedToggle(selection: $env.appearance, options: [
                (value: "light", label: tr("settings", "preferences.theme.light"), icon: nil),
                (value: "dark", label: tr("settings", "preferences.theme.dark"), icon: nil),
                (value: "system", label: tr("settings", "preferences.theme.system"), icon: nil),
            ])
        }
    }
}

private struct SettingsLanguageRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster

    private static let options: [(code: String, key: String)] = [
        ("en", "english"), ("zh-Hans", "chinese"), ("ko", "korean"), ("ja", "japanese"), ("fr", "french"),
    ]

    var body: some View {
        let current = L10n.shared.language
        SettingsRowView(tr("settings", "preferences.language.title"), size: .select, anchor: "language") {
            Picker("", selection: Binding(get: { current }, set: { change(to: $0) })) {
                ForEach(Self.options, id: \.code) { o in
                    Text(tr("settings", "preferences.language.\(o.key)")).tag(o.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(tr("settings", "preferences.language.title"))
        }
    }

    /// Persist locally, sync to the account, then re-render in the new
    /// language; a failed sync is announced before the switch.
    private func change(to code: String) {
        guard code != L10n.shared.language else { return }
        Task {
            do {
                let updated = try await session.api.updateMe(UpdateMeRequest(language: code))
                env.settingsAdopt(updated)
                env.setLanguage(code)
            } catch {
                toaster.show(tr("settings", "preferences.language.sync_failed"), kind: .info)
                try? await Task.sleep(for: .milliseconds(2500))
                env.setLanguage(code)
            }
        }
    }
}

private struct SettingsTimezoneRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @State private var stored: String?
    @State private var loaded = false
    @State private var open = false

    private var system: String { TimeZone.current.identifier }

    var body: some View {
        let current = stored ?? system
        let suffix = stored == nil ? tr("settings", "preferences.timezone.browser_suffix") : ""
        SettingsRowView(tr("settings", "preferences.timezone.title"), description: tr("settings", "preferences.timezone.hint"),
                        size: .selectWide, anchor: "timezone") {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Text(current + suffix).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(TimeZone(identifier: current).map { SettingsRules.utcOffset($0) } ?? "")
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.settingsCard))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.primary.opacity(0.15)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!loaded)
            .accessibilityLabel(tr("settings", "preferences.timezone.title"))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                SettingsTimezonePicker(stored: stored, system: system) { choose($0) }
            }
        }
        .task {
            if let me = try? await session.api.getMe() { stored = me.timezone.flatMap { $0.isEmpty ? nil : $0 } }
            loaded = true
        }
    }

    /// nil picks "follow this Mac" (sent as an empty string).
    private func choose(_ zone: String?) {
        open = false
        guard zone != stored else { return }
        Task {
            do {
                let updated = try await session.api.updateMe(UpdateMeRequest(timezone: zone ?? ""))
                stored = updated.timezone.flatMap { $0.isEmpty ? nil : $0 }
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("settings", "preferences.timezone.sync_failed"), kind: .error)
            }
        }
    }
}

/// Searchable list of every IANA zone, with the "follow this device" entry
/// first. Plain substring matching, like upstream.
private struct SettingsTimezonePicker: View {
    let stored: String?
    let system: String
    let onPick: (String?) -> Void
    @State private var query = ""
    @State private var all: [(zone: String, offset: String)] = []
    @State private var visible: [(zone: String, offset: String)] = []
    @FocusState private var focused: Bool

    private static let common = [
        "UTC", "America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York", "America/Sao_Paulo",
        "Europe/London", "Europe/Berlin", "Europe/Paris", "Europe/Moscow", "Africa/Cairo", "Asia/Dubai", "Asia/Kolkata",
        "Asia/Bangkok", "Asia/Shanghai", "Asia/Singapore", "Asia/Tokyo", "Australia/Sydney", "Pacific/Auckland",
    ]

    var body: some View {
        let suffix = tr("settings", "preferences.timezone.browser_suffix")
        let systemOffset = TimeZone(identifier: system).map { SettingsRules.utcOffset($0) } ?? ""
        let showSystem = matches("\(system) \(suffix)")
        VStack(spacing: 0) {
            TextField(tr("settings", "preferences.timezone.search"), text: $query)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .focused($focused)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if showSystem {
                        row(system + suffix, offset: systemOffset, selected: stored == nil) { onPick(nil) }
                    }
                    ForEach(visible, id: \.zone) { item in
                        row(item.zone, offset: item.offset, selected: stored == item.zone) { onPick(item.zone) }
                    }
                    if visible.isEmpty && !showSystem {
                        Text(tr("settings", "preferences.timezone.empty"))
                            .font(Theme.Font.caption).foregroundStyle(.secondary).padding(12)
                    }
                }
                .padding(4)
            }
            .frame(height: 300)
        }
        .frame(width: 320)
        .task {
            let current = stored ?? system
            var seen = Set<String>()
            let ids = ([current, system] + Self.common + TimeZone.knownTimeZoneIdentifiers).filter { seen.insert($0).inserted }
            let now = Date()
            all = ids.compactMap { id in TimeZone(identifier: id).map { (zone: id, offset: SettingsRules.utcOffset($0, at: now)) } }
            visible = all
            focused = true
        }
        .onChange(of: query) {
            visible = all.filter { matches("\($0.zone) \($0.offset)") }
        }
    }

    private func matches(_ value: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || value.lowercased().contains(needle)
    }

    private func row(_ title: String, offset: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                Spacer(minLength: 4)
                Text(offset).font(Theme.Font.caption).foregroundStyle(.secondary)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.brand).opacity(selected ? 1 : 0)
            }
        }
        .buttonStyle(HoverRowButtonStyle())
    }
}

private struct SettingsComposerRows: View {
    @State private var prefs = SettingsDevicePreferences.shared

    var body: some View {
        SettingsCardView {
            SettingsRowView(tr("settings", "preferences.sticky_comment_bar.title"), anchor: "sticky-comment-bar") {
                Toggle("", isOn: $prefs.stickyCommentBar).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel(tr("settings", "preferences.sticky_comment_bar.title"))
            }
            SettingsRowView(tr("settings", "preferences.running_agent_reply.title"),
                            description: tr("settings", "preferences.running_agent_reply.hint"), size: .select, anchor: "running-agent-reply") {
                Picker("", selection: $prefs.runningAgentReply) {
                    Text(tr("settings", "preferences.running_agent_reply.steer")).tag(SettingsDevicePreferences.RunningAgentReply.steer)
                    Text(tr("settings", "preferences.running_agent_reply.after_run")).tag(SettingsDevicePreferences.RunningAgentReply.afterRun)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsRowView(tr("settings", "chat.floating_label"), description: tr("settings", "chat.floating_hint"), anchor: "chat") {
                Toggle("", isOn: $prefs.floatingChatEnabled).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel(tr("settings", "chat.floating_label"))
            }
        }
    }
}

private struct SettingsIssueOpeningRow: View {
    @State private var prefs = SettingsDevicePreferences.shared

    var body: some View {
        SettingsCardView {
            SettingsRowView(tr("settings", "issue.opening.click"), description: tr("settings", "issue.opening.hint"), anchor: "issue-opening") {
                SegmentedToggle(selection: $prefs.issueOpenMode, options: [
                    (value: .page, label: tr("settings", "issue.opening.page"), icon: nil),
                    (value: .peek, label: tr("settings", "issue.opening.peek"), icon: nil),
                ])
            }
        }
    }
}

/// Field × dialog grid of the toolbar fields each create-issue dialog shows.
private struct SettingsIssueFieldsMatrix: View {
    @Environment(WorkspaceSession.self) private var session
    @State private var prefs = SettingsDevicePreferences.shared

    var body: some View {
        let ws = session.workspace.id
        let quick = prefs.quickCreateFields(workspaceID: ws)
        let manual = prefs.manualCreateFields(workspaceID: ws)
        let quickLabel = tr("settings", "preferences.issue_fields.quick")
        let manualLabel = tr("settings", "preferences.issue_fields.manual")
        SettingsCatalogCard {
            HStack(spacing: 0) {
                Text(tr("settings", "preferences.issue_fields.field")).frame(maxWidth: .infinity, alignment: .leading)
                Text(quickLabel).frame(width: 128)
                Text(manualLabel).frame(width: 128)
            }
        } content: {
            ForEach(Array(SettingsDevicePreferences.manualCreateFields.enumerated()), id: \.element) { i, field in
                if i > 0 { Divider() }
                let label = tr("settings", "issue.fields.\(field)")
                HStack(spacing: 0) {
                    Text(label).font(Theme.Font.body).frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        if SettingsDevicePreferences.quickCreateFields.contains(field) {
                            Toggle("", isOn: Binding(get: { quick.contains(field) },
                                                     set: { prefs.setQuickCreateField(field, visible: $0, workspaceID: ws) }))
                                .toggleStyle(.checkbox).labelsHidden()
                                .accessibilityLabel("\(label) · \(quickLabel)")
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                                .help(tr("settings", "preferences.issue_fields.unsupported"))
                                .accessibilityLabel(tr("settings", "preferences.issue_fields.unsupported"))
                        }
                    }
                    .frame(width: 128)
                    Toggle("", isOn: Binding(get: { manual.contains(field) },
                                             set: { prefs.setManualCreateField(field, visible: $0, workspaceID: ws) }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .accessibilityLabel("\(label) · \(manualLabel)")
                        .frame(width: 128)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }
}
