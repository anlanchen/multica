import AppKit
import MulticaCore
import SwiftUI
import UniformTypeIdentifiers

/// Avatar picker: upload an image, pick an emoji, or remove (upstream
/// AvatarUploadControl, without the crop step).
struct AgentsUIAvatarControl: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let value: String?
    let name: String
    var size: CGFloat = 56
    var disabled = false
    let onChange: (String) -> Void
    var onClear: (() -> Void)? = nil

    @State private var open = false
    @State private var uploading = false
    @State private var emojiText = ""

    static let suggestions = ["🐙", "🦊", "🦉", "🐝", "🐼", "🐸", "🐯", "🦁", "🐨", "🐵", "🐧", "🐳",
                              "🦋", "🌞", "🌙", "⭐", "🔥", "⚡", "🍀", "🌈", "🚀", "🤖", "👾", "🧠"]

    var body: some View {
        Button { open.toggle() } label: {
            ZStack {
                AgentsUIAvatar(name: name, avatarURL: value, size: size)
                if uploading {
                    RoundedRectangle(cornerRadius: size * 0.28).fill(.black.opacity(0.35)).frame(width: size, height: size)
                    ProgressView().controlSize(.small)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !disabled {
                    Image(systemName: "camera.fill").font(.system(size: 9)).foregroundStyle(.white)
                        .padding(4).background(Circle().fill(Color.black.opacity(0.6))).offset(x: 3, y: 3)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled || uploading)
        .help(tr("common", "avatar_upload.change"))
        .popover(isPresented: $open, arrowEdge: .bottom) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { pickImage() } label: { Label(tr("common", "avatar_upload.upload_image"), systemImage: "photo.badge.plus") }
                .buttonStyle(HoverRowButtonStyle())
            Divider()
            Text(tr("common", "avatar_upload.emoji_label")).font(Theme.Font.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8), spacing: 4) {
                ForEach(Self.suggestions, id: \.self) { e in
                    Button { select(e) } label: { Text(e).font(.system(size: 18)).frame(width: 28, height: 28) }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                }
            }
            HStack(spacing: 6) {
                TextField(tr("common", "avatar_upload.more_emojis"), text: $emojiText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { select(emojiText) }
                Button { NSApp.orderFrontCharacterPalette(nil) } label: { Image(systemName: "face.smiling") }
                    .buttonStyle(.borderless)
            }
            if let onClear, value != nil {
                Divider()
                Button(role: .destructive) {
                    open = false
                    onClear()
                } label: { Label(tr("common", "avatar_upload.remove"), systemImage: "xmark") }
                    .buttonStyle(HoverRowButtonStyle())
            }
        }
        .padding(10)
        .frame(width: 270)
    }

    private func select(_ raw: String) {
        let e = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = e.first else { return }
        open = false
        emojiText = ""
        onChange("emoji:" + String(first))
    }

    private func pickImage() {
        open = false
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false else {
            toaster.error(tr("common", "avatar_upload.select_image"))
            return
        }
        uploading = true
        Task {
            defer { uploading = false }
            do {
                let a = try await session.upload(fileAt: url)
                onChange(a.url)
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("common", "avatar_upload.failed"), kind: .error)
            }
        }
    }
}

