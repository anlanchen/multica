import MulticaCore
import SwiftUI

/// Settings › Labels (upstream labels-tab.tsx + labels/label-manager.tsx):
/// the issue and skill label catalogs, each searchable and editable.
struct SettingsLabelsTab: View {
    @Environment(WorkspaceSession.self) private var session
    @State private var scope = "issue"
    @State private var lists: [String: [LabelRecord]] = [:]

    var body: some View {
        SettingsTabView(title: tr("settings", "labels.title"), description: tr("settings", "labels.description"), scope: .workspace) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsViewTabs(items: [
                    (value: "issue", label: tr("settings", "labels.scopes.issue"), count: lists["issue"]?.count),
                    (value: "skill", label: tr("settings", "labels.scopes.skill"), count: lists["skill"]?.count),
                ], selection: $scope)
                SettingsLabelManager(scope: scope, labels: lists[scope], reload: { await load(scope) })
                    .id(scope)
            }
        }
        .task(id: session.revision("label")) {
            async let issue: Void = load("issue")
            async let skill: Void = load("skill")
            _ = await (issue, skill)
        }
    }

    private func load(_ scope: String) async {
        if let list = try? await session.api.settingsListLabelRecords(resourceType: scope) {
            lists[scope] = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } else if lists[scope] == nil {
            lists[scope] = []
        }
    }
}

/// Search, create, edit and delete the labels of one catalog.
struct SettingsLabelManager: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let scope: String
    let labels: [LabelRecord]?
    let reload: () async -> Void
    @State private var query = ""
    @State private var filtered: [LabelRecord] = []
    @State private var editing: SettingsLabelEditing?
    @State private var pendingDelete: LabelRecord?

    var body: some View {
        let scopeLabel = tr("settings", "labels.scopes.\(scope)")
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                SearchField(text: $query, prompt: tr("settings", "labels.search_placeholder")).frame(maxWidth: 384)
                Spacer(minLength: 0)
                Button { editing = SettingsLabelEditing(label: nil) } label: { Label(tr("settings", "labels.new_label"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            SettingsCatalogCard {
                HStack(spacing: 16) {
                    Text(tr("settings", "labels.columns.name")).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                    Text(tr("settings", "labels.columns.description")).frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                    Text(tr("settings", "labels.columns.usage")).frame(width: 96, alignment: .leading)
                    Text(tr("settings", "labels.columns.updated")).frame(width: 112, alignment: .leading)
                    Color.clear.frame(width: 28, height: 1)
                }
            } content: {
                if labels == nil {
                    SettingsCatalogPlaceholder(title: tr("settings", "labels.loading"))
                } else if filtered.isEmpty {
                    SettingsCatalogPlaceholder(icon: "tag", title: query.isEmpty ? tr("settings", "labels.empty", ["scope": scopeLabel]) : tr("settings", "labels.no_results"))
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { label in
                            if label.id != filtered.first?.id { Divider() }
                            row(label)
                        }
                    }
                }
            }
        }
        .onChange(of: labels, initial: true) { refilter() }
        .onChange(of: query) { refilter() }
        .sheet(item: $editing) { e in
            SettingsLabelEditorSheet(scope: scope, label: e.label, onClose: { editing = nil }, onSaved: {
                editing = nil
                Task { await reload() }
            })
        }
        .alert(tr("settings", "labels.delete_dialog.title"), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { label in
            Button(tr("settings", "labels.delete_dialog.cancel"), role: .cancel) {}
            Button(tr("settings", "labels.delete_dialog.confirm"), role: .destructive) { delete(label) }
        } message: { label in
            Text(tr("settings", "labels.delete_dialog.description", ["name": label.name, "count": label.usageCount ?? 0]))
        }
    }

    private func row(_ label: LabelRecord) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                Circle().fill(Color(hex: label.color)).frame(width: 10, height: 10)
                Text(label.name).font(Theme.Font.bodyMedium).lineLimit(1)
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            Text(label.description.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                .font(Theme.Font.body).foregroundStyle(.secondary).lineLimit(1)
                .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
            Text(tr("settings", "labels.usage_count", ["count": label.usageCount ?? 0]))
                .font(Theme.Font.body).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 96, alignment: .leading)
            Text(SettingsDates.short(label.updatedAt)).font(Theme.Font.caption).foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Menu {
                Button { editing = SettingsLabelEditing(label: label) } label: { Label(tr("settings", "labels.actions.edit"), systemImage: "pencil") }
                Button(role: .destructive) { pendingDelete = label } label: { Label(tr("settings", "labels.actions.delete"), systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .accessibilityLabel(tr("settings", "labels.actions.open", ["name": label.name]))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contextMenu {
            Button(tr("settings", "labels.actions.edit")) { editing = SettingsLabelEditing(label: label) }
            Button(tr("settings", "labels.actions.delete"), role: .destructive) { pendingDelete = label }
        }
    }

    private func refilter() {
        let all = labels ?? []
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = needle.isEmpty ? all : all.filter {
            $0.name.lowercased().contains(needle) || ($0.description ?? "").lowercased().contains(needle)
        }
    }

    private func delete(_ label: LabelRecord) {
        Task {
            do {
                try await session.api.deleteLabel(label.id)
                await reload()
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("settings", "labels.delete_dialog.failed"), kind: .error)
            }
        }
    }
}

private struct SettingsLabelEditing: Identifiable {
    let id = UUID()
    let label: LabelRecord?
}

private struct SettingsLabelEditorSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let scope: String
    let label: LabelRecord?
    let onClose: () -> Void
    let onSaved: () -> Void
    @State private var name = ""
    @State private var details = ""
    @State private var color = SettingsColor.defaultColor
    @State private var saving = false

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        SettingsDialog(title: label == nil ? tr("settings", "labels.editor.create_title") : tr("settings", "labels.editor.edit_title"),
                       description: tr("settings", "labels.editor.scope_hint", ["scope": tr("settings", "labels.scopes.\(scope)")]), width: 512) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "labels.editor.name"))
                    TextField(tr("settings", "labels.editor.name_placeholder"), text: Binding(get: { name }, set: { name = String($0.prefix(32)) }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "labels.editor.description"))
                    SettingsTextArea(text: $details, placeholder: tr("settings", "labels.editor.description_placeholder"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "labels.editor.color"))
                    SettingsColorField(color: $color) {
                        Circle().fill(Color(hex: color)).frame(width: 18, height: 18)
                    }
                    .accessibilityLabel(tr("settings", "labels.editor.color"))
                }
            }
        } footer: {
            Button(tr("settings", "labels.editor.cancel"), action: onClose).keyboardShortcut(.cancelAction)
            Button(saving ? tr("settings", "labels.editor.saving") : tr("settings", "labels.editor.save"), action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || saving)
        }
        .onAppear {
            name = label?.name ?? ""
            details = label?.description ?? ""
            color = label?.color ?? SettingsColor.defaultColor
        }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let description = details.trimmingCharacters(in: .whitespacesAndNewlines)
                if let label {
                    _ = try await session.api.updateLabel(label.id, UpdateLabelRequest(name: trimmed, description: description, color: color))
                } else {
                    _ = try await session.api.createLabel(CreateLabelRequest(resourceType: scope, name: trimmed, description: description, color: color))
                }
                onSaved()
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("settings", "labels.save_failed"), kind: .error)
            }
        }
    }
}
