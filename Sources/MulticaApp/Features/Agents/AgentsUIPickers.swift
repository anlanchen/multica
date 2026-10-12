import MulticaCore
import SwiftUI

/// Field-style trigger: icon, label, chevron; opens a popover.
struct AgentsUIFieldPicker<Label: View, Content: View>: View {
    var disabled = false
    var help: String? = nil
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: (_ dismiss: @escaping () -> Void) -> Content
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            AgentsUIFieldBox(interactive: true) {
                label()
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .help(help ?? "")
        .popover(isPresented: $open, arrowEdge: .bottom) { content { open = false } }
    }
}

/// A popover row with a trailing checkmark.
struct AgentsUIPickerRow<Content: View>: View {
    let selected: Bool
    var disabled = false
    var help: String? = nil
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                content()
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.brand)
                }
            }
            .font(Theme.Font.body)
        }
        .buttonStyle(HoverRowButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .help(help ?? "")
    }
}

// MARK: - Runtime picker (settings)

/// Two-level runtime picker: machines, then that machine's runtimes
/// (upstream inspector/runtime-picker). Opens inside the selected
/// runtime's machine.
struct AgentsUIRuntimeMachinePicker: View {
    @Environment(WorkspaceSession.self) private var session
    let value: String
    var canEdit = true
    let onChange: (String) -> Void

    @State private var open = false
    @State private var mineOnly = true
    @State private var machineID: String?

    private var userID: String { session.currentUser.id }
    private var runtimes: [RuntimeDeviceRecord] { session.runtimeRecords.items }

