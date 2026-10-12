import MulticaCore
import SwiftUI

/// One row in an issue-modal picker (upstream PickerItem).
struct IssueModalOption: Identifiable {
    var id: String
    var title: String
    var group: String? = nil
    var disabled = false
    var help: String? = nil
    /// Empty-value row ("Unassigned", "No project"): muted, never filtered out.
    var isEmptyValue = false
    var searchText: String? = nil
    var leading: AnyView? = nil
    var trailing: AnyView? = nil
}

/// Searchable option list for picker popovers (upstream PropertyPicker):
/// type to filter (substring or pinyin), ↑/↓ to move, ↩ to pick.
struct IssueModalOptionList: View {
    let options: [IssueModalOption]
    var selected: Set<String> = []
    var searchable = true
    var searchPlaceholder = ""
    var width: CGFloat = 256
    var createTitle: ((String) -> String)? = nil
    var createSwatch: ((String) -> Color)? = nil
    var onCreate: ((String) -> Void)? = nil
    var footer: AnyView? = nil
    var emptyText: String? = nil
    let onPick: (String) -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var focused: Bool
    @FocusState private var listFocused: Bool

    private func filtered(_ q: String) -> [IssueModalOption] {
        guard !q.isEmpty else { return options }
        return options.filter { o in
            o.isEmptyValue || IssueModalPinyin.filter(o.title, q) || (o.searchText?.lowercased().contains(q) ?? false)
        }
    }

