import MulticaCore
import SwiftUI

/// Settings › Quick Actions (upstream quick-actions-tab.tsx): preset agent +
/// prompt pairs run from an issue's sidebar, ordered by use.
struct SettingsQuickActionsTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @State private var query = ""
    @State private var visible: [QuickAction] = []
    @State private var editing: SettingsQuickActionEditing?
    @State private var pendingDelete: QuickAction?

    var body: some View {
        let store = session.quickActions
        SettingsTabView(title: tr("settings", "quick_actions.title"), description: tr("settings", "quick_actions.description"), scope: .workspace) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    SearchField(text: $query, prompt: tr("settings", "quick_actions.search_placeholder")).frame(maxWidth: 384)
                    Spacer(minLength: 0)
                    Button { editing = SettingsQuickActionEditing(action: nil) } label: {
                        Label(tr("settings", "quick_actions.add"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                SettingsCatalogCard {
                    HStack(spacing: 16) {
                        Text(tr("settings", "quick_actions.columns.name")).frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                        Text(tr("settings", "quick_actions.columns.target")).frame(minWidth: 144, maxWidth: .infinity, alignment: .leading)
                        Text(tr("settings", "quick_actions.columns.visibility")).frame(width: 96, alignment: .leading)
                        Text(tr("settings", "quick_actions.columns.usage")).frame(width: 80, alignment: .leading)
                        Text(tr("settings", "quick_actions.columns.updated")).frame(width: 112, alignment: .leading)
                        Color.clear.frame(width: 28, height: 1)
                    }
                } content: {
                    if !store.isLoaded {
                        SettingsCatalogPlaceholder(title: tr("settings", "quick_actions.loading"))
                    } else if visible.isEmpty {
                        SettingsCatalogPlaceholder(icon: "bolt",
                                                   title: query.isEmpty ? tr("settings", "quick_actions.empty_title") : tr("settings", "quick_actions.no_results"),
                                                   hint: query.isEmpty ? tr("settings", "quick_actions.empty_hint") : nil)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(visible) { action in
                                if action.id != visible.first?.id { Divider() }
                                row(action)
                            }
                        }
                    }
                }
            }
        }
        .task {
            await store.loadIfNeeded()
            await session.squads.loadIfNeeded()
        }
        .onChange(of: store.items, initial: true) { refilter() }
        .onChange(of: query) { refilter() }
        .sheet(item: $editing) { e in
            SettingsQuickActionSheet(action: e.action) { editing = nil }
        }
        .alert(tr("settings", "quick_actions.delete_title"), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { action in
            Button(tr("settings", "quick_actions.cancel"), role: .cancel) {}
            Button(tr("settings", "quick_actions.delete"), role: .destructive) { delete(action) }
        } message: { _ in
            Text(tr("settings", "quick_actions.delete_description"))
        }
    }

    private func row(_ action: QuickAction) -> some View {
        let stale = SettingsRules.isStaleQuickAction(action)
        return HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "bolt").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(action.name).font(Theme.Font.bodyMedium).lineLimit(1)
                if action.status != "active" {
                    Text(tr("settings", "quick_actions.archived")).font(.system(size: 10))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Theme.border))
                }
            }
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            targetLine(action)
                .font(Theme.Font.body)
                .lineLimit(1)
                .frame(minWidth: 144, maxWidth: .infinity, alignment: .leading)
            visibilityBadge(action).frame(width: 96, alignment: .leading)
            Text(action.useCount == 0 ? tr("settings", "quick_actions.never_used") : tr("settings", "quick_actions.used_count", ["count": action.useCount]))
                .font(Theme.Font.body).monospacedDigit()
                .foregroundStyle(stale ? Theme.warning : .secondary)
                .frame(width: 80, alignment: .leading)
            Text(SettingsDates.short(action.updatedAt)).font(Theme.Font.caption).foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Menu {
                Button { editing = SettingsQuickActionEditing(action: action) } label: {
                    Label(tr("settings", "quick_actions.edit"), systemImage: "pencil")
                }
                Button { toggleArchive(action) } label: {
                    if action.status == "active" {
                        Label(tr("settings", "quick_actions.archive"), systemImage: "archivebox")
                    } else {
                        Label(tr("settings", "quick_actions.unarchive"), systemImage: "arrow.uturn.backward")
                    }
                }
                Button(role: .destructive) { pendingDelete = action } label: {
                    Label(tr("settings", "quick_actions.delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .accessibilityLabel(tr("settings", "quick_actions.actions_open", ["name": action.name]))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(action.status != "active" ? 0.6 : 1)
    }

    /// The bound target and its current reachability, as plain metadata.
    @ViewBuilder
    private func targetLine(_ action: QuickAction) -> some View {
        if action.targetMissing {
            Label(tr("settings", "quick_actions.target_missing"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.destructive)
        } else {
            let mismatched = action.visibility == "public" && !action.targetPublic
            HStack(spacing: 4) {
                if mismatched { Image(systemName: "exclamationmark.triangle") }
                Text((action.targetName ?? "") + (action.targetPublic ? "" : " · \(tr("settings", "quick_actions.target_private"))"))
            }
            .foregroundStyle(mismatched ? Theme.warning : .secondary)
        }
    }

    @ViewBuilder
    private func visibilityBadge(_ action: QuickAction) -> some View {
        switch action.visibility {
        case "public":
            Label(tr("settings", "quick_actions.visibility_public"), systemImage: "globe")
                .font(Theme.Font.caption)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
        case "private":
            Label(tr("settings", "quick_actions.visibility_private"), systemImage: "lock")
                .font(Theme.Font.caption)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(Theme.border))
        default:
            Text(action.visibility).font(Theme.Font.caption)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(Theme.border))
        }
    }

    private func refilter() {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = SettingsRules.sortQuickActions(session.quickActions.items)
        visible = needle.isEmpty ? sorted : sorted.filter {
            $0.name.lowercased().contains(needle) || ($0.targetName ?? "").lowercased().contains(needle)
        }
    }

    private func toggleArchive(_ action: QuickAction) {
        Task {
            do {
                let updated = try await session.api.updateQuickAction(action.id, UpdateQuickActionRequest(status: action.status == "active" ? "archived" : "active"))
                session.quickActions.upsert(updated)
            } catch {
                toaster.error(error)
            }
        }
    }

    private func delete(_ action: QuickAction) {
        Task {
            do {
                try await session.api.deleteQuickAction(action.id)
                session.quickActions.remove(action.id)
            } catch {
                toaster.error(error)
            }
        }
    }
}

private struct SettingsQuickActionEditing: Identifiable {
    let id = UUID()
    let action: QuickAction?
}

private struct SettingsQuickActionSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let action: QuickAction?
    let onClose: () -> Void
    @State private var name = ""
    @State private var visibility = "public"
    @State private var target: ActorRef?
    @State private var prompt = ""
    @State private var saving = false

    var body: some View {
        let token = SettingsRules.quickActionTemplateToken(prompt)
        let canSave = !name.trimmingCharacters(in: .whitespaces).isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && target != nil && token == nil
        SettingsDialog(title: action == nil ? tr("settings", "quick_actions.create_title") : tr("settings", "quick_actions.edit_title"),
                       description: tr("settings", "quick_actions.dialog_description"), width: 512) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "quick_actions.field_name"))
                    TextField(tr("settings", "quick_actions.field_name_placeholder"), text: Binding(get: { name }, set: { name = String($0.prefix(32)) }))
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "quick_actions.field_visibility"))
                    HStack(spacing: 8) {
                        visibilityCard("public", icon: "globe", title: tr("settings", "quick_actions.visibility_public"), hint: tr("settings", "quick_actions.visibility_public_hint"))
                        visibilityCard("private", icon: "lock", title: tr("settings", "quick_actions.visibility_private"), hint: tr("settings", "quick_actions.visibility_private_hint"))
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "quick_actions.field_target"))
                    SettingsAgentOrSquadPicker(selection: target) { target = $0 }
                    if visibility == "public" {
                        Text(tr("settings", "quick_actions.public_target_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "quick_actions.field_prompt"))
                    SettingsTextArea(text: $prompt, placeholder: tr("settings", "quick_actions.field_prompt_placeholder"), minHeight: 100)
                    if let token {
                        Text(tr("settings", "quick_actions.template_not_supported", ["token": token]))
                            .font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                    } else {
                        Label(tr("settings", "quick_actions.prompt_hint"), systemImage: "info.circle")
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Button(tr("settings", "quick_actions.cancel"), action: onClose).keyboardShortcut(.cancelAction)
            Button(tr("settings", "quick_actions.save"), action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || saving)
        }
        .onAppear {
            guard let action else { return }
            name = action.name
            visibility = action.visibility == "private" ? "private" : "public"
            target = ActorRef(type: action.assigneeType == "squad" ? "squad" : "agent", id: action.assigneeId)
            prompt = action.prompt
        }
    }

    private func visibilityCard(_ value: String, icon: String, title: String, hint: String) -> some View {
        let selected = visibility == value
        return Button { visibility = value } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).foregroundStyle(.secondary).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Font.bodyMedium)
                    Text(hint).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.brand.opacity(0.08) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.brand : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func submit() {
        guard let target, !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let saved: QuickAction
                if let action {
                    saved = try await session.api.updateQuickAction(action.id, UpdateQuickActionRequest(
                        name: name, description: action.description, assigneeType: target.type, assigneeId: target.id, prompt: prompt, visibility: visibility))
                } else {
                    saved = try await session.api.createQuickAction(CreateQuickActionRequest(
                        name: name, description: "", assigneeType: target.type, assigneeId: target.id, prompt: prompt, visibility: visibility))
                }
                session.quickActions.upsert(saved)
                onClose()
            } catch {
                toaster.error(error)
            }
        }
    }
}

