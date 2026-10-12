import AppKit
import MulticaCore
import SwiftUI

/// Upstream COLOR_PICKER_PRESETS.
private let skillsLabelPresets = ["#6b7280", "#ef4444", "#f97316", "#eab308", "#22c55e", "#14b8a6", "#3b82f6", "#6366f1", "#a855f7", "#ec4899"]

/// "Manage labels…" from the skills filter: the skill label catalog
/// (upstream LabelManager scope="skill").
struct SkillsLabelManagerSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var editing: SkillsLabelEditTarget?
    @State private var pendingDelete: LabelRecord?

    var body: some View {
        let catalog = session.skillsStore.labels
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let labels = catalog.items.filter { q.isEmpty || $0.name.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q) }
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(tr("skills", "toolbar.manage_labels_title")).font(Theme.Font.title)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 12) {
                SearchField(text: $query, prompt: tr("settings", "labels.search_placeholder")).frame(maxWidth: 320)
                Spacer()
                Button { editing = .create } label: { Label(tr("settings", "labels.new_label"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text(tr("settings", "labels.columns.name")).frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                    Text(tr("settings", "labels.columns.description")).frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                    Text(tr("settings", "labels.columns.usage")).frame(width: 88, alignment: .leading)
                    Text(tr("settings", "labels.columns.updated")).frame(width: 96, alignment: .leading)
                    Color.clear.frame(width: 24)
                }
                .font(Theme.Font.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.03))
                Divider()
                if !catalog.isLoaded && catalog.error == nil {
                    Text(tr("settings", "labels.loading")).font(Theme.Font.body).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 48)
                } else if labels.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tag").font(.title2).foregroundStyle(.tertiary)
                        Text(query.isEmpty ? tr("settings", "labels.empty", ["scope": tr("settings", "labels.scopes.skill")]) : tr("settings", "labels.no_results"))
                            .font(Theme.Font.bodyMedium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(labels) { label in
                                row(label)
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 200, maxHeight: 440)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.015)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large))
        }
        .padding(20)
        .frame(width: 720)
        .task { await catalog.loadIfNeeded() }
        .sheet(item: $editing) { target in
            SkillsLabelEditorSheet(label: target.label)
        }
        .alert(tr("settings", "labels.delete_dialog.title"), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { label in
            Button(tr("settings", "labels.delete_dialog.cancel"), role: .cancel) {}
            Button(tr("settings", "labels.delete_dialog.confirm"), role: .destructive) {
                Task { await delete(label) }
            }
        } message: { label in
            Text(tr("settings", "labels.delete_dialog.description", ["name": label.name, "count": label.usageCount ?? 0]))
        }
    }

    private func row(_ label: LabelRecord) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Circle().fill(Color(hex: label.color)).frame(width: 9, height: 9)
                Text(label.name).font(Theme.Font.bodyMedium).lineLimit(1)
            }
            .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            Text((label.description ?? "").isEmpty ? "—" : label.description ?? "")
                .font(Theme.Font.body).foregroundStyle(.secondary).lineLimit(1)
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            Text(tr("settings", "labels.usage_count", ["count": label.usageCount ?? 0]))
                .font(Theme.Font.body).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 88, alignment: .leading)
            Text(Formatters.date(label.updatedAt)).font(Theme.Font.caption).foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Menu {
                Button { editing = .edit(label) } label: { Label(tr("settings", "labels.actions.edit"), systemImage: "pencil") }
                Button(role: .destructive) { pendingDelete = label } label: { Label(tr("settings", "labels.actions.delete"), systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help(tr("settings", "labels.actions.open", ["name": label.name]))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func delete(_ label: LabelRecord) async {
        do {
            try await session.api.deleteLabel(label.id)
            session.skillsStore.labels.remove(label.id)
            await session.skills.refreshIfLoaded()
        } catch {
            let message = (error as? APIError)?.message ?? error.localizedDescription
            toaster.error(message.isEmpty ? tr("settings", "labels.delete_dialog.failed") : message)
        }
    }
}

enum SkillsLabelEditTarget: Identifiable {
    case create
    case edit(LabelRecord)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let l): return l.id
        }
    }

    var label: LabelRecord? {
        if case .edit(let l) = self { return l }
        return nil
    }
}