    private var canCreate: Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return onCreate != nil && !q.isEmpty && !options.contains { $0.title.caseInsensitiveCompare(q) == .orderedSame }
    }

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = filtered(q)
        VStack(alignment: .leading, spacing: 0) {
            if searchable {
                TextField(searchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .focused($focused)
                    .onSubmit { submit(list) }
                    .onKeyPress(.downArrow) { move(1, in: list); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: list); return .handled }
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, o in
                            if let g = o.group, g != (i > 0 ? list[i - 1].group : nil) {
                                Text(g)
                                    .font(Theme.Font.micro.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 6)
                                    .padding(.bottom, 2)
                            }
                            row(o).id(o.id)
                        }
                        if canCreate, let createTitle {
                            Button { onCreate?(query.trimmingCharacters(in: .whitespaces)) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus").foregroundStyle(.secondary).frame(width: 16)
                                    Text(createTitle(query.trimmingCharacters(in: .whitespaces))).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if let createSwatch {
                                        Circle().fill(createSwatch(query.trimmingCharacters(in: .whitespaces))).frame(width: 10, height: 10)
                                    }
                                }
                                .font(Theme.Font.body)
                            }
                            .buttonStyle(HoverRowButtonStyle(selected: highlighted == "__create__"))
                            .padding(.horizontal, 4)
                        }
                        if list.allSatisfy(\.isEmptyValue), !q.isEmpty, !canCreate {
                            Text(emptyText ?? tr("issues", "pickers.no_results"))
                                .font(Theme.Font.caption)
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 320)
                .onChange(of: highlighted) { if let h = highlighted { proxy.scrollTo(h) } }
            }
            if let footer {
                Divider()
                footer.padding(4)
            }
        }
        .frame(width: width)
        .modifier(IssueModalListKeys(enabled: !searchable, focused: $listFocused,
                                     move: { move($0, in: list) }, submit: { submit(list) }))
        .onAppear {
            if searchable { focused = true } else { listFocused = true }
        }
        .onChange(of: query) { highlighted = nil }
    }

    private func submit(_ list: [IssueModalOption]) {
        if highlighted == "__create__" || (highlighted == nil && canCreate && list.allSatisfy(\.isEmptyValue)) {
            onCreate?(query.trimmingCharacters(in: .whitespaces))
            return
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        let fallback = q.isEmpty ? list.first { !$0.disabled } : list.first { !$0.disabled && !$0.isEmptyValue }
        if let h = highlighted ?? fallback?.id { onPick(h) }
    }

    private func move(_ delta: Int, in list: [IssueModalOption]) {
        var ids = list.filter { !$0.disabled }.map(\.id)
        if canCreate { ids.append("__create__") }
        guard !ids.isEmpty else { return }
        let i = ids.firstIndex { $0 == highlighted } ?? (delta > 0 ? -1 : ids.count)
        highlighted = ids[max(0, min(ids.count - 1, i + delta))]
    }

    private func row(_ o: IssueModalOption) -> some View {
        Button { onPick(o.id) } label: {
            HStack(spacing: 8) {
                if let leading = o.leading { leading.frame(minWidth: 16) }
                Text(o.title)
                    .lineLimit(1)
                    .foregroundStyle(o.isEmptyValue || o.disabled ? .secondary : .primary)
                Spacer(minLength: 4)
                if let trailing = o.trailing { trailing }
                if selected.contains(o.id) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
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

/// Arrow/Return handling for lists without a search field.
private struct IssueModalListKeys: ViewModifier {
    let enabled: Bool
    var focused: FocusState<Bool>.Binding
    let move: (Int) -> Void
    let submit: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .focusable()
                .focused(focused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.return) { submit(); return .handled }
        } else {
            content
        }
    }
}

/// Toolbar pill that owns a popover. `isPresented` lets an overflow menu
/// mount the pill and open its picker in one step (upstream fieldPickerOpen).
struct IssueModalPill<Label: View, Content: View>: View {
    var isPresented: Binding<Bool>? = nil
    var onClear: (() -> Void)? = nil
    var clearLabel: String = ""
    var highlighted = false
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: (_ dismiss: @escaping () -> Void) -> Content
    @State private var shown = false

    var body: some View {
        HStack(spacing: 0) {
            Button { shown.toggle() } label: {
                HStack(spacing: 5) { label() }
                    .padding(.leading, 9)
                    .padding(.trailing, onClear == nil ? 9 : 3)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let onClear {
                Button(action: onClear) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 18, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(clearLabel)
                .accessibilityLabel(clearLabel)
                .padding(.trailing, 3)
            }
        }
        .font(Theme.Font.caption)
        .frame(maxWidth: 224)
        .background(Capsule().fill(shown ? Theme.selected : Color.primary.opacity(0.001)))
        .overlay(Capsule().strokeBorder(highlighted ? Theme.destructive : Color.primary.opacity(0.14), lineWidth: highlighted ? 1.5 : 1))
        .hoverHighlight(cornerRadius: 12)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            content { shown = false }
        }
        .onAppear {
            if isPresented?.wrappedValue == true { DispatchQueue.main.async { shown = true } }
        }
        .onChange(of: isPresented?.wrappedValue ?? false) { _, v in if v != shown { shown = v } }
        .onChange(of: shown) { _, v in if let b = isPresented, b.wrappedValue != v { b.wrappedValue = v } }
    }
}

/// Muted placeholder text inside a pill.
struct IssueModalPlaceholder: View {
    let text: String
    var body: some View { Text(text).foregroundStyle(.secondary).lineLimit(1) }
}

// MARK: - Pickers

struct IssueModalStatusMenu: View {
    @Environment(WorkspaceSession.self) private var session
    let current: IssueStatusKey
    let onPick: (IssueStatusKey) -> Void

    var body: some View {
        let catalog = session.issues.catalog
        IssueModalOptionList(
            options: catalog.entries.filter { $0.archivedAt == nil }.map { e in
                IssueModalOption(id: e.key.rawValue, title: catalog.localizedName(for: e.key),
                                 leading: AnyView(StatusIcon(status: e.key, entry: e)))
            },
            selected: [current.rawValue],
            searchPlaceholder: tr("issues", "filters.search_status")
        ) { onPick(IssueStatusKey(rawValue: $0)) }
    }
}

struct IssueModalPriorityMenu: View {
    let current: IssuePriority
    let onPick: (IssuePriority) -> Void

    var body: some View {
        IssueModalOptionList(
            options: IssuePriority.displayOrder.map { p in
                IssueModalOption(id: p.rawValue, title: p.localizedName, leading: AnyView(PriorityIcon(priority: p)))
            },
            selected: [current.rawValue],
            searchable: false,
            width: 200
        ) { onPick(IssuePriority(rawValue: $0) ?? .none) }
    }
}

/// Assignee frequency per workspace, fetched once (upstream assigneeFrequencyOptions).
@MainActor
@Observable
final class IssueModalAssigneeFrequency {
    private static var stores: [String: IssueModalAssigneeFrequency] = [:]
    static func shared(_ workspaceID: String) -> IssueModalAssigneeFrequency {
        if let s = stores[workspaceID] { return s }
        let s = IssueModalAssigneeFrequency()
        stores[workspaceID] = s
        return s
    }

    private(set) var counts: [String: Int] = [:]
    @ObservationIgnored private var loaded = false

    func load(_ api: APIClient) async {
        guard !loaded else { return }
        loaded = true
        if let list = try? await api.getAssigneeFrequency() {
            counts = Dictionary(list.map { ("\($0.assigneeType):\($0.assigneeId)", $0.frequency) }, uniquingKeysWith: max)
        } else {
            loaded = false
        }
    }

    func count(_ type: String, _ id: String) -> Int { counts["\(type):\(id)"] ?? 0 }
}

/// Members, agents (invoke permission + runtime required) and squads
/// (leader runtime required), each group sorted by assignment frequency.
struct IssueModalAssigneeMenu: View {
    @Environment(WorkspaceSession.self) private var session
    let current: ActorRef?
    let onPick: (ActorRef?) -> Void

    var body: some View {
        IssueModalOptionList(
            options: options,
            selected: [current.map { "\($0.type):\($0.id)" } ?? "none"],
            searchPlaceholder: tr("issues", "pickers.assignee.search_placeholder")
        ) { key in
            if key == "none" { onPick(nil); return }
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            onPick(ActorRef(type: parts[0], id: parts[1]))
        }
        .task {
            async let a: Void = session.agentRecords.loadIfNeeded()
            async let s: Void = session.squads.loadIfNeeded()
            async let f: Void = IssueModalAssigneeFrequency.shared(session.workspace.id).load(session.api)
            _ = await (a, s, f)
        }
    }

    private var options: [IssueModalOption] {
        let freq = IssueModalAssigneeFrequency.shared(session.workspace.id)
        let userID = session.currentUser.id
        let role = session.issueModalRole
        var out = [IssueModalOption(id: "none", title: tr("issues", "pickers.assignee.trigger_unassigned"), isEmptyValue: true,
                                    leading: AnyView(Image(systemName: "person.crop.circle.badge.minus").foregroundStyle(.secondary)))]
        let membersGroup = tr("issues", "pickers.assignee.members_group")
        for m in session.directory.members.sorted(by: { freq.count("member", $0.userID) > freq.count("member", $1.userID) }) {
            out.append(IssueModalOption(id: "member:\(m.userID)", title: m.name, group: membersGroup,
                                        leading: AnyView(AvatarView(name: m.name, url: m.avatarURL, size: 16))))
        }
        let agentsGroup = tr("issues", "pickers.assignee.agents_group")
        let agents = agentRows()
        let runnable = Set(agents.filter { $0.archivedAt == nil && IssueModalAgentAccess.isRuntimeBound($0) }.map(\.id))
        for a in agents.filter({ $0.archivedAt == nil }).sorted(by: { freq.count("agent", $0.id) > freq.count("agent", $1.id) }) {
            let denial = IssueModalAgentAccess.denial(a, userID: userID, role: role)
            let bound = IssueModalAgentAccess.isRuntimeBound(a)
            out.append(IssueModalOption(
                id: "agent:\(a.id)", title: a.name, group: agentsGroup, disabled: denial != nil || !bound,
                help: denial ?? (bound ? nil : tr("issues", "pickers.assignee.agent_runtime_required")),
                leading: AnyView(AvatarView(name: a.name, url: a.avatarUrl, kind: .agent, size: 16)),
                trailing: a.visibility == "private" ? AnyView(Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(.secondary)) : nil))
        }
        let squadsGroup = tr("issues", "pickers.assignee.squads_group")
        for s in session.squads.items.filter({ $0.archivedAt == nil }).sorted(by: { freq.count("squad", $0.id) > freq.count("squad", $1.id) }) {
            let bound = runnable.contains(s.leaderId)
            out.append(IssueModalOption(
                id: "squad:\(s.id)", title: s.name, group: squadsGroup, disabled: !bound,
                help: bound ? nil : tr("issues", "pickers.assignee.squad_runtime_required"),
                leading: AnyView(AvatarView(name: s.name, url: s.avatarUrl, kind: .squad, size: 16))))
        }
        return out
    }

    /// Full agent records when loaded; the directory's agents until then.
    private func agentRows() -> [AgentRecord] {
        if session.agentRecords.isLoaded { return session.agentRecords.items }
        return session.directory.agents.map { a in
            AgentRecord(id: a.id, workspaceId: a.workspaceID, runtimeId: a.runtimeID, name: a.name, avatarUrl: a.avatarURL,
                        permissionMode: "public_to", invocationTargets: [AgentInvocationTarget(targetType: "workspace")], archivedAt: a.archivedAt)
        }
    }
}

/// Multi-select label list with inline create and "Manage labels…".
struct IssueModalLabelMenu: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let selectedIDs: [String]
    let onChange: ([String]) -> Void
    let dismiss: () -> Void
    @State private var creating = false

    var body: some View {
        IssueModalOptionList(
            options: session.labels.items.map { l in
                IssueModalOption(id: l.id, title: l.name, leading: AnyView(Circle().fill(Color(hex: l.color)).frame(width: 10, height: 10)))
            },
            selected: Set(selectedIDs),
            searchPlaceholder: tr("issues", "pickers.label.search_placeholder"),
            width: 300,
            createTitle: { "\(tr("issues", "pickers.label.create_action")) “\($0)”" },
            createSwatch: { Color(hex: IssueModalLabelColor.pick($0)) },
            onCreate: create,
            footer: AnyView(
                Button {
                    dismiss()
                    nav.push(.settings, query: ["tab": "labels"])
                } label: {
                    Label(tr("issues", "pickers.label.manage_action"), systemImage: "slider.horizontal.3")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(HoverRowButtonStyle())
            )
        ) { id in
            onChange(selectedIDs.contains(id) ? selectedIDs.filter { $0 != id } : selectedIDs + [id])
        }
        .task { await session.labels.loadIfNeeded() }
    }

    private func create(_ name: String) {
        guard !creating else { return }
        creating = true
        Task {
            defer { creating = false }
            do {
                let label = try await session.api.createLabel(CreateLabelRequest(resourceType: "issue", name: name, description: nil, color: IssueModalLabelColor.pick(name)))
                session.labels.upsert(label)
                onChange(selectedIDs + [label.id])
            } catch {
                toaster.error(IssueModalErrors.message(error, fallback: tr("issues", "pickers.label.create_failed")))
            }
        }
    }
}

struct IssueModalProjectMenu: View {
    @Environment(WorkspaceSession.self) private var session
    let currentID: String?
    let onPick: (String?) -> Void

    var body: some View {
        IssueModalOptionList(
            options: [IssueModalOption(id: "", title: tr("projects", "picker.no_project"), isEmptyValue: true,
                                       leading: AnyView(Image(systemName: "folder.badge.minus").foregroundStyle(.secondary)))]
                + session.projects.items.map { p in
                    IssueModalOption(id: p.id, title: p.title, leading: AnyView(ProjectIconView(icon: p.icon, size: 14)))
                },
            selected: [currentID ?? ""],
            searchPlaceholder: tr("projects", "picker.search_placeholder"),
            emptyText: session.projects.items.isEmpty ? tr("projects", "picker.empty") : nil
        ) { onPick($0.isEmpty ? nil : $0) }
        .task { await session.projects.loadIfNeeded() }
    }
}

/// Calendar-day picker body: the empty value first, then the calendar.
struct IssueModalDateMenu: View {
    let value: String?
    let emptyLabel: String
    let onPick: (String?) -> Void
    @State private var day = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { onPick(nil) } label: {
                HStack {
                    Text(emptyLabel).foregroundStyle(.secondary)
                    Spacer()
                    if value == nil { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                }
                .font(Theme.Font.body)
            }
            .buttonStyle(HoverRowButtonStyle())
            .padding(4)
            Divider()
            DatePicker("", selection: Binding(get: { day }, set: { d in
                day = d
                onPick(Formatters.dateOnlyString(d))
            }), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(10)
        }
        .onAppear { day = value.flatMap(Formatters.dateOnly) ?? Date() }
    }
}

struct IssueModalStageMenu: View {
    let stage: Int?
    let maxStage: Int
    let onPick: (Int?) -> Void

    var body: some View {
        IssueModalOptionList(
            options: [IssueModalOption(id: "none", title: tr("issues", "stage.none"), isEmptyValue: true,
                                       leading: AnyView(Image(systemName: "signpost.right").foregroundStyle(.secondary)))]
                + IssueModalStage.options(stage: stage, maxStage: maxStage).map { n in
                    IssueModalOption(id: String(n), title: tr("issues", "stage.value", ["n": n]),
                                     leading: AnyView(Image(systemName: "signpost.right").foregroundStyle(.secondary)))
                },
            selected: [stage.map(String.init) ?? "none"],
            searchable: false,
            width: 176
        ) { onPick(Int($0)) }
    }
}

/// `MMM d` for a `YYYY-MM-DD` day (upstream formatDateOnly).
enum IssueModalDates {
    static func short(_ value: String) -> String {
        guard let d = Formatters.dateOnly(value) else { return value }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    static func isPast(_ value: String) -> Bool {
        guard let d = Formatters.dateOnly(value) else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }
}
