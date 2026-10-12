import MulticaCore
import SwiftUI

/// Chrome shared by every creation route: back, flow title, step, chips.
struct AgentsUICreateShell<Content: View, Chips: View>: View {
    let title: String
    let step: String
    var backDisabled = false
    let onBack: () -> Void
    @ViewBuilder var chips: () -> Chips
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onBack) { Image(systemName: "arrow.left") }
                    .buttonStyle(.borderless)
                    .disabled(backDisabled)
                    .help(tr("agents", "creation_studio.back"))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(step).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                HStack(spacing: 8) { chips() }
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            .overlay(alignment: .bottom) { Divider() }
            content()
        }
        .tabTitle(title)
    }
}

struct AgentsUICreateChip: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

extension Navigator {
    /// Upstream `useBackOrReplace`: history back when there is one.
    func agentsUIBack(or route: AppRoute, query: [String: String] = [:]) {
        if canGoBack { back() } else { replace(route, query: query) }
    }
}

// MARK: - Choose method

struct AgentsUIChooseMethodPage: View {
    @Environment(Navigator.self) private var nav

    var body: some View {
        let squad = nav.query("squad")
        let query = squad.map { ["squad": $0] } ?? [:]
        AgentsUICreateShell(title: squad != nil ? tr("agents", "creation_studio.squad_title") : tr("agents", "creation_studio.title"),
                            step: tr("agents", "creation_studio.step_choose"),
                            onBack: { nav.agentsUIBack(or: .agents) }) {
            EmptyView()
        } content: {
            ScrollView {
                VStack(spacing: 36) {
                    VStack(spacing: 8) {
                        Text(tr("agents", "creation_studio.eyebrow").uppercased())
                            .font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary).tracking(1)
                        Text(tr("agents", "creation_studio.choose_title")).font(.system(size: 28, weight: .semibold))
                            .multilineTextAlignment(.center)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        card(icon: "doc.text", title: tr("agents", "creation_studio.modes.blank.title"),
                             description: tr("agents", "creation_studio.modes.blank.description"), recommended: false) {
                            nav.push(.newAgentManual, query: query)
                        }
                        card(icon: "bubble.left.and.text.bubble.right", title: tr("agents", "creation_studio.modes.ai.title"),
                             description: tr("agents", "creation_studio.modes.ai.description"), recommended: true) {
                            nav.push(.newAgentAI, query: query)
                        }
                    }
                    .frame(maxWidth: 768)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func card(icon: String, title: String, description: String, recommended: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    Spacer()
                    if recommended {
                        Text(tr("agents", "creation_studio.recommended")).font(Theme.Font.micro.weight(.medium)).foregroundStyle(Theme.brand)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Theme.brand.opacity(0.1)))
                    }
                }
                Text(title).font(.system(size: 15, weight: .semibold)).padding(.top, 28)
                Text(description).font(Theme.Font.body).foregroundStyle(.secondary).padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 20)
                HStack(spacing: 4) {
                    Text(tr("agents", "creation_studio.continue"))
                    Image(systemName: "chevron.right").font(.system(size: 10))
                }
                .font(Theme.Font.caption.weight(.medium))
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 224, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(recommended ? Theme.brand.opacity(0.025) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(recommended ? Theme.brand.opacity(0.3) : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 12)
    }
}

// MARK: - Shared form state

/// The draft plus the workspace catalogs every create route renders from.
@MainActor
struct AgentsUICreateForm {
    let session: WorkspaceSession

    var userID: String { session.currentUser.id }
    var runtimes: [RuntimeDeviceRecord] { session.runtimeRecords.items }
    var usableRuntimes: [RuntimeDeviceRecord] {
        runtimes.filter { $0.status == "online" && AgentsUI.isRuntimeUsable($0, userID: userID) }
    }

    func selectedRuntime(_ draft: AgentsUI.Draft) -> RuntimeDeviceRecord? { runtimes.first { $0.id == draft.runtimeId } }

