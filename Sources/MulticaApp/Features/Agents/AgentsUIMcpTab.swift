import MulticaCore
import SwiftUI

/// Capabilities › MCP (upstream tabs/mcp-config-tab): the agent's own
/// servers, workspace-library assignments, and the runtime's inventory.
struct AgentsUIMcpConfigTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let agent: AgentRecord
    let runtime: RuntimeDeviceRecord?
    let canEdit: Bool
    let onSave: ([String: JSONValue]) async throws -> Void

    @State private var assigned: [WorkspaceMcpServer]?
    @State private var library: [WorkspaceMcpServer] = []
    @State private var assignmentBusy = false
    @State private var editing: AgentsUI.ManagedMcpServer?
    @State private var editorOpen = false
    @State private var renaming: AgentsUI.ManagedMcpServer?
    @State private var renameDraft = ""
    @State private var renameError = ""
    @State private var renamePending = false
    @State private var deleting: AgentsUI.ManagedMcpServer?
    @State private var deletePending = false

    private var canRead: Bool { runtime.map { AgentsUI.isRuntimeUsable($0, userID: session.currentUser.id) } ?? false }
    private var discoverID: String? {
        guard let runtime, runtime.runtimeMode == "local", runtime.status == "online", canRead else { return nil }
        return runtime.id
    }
    private var managed: [AgentsUI.ManagedMcpServer] { AgentsUI.listManagedMcpServers(agent.mcpConfig) }

    var body: some View {
        let redacted = agent.mcpConfigRedacted == true
        let managed = managed
        let managedNames = Set(managed.map(\.name))
        let assignedList = assigned ?? []
        let effective = managedNames.union(assignedList.filter { $0.enabled != false }.map(\.name))
        let available = library.filter { lib in !assignedList.contains { $0.id == lib.id } }
        let state = session.agentsUIStore.localSkillsState(discoverID)
        VStack(alignment: .leading, spacing: 24) {
            group(tr("agents", "tab_body.mcp_config.managed_title")) {
                if !redacted && canEdit {
                    Button { editing = nil; editorOpen = true; cancelRename() } label: {
                        Label(tr("agents", "tab_body.mcp_config.add_action"), systemImage: "plus")
                    }
                    .disabled(renamePending)
                }
            } content: {
                if redacted {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tr("agents", "tab_body.mcp_config.redacted_title")).font(Theme.Font.bodyMedium)
                            Text(tr("agents", "tab_body.mcp_config.redacted_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
                } else if managed.isEmpty {
                    AgentsUINotice(text: tr("agents", "tab_body.mcp_config.managed_empty"))
                } else {
                    AgentsUIListCard {
                        ForEach(managed) { s in managedRow(s) }
                    }
                }
            }
            group(tr("agents", "tab_body.mcp_config.workspace_title")) {
                if canEdit && !available.isEmpty {
                    Menu {
                        ForEach(available) { s in
                            Button("\(s.name)    \(AgentsUI.mcpTransportLabel(s.transport))") { addWorkspace(s.id) }
                        }
                    } label: { Label(tr("agents", "tab_body.mcp_config.workspace_add_action"), systemImage: "plus") }
                        .fixedSize()
                        .disabled(assignmentBusy)
                }
            } content: {
                if assigned == nil {
                    AgentsUINotice(text: tr("agents", "tab_body.mcp_config.workspace_loading"), loading: true)
                } else if !assignedList.isEmpty {
                    AgentsUIListCard {
                        ForEach(assignedList) { s in workspaceRow(s, overridden: managedNames.contains(s.name)) }
                    }
                } else {
                    AgentsUINotice(text: library.isEmpty ? tr("agents", "tab_body.mcp_config.workspace_library_empty")
                                   : tr("agents", "tab_body.mcp_config.workspace_none_assigned"))
                }
            }
            group(runtime.map { tr("agents", "tab_body.mcp_config.runtime_title_named", ["runtime": AgentsUI.runtimeDisplayLabel($0)]) }
                  ?? tr("agents", "tab_body.mcp_config.runtime_title")) {
                if let id = discoverID {
                    Button { Task { await session.agentsUIStore.loadLocalSkills(id, force: true) } } label: {
                        Label(tr("agents", "tab_body.mcp_config.refresh_action"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(state.isLoading)
                }
            } content: {
                runtimeInventory(state, effective: effective)
            }
        }
        .task(id: agent.id) { await loadAssignments() }
        .task(id: discoverID) { if let id = discoverID { await session.agentsUIStore.loadLocalSkills(id) } }
        .sheet(isPresented: $editorOpen) {
            AgentsUIMcpServerSheet(server: editing, existingNames: managedNames, hideNameWhenEditing: true) { name, config in
                try await saveServer(name: name, config: config)
            }
        }
        .alert(tr("agents", "tab_body.mcp_config.delete_dialog_title"),
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 && !deletePending { deleting = nil } })) {
            Button(tr("agents", "tab_body.mcp_config.dialog_cancel"), role: .cancel) { deleting = nil }
            Button(tr("agents", "tab_body.mcp_config.delete_action"), role: .destructive) { deleteServer() }
        } message: {
            Text(tr("agents", "tab_body.mcp_config.delete_dialog_description", ["name": deleting?.name ?? ""]))
        }
    }

    @ViewBuilder
    private func runtimeInventory(_ state: AgentsUIStore.Discovery<AgentsUIStore.LocalSkills>, effective: Set<String>) -> some View {
        if runtime == nil {
            AgentsUINotice(text: tr("agents", "tab_body.mcp_config.runtime_missing"))
        } else if !canRead {
            AgentsUINotice(text: tr("agents", "tab_body.mcp_config.runtime_forbidden"))
        } else if runtime?.status != "online" {
            AgentsUINotice(text: tr("agents", "tab_body.mcp_config.runtime_offline"))
        } else if state.isInitialLoad || (state.value == nil && state.error == nil) {
            AgentsUINotice(text: tr("agents", "tab_body.mcp_config.runtime_discovering"), loading: true)
        } else if state.error != nil, state.value == nil {
            AgentsUINotice(text: session.agentsUIStore.localSkillsStatus[runtime?.id ?? ""] == 403
                           ? tr("agents", "tab_body.mcp_config.runtime_forbidden") : tr("agents", "tab_body.mcp_config.runtime_failed"))
        } else if let v = state.value, !v.mcpSupported {
            AgentsUINotice(text: tr("agents", "tab_body.mcp_config.runtime_unsupported"))
        } else if let v = state.value, v.mcpServers.isEmpty {
            AgentsUINotice(text: tr("agents", "tab_body.mcp_config.runtime_empty"))
        } else if let v = state.value {
            AgentsUIListCard {
                ForEach(v.mcpServers, id: \.name) { s in
                    HStack(spacing: 12) {
                        AgentsUIMcpTransportIcon(transport: s.transport ?? "unknown")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(Theme.Font.bodyMedium).lineLimit(1)
                            Text(AgentsUI.mcpTransportLabel(s.transport ?? "unknown")).font(Theme.Font.caption).foregroundStyle(.secondary)
                            if let source = s.source { Text(source).font(Theme.Font.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if effective.contains(s.name) {
                            Badge(text: tr("agents", "tab_body.mcp_config.runtime_overridden_badge"))
                        } else if !s.enabled {
                            Badge(text: tr("agents", "tab_body.mcp_config.runtime_disabled_badge"))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(minHeight: 64)
                }
            }
        }
    }

    private func group<A: View, C: View>(_ title: String, @ViewBuilder action: () -> A, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(Theme.Font.bodyMedium).lineLimit(1)
                Spacer()
                action()
            }
            content()
        }
    }

    private func managedRow(_ s: AgentsUI.ManagedMcpServer) -> some View {
        HStack(spacing: 12) {
            AgentsUIMcpTransportIcon(transport: s.transport)
            VStack(alignment: .leading, spacing: 4) {
                if renaming?.id == s.id {
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("", text: $renameDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 384)
                                .onSubmit(submitRename)
                                .onExitCommand(perform: cancelRename)
                                .onChange(of: renameDraft) { renameError = "" }
                                .disabled(renamePending)
                                .help(tr("agents", "tab_body.mcp_config.rename_server"))
                            if !renameError.isEmpty {
                                Text(renameError).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                            }
                        }
                        Button(action: submitRename) {
                            if renamePending { ProgressView().controlSize(.mini) } else { Image(systemName: "checkmark") }
                        }
                        .disabled(renamePending)
                        .help(tr("agents", "tab_body.mcp_config.rename_save"))
                        Button(action: cancelRename) { Image(systemName: "xmark") }
                            .disabled(renamePending)
                            .help(tr("agents", "tab_body.mcp_config.rename_cancel"))
                    }
                } else {
                    HStack(spacing: 8) {
                        Text(s.name).font(Theme.Font.bodyMedium).lineLimit(1)
                        if !s.enabled { Badge(text: tr("agents", "tab_body.mcp_config.agent_disabled_badge")) }
                    }
                }
                Text(AgentsUI.mcpTransportLabel(s.transport)).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if canEdit && renaming?.id != s.id {
                HStack(spacing: 2) {
                    Button { startRename(s) } label: { Image(systemName: "pencil") }
                        .help(tr("agents", "tab_body.mcp_config.rename_action"))
                    Button {
                        cancelRename()
                        editing = s
                        editorOpen = true
                    } label: { Image(systemName: "slider.horizontal.3") }
                        .help(tr("agents", "tab_body.mcp_config.edit_config"))
                    Divider().frame(height: 16).padding(.horizontal, 4)
                    Button {
                        cancelRename()
                        deleting = s
                    } label: { Image(systemName: "trash") }
                        .help(tr("agents", "tab_body.mcp_config.delete_action_short"))
                }
                .buttonStyle(.borderless)
                .disabled(renamePending)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
    }

    private func workspaceRow(_ s: WorkspaceMcpServer, overridden: Bool) -> some View {
        let enabled = s.enabled != false
        return HStack(spacing: 12) {
            AgentsUIMcpTransportIcon(transport: s.transport)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(s.name).font(Theme.Font.bodyMedium).lineLimit(1)
                    if overridden { Badge(text: tr("agents", "tab_body.mcp_config.workspace_overridden_badge")) }
                }
                Text(AgentsUI.mcpTransportLabel(s.transport)).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if canEdit {
                Toggle("", isOn: Binding(get: { enabled }, set: { v in assignment { try await session.api.setAgentMcpServerEnabled(agentId: agent.id, serverId: s.id, enabled: v) } }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(assignmentBusy)
                    .help(tr("agents", "tab_body.mcp_config.workspace_toggle_aria", ["name": s.name]))
                Divider().frame(height: 16)
                Button {
                    assignment(toast: tr("agents", "tab_body.mcp_config.workspace_removed_toast")) {
                        try await session.api.removeAgentMcpServer(agentId: agent.id, serverId: s.id)
                    }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(assignmentBusy)
                    .help(tr("agents", "tab_body.mcp_config.workspace_remove_aria", ["name": s.name]))
            } else if !enabled {
                Badge(text: tr("agents", "tab_body.mcp_config.workspace_disabled_badge"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
    }

    private func loadAssignments() async {
        let api = session.api
        async let a = try? api.listAgentMcpServers(agentId: agent.id)
        async let l = try? api.listWorkspaceMcpServers(workspaceId: agent.workspaceId.isEmpty ? session.workspace.id : agent.workspaceId)
        let (list, lib) = await (a, l)
        assigned = list ?? []
        library = lib ?? []
    }

    private func addWorkspace(_ id: String) {
        assignment(toast: tr("agents", "tab_body.mcp_config.workspace_added_toast")) {
            try await session.api.addAgentMcpServer(agentId: agent.id, serverId: id)
        }
    }

    private func assignment(toast: String? = nil, _ op: @escaping () async throws -> [WorkspaceMcpServer]) {
        assignmentBusy = true
        Task {
            defer { assignmentBusy = false }
            do {
                assigned = try await op()
                if let toast { toaster.success(toast) }
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("agents", "tab_body.mcp_config.workspace_action_failed"), kind: .error)
                await loadAssignments()
            }
        }
    }

    private func startRename(_ s: AgentsUI.ManagedMcpServer) {
        guard !renamePending else { return }
        renaming = s
        renameDraft = s.name
        renameError = ""
    }

    private func cancelRename() {
        guard !renamePending else { return }
        renaming = nil
        renameDraft = ""
        renameError = ""
    }

    private func submitRename() {
        guard let target = renaming, !renamePending else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { renameError = tr("agents", "tab_body.mcp_config.dialog_name_required"); return }
        if !AgentsUI.isValidMcpServerName(name) { renameError = tr("agents", "tab_body.mcp_config.dialog_name_invalid"); return }
        if name != target.name && managed.contains(where: { $0.name == name }) {
            renameError = tr("agents", "tab_body.mcp_config.dialog_name_duplicate")
            return
        }
        if name == target.name { cancelRename(); return }
        guard let current = managed.first(where: { $0.container == target.container && $0.name == target.name }) else {
            renameError = tr("agents", "tab_body.mcp_config.rename_failed_toast")
            return
        }
        renamePending = true
        Task {
            defer { renamePending = false }
            do {
                try await onSave(["mcp_config": .object(AgentsUI.upsertManagedMcpServer(agent.mcpConfig, previous: current, name: name, config: current.config))])
                toaster.success(tr("agents", "tab_body.mcp_config.renamed_toast"))
                renaming = nil
                renameDraft = ""
            } catch {
                renameError = (error as? APIError)?.message ?? tr("agents", "tab_body.mcp_config.rename_failed_toast")
            }
        }
    }

    private func saveServer(name: String, config: [String: JSONValue]) async throws {
        let next = AgentsUI.upsertManagedMcpServer(agent.mcpConfig, previous: editing, name: name, config: config)
        try await onSave(["mcp_config": .object(next)])
        toaster.success(editing != nil ? tr("agents", "tab_body.mcp_config.updated_toast") : tr("agents", "tab_body.mcp_config.added_toast"))
    }

    private func deleteServer() {
        guard let target = deleting else { return }
        deletePending = true
        Task {
            defer {
                deletePending = false
                deleting = nil
            }
            let next = AgentsUI.removeManagedMcpServer(agent.mcpConfig, server: target)
            do {
                try await onSave(["mcp_config": next.map(JSONValue.object) ?? .null])
                toaster.success(tr("agents", "tab_body.mcp_config.deleted_toast"))
            } catch {}
        }
    }
}

struct AgentsUIMcpTransportIcon: View {
    let transport: String

    var body: some View {
        let t = transport.trimmingCharacters(in: .whitespaces).lowercased()
        let icon = t == "stdio" || t == "local" ? "terminal" : (t == "http" || t == "remote" || t == "streamable-http" ? "globe" : "server.rack")
        Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .help(AgentsUI.mcpTransportLabel(transport))
    }
}

/// Add / edit one MCP server: guided form (STDIO or Streamable HTTP) or raw
/// JSON (upstream tabs/mcp-server-dialog).
struct AgentsUIMcpServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: AgentsUI.ManagedMcpServer?
    let existingNames: Set<String>
    var hideNameWhenEditing = false
    let onSave: (String, [String: JSONValue]) async throws -> Void

    enum Mode: String { case form, json }

    @State private var name = ""
    @State private var mode: Mode = .form
    @State private var form = AgentsUI.McpForm()
    @State private var jsonText = "{}"
    @State private var saving = false
    @State private var attempted = false

    private var formAvailable: Bool { server.map(AgentsUI.mcpFormSupports) ?? true }
    private var nameHidden: Bool { hideNameWhenEditing && server != nil }
    private var preservesName: Bool { server != nil && name == server?.name }
    private var submittedName: String { preservesName ? name : name.trimmingCharacters(in: .whitespaces) }

    private var nameError: String? {
        if preservesName { return nil }
        let n = submittedName
        if n.isEmpty { return tr("agents", "tab_body.mcp_config.dialog_name_required") }
        if !AgentsUI.isValidMcpServerName(n) { return tr("agents", "tab_body.mcp_config.dialog_name_invalid") }
        if existingNames.contains(n) && n != server?.name { return tr("agents", "tab_body.mcp_config.dialog_name_duplicate") }
        return nil
    }

    private var jsonResult: Result<[String: JSONValue], AgentsUI.McpJSONError> { AgentsUI.parseMcpServerJSON(jsonText) }

    private var jsonError: String? {
        guard case .failure(let e) = jsonResult else { return nil }
        switch e {
        case .notObject: return tr("agents", "tab_body.mcp_config.dialog_json_object")
        case .missingTarget: return tr("agents", "tab_body.mcp_config.dialog_json_target")
        case .invalid(let m): return tr("agents", "tab_body.mcp_config.invalid_json", ["error": m])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(server.map { nameHidden ? tr("agents", "tab_body.mcp_config.dialog_edit_title_named", ["name": $0.name])
                                         : tr("agents", "tab_body.mcp_config.dialog_edit_title") }
                 ?? tr("agents", "tab_body.mcp_config.dialog_add_title"))
                .font(Theme.Font.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !nameHidden {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tr("agents", "tab_body.mcp_config.dialog_name_label")).font(Theme.Font.bodyMedium)
                            TextField("", text: $name).textFieldStyle(.roundedBorder)
                            if attempted, let nameError {
                                Text(nameError).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                            } else {
                                Text(tr("agents", "tab_body.mcp_config.dialog_name_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(tr("agents", "tab_body.mcp_config.dialog_editor_label")).font(Theme.Font.bodyMedium)
                        Picker("", selection: Binding(get: { mode }, set: switchMode)) {
                            Text(tr("agents", "tab_body.mcp_config.dialog_form_tab")).tag(Mode.form)
                            Text(tr("agents", "tab_body.mcp_config.dialog_json_tab")).tag(Mode.json)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(!formAvailable)
                    }
                    if mode == .form { formBody } else { jsonBody }
                }
                .padding(28)
            }
            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button(tr("agents", "tab_body.mcp_config.dialog_cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button { save() } label: {
                    HStack(spacing: 5) {
                        if saving { ProgressView().controlSize(.mini) }
                        Text(server != nil ? tr("agents", "tab_body.mcp_config.dialog_update_action") : tr("agents", "tab_body.mcp_config.dialog_add_action"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
            }
            .controlSize(.small)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.03))
        }
        .frame(width: 620, height: 640)
        .onAppear(perform: seed)
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("agents", "tab_body.mcp_config.dialog_type_label")).font(Theme.Font.bodyMedium)
                HStack(spacing: 12) {
                    transportCard(.stdio, icon: "terminal", title: tr("agents", "tab_body.mcp_config.dialog_type_stdio"),
                                  hint: tr("agents", "tab_body.mcp_config.dialog_type_stdio_hint"))
                    transportCard(.http, icon: "globe", title: tr("agents", "tab_body.mcp_config.dialog_type_http"),
                                  hint: tr("agents", "tab_body.mcp_config.dialog_type_http_hint"))
                }
            }
            if form.transport == .stdio {
                field(tr("agents", "tab_body.mcp_config.dialog_command_label"),
                      error: attempted && form.missingField == "command" ? tr("agents", "tab_body.mcp_config.dialog_command_required") : nil) {
                    TextField("npx", text: $form.command).textFieldStyle(.roundedBorder).font(Theme.Font.mono)
                }
                AgentsUIStringListEditor(label: tr("agents", "tab_body.mcp_config.dialog_args_label"),
                                         description: tr("agents", "tab_body.mcp_config.dialog_args_hint"),
                                         addLabel: tr("agents", "tab_body.mcp_config.dialog_add_arg"),
                                         removeLabel: tr("agents", "tab_body.mcp_config.dialog_remove_arg"), values: $form.args)
                AgentsUIKeyValueEditor(label: tr("agents", "tab_body.mcp_config.dialog_env_label"),
                                       description: tr("agents", "tab_body.mcp_config.dialog_env_hint"),
                                       addLabel: tr("agents", "tab_body.mcp_config.dialog_add_env"),
                                       removeLabel: tr("agents", "tab_body.mcp_config.dialog_remove_env"),
                                       keyLabel: tr("agents", "tab_body.mcp_config.dialog_env_key"),
                                       valueLabel: tr("agents", "tab_body.mcp_config.dialog_value"), rows: $form.env)
            } else {
                field(tr("agents", "tab_body.mcp_config.dialog_url_label"),
                      error: attempted && form.missingField == "url" ? tr("agents", "tab_body.mcp_config.dialog_url_required") : nil) {
                    TextField("https://mcp.example.com/mcp", text: $form.url).textFieldStyle(.roundedBorder).font(Theme.Font.mono)
                }
                AgentsUIKeyValueEditor(label: tr("agents", "tab_body.mcp_config.dialog_headers_label"),
                                       description: tr("agents", "tab_body.mcp_config.dialog_headers_hint"),
                                       addLabel: tr("agents", "tab_body.mcp_config.dialog_add_header"),
                                       removeLabel: tr("agents", "tab_body.mcp_config.dialog_remove_header"),
                                       keyLabel: tr("agents", "tab_body.mcp_config.dialog_header_key"),
                                       valueLabel: tr("agents", "tab_body.mcp_config.dialog_value"), rows: $form.headers)
            }
        }
    }

    private var jsonBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("agents", "tab_body.mcp_config.dialog_json_help")).font(Theme.Font.caption).foregroundStyle(.secondary)
            Text(tr("agents", "tab_body.mcp_config.dialog_json_label")).font(Theme.Font.bodyMedium)
            if server?.container == .mcp {
                Text(tr("agents", "tab_body.mcp_config.dialog_native_json_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $jsonText)
                .font(Theme.Font.mono)
                .frame(minHeight: 288)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.primary.opacity(0.14)))
                .help(tr("agents", "tab_body.mcp_config.dialog_json_aria"))
            if attempted, let jsonError {
                Text(jsonError).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
            }
        }
    }

    private func transportCard(_ t: AgentsUI.McpForm.Transport, icon: String, title: String, hint: String) -> some View {
        let selected = form.transport == t
        return Button {
            attempted = false
            form.transport = t
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Font.bodyMedium)
                    Text(hint).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.brand.opacity(0.08) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.brand : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func field<C: View>(_ label: String, error: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.Font.bodyMedium)
            content()
            if let error { Text(error).font(Theme.Font.caption).foregroundStyle(Theme.destructive) }
        }
    }

    private func seed() {
        let config = server?.config ?? [:]
        name = server?.name ?? ""
        if let server {
            form = config.isEmpty ? { var f = AgentsUI.McpForm(); f.transport = server.transport == "stdio" ? .stdio : .http; return f }()
                : AgentsUI.mcpForm(from: config)
        } else {
            form = AgentsUI.McpForm()
        }
        jsonText = AgentsUI.prettyJSON(.object(config))
        mode = server.map { AgentsUI.mcpFormSupports($0) ? .form : .json } ?? .form
        attempted = false
    }

    private func switchMode(_ next: Mode) {
        if next == .json && mode == .form {
            jsonText = AgentsUI.prettyJSON(.object(AgentsUI.mcpConfig(from: form)))
        } else if next == .form && mode == .json, case .success(let v) = jsonResult {
            form = AgentsUI.mcpForm(from: v)
        }
        attempted = false
        mode = next
    }

    private func save() {
        attempted = true
        guard !saving, nameError == nil else { return }
        let config: [String: JSONValue]
        switch mode {
        case .form:
            guard form.missingField == nil else { return }
            config = AgentsUI.mcpConfig(from: form)
        case .json:
            guard case .success(let v) = jsonResult else { return }
            config = v
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await onSave(submittedName, config)
                dismiss()
            } catch {}
        }
    }
}

struct AgentsUIStringListEditor: View {
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
                Button(addLabel, systemImage: "plus") { values.append("") }.buttonStyle(.borderless)
            }
            ForEach(values.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    TextField("\(label) \(i + 1)", text: Binding(get: { values.indices.contains(i) ? values[i] : "" },
                                                                set: { if values.indices.contains(i) { values[i] = $0 } }))
                        .textFieldStyle(.roundedBorder).font(Theme.Font.mono)
                    Button { values.remove(at: i) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("\(removeLabel) \(i + 1)")
                }
            }
        }
    }
}

struct AgentsUIKeyValueEditor: View {
    let label: String
    let description: String
    let addLabel: String
    let removeLabel: String
    let keyLabel: String
    let valueLabel: String
    @Binding var rows: [AgentsUI.KeyValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(Theme.Font.bodyMedium)
                    Text(description).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(addLabel, systemImage: "plus") { rows.append(AgentsUI.KeyValue()) }.buttonStyle(.borderless)
            }
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    TextField("\(keyLabel) \(i + 1)", text: binding(i, \.key)).textFieldStyle(.roundedBorder).font(Theme.Font.mono)
                    TextField("\(valueLabel) \(i + 1)", text: binding(i, \.value)).textFieldStyle(.roundedBorder).font(Theme.Font.mono)
                    Button { rows.remove(at: i) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("\(removeLabel) \(i + 1)")
                }
            }
        }
    }

    private func binding(_ i: Int, _ key: WritableKeyPath<AgentsUI.KeyValue, String>) -> Binding<String> {
        Binding(get: { rows.indices.contains(i) ? rows[i][keyPath: key] : "" },
                set: { if rows.indices.contains(i) { rows[i][keyPath: key] = $0 } })
    }
}