/// Agent or squad picker (upstream autopilots AgentPicker): agents need a
/// runtime, squads a leader with one.
struct SettingsAgentOrSquadPicker: View {
    @Environment(WorkspaceSession.self) private var session
    let selection: ActorRef?
    let onChange: (ActorRef) -> Void

    var body: some View {
        let selectedName = selection.flatMap { s in
            s.type == "squad" ? session.squads.item(s.id)?.name : session.directory.agent(s.id)?.name
        }
        PopoverButton(label: {
            HStack(spacing: 6) {
                if let selection, let selectedName {
                    ActorAvatar(type: selection.type, id: selection.id, size: 16)
                    Text(selectedName).lineLimit(1)
                } else {
                    Image(systemName: "cpu").font(.system(size: 10))
                    Text(tr("autopilots", "agent_picker.select_assignee"))
                }
            }
        }, content: { dismiss in
            OptionList(options: options, selected: selection.map { ["\($0.type):\($0.id)"] } ?? [],
                       searchPlaceholder: tr("autopilots", "agent_picker.filter_placeholder")) { key in
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return }
                dismiss()
                onChange(ActorRef(type: parts[0], id: parts[1]))
            }
            .task { await session.squads.loadIfNeeded() }
        })
    }

    private var options: [PickerOption<String>] {
        var out: [PickerOption<String>] = []
        let agentsGroup = tr("autopilots", "agent_picker.agents_group")
        for a in session.directory.agents where a.archivedAt == nil {
            let bound = !a.runtimeID.isEmpty
            out.append(PickerOption(id: "agent:\(a.id)", title: a.name, group: agentsGroup, disabled: !bound,
                                    help: bound ? nil : tr("autopilots", "agent_picker.agent_runtime_required"),
                                    icon: AnyView(AvatarView(name: a.name, url: a.avatarURL, kind: .agent, size: 16))))
        }
        let squadsGroup = tr("autopilots", "agent_picker.squads_group")
        for s in session.squads.items where s.archivedAt == nil {
            let bound = session.directory.agent(s.leaderId).map { !$0.runtimeID.isEmpty } ?? false
            out.append(PickerOption(id: "squad:\(s.id)", title: s.name, group: squadsGroup, disabled: !bound,
                                    help: bound ? nil : tr("autopilots", "agent_picker.squad_runtime_required"),
                                    icon: AnyView(AvatarView(name: s.name, url: s.avatarUrl, kind: .squad, size: 16))))
        }
        return out
    }
}
