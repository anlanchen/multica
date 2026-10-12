import MulticaCore
import SwiftUI

/// Add a library MCP server, or replace a saved one's write-only
/// configuration (upstream agents/components/tabs/mcp-server-dialog.tsx in
/// the workspace library's create / replacement modes).
struct ConnectionsMcpServerDialog: View {
    @Environment(\.dismiss) private var dismiss
    let replacing: WorkspaceMcpServer?
    let existingNames: Set<String>
    let onSave: (String, [String: JSONValue]) async -> Bool

    private enum Mode: Hashable { case form, json }
    @State private var name = ""
    @State private var mode = Mode.form
    @State private var form = ConnectionsMcpForm()
    @State private var jsonText = "{}"
    @State private var saving = false
    @State private var saveAttempted = false
    @FocusState private var focus: Field?

    private enum Field: Hashable { case name, command, url, json }

    init(replacing: WorkspaceMcpServer?, existingNames: Set<String>, onSave: @escaping (String, [String: JSONValue]) async -> Bool) {
        self.replacing = replacing
        self.existingNames = existingNames
        self.onSave = onSave
        // Replacement starts blank; only the safe transport summary seeds the form.
        let seeded = ConnectionsMcpForm(transport: replacing.map { ConnectionsMcp.transportKind($0.transport) == .stdio ? .stdio : .http } ?? .stdio)
        _form = State(initialValue: seeded)
        _mode = State(initialValue: .form)
    }

