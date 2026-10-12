import MulticaCore
import SwiftUI

/// Save the current surface as a view, or edit one (upstream
/// save-view-dialog.tsx). Edits a throwaway draft of the view state; the
/// page underneath never notices.
struct IssueListSaveViewSheet: View {
    let model: IssueListSurfaceModel
    let views: IssueListViewsModel
    let scope: IssueListSaveScope
    let target: IssueListSaveTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(Toaster.self) private var toaster
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @State private var draft = IssueListViewState()
    @State private var name = ""
    @State private var nameError = false
    @State private var visibility = "private"
    @State private var variant = "all"
    @State private var displayOpen = false
    @State private var filterOpen = false
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    private static let workspaceVariants = ["all", "members", "agents"]
    private static let myVariants = ["any", "assigned", "created", "involved"]

    private var isMy: Bool { if case .my = scope { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(target.view == nil ? tr("issues", "save_view.title") : tr("issues", "save_view.edit_title")).font(Theme.Font.title)
                Text(scopeHint).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            formRow(tr("issues", "save_view.name_label")) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(tr("issues", "save_view.name_placeholder"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 256)
                        .focused($nameFocused)
                        .onSubmit(save)
                        .onChange(of: name) { _, v in
                            if v.count > 80 { name = String(v.prefix(80)) }
                            if nameError && !v.trimmingCharacters(in: .whitespaces).isEmpty { nameError = false }
                        }
                    if nameError {
                        Text(tr("issues", "save_view.name_required")).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                    }
                }
            }
            if isMy {
                Text(tr("issues", "save_view.my_private_note")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(.leading, 76)
            } else {
                formRow(tr("issues", "save_view.visibility_label")) {
                    Picker("", selection: $visibility) {
                        Text(tr("issues", "save_view.visibility_private")).tag("private")
                        Text(tr("issues", "save_view.visibility_workspace")).tag("workspace")
                    }
                    .labelsHidden()
                    .frame(width: 256)
                }
            }
            formRow(isMy ? tr("issues", "save_view.scope_label_my") : tr("issues", "save_view.scope_label_workspace")) {
                Picker("", selection: $variant) {
                    ForEach(isMy ? Self.myVariants : Self.workspaceVariants, id: \.self) { v in
                        Text(tr("issues", "save_view.\(Self.variantKey(v))")).tag(v)
                    }
                }
                .labelsHidden()
                .frame(width: 256)
            }
            formRow(tr("issues", "save_view.filters_label"), top: true) {
                IssueListFlowLayout(spacing: 6) {
                    ForEach(IssueListChips.build(state: draft, baseline: nil, model: model, showDate: false)) { chip in
                        IssueListChipView(chip: chip) {
                            if let d = chip.dimension { draft.clearFilterDimension(d) }
                        }
                    }
                    Button { filterOpen.toggle() } label: {
                        Label(tr("issues", "save_view.add_filter"), systemImage: "plus")
                            .font(Theme.Font.caption)
                            .padding(.horizontal, 8).frame(height: 24)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3])).foregroundStyle(Theme.border))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $filterOpen, arrowEdge: .bottom) {
                        IssueListFilterMenu(state: $draft, model: model, baseline: nil, showCounts: false, showDate: false)
                    }
                }
            }
            DisclosureGroup(isExpanded: $displayOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    formRow(tr("issues", "save_view.layout_label")) {
                        Picker("", selection: Binding(get: { draft.viewMode }, set: { draft.setViewMode($0) })) {
                            ForEach([IssueListViewMode.list, .board, .table, .swimlane], id: \.self) { m in
                                Text(tr("issues", "view.\(m.rawValue)")).tag(m)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 256)
                    }
                    IssueListDisplayPopover(state: $draft, model: model, mode: draft.viewMode)
                        .frame(width: 332)
                    Text(tr("issues", "save_view.default_hint")).font(Theme.Font.caption).foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 6) {
                    Text(tr("issues", "save_view.display_defaults")).font(Theme.Font.caption.weight(.medium))
                    Text(displaySummary).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack {
                Spacer()
                Button(tr("issues", "save_view.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(target.view == nil ? tr("issues", "save_view.create") : tr("issues", "save_view.update"), action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: seed)
    }

    private func formRow<C: View>(_ label: String, top: Bool = false, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: top ? .top : .center, spacing: 12) {
            Text(label).font(Theme.Font.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                .padding(.top, top ? 4 : 0)
            content()
            Spacer(minLength: 0)
        }
    }

    private static func variantKey(_ v: String) -> String {
        switch v {
        case "any": return "variant_my_any"
        case "assigned": return "variant_my_assigned"
        case "created": return "variant_my_created"
        case "involved": return "variant_my_involved"
        default: return "variant_\(v)"
        }
    }

    private var projectTitle: String {
        guard case .project(let id, _) = scope else { return "" }
        return session.projects.item(id)?.title ?? ""
    }

    private var scopeHint: String {
        switch scope {
        case .workspace:
            return variant == "members" ? tr("issues", "save_view.hint_workspace_members")
                : variant == "agents" ? tr("issues", "save_view.hint_workspace_agents") : tr("issues", "save_view.hint_workspace")
        case .my(let fallback):
            let v = Self.myVariants.contains(variant) ? variant : fallback
            return tr("issues", "save_view.hint_my_\(v)")
        case .project:
            return variant == "members" ? tr("issues", "save_view.hint_project_members", ["title": projectTitle])
                : variant == "agents" ? tr("issues", "save_view.hint_project_agents", ["title": projectTitle])
                : tr("issues", "save_view.hint_project", ["title": projectTitle])
        }
    }

    private var displaySummary: String {
        var parts = [tr("issues", "view.\(draft.viewMode.rawValue)")]
        if draft.viewMode == .board {
            if let pid = IssueListOptions.propertyID(fromKey: draft.grouping) {
                parts.append(model.property(pid)?.name ?? tr("issues", "save_view.custom_property"))
            } else {
                parts.append(tr("issues", "display.group_\(draft.grouping)"))
            }
        } else if draft.viewMode == .swimlane {
            parts.append(tr("issues", "display.group_\(draft.swimlaneGrouping.rawValue)"))
        }
        if let key = IssueListOptions.sortLabelKey(draft.sortBy) {
            parts.append(tr("issues", "display.\(key)"))
        } else if let pid = IssueListOptions.propertyID(fromKey: draft.sortBy) {
            parts.append(model.property(pid)?.name ?? tr("issues", "save_view.custom_property"))
        }
        if draft.sortBy != "position" {
            parts.append(tr("issues", "display.\(IssueListOptions.sortDirectionLabelKey(field: draft.sortBy, direction: draft.sortDirection))"))
        }
        return parts.joined(separator: " · ")
    }

    private func seed() {
        if target.fromDefinition, let view = target.view {
            var def = view.query
            for (k, v) in view.display { def[k] = v }
            draft = IssueListViewState(json: def, defaults: IssueListViewState())
        } else {
            draft = model.state
            draft.dateFilter = nil
            draft.agentRunningFilter = false
        }
        name = target.view?.name ?? ""
        visibility = target.view?.visibility == "workspace" ? "workspace" : "private"
        switch scope {
        case .workspace(let k), .project(_, let k):
            let fromEdit = target.view?.scopeVariant
            variant = fromEdit == "members" || fromEdit == "agents" ? fromEdit! : (target.view != nil ? "all" : k)
        case .my(let v):
            let fromEdit = target.view?.scopeVariant ?? ""
            variant = Self.myVariants.contains(fromEdit) ? fromEdit : v
        }
        nameFocused = true
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            nameError = true
            nameFocused = true
            return
        }
        let scopeVariant: String? = isMy ? variant : (variant == "members" || variant == "agents" ? variant : nil)
        let vis = isMy ? "private" : visibility
        saving = true
        Task {
            defer { saving = false }
            do {
                if let view = target.view {
                    try await views.update(view, name: trimmed, visibility: vis, scopeVariant: scopeVariant,
                                           query: draft.queryJSON, display: draft.displayJSON)
                    toaster.success(tr("issues", "save_view.toast_updated"))
                } else {
                    let request = CreateIssueViewRequest(name: trimmed, scopeType: scope.scopeType, scopeId: scope.scopeID,
                                                         scopeVariant: scopeVariant, visibility: vis, definitionVersion: 1,
                                                         query: draft.queryJSON, display: draft.displayJSON)
                    let created = try await views.create(request)
                    toaster.success(tr("issues", "save_view.toast_created"))
                    if let created { nav.setQuery("view", created.id) }
                }
                dismiss()
            } catch let e as APIError where e.status == 409 {
                toaster.error(tr("issues", "save_view.toast_conflict"))
            } catch {
                let message = (error as? APIError)?.message ?? error.localizedDescription
                toaster.error(message.isEmpty ? tr("issues", "save_view.toast_failed") : message)
            }
        }
    }
}

/// Order (drag), visibility (switch) and edit/delete for one surface's
/// view bar (upstream manage-views-dialog.tsx).
struct IssueListManageViewsSheet: View {
    let views: IssueListViewsModel
    let items: [IssueListBarItem]
    let hidden: Set<String>
    let anchorID: String
    let onReorder: ([String]) -> Void
    let onToggleHidden: (String, Bool) -> Void
    let onEdit: (IssueView) -> Void
    let onDelete: (IssueView) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Toaster.self) private var toaster
    @State private var order: [IssueListBarItem] = []
    @State private var deleting: IssueView?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "square.3.layers.3d")
                Text(tr("issues", "view_bar.manage_title")).font(Theme.Font.title)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            Text(tr("issues", "view_bar.manage_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
            List {
                ForEach(order) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help(tr("issues", "view_bar.drag_handle"))
                        Text(item.label).lineLimit(1)
                        if item.isBuiltin {
                            Text(tr("issues", "view_bar.builtin_tag")).font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let view = item.view, item.canManage {
                            Button { onEdit(view) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                .help(tr("issues", "view_selector.edit"))
                            Button { deleting = view } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help(tr("issues", "view_bar.delete"))
                        }
                        Toggle("", isOn: Binding(get: { !hidden.contains(item.id) }, set: { onToggleHidden(item.id, !$0) }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .disabled(item.id == anchorID)
                            .help(tr("issues", "view_bar.visible_toggle"))
                    }
                    .font(Theme.Font.body)
                }
                .onMove { from, to in
                    order.move(fromOffsets: from, toOffset: to)
                    onReorder(order.map(\.id))
                }
            }
            .listStyle(.bordered)
            .frame(height: min(420, CGFloat(order.count) * 34 + 20))
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { order = items }
        .onChange(of: items) { _, next in
            let ids = Set(next.map(\.id))
            order = order.filter { ids.contains($0.id) }.compactMap { o in next.first { $0.id == o.id } }
                + next.filter { n in !order.contains { $0.id == n.id } }
        }
        .alert(tr("issues", "view_bar.delete_title"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(tr("issues", "save_view.cancel"), role: .cancel) { deleting = nil }
            Button(tr("issues", "view_bar.delete"), role: .destructive) {
                guard let v = deleting else { return }
                deleting = nil
                Task {
                    do {
                        try await onDelete(v)
                        toaster.success(tr("issues", "view_bar.toast_deleted"))
                    } catch {
                        toaster.error(tr("issues", "save_view.toast_failed"))
                    }
                }
            }
        } message: {
            Text(tr("issues", "view_bar.delete_description", ["name": deleting?.name ?? ""]))
        }
    }
}