private struct SkillsLabelEditorSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let label: LabelRecord?
    @State private var name = ""
    @State private var description = ""
    @State private var color = skillsLabelPresets[6]
    @State private var saving = false

    var body: some View {
        SkillsDialog(title: label == nil ? tr("settings", "labels.editor.create_title") : tr("settings", "labels.editor.edit_title"),
                     description: tr("settings", "labels.editor.scope_hint", ["scope": tr("settings", "labels.scopes.skill")]), width: 480) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("settings", "labels.editor.name")).font(Theme.Font.caption.weight(.medium))
                    TextField(tr("settings", "labels.editor.name_placeholder"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: name) { if name.count > 32 { name = String(name.prefix(32)) } }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("settings", "labels.editor.description")).font(Theme.Font.caption.weight(.medium))
                    SkillsTextArea(text: $description, placeholder: tr("settings", "labels.editor.description_placeholder"), minHeight: 56)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("settings", "labels.editor.color")).font(Theme.Font.caption.weight(.medium))
                    HStack(spacing: 6) {
                        ForEach(skillsLabelPresets, id: \.self) { preset in
                            Button { color = preset } label: {
                                Circle().fill(Color(hex: preset)).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(color.lowercased() == preset ? 0.8 : 0), lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help(preset)
                        }
                        ColorPicker("", selection: Binding(get: { Color(hex: color) }, set: { color = Self.hex($0) ?? color }), supportsOpacity: false)
                            .labelsHidden()
                        Text(color.uppercased()).font(Theme.Font.mono).foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Button(tr("settings", "labels.editor.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            Button { Task { await save() } } label: {
                SkillsBusyLabel(title: saving ? tr("settings", "labels.editor.saving") : tr("settings", "labels.editor.save"), busy: saving)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
        }
        .onAppear {
            if let label {
                name = label.name
                description = label.description ?? ""
                color = label.color
            }
        }
    }

    static func hex(_ color: Color) -> String? {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if let label {
                _ = try await session.api.updateLabel(label.id, UpdateLabelRequest(name: trimmed, description: desc, color: color))
            } else {
                _ = try await session.api.createLabel(CreateLabelRequest(resourceType: "skill", name: trimmed, description: desc, color: color))
            }
            await session.skillsStore.labels.load()
            await session.skills.refreshIfLoaded()
            dismiss()
        } catch {
            let message = (error as? APIError)?.message ?? error.localizedDescription
            toaster.error(message.isEmpty ? tr("settings", "labels.save_failed") : message)
        }
    }
}

/// Labels row on the skill overview (upstream ResourceLabelPicker).
struct SkillsResourceLabelPicker: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let skillID: String
    let canEdit: Bool
    @State private var selected: [IssueLabel] = []
    @State private var open = false
    @State private var query = ""

    var body: some View {
        Group {
            if canEdit {
                Button { open.toggle() } label: {
                    HStack(spacing: 6) {
                        if selected.isEmpty {
                            Image(systemName: "tag").foregroundStyle(.secondary)
                            Text(tr("labels", "resource_picker.add"))
                        } else {
                            chips
                        }
                        Spacer(minLength: 0)
                    }
                    .font(Theme.Font.body)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: 32)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $open, arrowEdge: .bottom) { popover }
            } else if selected.isEmpty {
                Text(tr("labels", "resource_picker.empty")).font(Theme.Font.body).foregroundStyle(.secondary)
            } else {
                chips
            }
        }
        .skillsRefetch(on: ["label", "skill"], id: skillID) {
            if let r = try? await session.api.listLabelsForResource("skill", resourceId: skillID) { selected = r.labels }
        }
        .onChange(of: open) { if !open { query = "" } }
    }

    private var chips: some View {
        SkillsFlowLayout(spacing: 4) {
            ForEach(selected) { label in SkillsLabelChip(name: label.name, color: label.color) }
        }
    }

    private var popover: some View {
        let catalog = session.skillsStore.labels
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = catalog.items.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        let ids = Set(selected.map(\.id))
        return VStack(alignment: .leading, spacing: 8) {
            SearchField(text: $query, prompt: tr("labels", "resource_picker.search"), autofocus: true)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filtered) { label in
                        Button { Task { await toggle(label, attached: ids.contains(label.id)) } } label: {
                            HStack(spacing: 8) {
                                Circle().fill(Color(hex: label.color)).frame(width: 9, height: 9)
                                Text(label.name).lineLimit(1)
                                Spacer()
                                if ids.contains(label.id) {
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.brand)
                                }
                            }
                            .font(Theme.Font.body)
                        }
                        .buttonStyle(HoverRowButtonStyle())
                    }
                    if filtered.isEmpty {
                        Text(catalog.items.isEmpty ? tr("labels", "resource_picker.no_labels") : tr("labels", "resource_picker.no_results"))
                            .font(Theme.Font.caption).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }
            }
            .frame(maxHeight: 256)
        }
        .padding(8)
        .frame(width: 288)
        .task { await catalog.loadIfNeeded() }
    }

    private func toggle(_ label: LabelRecord, attached: Bool) async {
        do {
            let r = attached
                ? try await session.api.detachLabelFromResource("skill", resourceId: skillID, labelId: label.id)
                : try await session.api.attachLabelToResource("skill", resourceId: skillID, labelId: label.id)
            selected = r.labels
            await session.skills.refreshIfLoaded()
        } catch {
            toaster.error(error)
        }
    }
}

/// Wrapping row of chips.
struct SkillsFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