    private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
        tr("agents", "tab_body.mcp_config.\(key)", args)
    }

    private var submittedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var nameError: String? {
        guard replacing == nil else { return nil }
        if submittedName.isEmpty { return t("dialog_name_required") }
        if !ConnectionsMcp.isValidName(submittedName) { return t("dialog_name_invalid") }
        if existingNames.contains(submittedName) { return t("dialog_name_duplicate") }
        return nil
    }

    private var jsonResult: ConnectionsMcp.JSONParse { ConnectionsMcp.parseServerJSON(jsonText) }

    private var jsonError: String? {
        switch jsonResult {
        case .ok: return nil
        case .notObject: return t("dialog_json_object")
        case .missingTarget: return t("dialog_json_target")
        case .invalid(let e): return t("invalid_json", ["error": e])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(replacing.map { t("dialog_replace_title", ["name": $0.name]) } ?? t("dialog_add_title"))
                    .font(.system(size: 15, weight: .semibold))
                if replacing != nil {
                    Text(t("dialog_replace_description")).font(Theme.Font.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if replacing == nil {
                        ConnectionsField(label: t("dialog_name_label"), hint: t("dialog_name_hint"), error: saveAttempted ? nameError : nil) {
                            TextField("", text: $name).textFieldStyle(.roundedBorder).focused($focus, equals: .name)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(t("dialog_editor_label")).font(Theme.Font.bodyMedium)
                        Picker("", selection: Binding(get: { mode }, set: switchMode)) {
                            Text(t("dialog_form_tab")).tag(Mode.form)
                            Text(t("dialog_json_tab")).tag(Mode.json)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if mode == .form { formEditor } else { jsonEditor }
                }
                .padding(24)
            }
            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button(t("dialog_cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 6) {
                        if saving { ProgressView().controlSize(.small) }
                        Text(replacing != nil ? t("dialog_replace_action") : t("dialog_add_action"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(saving)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.02))
        }
        .frame(width: 620, height: 620)
        .interactiveDismissDisabled(saving)
        .onAppear { focus = replacing == nil ? .name : .command }
    }

    private func switchMode(_ next: Mode) {
        if next == .json, mode == .form {
            jsonText = ConnectionsMcp.prettyJSON(form.config)
        } else if next == .form, mode == .json, case .ok(let config) = jsonResult {
            form = ConnectionsMcpForm(config: config)
        }
        saveAttempted = false
        mode = next
    }

    @ViewBuilder private var formEditor: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("dialog_type_label")).font(Theme.Font.bodyMedium)
                HStack(spacing: 12) {
                    transportOption(.stdio, icon: "terminal", title: t("dialog_type_stdio"), hint: t("dialog_type_stdio_hint"))
                    transportOption(.http, icon: "globe", title: t("dialog_type_http"), hint: t("dialog_type_http_hint"))
                }
            }
            let problem = saveAttempted ? form.problem : nil
            if form.transport == .stdio {
                ConnectionsField(label: t("dialog_command_label"), error: problem == .command ? t("dialog_command_required") : nil) {
                    TextField("npx", text: $form.command).textFieldStyle(.roundedBorder).focused($focus, equals: .command)
                }
                ConnectionsMcpListEditor(label: t("dialog_args_label"), description: t("dialog_args_hint"),
                                         addLabel: t("dialog_add_arg"), removeLabel: t("dialog_remove_arg"), values: $form.args)
                ConnectionsMcpPairsEditor(label: t("dialog_env_label"), description: t("dialog_env_hint"),
                                          addLabel: t("dialog_add_env"), removeLabel: t("dialog_remove_env"),
                                          keyLabel: t("dialog_env_key"), valueLabel: t("dialog_value"), rows: $form.env)
            } else {
                ConnectionsField(label: t("dialog_url_label"), error: problem == .url ? t("dialog_url_required") : nil) {
                    TextField("https://mcp.example.com/mcp", text: $form.url).textFieldStyle(.roundedBorder).focused($focus, equals: .url)
                }
                ConnectionsMcpPairsEditor(label: t("dialog_headers_label"), description: t("dialog_headers_hint"),
                                          addLabel: t("dialog_add_header"), removeLabel: t("dialog_remove_header"),
                                          keyLabel: t("dialog_header_key"), valueLabel: t("dialog_value"), rows: $form.headers)
            }
        }
    }

    private func transportOption(_ transport: ConnectionsMcpForm.Transport, icon: String, title: String, hint: String) -> some View {
        let selected = form.transport == transport
        return Button {
            saveAttempted = false
            form.transport = transport
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Font.bodyMedium)
                    Text(hint).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.brand.opacity(0.08) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.brand : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var jsonEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("dialog_json_help")).font(Theme.Font.caption).foregroundStyle(.secondary)
            ConnectionsField(label: t("dialog_json_label"), error: saveAttempted ? jsonError : nil) {
                TextEditor(text: $jsonText)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 288)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                    .focused($focus, equals: .json)
                    .accessibilityLabel(t("dialog_json_aria"))
            }
        }
    }

    private func save() async {
        saveAttempted = true
        guard !saving else { return }
        if nameError != nil { focus = .name; return }
        let config: [String: JSONValue]
        switch mode {
        case .form:
            if let p = form.problem { focus = p == .command ? .command : .url; return }
            config = form.config
        case .json:
            guard case .ok(let c) = jsonResult else { focus = .json; return }
            config = c
        }
        saving = true
        let ok = await onSave(replacing?.name ?? submittedName, config)
        saving = false
        if ok { dismiss() }
    }
}

private struct ConnectionsMcpListEditor: View {
    let label: String
    let description: String
    let addLabel: String
    let removeLabel: String
    @Binding var values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(Theme.Font.bodyMedium)
                    Text(description).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { values.append("") } label: { Label(addLabel, systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
            ForEach(values.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    TextField("\(label) \(i + 1)", text: Binding(get: { i < values.count ? values[i] : "" },
                                                                 set: { if i < values.count { values[i] = $0 } }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button { values.remove(at: i) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("\(removeLabel) \(i + 1)")
                }
            }
        }
    }
}

private struct ConnectionsMcpPairsEditor: View {
    let label: String
    let description: String
    let addLabel: String
    let removeLabel: String
    let keyLabel: String
    let valueLabel: String
    @Binding var rows: [ConnectionsKeyValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(Theme.Font.bodyMedium)
                    Text(description).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { rows.append(ConnectionsKeyValue()) } label: { Label(addLabel, systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
            ForEach($rows) { $row in
                HStack(spacing: 8) {
                    TextField(keyLabel, text: $row.key).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    TextField(valueLabel, text: $row.value).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(removeLabel)
                }
            }
        }
    }
}