    var body: some View {
        let selected = runtimes.first { $0.id == value }
        let all = AgentsUI.runtimeMachines(runtimes, now: Date())
        let selectedMachine = selected.flatMap { s in all.first { $0.runtimes.contains { $0.id == s.id } } }
        let label = selected.map { AgentsUI.runtimeRowLabel($0, machineTitle: selectedMachine?.title ?? "") }
        let combined = selected.map { _ in
            selectedMachine.map { m in m.title != label ? "\(label ?? "") · \(m.title)" : (label ?? "") } ?? (label ?? "")
        } ?? tr("agents", "pickers.runtime_none")
        let online = selected?.status == "online"
        if !canEdit {
            AgentsUIFieldBox {
                if let selected { AgentsUIProviderLogo(provider: selected.provider, size: 16) } else { Image(systemName: "desktopcomputer") }
                Text(combined).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if selected != nil { AgentsUIRuntimeDot(online: online, size: 7) }
            }
        } else {
            Button { toggle(selected: selected) } label: {
                AgentsUIFieldBox(interactive: true) {
                    if let selected { AgentsUIProviderLogo(provider: selected.provider, size: 16) } else {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                    }
                    if selected != nil {
                        (Text(label ?? "") + Text(selectedMachine.map { $0.title != label ? " · \($0.title)" : "" } ?? "").foregroundColor(.secondary))
                            .lineLimit(1)
                    } else {
                        Text(combined).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if selected != nil { AgentsUIRuntimeDot(online: online) }
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(selected != nil
                  ? tr("agents", "pickers.runtime_tooltip", ["name": combined, "status": online ? tr("agents", "pickers.runtime_online") : tr("agents", "pickers.runtime_offline")])
                  : tr("agents", "pickers.runtime_tooltip_none"))
            .popover(isPresented: $open, arrowEdge: .bottom) { popover(all: all) }
        }
    }

    private func visibleMachines(_ all: [AgentsUI.RuntimeMachine]) -> [AgentsUI.RuntimeMachine] {
        mineOnly ? AgentsUI.runtimeMachines(runtimes.filter { $0.ownerId == userID }, now: Date()) : all
    }

    private func toggle(selected: RuntimeDeviceRecord?) {
        if !open {
            if let selected, selected.ownerId != userID { mineOnly = false }
            let visible = visibleMachines(AgentsUI.runtimeMachines(runtimes, now: Date()))
            if let selected {
                machineID = visible.first { $0.runtimes.contains { $0.id == selected.id } }?.id
            } else {
                machineID = visible.count == 1 ? visible[0].id : nil
            }
        }
        open.toggle()
    }

    private func popover(all: [AgentsUI.RuntimeMachine]) -> some View {
        let machines = visibleMachines(all)
        let drilled = machineID.flatMap { id in machines.first { $0.id == id } }
        let hasOthers = runtimes.contains { $0.ownerId != userID }
        return VStack(alignment: .leading, spacing: 0) {
            if let drilled {
                Button { machineID = nil } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left").foregroundStyle(.secondary)
                        Text(drilled.title).font(Theme.Font.bodyMedium).lineLimit(1)
                        Spacer()
                        Text(tr("agents", "create_dialog.runtime_group_online", ["online": drilled.onlineCount, "total": drilled.runtimes.count]))
                            .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("agents", "pickers.runtime_back_to_machines"))
                Divider()
            } else if hasOthers {
                Picker("", selection: $mineOnly) {
                    Text(tr("agents", "scope.mine")).tag(true)
                    Text(tr("agents", "scope.all")).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let drilled {
                        ForEach(drilled.runtimes, id: \.id) { rt in runtimeRow(rt, machine: drilled) }
                    } else if machines.isEmpty {
                        Text(tr("agents", "pickers.runtime_empty")).font(Theme.Font.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(12)
                    } else {
                        ForEach(machines) { m in machineRow(m) }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 340)
    }

    private func machineRow(_ m: AgentsUI.RuntimeMachine) -> some View {
        let owners = Set(m.runtimes.compactMap(\.ownerId))
        let owner = owners.count == 1 ? owners.first.flatMap { session.directory.member(userID: $0) } : nil
        let contains = m.runtimes.contains { $0.id == value }
        return Button { machineID = m.id } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(m.title).font(Theme.Font.bodyMedium).lineLimit(1)
                        if m.mode == "cloud" { Badge(text: tr("agents", "create_dialog.runtime_cloud_badge"), color: Theme.info) }
                    }
                    HStack(spacing: 5) {
                        if let owner {
                            AvatarView(name: owner.name, url: owner.avatarURL, size: 14)
                            Text(owner.name).lineLimit(1)
                        }
                        if owner != nil && !m.providerNames.isEmpty { Text("·").foregroundStyle(.tertiary) }
                        ForEach(m.providerNames.prefix(4), id: \.self) { p in AgentsUIProviderLogo(provider: p, size: 12) }
                        if m.providerNames.count > 4 { Text("+\(m.providerNames.count - 4)").font(Theme.Font.micro) }
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(tr("agents", "create_dialog.runtime_group_online", ["online": m.onlineCount, "total": m.runtimes.count]))
                    .font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
                if contains { Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(HoverRowButtonStyle())
    }

    private func runtimeRow(_ rt: RuntimeDeviceRecord, machine: AgentsUI.RuntimeMachine) -> some View {
        let locked = !AgentsUI.isRuntimeUsable(rt, userID: userID)
        let online = rt.status == "online"
        let label = AgentsUI.runtimeRowLabel(rt, machineTitle: machine.title)
        let owner = rt.ownerId.flatMap { session.directory.member(userID: $0) }
        let tooltip = [label, owner.map { tr("agents", "pickers.runtime_owned_by", ["name": $0.name]) },
                       online ? tr("agents", "pickers.runtime_online") : tr("agents", "pickers.runtime_offline"),
                       locked ? tr("agents", "create_dialog.runtime_private_locked_tooltip") : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return AgentsUIPickerRow(selected: rt.id == value, disabled: locked, help: tooltip) {
            open = false
            if rt.id != value { onChange(rt.id) }
        } content: {
            AgentsUIProviderLogo(provider: rt.provider, size: 16)
            Text(label).font(Theme.Font.bodyMedium).lineLimit(1)
            if rt.runtimeMode == "cloud" { Badge(text: tr("agents", "create_dialog.runtime_cloud_badge"), color: Theme.info) }
            if locked {
                Label(tr("agents", "create_dialog.runtime_private_badge"), systemImage: "lock").font(Theme.Font.micro).foregroundStyle(.secondary)
            }
            AgentsUIRuntimeDot(online: online)
        }
    }
}

// MARK: - Model list (shared popover body)

/// Searchable model catalog with refresh, custom ids and clear; flat for
/// the settings picker, grouped by provider for the create dropdown.
struct AgentsUIModelList: View {
    @Environment(WorkspaceSession.self) private var session
    let runtimeID: String?
    let runtimeOnline: Bool
    let value: String
    var grouped = false
    let onSelect: (String) -> Void
    @State private var search = ""
    @FocusState private var focused: Bool

    var body: some View {
        let state = session.agentsUIStore.modelsState(runtimeOnline ? runtimeID : nil)
        let models = state.value?.models ?? []
        let q = search.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? models : models.filter { $0.id.lowercased().contains(q.lowercased()) || $0.label.lowercased().contains(q.lowercased()) }
        let canCreate = !q.isEmpty && !models.contains { $0.id == q || $0.label == q }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                TextField(tr("agents", "pickers.model_search_placeholder"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { if canCreate { onSelect(q) } else if let first = filtered.first { onSelect(first.id) } }
                Button {
                    guard let runtimeID, runtimeOnline else { return }
                    Task { await session.agentsUIStore.loadModels(runtimeID, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(state.isLoading ? 360 : 0))
                        .animation(state.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: state.isLoading)
                }
                .buttonStyle(.borderless)
                .disabled(!runtimeOnline || runtimeID == nil || state.isLoading)
                .help(state.isLoading ? tr("agents", "pickers.model_refreshing") : tr("agents", "pickers.model_refresh"))
            }
            .padding(8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if state.isInitialLoad {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(tr("agents", "pickers.model_discovering"))
                        }
                        .font(Theme.Font.caption).foregroundStyle(.secondary).padding(12)
                    } else {
                        if grouped {
                            let providers = filtered.reduce(into: [String]()) { acc, m in
                                let p = m.provider ?? ""
                                if !acc.contains(p) { acc.append(p) }
                            }
                            ForEach(providers, id: \.self) { p in
                                if !p.isEmpty {
                                    Text(p.uppercased()).font(Theme.Font.micro.weight(.medium)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                                }
                                ForEach(filtered.filter { ($0.provider ?? "") == p }, id: \.id) { m in modelRow(m) }
                            }
                        } else {
                            ForEach(filtered, id: \.id) { m in modelRow(m) }
                        }
                        if let error = state.error, models.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(tr("agents", "pickers.model_discovery_failed_title"), systemImage: "info.circle").font(Theme.Font.bodyMedium)
                                Text(error).font(Theme.Font.caption).textSelection(.enabled)
                                Text(tr("agents", "pickers.model_discovery_failed_hint")).font(Theme.Font.caption)
                            }
                            .foregroundStyle(.secondary)
                            .padding(12)
                        } else if filtered.isEmpty && !canCreate {
                            Text(grouped ? tr("agents", "pickers.model_empty_with_dot") : tr("agents", "pickers.model_empty"))
                                .font(Theme.Font.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(12)
                        }
                        let unavailable = state.value?.unavailableModels ?? []
                        if !unavailable.isEmpty {
                            Divider().padding(.vertical, 4)
                            Text(tr("agents", "pickers.model_unavailable_heading").uppercased())
                                .font(Theme.Font.micro.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 10)
                            ForEach(unavailable, id: \.id) { m in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.label).font(Theme.Font.body).foregroundStyle(.secondary).lineLimit(1)
                                    if let r = m.reason { Text(r).font(Theme.Font.caption).foregroundStyle(.secondary) }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                            }
                        }
                    }
                    if canCreate {
                        AgentsUIPickerRow(selected: false, help: tr("agents", "pickers.model_custom_tooltip", ["value": q])) { onSelect(q) } content: {
                            Image(systemName: "plus").foregroundStyle(Theme.brand)
                            Text(tr("agents", "pickers.model_custom_use", ["value": q])).foregroundStyle(Theme.brand).lineLimit(1)
                        }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 300)
            if !value.isEmpty {
                Divider()
                Button { onSelect("") } label: {
                    Text(grouped ? tr("agents", "model_dropdown.clear_full") : tr("agents", "pickers.model_clear"))
                        .font(Theme.Font.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(HoverRowButtonStyle())
                .help(tr("agents", "pickers.model_clear_title"))
                .padding(4)
            }
        }
        .frame(width: 320)
        .onAppear { focused = true }
        .task(id: runtimeID) {
            if let runtimeID, runtimeOnline { await session.agentsUIStore.loadModels(runtimeID) }
        }
    }

    private func modelRow(_ m: RuntimeModel) -> some View {
        AgentsUIPickerRow(selected: m.id == value, help: m.label != m.id ? "\(m.label) · \(m.id)" : m.id) { onSelect(m.id) } content: {
            VStack(alignment: .leading, spacing: 1) {
                Text(m.label).font(Theme.Font.bodyMedium).lineLimit(1)
                if m.label != m.id {
                    Text(m.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// Model field for agent settings (upstream inspector/model-picker).
struct AgentsUIModelPicker: View {
    @Environment(WorkspaceSession.self) private var session
    let runtimeID: String?
    let runtimeOnline: Bool
    let value: String
    var canEdit = true
    let onChange: (String) -> Void

    var body: some View {
        let state = session.agentsUIStore.modelsState(runtimeOnline ? runtimeID : nil)
        let label = value.isEmpty ? tr("agents", "pickers.model_default") : value
        Group {
            if let r = state.value, !r.supported, !state.isLoading {
                AgentsUIFieldBox(dashed: true) {
                    Image(systemName: "cpu")
                    Text(tr("agents", "pickers.model_managed_by_runtime")).italic()
                }
                .foregroundStyle(.secondary)
            } else if !canEdit {
                AgentsUIFieldBox {
                    Image(systemName: "cpu")
                    Text(label).font(Theme.Font.mono).lineLimit(1)
                }
                .foregroundStyle(.secondary)
            } else {
                AgentsUIFieldPicker(help: tr("agents", "pickers.model_tooltip", ["value": label])) {
                    Image(systemName: "cpu").foregroundStyle(.secondary)
                    Text(label).font(Theme.Font.mono).lineLimit(1)
                } content: { dismiss in
                    AgentsUIModelList(runtimeID: runtimeID, runtimeOnline: runtimeOnline, value: value) { id in
                        dismiss()
                        if id != value { onChange(id) }
                    }
                }
            }
        }
        .task(id: runtimeOnline ? runtimeID : nil) {
            if let runtimeID, runtimeOnline { await session.agentsUIStore.loadModels(runtimeID) }
        }
    }
}

// MARK: - Thinking / speed

/// Reasoning level field; hidden when the model advertises no levels and
/// nothing is persisted (an orphan value stays visible to clear it).
struct AgentsUIThinkingField: View {
    @Environment(WorkspaceSession.self) private var session
    let label: String
    let runtimeID: String?
    let runtimeOnline: Bool
    let provider: String
    let model: String
    let value: String
    let canEdit: Bool
    let onChange: (String) -> Void

    var body: some View {
        let models = session.agentsUIStore.modelsState(runtimeOnline ? runtimeID : nil).value?.models ?? []
        let levels = AgentsUI.thinkingModelEntry(models, model: model, provider: provider)?.thinking?.supportedLevels ?? []
        if !levels.isEmpty || !value.isEmpty {
            let selected = value.isEmpty ? nil : levels.first { $0.value == value }
            let display = selected?.label ?? (value.isEmpty ? tr("agents", "pickers.thinking_default") : value)
            AgentsUISettingsRow(label: label) {
                if canEdit {
                    AgentsUIFieldPicker(help: tr("agents", "pickers.thinking_tooltip", ["value": display])) {
                        Image(systemName: "brain").foregroundStyle(.secondary)
                        Text(display).lineLimit(1)
                    } content: { dismiss in
                        AgentsUIOptionPopover(
                            options: levels.map { AgentsUIOption(id: $0.value, label: $0.label, detail: $0.description) }, value: value,
                            clearLabel: value.isEmpty ? nil : tr("agents", "pickers.thinking_clear"),
                            clearHelp: tr("agents", "pickers.thinking_clear_title")
                        ) { v in
                            dismiss()
                            if v != value { onChange(v) }
                        }
                    }
                } else {
                    AgentsUIFieldBox { Image(systemName: "brain"); Text(display).lineLimit(1) }.foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Codex service tier; capability from the exact model's live catalog.
struct AgentsUIServiceTierField: View {
    @Environment(WorkspaceSession.self) private var session
    let label: String
    let runtimeID: String?
    let runtimeOnline: Bool
    let provider: String
    let model: String
    let value: String
    let canEdit: Bool
    let onChange: (String) -> Void

    var body: some View {
        let models = session.agentsUIStore.modelsState(runtimeOnline ? runtimeID : nil).value?.models ?? []
        let tiers = AgentsUI.findModelCapabilityEntry(models, model: model, provider: provider)?.serviceTiers ?? []
        let explicitStandard = models.contains { $0.supportsExplicitStandardServiceTier == true }
        if !tiers.isEmpty || explicitStandard || !value.isEmpty {
            let options: [AgentsUIOption] = (explicitStandard
                ? [AgentsUIOption(id: "default", label: tr("agents", "pickers.service_tier_standard"),
                                  detail: tr("agents", "pickers.service_tier_standard_description"))]
                : []) + tiers.filter { !explicitStandard || $0.id != "default" }.map { AgentsUIOption(id: $0.id, label: $0.name, detail: $0.description) }
            let display = options.first { $0.id == value }?.label ?? (value.isEmpty ? tr("agents", "pickers.service_tier_default") : value)
            AgentsUISettingsRow(label: label) {
                if canEdit {
                    AgentsUIFieldPicker(help: tr("agents", "pickers.service_tier_tooltip", ["value": display])) {
                        Image(systemName: "gauge.medium").foregroundStyle(.secondary)
                        Text(display).lineLimit(1)
                    } content: { dismiss in
                        AgentsUIOptionPopover(options: options, value: value,
                                              clearLabel: value.isEmpty ? nil : tr("agents", "pickers.service_tier_clear"),
                                              clearHelp: tr("agents", "pickers.service_tier_clear_title")) { v in
                            dismiss()
                            if v != value { onChange(v) }
                        }
                    }
                } else {
                    AgentsUIFieldBox { Image(systemName: "gauge.medium"); Text(display).lineLimit(1) }.foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AgentsUIOption: Identifiable, Hashable {
    var id: String
    var label: String
    var detail: String?
}

/// Labelled options with descriptions plus a "clear" footer.
struct AgentsUIOptionPopover: View {
    let options: [AgentsUIOption]
    let value: String
    var clearLabel: String?
    var clearHelp: String?
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(options) { o in
                    AgentsUIPickerRow(selected: o.id == value) { onSelect(o.id) } content: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(o.label).font(Theme.Font.bodyMedium)
                            if let d = o.detail, !d.isEmpty { Text(d).font(Theme.Font.micro).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .padding(4)
            if let clearLabel {
                Divider()
                Button { onSelect("") } label: {
                    Text(clearLabel).font(Theme.Font.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(HoverRowButtonStyle())
                .help(clearHelp ?? "")
                .padding(4)
            }
        }
        .frame(width: 280)
    }
}

// MARK: - Create flow pickers

/// Runtime picker for the create flows: grouped by machine, Mine/All,
/// search past six runtimes, seeds the first usable runtime.
struct AgentsUICreateRuntimePicker: View {
    @Environment(WorkspaceSession.self) private var session
    let selectedID: String
    var disabled = false
    let onSelect: (String) -> Void

    @State private var mineOnly = true
    @State private var open = false
    @State private var search = ""

    private var userID: String { session.currentUser.id }

    var body: some View {
        let runtimes = session.runtimeRecords.items
        let loading = !session.runtimeRecords.isLoaded
        let filtered = AgentsUI.createPickerRuntimes(runtimes, mineOnly: mineOnly, userID: userID)
        let selected = runtimes.first { $0.id == selectedID }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tr("agents", "create_dialog.runtime_label")).font(Theme.Font.caption).foregroundStyle(.secondary)
                Spacer()
                if runtimes.contains(where: { $0.ownerId != userID }) {
                    Picker("", selection: Binding(get: { mineOnly }, set: { setFilter($0, runtimes: runtimes) })) {
                        Text(tr("agents", "create_dialog.runtime_filter_mine")).tag(true)
                        Text(tr("agents", "create_dialog.runtime_filter_all")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.mini)
                    .disabled(disabled)
                }
            }
            .frame(height: 22)
            Button { open.toggle() } label: {
                HStack(spacing: 10) {
                    if loading { ProgressView().controlSize(.small) }
                    else if let selected { AgentsUIProviderLogo(provider: selected.provider, size: 16) }
                    else { Image(systemName: "cloud").foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(loading ? tr("agents", "create_dialog.runtime_loading")
                                 : selected.map(AgentsUI.runtimeDisplayName) ?? tr("agents", "create_dialog.runtime_none"))
                                .font(Theme.Font.bodyMedium).lineLimit(1)
                            if selected?.runtimeMode == "cloud" { Badge(text: tr("agents", "create_dialog.runtime_cloud_badge"), color: Theme.info) }
                        }
                        if let selected {
                            Text(selected.ownerId.flatMap { session.directory.member(userID: $0)?.name } ?? selected.deviceInfo)
                                .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.14)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled || (runtimes.isEmpty && !loading))
            .opacity(disabled ? 0.5 : 1)
            .popover(isPresented: $open, arrowEdge: .bottom) { popover(filtered, total: runtimes.count) }
        }
        .task(id: "\(filtered.map(\.id))\(selectedID)") {
            guard selectedID.isEmpty, !disabled else { return }
            if let first = filtered.first(where: { AgentsUI.isRuntimeUsable($0, userID: userID) }) { onSelect(first.id) }
        }
    }

    private func setFilter(_ mine: Bool, runtimes: [RuntimeDeviceRecord]) {
        guard mine != mineOnly else { return }
        mineOnly = mine
        let list = AgentsUI.createPickerRuntimes(runtimes, mineOnly: mine, userID: userID)
        onSelect(list.first { AgentsUI.isRuntimeUsable($0, userID: userID) }?.id ?? "")
    }

    private func popover(_ runtimes: [RuntimeDeviceRecord], total: Int) -> some View {
        let machines = AgentsUI.filterMachines(AgentsUI.runtimeMachines(runtimes, now: Date()), query: search)
        return VStack(alignment: .leading, spacing: 0) {
            if total > 6 {
                SearchField(text: $search, prompt: tr("agents", "create_dialog.runtime_search_placeholder"), autofocus: true).padding(6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if machines.isEmpty {
                        Text(tr("agents", "create_dialog.runtime_no_results")).font(Theme.Font.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                    ForEach(machines) { m in
                        HStack {
                            Text(m.title).lineLimit(1)
                            Spacer()
                            Text(tr("agents", "create_dialog.runtime_group_online", ["online": m.onlineCount, "total": m.runtimes.count])).monospacedDigit()
                        }
                        .font(Theme.Font.micro.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                        ForEach(m.runtimes, id: \.id) { rt in row(rt) }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 288)
        }
        .frame(width: 360)
        .onDisappear { search = "" }
    }

    private func row(_ rt: RuntimeDeviceRecord) -> some View {
        let locked = !AgentsUI.isRuntimeUsable(rt, userID: userID)
        let owner = rt.ownerId.flatMap { session.directory.member(userID: $0) }
        return AgentsUIPickerRow(selected: rt.id == selectedID, disabled: locked,
                                 help: locked ? tr("agents", "create_dialog.runtime_private_locked_tooltip") : nil) {
            onSelect(rt.id)
            open = false
        } content: {
            AgentsUIProviderLogo(provider: rt.provider, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(AgentsUI.runtimeDisplayName(rt)).font(Theme.Font.bodyMedium).lineLimit(1)
                    if rt.runtimeMode == "cloud" { Badge(text: tr("agents", "create_dialog.runtime_cloud_badge"), color: Theme.info) }
                    if locked { Label(tr("agents", "create_dialog.runtime_private_badge"), systemImage: "lock").font(Theme.Font.micro).foregroundStyle(.secondary) }
                }
                HStack(spacing: 4) {
                    if let owner {
                        AvatarView(name: owner.name, url: owner.avatarURL, size: 14)
                        Text(owner.name).lineLimit(1)
                    } else {
                        Text(rt.deviceInfo).lineLimit(1)
                    }
                }
                .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            AgentsUIRuntimeDot(online: rt.status == "online", size: 7)
        }
    }
}

/// Model dropdown for the create flows (upstream model-dropdown).
struct AgentsUIModelDropdown: View {
    @Environment(WorkspaceSession.self) private var session
    let runtimeID: String?
    let runtimeOnline: Bool
    let value: String
    var disabled = false
    let onChange: (String) -> Void
    @State private var open = false

    var body: some View {
        let state = session.agentsUIStore.modelsState(runtimeOnline ? runtimeID : nil)
        let models = state.value?.models ?? []
        let supported = state.value?.supported ?? true
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tr("agents", "model_dropdown.label")).font(Theme.Font.caption).foregroundStyle(.secondary)
                Spacer()
                if let e = state.error {
                    Text(tr("agents", "model_dropdown.discovery_failed")).font(Theme.Font.caption).foregroundStyle(.secondary).help(e)
                }
            }
            .frame(height: 22)
            if !supported && !state.isLoading {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("agents", "model_dropdown.managed_by_runtime_title"))
                        Text(tr("agents", "model_dropdown.managed_by_runtime_hint")).font(Theme.Font.caption)
                    }
                }
                .font(Theme.Font.body).foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                Button { open.toggle() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "cpu").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(value.isEmpty ? (disabled ? tr("agents", "model_dropdown.select_runtime_first")
                                                  : runtimeOnline ? tr("agents", "model_dropdown.default_provider")
                                                  : tr("agents", "model_dropdown.runtime_offline_manual")) : value)
                                .font(Theme.Font.bodyMedium).lineLimit(1)
                            if !value.isEmpty {
                                Text(models.first { $0.id == value }.map { $0.provider ?? "model" } ?? "custom")
                                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.14)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1)
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    AgentsUIModelList(runtimeID: runtimeID, runtimeOnline: runtimeOnline, value: value, grouped: true) { id in
                        open = false
                        onChange(id)
                    }
                }
            }
        }
        .task(id: runtimeOnline ? runtimeID : nil) {
            if let runtimeID, runtimeOnline { await session.agentsUIStore.loadModels(runtimeID) }
        }
        .onChange(of: supported) { if !supported && !value.isEmpty { onChange("") } }
    }
}