    func ready(_ draft: AgentsUI.Draft) -> Bool {
        guard let rt = selectedRuntime(draft), AgentsUI.isRuntimeUsable(rt, userID: userID) else { return false }
        return draft.descriptionWithinLimit && !draft.accessInvalid && !draft.conversationStartersInvalid
    }
}

/// Commits a draft (not optimistic: the flow navigates to the new agent).
@MainActor
enum AgentsUICreateSubmit {
    struct Errors {
        var name: String?
        var form: String?
    }

    static func create(session: WorkspaceSession, toaster: Toaster, nav: Navigator, draft: AgentsUI.Draft, runtimeID: String,
                       squadID: String?, template: String? = nil, duplicateSource: AgentRecord? = nil,
                       onCreated: ((AgentRecord) async -> Void)? = nil) async -> Errors? {
        do {
            let agent = try await session.api.createAgent(AgentsUI.createRequest(draft, runtimeID: runtimeID, template: template, duplicateSource: duplicateSource))
            guard !agent.id.isEmpty else { return Errors(form: tr("agents", "creation_studio.create_failed")) }
            if let squadID {
                do {
                    _ = try await session.api.addSquadMember(squadId: squadID, memberType: "agent", memberId: agent.id)
                    await session.squads.refreshIfLoaded()
                } catch {
                    toaster.show(tr("agents", "create_dialog.squad_join_failed_toast",
                                    ["name": agent.name.isEmpty ? draft.name : agent.name, "error": (error as? APIError)?.message ?? "unknown error"]))
                }
            }
            await onCreated?(agent)
            session.agentRecords.upsert(agent)
            Task { await session.agentRecords.refreshIfLoaded() }
            toaster.success(tr("agents", "creation_studio.created", ["name": agent.name.isEmpty ? draft.name.trimmingCharacters(in: .whitespaces) : agent.name]))
            if let squadID { nav.push(.squad(squadID)) } else { nav.push(.agent(agent.id), title: agent.name) }
            return nil
        } catch {
            if (error as? APIError)?.status == 409 { return Errors(name: tr("agents", "creation_studio.name_conflict")) }
            return Errors(form: (error as? APIError)?.message ?? tr("agents", "creation_studio.create_failed"))
        }
    }
}

/// Commit / discard bar at the bottom of a create route.
struct AgentsUICreateFooter: View {
    let canCreate: Bool
    let creating: Bool
    let squad: Bool
    let error: String?
    let onCreate: () -> Void
    var onDiscard: (() -> Void)? = nil
    var discarding = false

