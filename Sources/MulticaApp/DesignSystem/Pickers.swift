import MulticaCore
import SwiftUI

/// One row in a searchable picker.
struct PickerOption<ID: Hashable>: Identifiable {
    var id: ID
    var title: String
    var subtitle: String? = nil
    var group: String? = nil
    var disabled = false
    var help: String? = nil
    var icon: AnyView? = nil
}

/// Searchable option list used inside picker popovers (upstream
/// PropertyPicker): type to filter, ↑/↓ to move, ↩ to pick.
struct OptionList<ID: Hashable>: View {
    let options: [PickerOption<ID>]
    var selected: Set<ID> = []
    var searchPlaceholder: String = ""
    var multiSelect = false
    var footer: AnyView? = nil
    /// Offered when the query matches nothing exactly (create label, ...).
    var createLabel: ((String) -> String)? = nil
    var onCreate: ((String) -> Void)? = nil
    let onPick: (ID) -> Void

    @State private var query = ""
    @State private var highlighted: ID?
    @FocusState private var focused: Bool

    private var filtered: [PickerOption<ID>] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return options }
        return options.filter { $0.title.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false) }
    }

    var body: some View {
        let list = filtered
        VStack(alignment: .leading, spacing: 0) {
            TextField(searchPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .focused($focused)
                .onSubmit {
                    if let h = highlighted ?? list.first(where: { !$0.disabled })?.id { onPick(h) }
                    else if let onCreate, !query.isEmpty { onCreate(query) }
                }
                .onKeyPress(.downArrow) { move(1, in: list); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: list); return .handled }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(list) { o in
                        if let g = o.group, g != groupBefore(o, in: list) {
                            Text(g).font(Theme.Font.micro).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                        }
                        row(o)
                    }
                    if list.isEmpty && onCreate == nil {
                        Text(tr("issues", "pickers.no_results"))
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                            .padding(10)
                    }
                    if let onCreate, let createLabel, !query.isEmpty,
                       !options.contains(where: { $0.title.caseInsensitiveCompare(query) == .orderedSame }) {
                        Button { onCreate(query) } label: {
                            Label(createLabel(query), systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(HoverRowButtonStyle())
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 300)
            if let footer {
                Divider()
                footer.padding(4)
            }
        }
        .frame(width: 260)
        .onAppear { focused = true }
    }

    private func groupBefore(_ o: PickerOption<ID>, in list: [PickerOption<ID>]) -> String? {
        guard let i = list.firstIndex(where: { $0.id == o.id }), i > 0 else { return nil }
        return list[i - 1].group
    }

    private func move(_ delta: Int, in list: [PickerOption<ID>]) {
        let enabled = list.filter { !$0.disabled }
        guard !enabled.isEmpty else { return }
        let i = enabled.firstIndex { $0.id == highlighted } ?? (delta > 0 ? -1 : enabled.count)
        highlighted = enabled[max(0, min(enabled.count - 1, i + delta))].id
    }

    private func row(_ o: PickerOption<ID>) -> some View {
        Button { onPick(o.id) } label: {
            HStack(spacing: 8) {
                if let icon = o.icon { icon.frame(width: 16) }
                Text(o.title).lineLimit(1)
                if let s = o.subtitle { Text(s).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 4)
                if selected.contains(o.id) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.brand)
                }
            }
            .font(Theme.Font.body)
        }
        .buttonStyle(HoverRowButtonStyle(selected: highlighted == o.id))
        .disabled(o.disabled)
        .help(o.help ?? "")
        .padding(.horizontal, 4)
    }
}

/// A trigger that opens a popover with arbitrary content.
struct PopoverButton<Label: View, Content: View>: View {
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: (_ dismiss: @escaping () -> Void) -> Content
    var style: PillButtonStyle? = PillButtonStyle()
    @State private var open = false

    var body: some View {
        Group {
            if let style {
                Button { open.toggle() } label: { label() }.buttonStyle(style)
            } else {
                Button { open.toggle() } label: { label() }.buttonStyle(.plain)
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            content { open = false }
        }
    }
}

// MARK: - Issue property pickers

struct StatusPicker: View {
    @Environment(WorkspaceSession.self) private var session
    let current: IssueStatusKey
    var showLabel = true
    var style: PillButtonStyle? = PillButtonStyle()
    let onChange: (IssueStatusKey) -> Void

