import MulticaCore
import SwiftUI

/// Capabilities › Skills (upstream tabs/skills-tab): workspace skills
/// assigned to the agent, plus skills inherited from a local runtime.
struct AgentsUISkillsTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let agent: AgentRecord
    let runtime: RuntimeDeviceRecord?
    let canEdit: Bool

    enum Selected: Identifiable {
        case workspace(String)
        case runtime(RuntimeLocalSkillSummary)
        var id: String {
            switch self {
            case .workspace(let id): return "w:\(id)"
            case .runtime(let s): return "r:\(s.root ?? ""):\(s.key)"
            }
        }
    }

    @State private var busyID: String?
    @State private var showAdd = false
    @State private var selected: Selected?

    private var canRead: Bool { runtime.map { AgentsUI.isRuntimeUsable($0, userID: session.currentUser.id) } ?? false }
    private var discoverID: String? {
        guard let runtime, runtime.runtimeMode == "local", runtime.status == "online", canRead else { return nil }
        return runtime.id
    }

    var body: some View {
        let store = session.agentsUIStore
        let state = store.localSkillsState(discoverID)
        VStack(alignment: .leading, spacing: 32) {
            section(tr("agents", "tab_body.skills.assigned_title"), tr("agents", "tab_body.skills.assigned_hint")) {
                if canEdit {
                    Button { showAdd = true } label: { Label(tr("agents", "tab_body.skills.add_action"), systemImage: "plus") }
                        .disabled(session.skills.items.isEmpty)
                }
            } content: {
                if agent.skills.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(.tertiary)
                        Text(tr("agents", "tab_body.skills.empty_title")).font(Theme.Font.body).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                } else {
                    AgentsUIListCard {
                        ForEach(agent.skills, id: \.id) { skill in assignedRow(skill) }
                    }
                }
            }
            section(tr("agents", "tab_body.skills.runtime_title"),
                    tr("agents", "tab_body.skills.runtime_hint", ["runtime": runtime.map(AgentsUI.runtimeDisplayLabel) ?? "Runtime"])) {
                if let id = discoverID {
                    Button { Task { await store.loadLocalSkills(id, force: true) } } label: {
                        Label(tr("agents", "tab_body.skills.refresh_action"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(state.isLoading)
                }
            } content: {
                runtimeSection(state)
            }
        }
        .task { await session.skills.loadIfNeeded() }
        .task(id: discoverID) { if let id = discoverID { await store.loadLocalSkills(id) } }
        .sheet(isPresented: $showAdd) { AgentsUISkillAddSheet(agent: agent) }
        .sheet(item: $selected) { AgentsUISkillDetailSheet(selected: $0) }
    }

    @ViewBuilder
    private func runtimeSection(_ state: AgentsUIStore.Discovery<AgentsUIStore.LocalSkills>) -> some View {
        if runtime == nil {
            AgentsUINotice(text: tr("agents", "tab_body.skills.runtime_missing"))
        } else if !canRead {
            AgentsUINotice(text: tr("agents", "tab_body.skills.runtime_forbidden"))
        } else if runtime?.status != "online" {
            AgentsUINotice(text: tr("agents", "tab_body.skills.runtime_offline"))
        } else if state.isInitialLoad || (state.value == nil && state.error == nil) {
            AgentsUINotice(text: tr("agents", "tab_body.skills.runtime_discovering"), loading: true)
        } else if state.error != nil, state.value == nil {
            AgentsUINotice(text: session.agentsUIStore.localSkillsStatus[runtime?.id ?? ""] == 403
                           ? tr("agents", "tab_body.skills.runtime_forbidden") : tr("agents", "tab_body.skills.runtime_failed"))
        } else if let v = state.value, !v.supported {
            AgentsUINotice(text: tr("agents", "tab_body.skills.runtime_unsupported"))
        } else if let v = state.value, v.skills.isEmpty {
            AgentsUINotice(text: tr("agents", "tab_body.skills.runtime_empty"))
        } else if let v = state.value {
            AgentsUIListCard {
                ForEach(v.skills, id: \.key) { skill in runtimeRow(skill) }
            }
        }
    }

    private func section<A: View, C: View>(_ title: String, _ hint: String, @ViewBuilder action: () -> A, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.Font.bodyMedium)
                    Text(hint).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                action()
            }
            content()
        }
    }

    private func assignedRow(_ skill: AgentSkillSummary) -> some View {
        let enabled = skill.enabled != false
        return HStack(spacing: 12) {
            Button { selected = .workspace(skill.id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").foregroundStyle(enabled ? .secondary : .tertiary)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.05)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name).font(Theme.Font.bodyMedium).foregroundStyle(enabled ? .primary : .secondary)
                        Text(skill.description.isEmpty ? tr("agents", "tab_body.skills.no_description") : skill.description)
                            .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if canEdit {
                if busyID == skill.id {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(get: { enabled }, set: { toggle(skill, $0) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .help(tr("agents", "tab_body.skills.toggle_aria", ["name": skill.name]))
                }
                Button { remove(skill) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(busyID != nil)
                    .help(tr("agents", "tab_body.skills.remove_aria", ["name": skill.name]))
            }
        }
        .padding(12)
    }

    private func runtimeRow(_ skill: RuntimeLocalSkillSummary) -> some View {
        let disabled = isDisabled(skill)
        let key = "runtime:\(skill.root ?? "unknown"):\(skill.key):\(skill.plugin ?? "")"
        return HStack(spacing: 12) {
            Button { selected = .runtime(skill) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack").foregroundStyle(.secondary).opacity(disabled ? 0.5 : 1)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.05)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name).font(Theme.Font.bodyMedium).foregroundStyle(disabled ? .secondary : .primary)
                        Text((skill.description?.isEmpty == false ? skill.description : nil) ?? skill.sourcePath)
                            .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if canEdit, skill.canDisable == true, skill.root != nil {
                if busyID == key {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(get: { !disabled }, set: { toggleRuntime(skill, enabled: $0, key: key) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .help(tr("agents", "tab_body.skills.runtime_toggle_aria", ["name": skill.name]))
                }
            }
        }
        .padding(12)
    }

    private func isDisabled(_ skill: RuntimeLocalSkillSummary) -> Bool {
        guard let runtime, let root = skill.root else { return false }
        return (agent.disabledRuntimeSkills ?? []).contains {
            $0.runtimeId == runtime.id && $0.provider == skill.provider && $0.root == root && $0.key == skill.key
                && ($0.plugin ?? "") == (skill.plugin ?? "")
        }
    }

    private func toggle(_ skill: AgentSkillSummary, _ enabled: Bool) {
        busyID = skill.id
        Task {
            defer { busyID = nil }
            do {
                try await session.api.agentsUISetSkillEnabled(agentId: agent.id, skillId: skill.id, enabled: enabled)
                await session.agentsUIReload(agent.id)
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("agents", "tab_body.skills.toggle_failed_toast"), kind: .error)
            }
        }
    }

    private func remove(_ skill: AgentSkillSummary) {
        busyID = skill.id
        Task {
            defer { busyID = nil }
            do {
                try await session.api.agentsUIRemoveSkill(agentId: agent.id, skillId: skill.id)
                await session.agentsUIReload(agent.id)
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("agents", "tab_body.skills.remove_failed_toast"), kind: .error)
            }
        }
    }

    private func toggleRuntime(_ skill: RuntimeLocalSkillSummary, enabled: Bool, key: String) {
        guard let runtime, let root = skill.root else { return }
        busyID = key
        Task {
            defer { busyID = nil }
            do {
                try await session.api.setAgentRuntimeSkillEnabled(agentId: agent.id, SetAgentRuntimeSkillEnabledRequest(
                    runtimeId: runtime.id, root: root, key: skill.key, name: skill.name, plugin: skill.plugin, enabled: enabled))
                await session.agentsUIReload(agent.id)
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("agents", "tab_body.skills.runtime_toggle_failed_toast"), kind: .error)
            }
        }
    }
}

/// Searchable multi-select over workspace skills (upstream skill-picker-list).
struct AgentsUISkillPickerList: View {
    let skills: [SkillSummary]
    let selected: Set<String>
    var loading = false
    var emptyMessage: String? = nil
    let onToggle: (SkillSummary) -> Void
    @State private var query = ""

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? skills : skills.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
        VStack(spacing: 0) {
            if !skills.isEmpty {
                SearchField(text: $query, prompt: tr("agents", "create_dialog.skills_section.search_placeholder")).padding(8)
                Divider()
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    if loading {
                        message(tr("agents", "create_dialog.skills_section.list_loading"))
                    } else if skills.isEmpty {
                        message(emptyMessage ?? tr("agents", "create_dialog.skills_section.list_empty_default"))
                    } else if filtered.isEmpty {
                        message(tr("agents", "create_dialog.skills_section.list_no_match"))
                    } else {
                        ForEach(filtered) { skill in
                            let isSelected = selected.contains(skill.id)
                            Button { onToggle(skill) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: isSelected ? "checkmark.square.fill" : "square").foregroundStyle(isSelected ? Theme.brand : .secondary)
                                    Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(skill.name).font(Theme.Font.bodyMedium).lineLimit(1)
                                        if !skill.description.isEmpty {
                                            Text(skill.description).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(HoverRowButtonStyle(selected: isSelected))
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 256)
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
    }

    private func message(_ s: String) -> some View {
        Text(s).font(Theme.Font.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

/// "Add skill" with explicit confirm (upstream skill-add-dialog).
struct AgentsUISkillAddSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let agent: AgentRecord
    @State private var selected: Set<String> = []
    @State private var saving = false

    var body: some View {
        let attached = Set(agent.skills.map(\.id))
        let all = session.skills.items
        let available = all.filter { !attached.contains($0.id) }
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("agents", "tab_body.skills.add_dialog_title")).font(Theme.Font.title)
            AgentsUISkillPickerList(skills: available, selected: selected, loading: !session.skills.isLoaded,
                                    emptyMessage: all.isEmpty ? tr("agents", "tab_body.skills.add_dialog_empty") : tr("agents", "tab_body.skills.add_dialog_empty_partial")) { s in
                if selected.contains(s.id) { selected.remove(s.id) } else { selected.insert(s.id) }
            }
            HStack {
                Spacer()
                Button(tr("agents", "tab_body.skills.add_dialog_cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? tr("agents", "tab_body.skills.add_dialog_saving")
                       : selected.isEmpty ? tr("agents", "tab_body.skills.add_dialog_confirm_default")
                       : tr("agents", "tab_body.skills.add_dialog_confirm", ["count": selected.count])) {
                    confirm()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || saving)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { await session.skills.loadIfNeeded() }
    }

    private func confirm() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await session.api.setAgentSkills(agentId: agent.id, SetAgentSkillsRequest(skillIds: agent.skills.map(\.id) + selected.sorted()))
                await session.agentsUIReload(agent.id)
                dismiss()
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("agents", "tab_body.skills.add_failed_toast"), kind: .error)
            }
        }
    }
}

/// Skill content (workspace) or source facts (runtime).
struct AgentsUISkillDetailSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let selected: AgentsUISkillsTab.Selected
    @State private var skill: Skill?
    @State private var loading = false

    var body: some View {
        let runtimeSkill: RuntimeLocalSkillSummary? = { if case .runtime(let s) = selected { return s } else { return nil } }()
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(runtimeSkill?.name ?? skill?.name ?? tr("agents", "tab_body.skills.detail_title")).font(Theme.Font.title)
                Badge(text: runtimeSkill != nil ? tr("agents", "tab_body.skills.inherited_badge") : tr("agents", "tab_body.skills.workspace_badge"))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            }
            if let d = (runtimeSkill?.description?.isEmpty == false ? runtimeSkill?.description : nil) ?? skill?.description, !d.isEmpty {
                Text(d).font(Theme.Font.body).foregroundStyle(.secondary)
            }
            if loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(tr("agents", "tab_body.skills.detail_loading")) }
                    .foregroundStyle(.secondary).padding(.vertical, 24)
            } else if let r = runtimeSkill {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow { label("tab_body.skills.detail_source"); Text(r.sourcePath).textSelection(.enabled) }
                    GridRow { label("tab_body.skills.detail_provider"); Text(r.provider) }
                    if let p = r.plugin { GridRow { label("tab_body.skills.detail_plugin"); Text(p) } }
                    GridRow { label("tab_body.skills.detail_files"); Text("\(r.fileCount)") }
                }
                .font(Theme.Font.caption)
                .padding(16)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
            } else if let skill {
                ScrollView {
                    Text(skill.content).font(Theme.Font.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                .frame(maxHeight: 384)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
                if !skill.files.isEmpty {
                    Text(tr("agents", "tab_body.skills.detail_supporting_files")).font(Theme.Font.caption.weight(.medium))
                    AgentsUIFlowLayout(spacing: 6) {
                        ForEach(skill.files) { f in Badge(text: f.path) }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 640)
        .task {
            guard case .workspace(let id) = selected else { return }
            loading = true
            skill = try? await session.api.getSkill(id)
            loading = false
        }
    }

    private func label(_ key: String) -> some View {
        Text(tr("agents", key)).foregroundStyle(.secondary)
    }
}
