import MulticaCore
import SwiftUI

private struct SettingsWorkspaceDraft: Equatable {
    var name: String
    var description: String
    var context: String
}

/// Settings › General (upstream workspace-tab.tsx): logo, details
/// (auto-saved), slug, issue prefix, and the danger zone.
struct SettingsWorkspaceTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster
    @State private var record: WorkspaceRecord?
    @State private var name = ""
    @State private var details = ""
    @State private var context = ""
    @State private var autoSave: SettingsAutoSave<SettingsWorkspaceDraft>?
    @State private var prefixStatus: SettingsSaveStatus = .idle
    @State private var prefixDraft: String?
    @State private var action: String?
    @State private var leaveConfirm = false
    @State private var deleteOpen = false
    @FocusState private var focused: Int?

    private var draft: SettingsWorkspaceDraft { SettingsWorkspaceDraft(name: name, description: details, context: context) }
    private var saved: SettingsWorkspaceDraft {
        SettingsWorkspaceDraft(name: record?.name ?? "", description: record?.description ?? "", context: record?.context ?? "")
    }

    var body: some View {
        let ws = env.settingsWorkspace(session)
        let role = session.settingsMyRole
        let canManage = role == "owner" || role == "admin"
        let membersLoaded = !session.directory.members.isEmpty
        let readOnly = membersLoaded && !canManage
        let saveStatus: SettingsSaveStatus = prefixStatus == .saving || prefixStatus == .error
            ? prefixStatus : ((autoSave?.status ?? .idle) == .idle ? prefixStatus : autoSave?.status ?? .idle)
        SettingsTabView(title: tr("settings", "page.tabs.general"), scope: .workspace) {
            if readOnly { SettingsReadOnlyNotice() }
            SettingsSectionView(title: tr("settings", "workspace.section_general"), action: { SettingsSaveStateView(status: saveStatus) }) {
                SettingsCardView {
                    SettingsRowView(tr("settings", "workspace.logo_label"),
                                    description: canManage ? tr("settings", "workspace.click_logo_hint") : nil,
                                    size: SettingsControlSize.none, anchor: "logo") {
                        SettingsAvatarUploadControl(value: record?.avatarUrl ?? ws.avatarURL, kind: .workspace, name: ws.name,
                                                    disabled: !canManage, accessibilityLabel: tr("settings", "workspace.change_logo_aria")) { url in
                            await saveLogo(url)
                        }
                    }
                    SettingsRowView(tr("settings", "workspace.name_label"), size: readOnly ? nil : .text, anchor: "name") {
                        if readOnly {
                            readOnlyText(ws.name)
                        } else {
                            TextField("", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .focused($focused, equals: 0)
                                .onSubmit { autoSave?.flush() }
                                .disabled(!canManage)
                                .accessibilityLabel(tr("settings", "workspace.name_label"))
                        }
                    }
                    SettingsRowView(tr("settings", "workspace.description_label"), size: readOnly ? nil : .text, align: .top, anchor: "description") {
                        if readOnly {
                            readOnlyText(record?.description ?? "")
                        } else {
                            SettingsTextArea(text: $details, placeholder: tr("settings", "workspace.description_placeholder"), disabled: !canManage)
                                .focused($focused, equals: 1)
                        }
                    }
                    SettingsRowView(tr("settings", "workspace.context_label"), description: tr("settings", "workspace.context_hint"),
                                    size: readOnly ? nil : .text, align: .top, anchor: "context") {
                        if readOnly {
                            readOnlyText(record?.context ?? "")
                        } else {
                            SettingsTextArea(text: $context, placeholder: tr("settings", "workspace.context_placeholder"), minHeight: 84, disabled: !canManage)
                                .focused($focused, equals: 2)
                        }
                    }
                    SettingsRowView(tr("settings", "workspace.slug_label"), description: tr("settings", "workspace.slug_hint"), anchor: "slug") {
                        HStack(spacing: 4) {
                            Text(ws.slug).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            Button {
                                SettingsClipboard.copy(ws.slug)
                            } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                                .buttonStyle(.borderless)
                                .help(tr("settings", "workspace.copy_slug"))
                                .accessibilityLabel(tr("settings", "workspace.copy_slug"))
                        }
                    }
                    SettingsRowView(tr("settings", "workspace.issue_prefix_label"),
                                    description: tr("settings", "workspace.issue_prefix_hint", ["example": "\(currentPrefix(ws))-123"]), anchor: "issue-prefix") {
                        HStack(spacing: 12) {
                            Text(currentPrefix(ws)).font(.system(size: 12, design: .monospaced))
                            if canManage {
                                Button(tr("settings", "workspace.change_prefix")) {
                                    prefixStatus = .idle
                                    prefixDraft = currentPrefix(ws)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }

            if membersLoaded {
                dangerZone(ws: ws, role: role)
            }
        }
        .task(id: session.revision("workspace")) { await load() }
        .onChange(of: draft) { feed(canManage: canManage) }
        .onChange(of: record) { feed(canManage: canManage) }
        .onChange(of: canManage) { feed(canManage: canManage) }
        .onChange(of: focused) { old, new in
            if old != nil && new != old { autoSave?.flush() }
        }
        .onDisappear { autoSave?.flush() }
        .sheet(isPresented: Binding(get: { prefixDraft != nil }, set: { if !$0, prefixStatus != .saving { prefixDraft = nil } })) {
            SettingsIssuePrefixSheet(current: currentPrefix(ws), draft: Binding(get: { prefixDraft ?? "" }, set: { prefixDraft = $0 }),
                                     saving: prefixStatus == .saving, onCancel: { prefixDraft = nil }, onSave: savePrefix)
                .interactiveDismissDisabled(prefixStatus == .saving)
        }
        .sheet(isPresented: $deleteOpen) {
            SettingsDeleteWorkspaceSheet(workspaceName: ws.name, loading: action == "delete-workspace",
                                         onCancel: { deleteOpen = false }, onConfirm: deleteWorkspace)
                .interactiveDismissDisabled(action == "delete-workspace")
        }
        .alert(tr("settings", "workspace.leave_confirm_title"), isPresented: $leaveConfirm) {
            Button(tr("settings", "workspace.confirm_cancel"), role: .cancel) {}
            Button(tr("settings", "workspace.confirm_action"), role: .destructive) { leave() }
        } message: {
            Text(tr("settings", "workspace.leave_confirm_description", ["name": ws.name]))
        }
    }

    private func currentPrefix(_ ws: Workspace) -> String { record?.issuePrefix ?? ws.issuePrefix }

    private func readOnlyText(_ value: String) -> some View {
        Group {
            if value.isEmpty {
                Text("—").foregroundStyle(.tertiary)
            } else {
                Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
        }
        .font(Theme.Font.body)
        .frame(maxWidth: 384, alignment: .trailing)
    }

    @ViewBuilder
    private func dangerZone(ws: Workspace, role: String?) -> some View {
        let members = session.directory.members
        let isOwner = role == "owner"
        let soleOwner = isOwner && members.filter { $0.role == "owner" }.count <= 1
        let soleMember = members.count <= 1
        SettingsSectionView(title: tr("settings", "workspace.danger_zone")) {
            SettingsCardView {
                SettingsRowView(tr("settings", "workspace.leave_title"),
                                description: soleOwner ? (soleMember ? tr("settings", "workspace.leave_sole_member") : tr("settings", "workspace.leave_sole_owner"))
                                    : tr("settings", "workspace.leave_default"),
                                anchor: "leave") {
                    Button(action == "leave" ? tr("settings", "workspace.leaving") : tr("settings", "workspace.leave_button")) { leaveConfirm = true }
                        .controlSize(.small)
                        .disabled(action == "leave" || soleOwner)
                }
                if isOwner {
                    SettingsRowView(tr("settings", "workspace.delete_title"), description: tr("settings", "workspace.delete_description"),
                                    labelColor: Theme.destructive, anchor: "delete") {
                        Button(action == "delete-workspace" ? tr("settings", "workspace.deleting") : tr("settings", "workspace.delete_button"), role: .destructive) {
                            deleteOpen = true
                        }
                        .controlSize(.small)
                        .tint(Theme.destructive)
                        .disabled(action == "delete-workspace")
                    }
                }
            }
        }
    }

    private func load() async {
        let wsID = session.workspace.id
        if autoSave == nil {
            let ws = env.settingsWorkspace(session)
            name = ws.name
            let api = session.api
            autoSave = SettingsAutoSave(initial: SettingsWorkspaceDraft(name: ws.name, description: "", context: ""), save: { next in
                let updated = try await api.updateWorkspace(wsID, patch: [
                    "name": JSONValue(next.name), "description": JSONValue(next.description), "context": JSONValue(next.context),
                ])
                record = updated
                env.settingsAdopt(updated)
            }, onError: { error in
                toaster.show((error as? APIError)?.message ?? tr("settings", "workspace.toast_save_failed"), kind: .error)
            })
        }
        do {
            let fresh = try await session.api.getWorkspace(wsID)
            let first = record == nil
            record = fresh
            env.settingsAdopt(fresh)
            if first {
                name = fresh.name
                details = fresh.description ?? ""
                context = fresh.context ?? ""
            }
        } catch {
            if record == nil { toaster.error(error) }
        }
    }

    private func feed(canManage: Bool) {
        autoSave?.update(value: draft, saved: saved, enabled: record != nil && canManage && !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func saveLogo(_ url: String) async -> Bool {
        do {
            let updated = try await session.api.updateWorkspace(session.workspace.id, patch: ["avatar_url": JSONValue(url)])
            record = updated
            env.settingsAdopt(updated)
            return true
        } catch {
            toaster.show((error as? APIError)?.message ?? tr("settings", "workspace.toast_logo_failed"), kind: .error)
            return false
        }
    }

    private func savePrefix(_ prefix: String) {
        prefixStatus = .saving
        Task {
            do {
                let updated = try await session.api.updateWorkspace(session.workspace.id, patch: ["issue_prefix": JSONValue(prefix)])
                record = updated
                env.settingsAdopt(updated)
                prefixStatus = .saved
                prefixDraft = nil
                if let page = try? await session.api.listIssues(.init(limit: WorkspaceSession.pageSize)) {
                    session.issues.merge(page: page.issues, total: page.total, replacing: false)
                }
            } catch {
                prefixStatus = .error
                toaster.show((error as? APIError)?.message ?? tr("settings", "workspace.toast_save_failed"), kind: .error)
            }
        }
    }

    private func leave() {
        action = "leave"
        let wsID = session.workspace.id
        Task {
            do {
                try await session.api.leaveWorkspace(wsID)
                await env.app.reloadWorkspaces()
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("settings", "workspace.toast_leave_failed"), kind: .error)
            }
            action = nil
        }
    }

    /// Waits for the server before leaving the workspace; on failure the
    /// dialog stays open.
    private func deleteWorkspace() {
        action = "delete-workspace"
        let wsID = session.workspace.id
        Task {
            do {
                try await session.api.deleteWorkspace(wsID)
                deleteOpen = false
                action = nil
                await env.app.reloadWorkspaces()
            } catch {
                action = nil
                toaster.show((error as? APIError)?.message ?? tr("settings", "workspace.toast_delete_failed"), kind: .error)
            }
        }
    }
}

private struct SettingsIssuePrefixSheet: View {
    let current: String
    @Binding var draft: String
    let saving: Bool
    let onCancel: () -> Void
    let onSave: (String) -> Void

    var body: some View {
        let normalized = SettingsRules.normalizeIssuePrefix(draft)
        let invalid = normalized.isEmpty
        let changed = normalized != current
        SettingsDialog(title: tr("settings", "workspace.prefix_dialog_title"), description: tr("settings", "workspace.prefix_dialog_description")) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "workspace.prefix_new_label"))
                    TextField("", text: Binding(get: { draft }, set: { draft = SettingsRules.normalizeIssuePrefix($0) }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .onSubmit { if !invalid && changed && !saving { onSave(normalized) } }
                    Text(tr("settings", "workspace.prefix_rule")).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("\(current)-123").strikethrough().foregroundStyle(.secondary)
                    Text("→").foregroundStyle(.secondary)
                    Text("\(normalized.isEmpty ? current : normalized)-123").fontWeight(.medium)
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                Text(tr("settings", "workspace.prefix_external_warning", ["oldExample": "\(current)-123"]))
                    .font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Button(tr("settings", "workspace.confirm_cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(saving)
            Button(tr("settings", "workspace.prefix_confirm_action", ["prefix": normalized.isEmpty ? current : normalized]), role: .destructive) {
                onSave(normalized)
            }
            .tint(Theme.destructive)
            .disabled(invalid || !changed || saving)
        }
    }
}

/// Typed confirmation: the button unlocks only when the exact
/// (case-sensitive, untrimmed) workspace name is typed.
private struct SettingsDeleteWorkspaceSheet: View {
    let workspaceName: String
    let loading: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @State private var typed = ""

    var body: some View {
        let matched = typed == workspaceName
        SettingsDialog(title: tr("settings", "delete_workspace_dialog.title"), description: tr("settings", "delete_workspace_dialog.description")) {
            VStack(alignment: .leading, spacing: 8) {
                (Text(tr("settings", "delete_workspace_dialog.type_to_confirm_prefix") + " ")
                    + Text(workspaceName).font(.system(size: 11, design: .monospaced))
                    + Text(tr("settings", "delete_workspace_dialog.type_to_confirm_suffix")))
                    .font(Theme.Font.caption)
                TextField(workspaceName, text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .disabled(loading)
                    .onSubmit { if matched && !loading { onConfirm() } }
            }
        } footer: {
            Button(tr("settings", "delete_workspace_dialog.cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(loading)
            Button(loading ? tr("settings", "delete_workspace_dialog.deleting") : tr("settings", "delete_workspace_dialog.confirm"), role: .destructive, action: onConfirm)
                .tint(Theme.destructive)
                .disabled(!matched || loading)
        }
        .onChange(of: workspaceName) { typed = "" }
    }
}
