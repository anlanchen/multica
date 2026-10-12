import MulticaCore
import SwiftUI

/// Settings › Custom Args (upstream tabs/custom-args-tab): ordered CLI
/// tokens with inline add/edit and a launch command preview.
struct AgentsUICustomArgsTab: View {
    @Environment(Toaster.self) private var toaster
    let agent: AgentRecord
    let runtime: RuntimeDeviceRecord?
    let onDirtyChange: (Bool) -> Void
    let onSave: ([String: JSONValue]) async throws -> Void

    struct Arg: Identifiable, Equatable {
        let id = UUID()
        var value: String
    }

    enum Editor: Equatable { case add, edit(UUID) }

    @State private var entries: [Arg] = []
    @State private var editor: Editor?
    @State private var editorValue = ""
    @State private var saving = false
    @State private var seededFor: String?
    @FocusState private var editorFocused: Bool

    private var current: [String] { entries.map { $0.value.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    private var dirty: Bool { current != agent.customArgs }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(tr("agents", "tab_body.custom_args.intro")).font(Theme.Font.body).foregroundStyle(.secondary)
            AgentsUISettingsSection(title: tr("agents", "tab_body.custom_args.arguments_label"),
                                    description: tr("agents", "tab_body.custom_args.arguments_description")) {
                Button { startAdd() } label: { Label(tr("agents", "tab_body.custom_args.add_argument_action"), systemImage: "plus") }
                    .disabled(editor != nil)
            } content: {
                VStack(spacing: 8) {
                    if entries.isEmpty && editor != .add {
                        VStack(spacing: 10) {
                            Image(systemName: "terminal").foregroundStyle(.secondary)
                                .frame(width: 36, height: 36)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                            Text(tr("agents", "tab_body.custom_args.empty_title")).font(Theme.Font.bodyMedium)
                        }
                        .frame(maxWidth: .infinity, minHeight: 112)
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                        if editor == .edit(e.id) {
                            editorView(index: i + 1)
                        } else {
                            HStack(spacing: 12) {
                                Text("\(i + 1)").font(Theme.Font.micro.weight(.medium).monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                                Text(e.value).font(Theme.Font.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                Button { startEdit(e) } label: { Image(systemName: "pencil") }
                                    .disabled(editor != nil)
                                    .help(tr("agents", "tab_body.custom_args.edit_aria", ["index": i + 1]))
                                Button { remove(e.id) } label: { Image(systemName: "trash") }
                                    .disabled(editor != nil)
                                    .help(tr("agents", "tab_body.custom_args.remove_aria", ["index": i + 1]))
                            }
                            .buttonStyle(.borderless)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
                        }
                    }
                    if editor == .add { editorView(index: nil) }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.02)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
            }
            if let header = runtime?.launchHeader, !header.isEmpty {
                let command = ([header] + current.map { $0.contains(where: \.isWhitespace) ? "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" : $0 })
                    .joined(separator: " ")
                AgentsUISettingsSection(title: tr("agents", "tab_body.custom_args.command_preview_label")) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                        Text(command).font(Theme.Font.mono).textSelection(.enabled).padding(.top, 6)
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.02)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
                }
            }
            AgentsUISaveBar(dirty: dirty, canSave: editor == nil, saving: saving, onSave: save)
        }
        .onAppear(perform: seed)
        .onChange(of: agent.id) { seed() }
        .onChange(of: dirty, initial: true) { onDirtyChange(dirty) }
    }

    private func seed() {
        guard seededFor != agent.id else { return }
        seededFor = agent.id
        entries = agent.customArgs.map { Arg(value: $0) }
    }

