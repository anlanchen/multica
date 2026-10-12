import MulticaCore
import SwiftUI

/// Settings › Properties (upstream properties-tab.tsx): custom issue field
/// definitions — create, edit options, archive and restore.
struct SettingsPropertiesTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @State private var query = ""
    @State private var showArchived = false
    @State private var visible: [IssueProperty] = []
    @State private var editing: SettingsPropertyEditing?
    @State private var pendingArchive: IssueProperty?

    static let types = ["text", "number", "select", "multi_select", "date", "checkbox", "url", "actor", "multi_actor", "multi_text", "multi_url"]

    static func typeLabel(_ type: String) -> String {
        types.contains(type) ? tr("settings", "properties.types.\(type)") : type
    }

    static func hasOptions(_ type: String) -> Bool { type == "select" || type == "multi_select" }

    var body: some View {
        let store = session.properties
        let role = session.settingsMyRole
        let canManage = role == "owner" || role == "admin"
        let activeCount = store.items.filter { !$0.archived }.count
        SettingsTabView(title: tr("settings", "properties.title"), description: tr("settings", "properties.description"), scope: .workspace) {
            if role != nil && !canManage { SettingsReadOnlyNotice() }
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    SearchField(text: $query, prompt: tr("settings", "properties.search_placeholder")).frame(maxWidth: 384)
                    Spacer(minLength: 0)
                    Toggle(isOn: $showArchived) {
                        Text(tr("settings", "properties.show_archived")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Text(tr("settings", "properties.limit_hint", ["count": activeCount, "max": SettingsRules.maxActiveProperties]))
                        .font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                    if canManage {
                        Button { editing = SettingsPropertyEditing(property: nil) } label: {
                            Label(tr("settings", "properties.new_property"), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(activeCount >= SettingsRules.maxActiveProperties)
                    }
                }
                if !canManage {
                    Text(tr("settings", "properties.editor.admin_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                SettingsCatalogCard {
                    HStack(spacing: 16) {
                        Text(tr("settings", "properties.columns.name")).frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                        Text(tr("settings", "properties.columns.type")).frame(width: 96, alignment: .leading)
                        Text(tr("settings", "properties.columns.options")).frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                        Text(tr("settings", "properties.columns.usage")).frame(width: 96, alignment: .leading)
                        Text(tr("settings", "properties.columns.updated")).frame(width: 112, alignment: .leading)
                        Color.clear.frame(width: 28, height: 1)
                    }
                } content: {
                    if !store.isLoaded {
                        SettingsCatalogPlaceholder(title: tr("settings", "properties.loading"))
                    } else if visible.isEmpty {
                        SettingsCatalogPlaceholder(icon: "slider.horizontal.3",
                                                   title: query.isEmpty ? tr("settings", "properties.empty") : tr("settings", "properties.no_results"),
                                                   hint: query.isEmpty ? tr("settings", "properties.empty_hint") : nil)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(visible) { property in
                                if property.id != visible.first?.id { Divider() }
                                row(property, canManage: canManage)
                            }
                        }
                    }
                }
            }
        }
        .task { await store.loadIfNeeded() }
        .onChange(of: store.items, initial: true) { refilter() }
        .onChange(of: query) { refilter() }
        .onChange(of: showArchived) { refilter() }
        .sheet(item: $editing) { e in
            SettingsPropertyEditorSheet(property: e.property) { editing = nil }
        }
        .alert(tr("settings", "properties.archive_dialog.title"), isPresented: Binding(get: { pendingArchive != nil }, set: { if !$0 { pendingArchive = nil } }),
               presenting: pendingArchive) { property in
            Button(tr("settings", "properties.archive_dialog.cancel"), role: .cancel) {}
            Button(tr("settings", "properties.archive_dialog.confirm"), role: .destructive) {
                setArchived(property, true, failure: tr("settings", "properties.archive_dialog.failed"))
            }
        } message: { property in
            Text(tr("settings", "properties.archive_dialog.description", ["name": property.name]))
        }
    }

    private func row(_ property: IssueProperty, canManage: Bool) -> some View {
        let options = property.config?.options ?? []
        return HStack(spacing: 16) {
            HStack(spacing: 8) {
                if let icon = property.icon, !icon.isEmpty { SettingsPropertyIcons.glyph(icon) }
                Text(property.name).font(Theme.Font.bodyMedium).lineLimit(1)
                if property.archived {
                    Text(tr("settings", "properties.archived_badge")).font(.system(size: 10))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Theme.border))
                }
            }
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            Text(Self.typeLabel(property.type)).font(Theme.Font.body).foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            HStack(spacing: 4) {
                if Self.hasOptions(property.type) {
                    ForEach(options.prefix(6)) { option in
                        HStack(spacing: 5) {
                            Circle().fill(Color(hex: option.color)).frame(width: 7, height: 7)
                            Text(option.name).lineLimit(1)
                        }
                        .font(Theme.Font.caption)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(Theme.border))
                    }
                    if options.count > 6 {
                        Text("+\(options.count - 6)").font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("—").font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            .clipped()
            Text(tr("settings", "properties.usage_count", ["count": property.usageCount ?? 0]))
                .font(Theme.Font.body).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 96, alignment: .leading)
            Text(SettingsDates.short(property.updatedAt)).font(Theme.Font.caption).foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Group {
                if canManage {
                    Menu {
                        Button { editing = SettingsPropertyEditing(property: property) } label: {
                            Label(tr("settings", "properties.actions.edit"), systemImage: "pencil")
                        }
                        if property.archived {
                            Button { setArchived(property, false, failure: tr("settings", "properties.save_failed")) } label: {
                                Label(tr("settings", "properties.actions.unarchive"), systemImage: "arrow.uturn.backward")
                            }
                        } else {
                            Button(role: .destructive) { pendingArchive = property } label: {
                                Label(tr("settings", "properties.actions.archive"), systemImage: "archivebox")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .accessibilityLabel(tr("settings", "properties.actions.open", ["name": property.name]))
                }
            }
            .frame(width: 28)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func refilter() {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        visible = session.properties.items
            .filter { showArchived || !$0.archived }
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
    }

    private func setArchived(_ property: IssueProperty, _ archived: Bool, failure: String) {
        Task {
            do {
                let updated = try await session.api.updateProperty(property.id, UpdatePropertyRequest(archived: archived))
                session.properties.upsert(updated)
            } catch {
                toaster.show((error as? APIError)?.message ?? failure, kind: .error)
            }
        }
    }
}

private struct SettingsPropertyEditing: Identifiable {
    let id = UUID()
    let property: IssueProperty?
}

private struct SettingsOptionDraft: Identifiable, Equatable {
    var id = UUID()
    var serverID: String?
    var name: String
    var color: String
}

private struct SettingsPropertyEditorSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let property: IssueProperty?
    let onClose: () -> Void
    @State private var name = ""
    @State private var type = "select"
    @State private var details = ""
    @State private var icon = ""
    @State private var options: [SettingsOptionDraft] = [SettingsOptionDraft(name: "", color: SettingsColor.defaultColor)]
    @State private var iconPicker = false
    @State private var saving = false

    var body: some View {
        let showOptions = SettingsPropertiesTab.hasOptions(type)
        let valid = options.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        let canSubmit = !name.trimmingCharacters(in: .whitespaces).isEmpty && (!showOptions || !valid.isEmpty)
        SettingsDialog(title: property == nil ? tr("settings", "properties.editor.create_title") : tr("settings", "properties.editor.edit_title"),
                       description: tr("settings", "properties.editor.admin_hint"), width: 512) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsFieldLabel(tr("settings", "properties.editor.icon"))
                            Button { iconPicker.toggle() } label: {
                                Group {
                                    if icon.isEmpty {
                                        Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                                    } else {
                                        SettingsPropertyIcons.glyph(icon)
                                    }
                                }
                                .frame(width: 60, height: 28)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.settingsCard))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.primary.opacity(0.15)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tr("settings", "properties.editor.choose_icon"))
                            .popover(isPresented: $iconPicker, arrowEdge: .bottom) {
                                SettingsPropertyIconPicker(value: icon, onSelect: { icon = $0; iconPicker = false },
                                                           onRemove: { icon = ""; iconPicker = false })
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsFieldLabel(tr("settings", "properties.editor.name"))
                            TextField(tr("settings", "properties.editor.name_placeholder"), text: Binding(get: { name }, set: { name = String($0.prefix(32)) }))
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            SettingsFieldLabel(tr("settings", "properties.editor.type"))
                            if let property {
                                Text(SettingsPropertiesTab.typeLabel(property.type))
                                    .font(Theme.Font.body).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
                                    .help(tr("settings", "properties.editor.type_locked_hint"))
                            } else {
                                Picker("", selection: $type) {
                                    ForEach(SettingsPropertiesTab.types, id: \.self) { Text(SettingsPropertiesTab.typeLabel($0)).tag($0) }
                                }
                                .labelsHidden()
                            }
                        }
                        .frame(width: 160)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        SettingsFieldLabel(tr("settings", "properties.editor.description"))
                        SettingsTextArea(text: $details, placeholder: tr("settings", "properties.editor.description_placeholder"), minHeight: 48)
                    }
                    if showOptions {
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsFieldLabel(tr("settings", "properties.editor.options"))
                            ForEach($options) { $option in
                                HStack(spacing: 8) {
                                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                                    SettingsColorPickerButton(color: $option.color) {
                                        Circle().fill(Color(hex: option.color)).frame(width: 22, height: 22)
                                            .overlay(Circle().strokeBorder(Theme.border))
                                    }
                                    .accessibilityLabel(option.color)
                                    TextField(tr("settings", "properties.editor.option_name_placeholder"),
                                              text: Binding(get: { option.name }, set: { option.name = String($0.prefix(32)) }))
                                        .textFieldStyle(.roundedBorder)
                                    Button { options.removeAll { $0.id == option.id } } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.borderless)
                                        .disabled(options.count <= 1)
                                        .help(tr("settings", "properties.editor.remove_option"))
                                }
                            }
                            Button {
                                options.append(SettingsOptionDraft(name: "", color: SettingsColor.presets[options.count % SettingsColor.presets.count]))
                            } label: {
                                Label(tr("settings", "properties.editor.add_option"), systemImage: "plus")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxHeight: 460)
        } footer: {
            Button(tr("settings", "properties.editor.cancel"), action: onClose).keyboardShortcut(.cancelAction)
            Button(saving ? tr("settings", "properties.editor.saving") : tr("settings", "properties.editor.save"), action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || saving)
        }
        .onAppear {
            guard let property else { return }
            name = property.name
            type = property.type
            details = property.description ?? ""
            icon = property.icon ?? ""
            options = (property.config?.options ?? []).map { SettingsOptionDraft(serverID: $0.id, name: $0.name, color: $0.color) }
        }
        .onChange(of: type) {
            if SettingsPropertiesTab.hasOptions(type) && options.isEmpty {
                options = [SettingsOptionDraft(name: "", color: SettingsColor.defaultColor)]
            }
        }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !saving else { return }
        let config: IssuePropertyConfig? = SettingsPropertiesTab.hasOptions(type)
            ? IssuePropertyConfig(options: options
                .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { IssuePropertyOption(id: $0.serverID ?? "", name: $0.name.trimmingCharacters(in: .whitespaces), color: $0.color) })
            : nil
        let description = details.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        Task {
            defer { saving = false }
            do {
                let saved: IssueProperty
                if let property {
                    saved = try await session.api.updateProperty(property.id, UpdatePropertyRequest(name: trimmed, description: description, icon: icon, config: config))
                } else {
                    saved = try await session.api.createProperty(CreatePropertyRequest(name: trimmed, type: type, description: description, icon: icon, config: config))
                }
                session.properties.upsert(saved)
                onClose()
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("settings", "properties.save_failed"), kind: .error)
            }
        }
    }
}