    var body: some View {
        let catalog = session.issues.catalog
        PopoverButton(label: {
            HStack(spacing: 6) {
                catalog.icon(for: current)
                if showLabel { Text(catalog.localizedName(for: current)).lineLimit(1) }
            }
        }, content: { dismiss in
            OptionList(
                options: catalog.entries.filter { $0.archivedAt == nil }.map { e in
                    PickerOption(id: e.key, title: catalog.localizedName(for: e.key), icon: AnyView(StatusIcon(status: e.key, entry: e)))
                },
                selected: [current],
                searchPlaceholder: tr("issues", "filters.search_status")
            ) { key in
                dismiss()
                if key != current { onChange(key) }
            }
        }, style: style)
    }
}

struct PriorityPicker: View {
    let current: IssuePriority
    var showLabel = true
    var style: PillButtonStyle? = PillButtonStyle()
    let onChange: (IssuePriority) -> Void

    var body: some View {
        PopoverButton(label: {
            HStack(spacing: 6) {
                PriorityIcon(priority: current)
                if showLabel { Text(current.localizedName).lineLimit(1) }
            }
        }, content: { dismiss in
            OptionList(
                options: IssuePriority.displayOrder.map { p in
                    PickerOption(id: p, title: p.localizedName, icon: AnyView(PriorityIcon(priority: p)))
                },
                selected: [current]
            ) { p in
                dismiss()
                if p != current { onChange(p) }
            }
        }, style: style)
    }
}

/// Assignee picker: members, agents (runtime required) and squads.
struct AssigneePicker: View {
    @Environment(WorkspaceSession.self) private var session
    let current: ActorRef?
    var showLabel = true
    var allowSquads = true
    var style: PillButtonStyle? = PillButtonStyle()
    let onChange: (ActorRef?) -> Void

    var body: some View {
        PopoverButton(label: {
            HStack(spacing: 6) {
                if let current {
                    ActorAvatar(type: current.type, id: current.id, size: 16, showName: showLabel, nameFont: Theme.Font.caption)
                } else {
                    Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(.secondary)
                    if showLabel { Text(tr("issues", "pickers.assignee.trigger_unassigned")) }
                }
            }
        }, content: { dismiss in
            OptionList(
                options: options,
                selected: current.map { ["\($0.type):\($0.id)"] } ?? ["none"],
                searchPlaceholder: tr("issues", "pickers.assignee.search_placeholder")
            ) { key in
                dismiss()
                if key == "none" { onChange(nil); return }
                let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return }
                onChange(ActorRef(type: parts[0], id: parts[1]))
            }
            .task { await session.squads.loadIfNeeded() }
        }, style: style)
    }

    private var options: [PickerOption<String>] {
        var out: [PickerOption<String>] = [
            PickerOption(id: "none", title: tr("issues", "pickers.assignee.trigger_unassigned"),
                         icon: AnyView(Image(systemName: "person.crop.circle.dashed").foregroundStyle(.secondary))),
        ]
        let membersGroup = tr("issues", "pickers.assignee.members_group")
        for m in session.directory.members {
            out.append(PickerOption(id: "member:\(m.userID)", title: m.name, group: membersGroup,
                                    icon: AnyView(AvatarView(name: m.name, url: m.avatarURL, size: 16))))
        }
        let agentsGroup = tr("issues", "pickers.assignee.agents_group")
        for a in session.directory.agents where a.archivedAt == nil {
            let bound = !a.runtimeID.isEmpty
            out.append(PickerOption(id: "agent:\(a.id)", title: a.name, group: agentsGroup, disabled: !bound,
                                    help: bound ? nil : tr("issues", "pickers.assignee.agent_runtime_required"),
                                    icon: AnyView(AvatarView(name: a.name, url: a.avatarURL, kind: .agent, size: 16))))
        }
        if allowSquads {
            let squadsGroup = tr("issues", "pickers.assignee.squads_group")
            for s in session.squads.items where s.archivedAt == nil {
                out.append(PickerOption(id: "squad:\(s.id)", title: s.name, group: squadsGroup,
                                        icon: AnyView(AvatarView(name: s.name, url: s.avatarUrl, kind: .squad, size: 16))))
            }
        }
        return out
    }
}

/// Multi-select label picker with inline create.
struct LabelPicker: View {
    @Environment(WorkspaceSession.self) private var session
    let selected: [IssueLabel]
    var compact = false
    let onToggle: (IssueLabel, Bool) -> Void