    var body: some View {
        HStack(spacing: 12) {
            if let error {
                Text(error).font(Theme.Font.body).foregroundStyle(Theme.destructive).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }
            if let onDiscard {
                Button(tr("agents", "creation_studio.drafts.discard"), action: onDiscard)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(creating || discarding)
            }
            Button(action: onCreate) {
                HStack(spacing: 6) {
                    if creating { ProgressView().controlSize(.mini) }
                    Text(creating ? tr("agents", "creation_studio.creating")
                         : squad ? tr("agents", "creation_studio.create_and_add") : tr("agents", "creation_studio.create_and_open"))
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canCreate)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Configuration panel

/// Identity, behaviour, execution and access for a draft (upstream
/// agent-configuration-panel); `compact` stacks fields for the builder.
struct AgentsUIConfigurationPanel: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Binding var draft: AgentsUI.Draft
    var nameError: String?
    var compact = false
    var onNameChange: (() -> Void)? = nil
    /// Builder sessions rebind the carrier instead of editing the draft.
    var onRuntimeSelect: ((String) -> Void)? = nil
    var runtimeSwitchPending = false
    var runtimeSwitchInFlight = false

    var body: some View {
        let selected = session.runtimeRecords.item(draft.runtimeId)
        let locked = runtimeSwitchPending || runtimeSwitchInFlight
        let others = session.directory.members.filter { $0.userID != session.currentUser.id }
        VStack(alignment: .leading, spacing: compact ? 24 : 32) {
            AgentsUISettingsSection(title: tr("agents", "creation_studio.sections.identity")) {
                AgentsUISettingsCard {
                    row(tr("agents", "create_dialog.avatar.change_aria")) {
                        HStack {
                            if !compact { Spacer() }
                            AgentsUIAvatarControl(value: draft.avatarUrl, name: draft.name, size: compact ? 52 : 56) { draft.avatarUrl = $0 }
                                onClear: { draft.avatarUrl = nil }
                        }
                    }
                    row(tr("agents", "create_dialog.name_label")) {
                        VStack(alignment: .leading, spacing: 5) {
                            TextField(tr("agents", "create_dialog.name_placeholder"), text: Binding(get: { draft.name }, set: {
                                onNameChange?()
                                draft.name = $0
                            }))
                            .textFieldStyle(.roundedBorder)
                            if let nameError { Text(nameError).font(Theme.Font.caption).foregroundStyle(Theme.destructive) }
                        }
                    }
                    row(tr("agents", "create_dialog.description_label"), alignTop: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            AgentsUITextArea(text: Binding(get: { draft.description }, set: { draft.description = String($0.prefix(AgentsUI.descriptionMaxLength)) }),
                                             placeholder: tr("agents", "create_dialog.description_placeholder"), height: compact ? 60 : 80)
                            AgentsUICharCounter(length: draft.description.count, max: AgentsUI.descriptionMaxLength)
                        }
                    }
                }
            }
            AgentsUISettingsSection(title: tr("agents", "creation_studio.sections.behavior")) {
                AgentsUISettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("agents", "create_dialog.instructions.label")).font(Theme.Font.bodyMedium)
                        AgentsUITextArea(text: $draft.instructions, placeholder: tr("agents", "create_dialog.instructions.editor_placeholder"),
                                         height: compact ? 180 : 240, monospaced: true)
                    }
                    .padding(16)
                    if env.appConfig?.agentConversationStartersSupported == true {
                        AgentsUIConversationStartersEditor(value: $draft.conversationStarters).padding(16)
                    }
                    AgentsUISkillMultiSelect(selected: $draft.skillIds).padding(16)
                }
            }
            AgentsUISettingsSection(title: tr("agents", "creation_studio.sections.execution"),
                                    description: tr("agents", "creation_studio.sections.execution_hint")) {
                AgentsUISettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        let grid = compact ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 16), GridItem(.flexible())]
                        LazyVGrid(columns: grid, alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                AgentsUICreateRuntimePicker(selectedID: draft.runtimeId, disabled: locked) { id in
                                    guard id != draft.runtimeId else { return }
                                    if let onRuntimeSelect { onRuntimeSelect(id) } else { draft = draft.withRuntime(id) }
                                }
                                if runtimeSwitchPending {
                                    Text(tr("agents", "creation_studio.builder.switch_runtime_pending")).font(Theme.Font.caption).foregroundStyle(.secondary)
                                }
                            }
                            AgentsUIModelDropdown(runtimeID: selected?.id, runtimeOnline: selected?.status == "online", value: draft.model,
                                                  disabled: selected == nil || runtimeSwitchInFlight) { draft = draft.withModel($0) }
                        }
                        .padding(16)
                        AgentsUIThinkingField(label: tr("agents", "creation_studio.thinking_label"), runtimeID: selected?.id,
                                              runtimeOnline: selected?.status == "online", provider: selected?.provider ?? "", model: draft.model,
                                              value: draft.thinkingLevel, canEdit: !locked) { draft.thinkingLevel = $0 }
                        AgentsUIServiceTierField(label: tr("agents", "creation_studio.speed_label"), runtimeID: selected?.id,
                                                 runtimeOnline: selected?.status == "online", provider: selected?.provider ?? "", model: draft.model,
                                                 value: draft.serviceTier, canEdit: !locked) { draft.serviceTier = $0 }
                    }
                }
            }
            AgentsUISettingsSection(title: tr("agents", "creation_studio.sections.access")) {
                AgentsUISettingsCard {
                    VStack(spacing: 4) {
                        ForEach(AgentsUI.PermissionScope.allCases, id: \.self) { scope in
                            Button { draft.permissionScope = scope } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: draft.permissionScope == scope ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(draft.permissionScope == scope ? Theme.brand : .secondary)
                                        .padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tr("agents", "creation_studio.access.\(scope.rawValue).title")).font(Theme.Font.bodyMedium)
                                        Text(tr("agents", "creation_studio.access.\(scope.rawValue).description")).font(Theme.Font.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(draft.permissionScope == scope ? Theme.selected : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    if draft.permissionScope == .members {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(others) { m in
                                    let checked = draft.memberIds.contains(m.userID)
                                    Button {
                                        if checked { draft.memberIds.remove(m.userID) } else { draft.memberIds.insert(m.userID) }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(checked ? Theme.brand : .secondary)
                                            AvatarView(name: m.name, url: m.avatarURL, size: 18)
                                            Text(m.name).lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                    }
                                    .buttonStyle(HoverRowButtonStyle())
                                }
                                if draft.memberIds.isEmpty {
                                    Text(tr("agents", "creation_studio.access.members.required")).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                }
                            }
                            .padding(8)
                        }
                        .frame(maxHeight: 192)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row<C: View>(_ label: String, alignTop: Bool = false, @ViewBuilder _ content: @escaping () -> C) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(Theme.Font.bodyMedium)
                content()
            }
            .padding(16)
        } else {
            AgentsUISettingsRow(label: label, alignTop: alignTop, content: content)
        }
    }
}