/// Settings › General (upstream AgentDetailInspector): profile with
/// autosave, then runtime / model / thinking / speed / concurrency.
struct AgentsUIGeneralTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let agent: AgentRecord
    let runtime: RuntimeDeviceRecord?
    let canEdit: Bool
    let onUpdate: ([String: JSONValue]) async throws -> Void

    enum SaveState { case idle, saving, saved, failed }
    enum Field: Hashable { case name, description, concurrency }

    @State private var name = ""
    @State private var description = ""
    @State private var saveState: SaveState = .idle
    @State private var saveTask: Task<Void, Never>?
    @State private var concurrency = ""
    @FocusState private var focus: Field?

    private var canDiscover: Bool {
        guard let runtime else { return false }
        return runtime.status == "online" && AgentsUI.isRuntimeUsable(runtime, userID: session.currentUser.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            AgentsUISettingsSection(title: tr("agents", "inspector.section_profile")) {
                saveIndicator
            } content: {
                AgentsUISettingsCard {
                    AgentsUISettingsRow(label: tr("agents", "inspector.avatar_label")) {
                        HStack {
                            Spacer()
                            AgentsUIAvatarControl(value: agent.avatarUrl, name: agent.name, size: 56, disabled: !canEdit) { url in
                                Task { try? await onUpdate(["avatar_url": .string(url)]) }
                            }
                        }
                    }
                    AgentsUISettingsRow(label: tr("agents", "inspector.name_label")) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .focused($focus, equals: .name)
                                .disabled(!canEdit)
                                .onSubmit { flush() }
                            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                                Text(tr("agents", "inspector.rename_required")).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                            }
                        }
                    }
                    AgentsUISettingsRow(label: tr("agents", "inspector.description_label"), alignTop: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: $description)
                                .focused($focus, equals: .description)
                                .font(Theme.Font.body)
                                .frame(height: 96)
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.primary.opacity(0.14)))
                                .overlay(alignment: .topLeading) {
                                    if description.isEmpty {
                                        Text(tr("agents", "inspector.description_placeholder")).foregroundStyle(.tertiary)
                                            .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                                    }
                                }
                                .disabled(!canEdit)
                                .onChange(of: description) {
                                    if description.count > AgentsUI.descriptionMaxLength {
                                        description = String(description.prefix(AgentsUI.descriptionMaxLength))
                                    }
                                }
                            AgentsUICharCounter(length: description.count, max: AgentsUI.descriptionMaxLength)
                        }
                    }
                }
            }
            AgentsUISettingsSection(title: tr("agents", "inspector.section_execution")) {
                AgentsUISettingsCard {
                    AgentsUISettingsRow(label: tr("agents", "inspector.prop_runtime")) {
                        AgentsUIRuntimeMachinePicker(value: agent.runtimeId, canEdit: canEdit) { id in
                            Task { try? await onUpdate(["runtime_id": .string(id), "model": "", "thinking_level": "", "service_tier": ""]) }
                        }
                    }
                    AgentsUISettingsRow(label: tr("agents", "inspector.prop_model")) {
                        AgentsUIModelPicker(runtimeID: agent.runtimeId, runtimeOnline: canDiscover, value: agent.model, canEdit: canEdit) { model in
                            changeModel(model)
                        }
                    }
                    AgentsUIThinkingField(label: tr("agents", "inspector.prop_thinking"), runtimeID: agent.runtimeId, runtimeOnline: canDiscover,
                                          provider: runtime?.provider ?? "", model: agent.model, value: agent.thinkingLevel ?? "",
                                          canEdit: canEdit) { v in Task { try? await onUpdate(["thinking_level": .string(v)]) } }
                    AgentsUIServiceTierField(label: tr("agents", "inspector.prop_speed"), runtimeID: agent.runtimeId, runtimeOnline: canDiscover,
                                             provider: runtime?.provider ?? "", model: agent.model, value: agent.serviceTier ?? "",
                                             canEdit: canEdit) { v in Task { try? await onUpdate(["service_tier": .string(v)]) } }
                    AgentsUISettingsRow(label: tr("agents", "inspector.prop_concurrency")) {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("", text: $concurrency)
                                .focused($focus, equals: .concurrency)
                                .textFieldStyle(.roundedBorder)
                                .font(Theme.Font.mono)
                                .disabled(!canEdit)
                                .onSubmit(commitConcurrency)
                            Text(tr("agents", "pickers.concurrency_range", ["min": AgentsUI.concurrencyRange.lowerBound, "max": AgentsUI.concurrencyRange.upperBound]))
                                .font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onAppear(perform: seed)
        .onChange(of: agent.id) { seed() }
        .onChange(of: agent.maxConcurrentTasks) { concurrency = String(agent.maxConcurrentTasks) }
        .onChange(of: focus) { old, _ in
            if old == .concurrency { commitConcurrency() }
            if old == .name || old == .description { flush() }
        }
        .onChange(of: name) { schedule() }
        .onChange(of: description) { schedule() }
        .onDisappear {
            commitConcurrency()
            flush()
        }
    }

    @ViewBuilder
    private var saveIndicator: some View {
        switch saveState {
        case .idle: EmptyView()
        case .saving: HStack(spacing: 5) { ProgressView().controlSize(.mini); Text(tr("settings", "auto_save.saving")) }.font(Theme.Font.caption).foregroundStyle(.secondary)
        case .saved: Label(tr("settings", "auto_save.saved"), systemImage: "checkmark").font(Theme.Font.caption).foregroundStyle(.secondary)
        case .failed: Label(tr("settings", "auto_save.failed"), systemImage: "exclamationmark.triangle").font(Theme.Font.caption).foregroundStyle(Theme.destructive)
        }
    }

    private func seed() {
        name = agent.name
        description = agent.description
        concurrency = String(agent.maxConcurrentTasks)
    }

    private var profileDirty: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n != agent.name || description != agent.description
    }

    private func schedule() {
        guard canEdit, profileDirty else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func flush() {
        saveTask?.cancel()
        guard canEdit, profileDirty else { return }
        Task { await save() }
    }

    private func save() async {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, description.count <= AgentsUI.descriptionMaxLength, profileDirty else { return }
        saveState = .saving
        do {
            try await session.agentsUIUpdate(agent.id, ["name": .string(n), "description": .string(description)], toaster: toaster, successToast: false)
            saveState = .saved
        } catch {
            saveState = .failed
        }
    }

    private func commitConcurrency() {
        guard let next = Int(concurrency.trimmingCharacters(in: .whitespaces)), AgentsUI.concurrencyRange.contains(next) else {
            concurrency = String(agent.maxConcurrentTasks)
            return
        }
        if next != agent.maxConcurrentTasks {
            Task { try? await onUpdate(["max_concurrent_tasks": .number(Double(next))]) }
        }
    }

    private func changeModel(_ model: String) {
        let catalog: [RuntimeModel]? = {
            guard canDiscover, let r = session.agentsUIStore.modelsState(agent.runtimeId).value else { return nil }
            return r.supported ? r.models : []
        }()
        let change = AgentsUI.modelChange(provider: runtime?.provider ?? "", model: model, thinkingLevel: agent.thinkingLevel ?? "",
                                          serviceTier: agent.serviceTier ?? "", catalog: catalog)
        Task { try? await onUpdate(change.patch) }
    }
}