    var body: some View {
        PopoverButton(label: {
            if selected.isEmpty || compact {
                HStack(spacing: 4) {
                    Image(systemName: "tag").foregroundStyle(.secondary)
                    if !compact { Text(tr("issues", "pickers.label.trigger_label")) }
                    else if !selected.isEmpty { Text("\(selected.count)") }
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(selected.prefix(3)) { l in
                        Circle().fill(Color(hex: l.color)).frame(width: 7, height: 7)
                    }
                    Text(selected.count == 1 ? selected[0].name : "\(selected.count)")
                }
            }
        }, content: { _ in
            OptionList(
                options: session.labels.items.map { l in
                    PickerOption(id: l.id, title: l.name, icon: AnyView(Circle().fill(Color(hex: l.color)).frame(width: 8, height: 8)))
                },
                selected: Set(selected.map(\.id)),
                searchPlaceholder: tr("issues", "pickers.label.search_placeholder"),
                multiSelect: true,
                createLabel: { "\(tr("issues", "pickers.label.create_action")) “\($0)”" },
                onCreate: { name in
                    Task {
                        let colors = ["#ef4444", "#f97316", "#eab308", "#22c55e", "#06b6d4", "#3b82f6", "#8b5cf6", "#ec4899"]
                        let color = colors[abs(name.hashValue) % colors.count]
                        if let label = try? await session.api.createLabel(CreateLabelRequest(resourceType: "issue", name: name, description: nil, color: color)) {
                            session.labels.upsert(label)
                            onToggle(label, true)
                        }
                    }
                }
            ) { id in
                guard let label = session.labels.item(id) else { return }
                onToggle(label, !selected.contains { $0.id == id })
            }
            .task { await session.labels.loadIfNeeded() }
        })
    }
}

struct ProjectPicker: View {
    @Environment(WorkspaceSession.self) private var session
    let currentID: String?
    var showLabel = true
    let onChange: (String?) -> Void

    var body: some View {
        let current = currentID.flatMap { session.projects.item($0) }
        PopoverButton(label: {
            HStack(spacing: 6) {
                ProjectIconView(icon: current?.icon, size: 14)
                if showLabel { Text(current?.title ?? tr("projects", "picker.no_project")).lineLimit(1) }
            }
        }, content: { dismiss in
            OptionList(
                options: [PickerOption(id: "", title: tr("projects", "picker.no_project"), icon: AnyView(Image(systemName: "folder.badge.minus").foregroundStyle(.secondary)))]
                    + session.projects.items.map { p in PickerOption(id: p.id, title: p.title, icon: AnyView(ProjectIconView(icon: p.icon, size: 14))) },
                selected: [currentID ?? ""],
                searchPlaceholder: tr("projects", "picker.search_placeholder")
            ) { id in
                dismiss()
                onChange(id.isEmpty ? nil : id)
            }
            .task { await session.projects.loadIfNeeded() }
        })
    }
}

/// Emoji or folder glyph for a project (upstream ProjectIcon).
struct ProjectIconView: View {
    let icon: String?
    var size: CGFloat = 16

    var body: some View {
        if let icon, !icon.isEmpty {
            Text(icon).font(.system(size: size * 0.9)).frame(width: size, height: size)
        } else {
            Image(systemName: "folder").font(.system(size: size * 0.8)).foregroundStyle(.secondary).frame(width: size, height: size)
        }
    }
}

/// Date-only picker for start/due dates (`YYYY-MM-DD`), with clear.
struct DateOnlyPicker: View {
    let value: String?
    let label: String
    let noneLabel: String
    var icon = "calendar"
    let onChange: (String?) -> Void
    @State private var draft = Date()

    var body: some View {
        PopoverButton(label: {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(isOverdue ? Theme.destructive : .secondary)
                Text(value.map { Formatters.date($0) } ?? label)
                    .foregroundStyle(isOverdue ? Theme.destructive : .primary)
            }
        }, content: { dismiss in
            VStack(alignment: .leading, spacing: 8) {
                DatePicker("", selection: $draft, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                HStack {
                    Button(noneLabel) { dismiss(); onChange(nil) }
                    Spacer()
                    Button(tr("common", "save")) { dismiss(); onChange(Formatters.dateOnlyString(draft)) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .onAppear { draft = value.flatMap(Formatters.dateOnly) ?? Date() }
        })
    }

    private var isOverdue: Bool {
        guard icon == "calendar.badge.exclamationmark" || label == tr("issues", "pickers.due_date.trigger_label"),
              let value, let d = Formatters.dateOnly(value) else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }
}