/// Multiline plain-text field with placeholder.
struct AgentsUITextArea: View {
    @Binding var text: String
    var placeholder = ""
    var height: CGFloat = 80
    var monospaced = false

    var body: some View {
        TextEditor(text: $text)
            .font(monospaced ? Theme.Font.mono : Theme.Font.body)
            .frame(minHeight: height)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.primary.opacity(0.14)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(monospaced ? Theme.Font.mono : Theme.Font.body).foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                }
            }
    }
}

/// Collapsible skills multi-select (upstream skill-multi-select).
struct AgentsUISkillMultiSelect: View {
    @Environment(WorkspaceSession.self) private var session
    @Binding var selected: Set<String>
    @State private var expanded: Bool?

    var body: some View {
        let open = expanded ?? !selected.isEmpty
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tr("agents", "create_dialog.skills_section.label").uppercased()
                     + (open && !selected.isEmpty ? "  (\(selected.count))" : ""))
                    .font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary).tracking(0.5)
                Spacer()
                if open {
                    Button { expanded = false } label: { Label(tr("agents", "create_dialog.skills_section.collapse"), systemImage: "xmark") }
                        .buttonStyle(.borderless).font(Theme.Font.caption)
                }
            }
            if open {
                AgentsUISkillPickerList(skills: session.skills.items, selected: selected, loading: !session.skills.isLoaded,
                                        emptyMessage: tr("agents", "create_dialog.skills_section.list_empty_multi")) { s in
                    if selected.contains(s.id) { selected.remove(s.id) } else { selected.insert(s.id) }
                }
            } else {
                Button { expanded = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus").foregroundStyle(.secondary)
                        Text(selected.isEmpty ? tr("agents", "create_dialog.skills_section.placeholder")
                             : tr("agents", "create_dialog.skills_section.selected", ["count": selected.count]))
                            .foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .task { await session.skills.loadIfNeeded() }
    }
}

// MARK: - Manual create / duplicate