/// The property icon catalog (upstream common/property-icon.tsx), keyed by
/// the stable names the server stores.
enum SettingsPropertyIcons {
    static let options: [(value: String, label: String, symbol: String)] = [
        ("circle-dot", "Status", "smallcircle.filled.circle"), ("signal-high", "Priority", "cellularbars"),
        ("user-round", "Assignee", "person"), ("folder-kanban", "Project", "folder"), ("calendar-days", "Date", "calendar"),
        ("tag", "Label", "tag"), ("milestone", "Milestone", "signpost.right"), ("flag", "Flag", "flag"),
        ("bookmark", "Bookmark", "bookmark"), ("star", "Star", "star"), ("target", "Target", "target"),
        ("shield", "Shield", "shield"), ("bug", "Bug", "ladybug"), ("zap", "Lightning", "bolt"),
        ("rocket", "Rocket", "paperplane"), ("sparkles", "Sparkles", "sparkles"), ("lightbulb", "Idea", "lightbulb"),
        ("globe-2", "Globe", "globe"), ("link", "Link", "link"), ("hash", "Number", "number"),
        ("list-checks", "Checklist", "checklist"), ("circle-check", "Complete", "checkmark.circle"), ("clock-3", "Time", "clock"),
        ("briefcase-business", "Work", "briefcase"), ("layers-3", "Layers", "square.3.layers.3d"), ("gauge", "Gauge", "speedometer"),
        ("database", "Database", "cylinder.split.1x2"), ("code-2", "Code", "chevron.left.forwardslash.chevron.right"),
        ("palette", "Design", "paintpalette"), ("megaphone", "Announcement", "megaphone"), ("map-pin", "Location", "mappin"),
        ("package", "Package", "shippingbox"), ("wrench", "Tools", "wrench.adjustable"), ("heart", "Favorite", "heart"),
        ("circle-alert", "Alert", "exclamationmark.circle"), ("lock-keyhole", "Private", "lock"),
    ]

    static func symbol(_ value: String) -> String {
        options.first { $0.value == value }?.symbol ?? "square.on.circle"
    }

    static func glyph(_ value: String) -> some View {
        Image(systemName: symbol(value)).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 16)
    }
}

private struct SettingsPropertyIconPicker: View {
    let value: String
    let onSelect: (String) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("settings", "properties.editor.choose_icon")).font(.system(size: 11, weight: .medium))
                Spacer()
                if let label = SettingsPropertyIcons.options.first(where: { $0.value == value })?.label {
                    Text(label).font(Theme.Font.micro).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8), spacing: 4) {
                ForEach(SettingsPropertyIcons.options, id: \.value) { option in
                    Button { onSelect(option.value) } label: {
                        Image(systemName: option.symbol)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(value == option.value ? Theme.selected : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(option.label)
                    .accessibilityLabel(option.label)
                }
            }
            if !value.isEmpty {
                Button(action: onRemove) { Label(tr("settings", "properties.editor.remove_icon"), systemImage: "xmark") }
                    .buttonStyle(.borderless)
                    .font(Theme.Font.caption)
            }
        }
        .padding(8)
        .frame(width: 264)
    }
}