/// Capabilities › MCP Apps (upstream tabs/agent-mcp-tab): which of the
/// owner's Composio connections this agent may mount.
struct AgentsUIComposioTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let agent: AgentRecord

    @State private var connections: [ComposioConnection]?
    @State private var toolkits: [String: ComposioToolkit] = [:]
    @State private var failed = false
    @State private var saving = false

    var body: some View {
        let allowlist = agent.composioToolkitAllowlist ?? []
        let active = activeSlugs
        let isPrivate = agent.permissionMode == "private"
        let workspacePublic = AgentsUI.accessScope(permissionMode: agent.permissionMode, targets: agent.invocationTargets) == .workspace
        VStack(alignment: .leading, spacing: 16) {
            if agent.composioToolkitAllowlistRedacted == true {
                Label(tr("agents", "tab_body.composio_mcp.redacted_title"), systemImage: "lock").font(Theme.Font.bodyMedium)
                Text(tr("agents", "tab_body.composio_mcp.redacted_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
            } else {
                Text(tr("agents", "tab_body.composio_mcp.subtitle")).font(Theme.Font.caption).foregroundStyle(.secondary)
                if !isPrivate && (!allowlist.isEmpty || !active.isEmpty) {
                    Label(workspacePublic ? tr("agents", "tab_body.composio_mcp.workspace_warning") : tr("agents", "tab_body.composio_mcp.shared_warning"),
                          systemImage: "exclamationmark.triangle")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.warning)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.warning.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.warning.opacity(0.4)))
                }
                if connections == nil && !failed {
                    Text(tr("agents", "tab_body.composio_mcp.loading")).foregroundStyle(.secondary)
                } else if failed {
                    Text(tr("agents", "tab_body.composio_mcp.load_failed")).foregroundStyle(Theme.destructive)
                } else if active.isEmpty {
                    VStack(spacing: 8) {
                        Text(tr("agents", "tab_body.composio_mcp.empty_title")).font(Theme.Font.bodyMedium)
                        Button { nav.push(.settings, query: ["tab": "apps"]) } label: {
                            Label(tr("agents", "tab_body.composio_mcp.empty_link_to_settings"), systemImage: "powerplug")
                        }
                        .buttonStyle(.link)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                } else {
                    AgentsUIListCard {
                        ForEach(active, id: \.self) { slug in
                            let tk = toolkits[slug]
                            let name = (tk?.name.isEmpty == false ? tk?.name : nil) ?? slug
                            HStack(spacing: 12) {
                                RemoteImage(url: URL(string: tk?.logo ?? "") ?? URL(string: "https://logos.composio.dev/api/\(slug.lowercased())")) {
                                    Text(String(name.prefix(1)).uppercased()).font(Theme.Font.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        .frame(width: 32, height: 32).background(Color.primary.opacity(0.06))
                                }
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name).font(Theme.Font.bodyMedium).lineLimit(1)
                                    Text(tr("agents", "tab_body.composio_mcp.connected").uppercased()).font(Theme.Font.micro).foregroundStyle(.green)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(get: { allowlist.contains(slug) }, set: { toggle(slug, $0, allowlist: allowlist) }))
                                    .toggleStyle(.checkbox).labelsHidden()
                                    .disabled(saving)
                                    .help(tr("agents", "tab_body.composio_mcp.toggle_aria", ["toolkit": name]))
                            }
                            .padding(12)
                        }
                    }
                }
                if saving {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(tr("agents", "tab_body.composio_mcp.saving")) }
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task {
            async let c = try? session.api.listComposioConnections()
            async let t = try? session.api.listComposioToolkits()
            let (conns, kits) = await (c, t)
            if let conns { connections = conns } else { failed = true }
            toolkits = Dictionary((kits ?? []).map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    private var activeSlugs: [String] {
        var seen = Set<String>()
        return (connections ?? []).filter { $0.status == "active" && seen.insert($0.toolkitSlug).inserted }.map(\.toolkitSlug)
    }

    private func toggle(_ slug: String, _ on: Bool, allowlist: [String]) {
        var next = allowlist
        if on { if !next.contains(slug) { next.append(slug) } } else { next.removeAll { $0 == slug } }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await session.agentsUIUpdate(agent.id, ["composio_toolkit_allowlist": JSONValue(next)], toaster: toaster, successToast: false)
            } catch {
                toaster.error(tr("agents", "tab_body.composio_mcp.save_failed_toast"))
            }
        }
    }
}