struct AgentsUIManualCreatePage: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster

    @State private var draft = AgentsUI.Draft()
    @State private var restored = false
    @State private var runtimeReset = false
    @State private var creating = false
    @State private var nameError: String?
    @State private var formError: String?

    private var duplicateID: String? { nav.query("duplicate") }
    private var squadID: String? { nav.query("squad") }
    private var duplicateSource: AgentRecord? { duplicateID.flatMap { session.agentRecords.item($0) } }
    private var storeKey: String { "multica:agents:manual-draft:\(session.workspace.id)" }

    var body: some View {
        let form = AgentsUICreateForm(session: session)
        let source = duplicateSource
        let selected = form.selectedRuntime(draft)
        AgentsUICreateShell(
            title: source.map { tr("agents", "creation_studio.duplicate_title", ["name": $0.name]) }
                ?? (squadID != nil ? tr("agents", "creation_studio.squad_title") : tr("agents", "creation_studio.title")),
            step: tr("agents", "creation_studio.step_configure"),
            onBack: { duplicateID != nil ? nav.agentsUIBack(or: .agents) : nav.agentsUIBack(or: .newAgent) }
        ) {
            AgentsUICreateChip(text: tr("agents", "creation_studio.modes.blank.title"))
            if let selected { AgentsUICreateChip(text: AgentsUI.runtimeDisplayLabel(selected)) }
        } content: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if source != nil { notice(tr("agents", "creation_studio.duplicate_env_notice")) }
                        if runtimeReset { notice(tr("agents", "creation_studio.duplicate_runtime_reset_notice")) }
                        AgentsUIConfigurationPanel(draft: $draft, nameError: nameError, onNameChange: { nameError = nil })
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 32)
                    .frame(maxWidth: 896)
                    .frame(maxWidth: .infinity)
                }
                AgentsUICreateFooter(canCreate: !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && form.ready(draft) && !creating,
                                     creating: creating, squad: squadID != nil, error: formError, onCreate: create)
            }
        }
        .task {
            async let a: Void = session.agentRecords.loadIfNeeded()
            async let r: Void = session.runtimeRecords.loadIfNeeded()
            async let s: Void = session.skills.loadIfNeeded()
            _ = await (a, r, s)
            seed()
        }
        .onChange(of: draft) { persist() }
        .onChange(of: form.usableRuntimes.map(\.id)) { seedRuntime() }
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(Theme.Font.body)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warning.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.warning.opacity(0.3)))
    }

    private var drafts: AgentsUI.ManualDrafts {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let d = try? JSONDecoder().decode(AgentsUI.ManualDrafts.self, from: data) else { return AgentsUI.ManualDrafts() }
        return d
    }

    /// Duplicate seed first (once runtimes settle), then any saved local
    /// draft for the same owner, then the first usable runtime.
    private func seed() {
        guard !restored else { return }
        let form = AgentsUICreateForm(session: session)
        if let source = duplicateSource {
            let d = AgentsUI.duplicateDraft(source, runtimes: form.runtimes, userID: form.userID,
                                            fallbackRuntimeID: form.usableRuntimes.first?.id ?? "",
                                            nameSuffix: tr("agents", "create_dialog.duplicate_copy_suffix"))
            runtimeReset = d.runtimeId != source.runtimeId
            draft = d
        }
        if let entry = drafts.byOwner[AgentsUI.ManualDrafts.owner(duplicateID: duplicateID)] {
            draft = entry.draft.draft(runtimeID: entry.runtimeId)
        }
        restored = true
        seedRuntime()
    }

    private func seedRuntime() {
        guard restored, draft.runtimeId.isEmpty, let first = AgentsUICreateForm(session: session).usableRuntimes.first else { return }
        draft.runtimeId = first.id
    }

    private func persist() {
        guard restored else { return }
        var d = drafts
        d.set(AgentsUI.ManualDrafts.owner(duplicateID: duplicateID),
              AgentsUI.ManualDrafts.Entry(runtimeId: draft.runtimeId, draft: AgentsUI.StoredDraft(draft, appliedMessageID: nil)))
        if let data = try? JSONEncoder().encode(d) { UserDefaults.standard.set(data, forKey: storeKey) }
    }

    private func create() {
        let runtimeID = draft.runtimeId
        guard !runtimeID.isEmpty, !creating else { return }
        creating = true
        nameError = nil
        formError = nil
        let owner = AgentsUI.ManualDrafts.owner(duplicateID: duplicateID)
        Task {
            let errors = await AgentsUICreateSubmit.create(session: session, toaster: toaster, nav: nav, draft: draft, runtimeID: runtimeID,
                                                          squadID: squadID, duplicateSource: duplicateSource) { _ in
                var d = drafts
                d.set(owner, nil)
                if let data = try? JSONEncoder().encode(d) { UserDefaults.standard.set(data, forKey: storeKey) }
                restored = false
            }
            if let errors {
                nameError = errors.name
                formError = errors.form
                creating = false
            }
        }
    }
}