    private func editorView(index: Int?) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField(tr("agents", "tab_body.custom_args.input_placeholder"), text: $editorValue)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Font.mono)
                .focused($editorFocused)
                .onSubmit(commit)
                .onExitCommand(perform: close)
                .help(index.map { tr("agents", "tab_body.custom_args.input_aria", ["index": $0]) } ?? tr("agents", "tab_body.custom_args.new_argument_aria"))
            HStack(spacing: 8) {
                Button(tr("agents", "tab_body.custom_args.cancel_action"), action: close)
                Button(editor == .add ? tr("agents", "tab_body.custom_args.add_action") : tr("agents", "tab_body.custom_args.update_action"), action: commit)
                    .buttonStyle(.borderedProminent)
                    .disabled(editorValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.14)))
        .onAppear { editorFocused = true }
    }

    private func startAdd() {
        editor = .add
        editorValue = ""
    }

    private func startEdit(_ e: Arg) {
        editor = .edit(e.id)
        editorValue = e.value
    }

    private func close() {
        editor = nil
        editorValue = ""
    }

    private func commit() {
        let v = editorValue.trimmingCharacters(in: .whitespaces)
        guard let editor, !v.isEmpty else { return }
        switch editor {
        case .add: entries.append(Arg(value: v))
        case .edit(let id): if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].value = v }
        }
        close()
    }

    private func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if editor == .edit(id) { close() }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await onSave(["custom_args": JSONValue(current)])
                toaster.success(tr("agents", "tab_body.custom_args.saved_toast"))
            } catch {}
        }
    }
}

/// Settings › Routing for OpenClaw runtimes (upstream tabs/runtime-config-tab).
struct AgentsUIRuntimeConfigTab: View {
    @Environment(Toaster.self) private var toaster
    let agent: AgentRecord
    let onDirtyChange: (Bool) -> Void
    let onSave: ([String: JSONValue]) async throws -> Void

    @State private var form = AgentsUI.OpenclawForm()
    @State private var baseline = AgentsUI.OpenclawForm()
    @State private var saving = false

    private var original: AgentsUI.OpenclawConfig { AgentsUI.OpenclawConfig(agent.runtimeConfig) }
    private var dirty: Bool { !original.semanticallyEquals(form.config) }

    var body: some View {
        let gateway = form.mode == "gateway"
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("agents", "tab_body.runtime_config.mode_label")).font(Theme.Font.caption.weight(.medium))
                Picker("", selection: Binding(get: { form.mode }, set: { m in
                    guard m != form.mode else { return }
                    form.mode = m
                    form.tokenWasMasked = false
                })) {
                    Text(tr("agents", "tab_body.runtime_config.mode_local")).tag("local")
                    Text(tr("agents", "tab_body.runtime_config.mode_gateway")).tag("gateway")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(gateway ? tr("agents", "tab_body.runtime_config.mode_gateway_hint") : tr("agents", "tab_body.runtime_config.mode_local_hint"))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            GroupBox(tr("agents", "tab_body.runtime_config.gateway_legend")) {
                VStack(alignment: .leading, spacing: 12) {
                    field(tr("agents", "tab_body.runtime_config.host_label")) {
                        TextField(tr("agents", "tab_body.runtime_config.host_placeholder"), text: $form.host).font(Theme.Font.mono)
                    }
                    field(tr("agents", "tab_body.runtime_config.port_label")) {
                        TextField("18789", text: $form.port).font(Theme.Font.mono)
                        if !form.portValid {
                            Text(tr("agents", "tab_body.runtime_config.port_invalid")).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                        }
                    }
                    field(tr("agents", "tab_body.runtime_config.token_label")) {
                        SecureField(form.tokenWasMasked ? tr("agents", "tab_body.runtime_config.token_masked_placeholder")
                                    : tr("agents", "tab_body.runtime_config.token_placeholder"),
                                    text: Binding(get: { form.token }, set: { form.token = $0; form.tokenWasMasked = false }))
                            .font(Theme.Font.mono)
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("agents", "tab_body.runtime_config.tls_label")).font(Theme.Font.caption)
                            Text(tr("agents", "tab_body.runtime_config.tls_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $form.tls).toggleStyle(.switch).labelsHidden()
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(6)
                .disabled(!gateway)
                .opacity(gateway ? 1 : 0.5)
            }
            AgentsUISaveBar(dirty: dirty, canSave: form.portValid, saving: saving, onSave: save)
        }
        .onAppear {
            form = AgentsUI.OpenclawForm(original)
            baseline = form
        }
        .onChange(of: agent.runtimeConfig) {
            let next = AgentsUI.OpenclawForm(original)
            if form == baseline { form = next }
            baseline = next
        }
        .onChange(of: dirty, initial: true) { onDirtyChange(dirty) }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(Theme.Font.caption)
            content()
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await onSave(["runtime_config": .object(form.config.json)])
                toaster.success(tr("agents", "tab_body.runtime_config.saved_toast"))
            } catch {}
        }
    }
}
