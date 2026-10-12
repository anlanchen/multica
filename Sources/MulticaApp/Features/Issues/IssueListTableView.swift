import AppKit
import MulticaCore
import SwiftUI

/// Table layout (upstream table-view.tsx): configurable columns (sort, hide,
/// reorder, resize), server grouping, sub-issue hierarchy, inline editors,
/// search and CSV export.
struct IssueListTableView: View {
    @Bindable var model: IssueListSurfaceModel
    @Environment(Toaster.self) private var toaster
    @State private var exporting = false
    @State private var columnsOpen = false

    static let selectWidth: CGFloat = 36
    static let rowHeight: CGFloat = 36

    static func defaultWidth(_ key: String) -> CGFloat {
        switch key {
        case "title": return 360
        case "status": return 150
        case "priority": return 130
        case "assignee", "project", "creator": return 180
        case "labels": return 220
        case "identifier": return 110
        default: return 150
        }
    }

    private var columns: [IssueListTableColumn] {
        model.state.tableColumns.filter { c in
            IssueListOptions.propertyID(fromKey: c.key).map { model.property($0) != nil } ?? true
        }
    }

    private func width(_ c: IssueListTableColumn) -> CGFloat { CGFloat(c.width ?? Double(Self.defaultWidth(c.key))) }

    var body: some View {
        let table = model.table
        let columns = columns
        let total = Self.selectWidth + columns.reduce(0) { $0 + width($1) } + 40
        let rows = table.displayRows()
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SearchField(text: $model.search, prompt: tr("issues", "table.search_placeholder"))
                    .frame(width: 280)
                Spacer()
                Menu {
                    Button { export(all: true) } label: { Label(tr("issues", "table.export_all"), systemImage: "square.and.arrow.down") }
                    Button { export(all: false) } label: {
                        Label(tr("issues", "table.export_selected", ["count": model.selectedIssues.count]), systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.selectedIssues.isEmpty)
                } label: {
                    if exporting { ProgressView().controlSize(.mini) } else { Label(tr("issues", "table.export"), systemImage: "square.and.arrow.down") }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(exporting)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) { Divider() }
            GeometryReader { geo in
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        header(columns, rows: rows)
                        Divider()
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                if !table.loaded && rows.allSatisfy({ if case .issue = $0 { return false } else { return true } }) {
                                    ForEach(0..<12, id: \.self) { _ in
                                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06))
                                            .frame(width: max(200, total - 80), height: 12)
                                            .padding(.horizontal, 16)
                                            .frame(height: Self.rowHeight)
                                    }
                                } else if rows.isEmpty || (table.loaded && !rows.contains(where: { if case .issue = $0 { return true } else { return false } }) && !table.usesGrouping) {
                                    Text(tr("issues", "table.empty")).font(Theme.Font.body).foregroundStyle(.secondary)
                                        .frame(width: min(geo.size.width, total), alignment: .center)
                                        .padding(.vertical, 40)
                                }
                                ForEach(rows) { row in
                                    rowView(row, columns: columns, width: total)
                                }
                                Color.clear.frame(height: 80)
                            }
                        }
                        .frame(height: max(0, geo.size.height - Self.rowHeight - 1))
                    }
                    .frame(width: max(total, geo.size.width), alignment: .leading)
                }
            }
        }
    }

    private func header(_ columns: [IssueListTableColumn], rows: [IssueListTableRow]) -> some View {
        let ids = model.table.visibleIssueIDs()
        let selected = ids.filter { model.selection.contains($0) }.count
        return HStack(spacing: 0) {
            Button {
                if selected == ids.count && !ids.isEmpty { model.deselect(ids) } else { model.select(ids) }
            } label: {
                Image(systemName: selected == ids.count && !ids.isEmpty ? "checkmark.square.fill" : (selected > 0 ? "minus.square.fill" : "square"))
                    .foregroundStyle(selected > 0 ? Theme.brand : .secondary)
            }
            .buttonStyle(.plain)
            .help(tr("issues", "table.select_all"))
            .frame(width: Self.selectWidth)
            ForEach(columns) { c in
                IssueListTableHeaderCell(model: model, column: c, width: width(c))
            }
            Button { columnsOpen.toggle() } label: {
                Image(systemName: "plus").foregroundStyle(.secondary).frame(width: 32, height: Self.rowHeight)
            }
            .buttonStyle(.plain)
            .help(tr("issues", "table.columns.add"))
            .popover(isPresented: $columnsOpen, arrowEdge: .bottom) { IssueListColumnPicker(model: model) }
        }
        .font(Theme.Font.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(height: Self.rowHeight)
    }

    @ViewBuilder
    private func rowView(_ row: IssueListTableRow, columns: [IssueListTableColumn], width: CGFloat) -> some View {
        switch row {
        case .group(let key, let label, let count, let collapsed):
            Button { model.state.toggleTableGroupCollapsed(key) } label: {
                HStack(spacing: 8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold))
                    Text(label).font(Theme.Font.caption.weight(.medium))
                    Text("\(count)").font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(width: width, height: 34)
                .background(Color.primary.opacity(0.04))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onChange(of: collapsed) { _, now in if !now { model.table.activate(IssueListTableModel.branchKey(key, nil)) } }
        case .issue(let id, let depth, let hasChildren, let collapsed):
            if let m = model.session.issues.model(id) {
                IssueListTableRowView(model: model, issueModel: m, columns: columns, depth: depth,
                                      hasChildren: hasChildren, collapsed: collapsed, width: width)
            }
        case .activate(let key, let branch):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(tr("issues", "table.loading_branch")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            .frame(width: min(width, 600), height: 30)
            .id(key)
            .onAppear { model.table.activate(branch) }
        case .loadMore(_, let branch):
            if let b = model.table.branches[branch] {
                IssueListLoadMoreFooter(branch: b, onLoadMore: { model.table.loadMore(branch) }, onRetry: { model.table.retry(branch) })
                    .frame(width: min(width, 600))
            }
        }
    }

    private func export(all: Bool) {
        exporting = true
        let selected = model.selectedIssues
        Task {
            defer { exporting = false }
            do {
                let issues = all ? try await model.table.exportAll() : selected
                let csv = IssueListTableExport.csv(issues: issues, columns: columns, model: model)
                let panel = NSSavePanel()
                let day = IssueListQuery.dayString(Date())
                panel.nameFieldStringValue = "\(all ? "issues" : "issues-selected")-\(day).csv"
                panel.allowedContentTypes = [.commaSeparatedText]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try Data(("\u{FEFF}" + csv).utf8).write(to: url)
                toaster.success(tr("issues", "table.export_success", ["count": issues.count]))
            } catch {
                let message = (error as? APIError)?.message
                toaster.error(message ?? tr("issues", "table.export_failed"))
            }
        }
    }
}

private struct IssueListTableHeaderCell: View {
    @Bindable var model: IssueListSurfaceModel
    let column: IssueListTableColumn
    let width: CGFloat
    @State private var dragWidth: CGFloat?

    private static let sortable: [String: String] = [
        "title": "title", "status": "status", "priority": "priority", "start_date": "start_date",
        "due_date": "due_date", "created_at": "created_at", "updated_at": "updated_at",
    ]

    private var sortField: String? {
        if let pid = IssueListOptions.propertyID(fromKey: column.key) {
            return model.property(pid).map { ["number", "date"].contains($0.type) } == true ? column.key : nil
        }
        return Self.sortable[column.key]
    }

    private var label: String {
        if let pid = IssueListOptions.propertyID(fromKey: column.key) { return model.property(pid)?.name ?? tr("issues", "table.no_value") }
        return tr("issues", "table.columns.\(column.key)")
    }

    var body: some View {
        let active = sortField != nil && sortField == model.state.sortBy
        let w = dragWidth ?? width
        HStack(spacing: 0) {
            Menu {
                if let field = sortField {
                    Button { sort(field, .asc) } label: { Label(tr("issues", "table.sort_ascending"), systemImage: "arrow.up") }
                    Button { sort(field, .desc) } label: { Label(tr("issues", "table.sort_descending"), systemImage: "arrow.down") }
                }
                if column.key != "title" {
                    if sortField != nil { Divider() }
                    Button { model.state.toggleTableColumn(column.key) } label: { Label(tr("issues", "table.columns.hide"), systemImage: "eye.slash") }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(label).lineLimit(1)
                    if active { Image(systemName: model.state.sortDirection == .asc ? "arrow.up" : "arrow.down").font(.system(size: 9)) }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.leading, 10)
            Spacer(minLength: 0)
            Rectangle()
                .fill(Color.clear)
                .frame(width: 6)
                .overlay(Rectangle().fill(Theme.border).frame(width: 1))
                .contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in dragWidth = max(80, width + v.translation.width) }
                    .onEnded { _ in
                        if let dragWidth { model.state.setTableColumnWidth(column.key, Double(dragWidth)) }
                        dragWidth = nil
                    })
        }
        .frame(width: w, height: IssueListTableView.rowHeight)
        .contentShape(Rectangle())
        .draggable(column.key) { Text(label).font(Theme.Font.caption).padding(6) }
        .dropDestination(for: String.self) { items, _ in
            guard let from = items.first, from != column.key else { return false }
            model.state.reorderTableColumn(from, over: column.key)
            return true
        }
        .help(column.key == "title" ? "" : tr("issues", "table.columns.reorder", ["column": label]))
    }

    private func sort(_ field: String, _ dir: IssueListSortDirection) {
        if model.state.sortBy != field { model.state.setSortBy(field) }
        model.state.setSortDirection(dir)
    }
}

private struct IssueListTableRowView: View {
    let model: IssueListSurfaceModel
    let issueModel: IssueModel
    let columns: [IssueListTableColumn]
    let depth: Int
    let hasChildren: Bool
    let collapsed: Bool
    let width: CGFloat
    @Environment(Navigator.self) private var nav
    @State private var hovering = false

    var body: some View {
        let issue = issueModel.issue
        let selected = model.selection.contains(issue.id)
        HStack(spacing: 0) {
            Button {
                let ids = model.table.visibleIssueIDs()
                if NSEvent.modifierFlags.contains(.shift), let anchor = model.table.selectionAnchor,
                   let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: issue.id) {
                    model.select(Array(ids[min(a, b)...max(a, b)]))
                } else {
                    model.toggleSelection(issue.id)
                }
                model.table.selectionAnchor = issue.id
            } label: {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? Theme.brand : .secondary)
                    .opacity(selected || hovering ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .help(tr("issues", "table.select_issue", ["identifier": issue.identifier]))
            .frame(width: IssueListTableView.selectWidth)
            ForEach(columns) { c in
                IssueListTableCell(model: model, issueModel: issueModel, key: c.key, depth: depth,
                                   hasChildren: hasChildren, collapsed: collapsed)
                    .padding(.horizontal, 8)
                    .frame(width: CGFloat(c.width ?? Double(IssueListTableView.defaultWidth(c.key))), alignment: .leading)
                    .clipped()
            }
        }
        .font(Theme.Font.body)
        .frame(width: width, height: IssueListTableView.rowHeight, alignment: .leading)
        .background(selected ? Theme.brand.opacity(0.08) : (hovering ? Theme.hover : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(model.peekID == issue.id ? Theme.brand.opacity(0.5) : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { IssueListOpen.click(issue, model: model, nav: nav) }
        .contextMenu { IssueListActionsMenu(issue: issue, model: model) }
    }
}

private struct IssueListTableCell: View {
    let model: IssueListSurfaceModel
    let issueModel: IssueModel
    let key: String
    let depth: Int
    let hasChildren: Bool
    let collapsed: Bool
    @Environment(WorkspaceSession.self) private var session
    @Environment(ModalCenter.self) private var modals
    @Environment(Navigator.self) private var nav
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var renaming: Bool

    var body: some View {
        let issue = issueModel.issue
        if let pid = IssueListOptions.propertyID(fromKey: key) {
            if let p = model.property(pid) {
                IssueListPropertyCell(model: model, issueID: issue.id, property: p)
            }
        } else {
            switch key {
            case "title": title(issue)
            case "identifier": Text(issue.identifier).font(Theme.Font.caption).foregroundStyle(.secondary)
            case "status":
                StatusPicker(current: issue.status, showLabel: true, style: nil) { s in
                    var p = IssueListPatch()
                    p.status = s
                    model.updateField(issue, p)
                }
            case "priority":
                PriorityPicker(current: issue.priority, showLabel: true, style: nil) { pr in
                    var p = IssueListPatch()
                    p.priority = pr
                    model.update(issue.id, p)
                }
            case "assignee":
                AssigneePicker(current: issue.assignee, showLabel: true, style: nil) { ref in
                    var p = IssueListPatch()
                    p.assignee = IssueListField(ref)
                    model.updateField(issue, p)
                }
            case "labels":
                LabelPicker(selected: issue.labels) { label, attach in
                    Task {
                        let api = session.api
                        if let r = try? await (attach ? api.attachLabel(issueId: issue.id, labelId: label.id) : api.detachLabel(issueId: issue.id, labelId: label.id)) {
                            session.issues.setLabels(issue.id, r.labels)
                        }
                    }
                }
            case "project":
                ProjectPicker(currentID: issue.projectID, showLabel: true) { pid in
                    var p = IssueListPatch()
                    p.projectID = IssueListField(pid)
                    model.update(issue.id, p)
                }
            case "start_date", "due_date":
                let value = key == "start_date" ? issue.startDate : issue.dueDate
                IssueListOptionalDayPicker(value: value, destructive: key == "due_date" && IssueListFormat.isPast(value)) { day in
                    var p = IssueListPatch()
                    if key == "start_date" { p.startDate = IssueListField(day) } else { p.dueDate = IssueListField(day) }
                    model.update(issue.id, p)
                }
            case "created_at", "updated_at":
                let raw = key == "created_at" ? issue.createdAt : issue.updatedAt
                Text(Timestamp.parse(raw).map { $0.formatted(.dateTime.month(.abbreviated).day().year()) } ?? "")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            case "child_progress":
                if let p = model.extras(issue.id).childProgress ?? model.progress(issue.id) {
                    HStack(spacing: 5) {
                        IssueListProgressRing(done: p.done, total: p.total)
                        Text("\(p.done)/\(p.total)").font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    Text(tr("issues", "table.empty_value")).foregroundStyle(.secondary)
                }
            case "creator":
                if let c = issue.creator {
                    ActorAvatar(type: c.type, id: c.id, size: 18, showName: true)
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func title(_ issue: Issue) -> some View {
        HStack(spacing: 6) {
            if hasChildren {
                Button { model.state.toggleTableParentCollapsed(issue.id) } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 14)
                }
                .buttonStyle(.plain)
                .help(tr("issues", "table.toggle_sub_issues"))
            } else {
                Color.clear.frame(width: 14)
            }
            Text(issue.identifier).font(Theme.Font.caption).foregroundStyle(.secondary).frame(minWidth: 56, alignment: .leading)
            IssueListActivityBadge(entry: model.activity.entry(issue.id), activeRuns: issueModel.activeRuns)
            if model.table.editingTitle == issue.id {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($renaming)
                    .onSubmit { commit(issue) }
                    .onExitCommand { model.table.editingTitle = nil }
                    .onChange(of: renaming) { _, focused in if !focused { commit(issue) } }
                    .onAppear { draft = issue.title; renaming = true }
            } else {
                Button { IssueListOpen.click(issue, model: model, nav: nav) } label: {
                    Text(issue.title).lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
                if let dup = model.extras(issue.id).duplicateOf { IssueListDuplicateMarker(identifier: dup) }
                Spacer(minLength: 0)
                if hovering {
                    Button {
                        var draft = CreateIssueDraft()
                        draft.parentIssueID = issue.id
                        draft.projectID = issue.projectID
                        draft.assignee = issue.assignee
                        modals.createIssue(draft)
                    } label: { Image(systemName: "plus").font(.system(size: 10)) }
                        .buttonStyle(.borderless)
                        .help(tr("issues", "actions.create_sub_issue"))
                    Button { model.table.editingTitle = issue.id } label: { Image(systemName: "pencil").font(.system(size: 10)) }
                        .buttonStyle(.borderless)
                        .help(tr("issues", "table.rename_title"))
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 18)
        .onHover { hovering = $0 }
    }

    private func commit(_ issue: Issue) {
        guard model.table.editingTitle == issue.id else { return }
        model.table.editingTitle = nil
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != issue.title else { return }
        var p = IssueListPatch()
        p.title = title
        model.update(issue.id, p)
    }
}

/// Date cell: the value (or "Empty") opening a calendar with clear.
struct IssueListOptionalDayPicker: View {
    let value: String?
    var destructive = false
    let onChange: (String?) -> Void
    @State private var open = false
    @State private var draft = Date()

    var body: some View {
        Button { open.toggle() } label: {
            Text(value.map(IssueListFormat.shortDay) ?? tr("issues", "table.empty_value"))
                .font(Theme.Font.caption)
                .foregroundStyle(value == nil ? .secondary : (destructive ? Theme.destructive : .primary))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                DatePicker("", selection: $draft, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                HStack {
                    if value != nil { Button(tr("issues", "actions.due_clear")) { open = false; onChange(nil) } }
                    Spacer()
                    Button(tr("common", "save")) { open = false; onChange(IssueListQuery.dayString(draft)) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .onAppear { draft = value.flatMap { IssueListQuery.parseDay($0) } ?? Date() }
        }
    }
}

/// Custom property cell: the value, editable in a popover.
struct IssueListPropertyCell: View {
    let model: IssueListSurfaceModel
    let issueID: String
    let property: IssueProperty
    @Environment(WorkspaceSession.self) private var session
    @State private var open = false
    @State private var text = ""
    @State private var date = Date()

    var body: some View {
        let value = model.extras(issueID).properties[property.id]
        Button { open.toggle() } label: {
            if value == nil {
                Text(tr("issues", "table.empty_value")).foregroundStyle(.secondary)
            } else {
                IssueListPropertyChip(property: property, value: value)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) { editor(value) }
    }

    @ViewBuilder
    private func editor(_ value: JSONValue?) -> some View {
        switch property.type {
        case "select", "multi_select", "actor", "multi_actor":
            let multi = property.type.hasPrefix("multi")
            let current = Set(multi ? (value?.arrayValue ?? []).compactMap(\.stringValue) : [value?.stringValue].compactMap { $0 })
            OptionList(options: options, selected: current, multiSelect: multi) { id in
                if multi {
                    var next = Array(current)
                    if current.contains(id) { next.removeAll { $0 == id } } else { next.append(id) }
                    set(next.isEmpty ? nil : .array(next.map(JSONValue.string)))
                } else {
                    open = false
                    set(current.contains(id) ? nil : .string(id))
                }
            }
        case "checkbox":
            Toggle(property.name, isOn: Binding(get: { value?.boolValue == true }, set: { set(.bool($0)) }))
                .padding(12)
        case "date":
            VStack(alignment: .leading, spacing: 8) {
                DatePicker("", selection: $date, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                HStack {
                    Button(tr("issues", "pickers.custom_property.none")) { open = false; set(nil) }
                    Spacer()
                    Button(tr("common", "save")) { open = false; set(.string(IssueListQuery.dayString(date))) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .onAppear { date = value?.stringValue.flatMap { IssueListQuery.parseDay($0) } ?? Date() }
        default:
            HStack {
                TextField(property.name, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { commitText() }
                Button(tr("common", "save")) { commitText() }
            }
            .padding(12)
            .onAppear {
                if let arr = value?.arrayValue { text = arr.compactMap(\.stringValue).joined(separator: ", ") } else { text = value?.stringValue ?? "" }
            }
        }
    }

    private var options: [PickerOption<String>] {
        if IssueListOptions.isActorPropertyType(property.type) {
            return session.directory.members.map {
                PickerOption(id: "member:\($0.userID)", title: $0.name, icon: AnyView(AvatarView(name: $0.name, url: $0.avatarURL, size: 16)))
            }
        }
        return (property.config?.options ?? []).map {
            PickerOption(id: $0.id, title: $0.name, icon: AnyView(Circle().fill(Color(hex: $0.color)).frame(width: 8, height: 8)))
        }
    }

    private func commitText() {
        open = false
        let raw = text.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return set(nil) }
        switch property.type {
        case "number": set(Double(raw).map(JSONValue.number) ?? .string(raw))
        case "multi_text", "multi_url":
            set(.array(raw.split(separator: ",").map { JSONValue.string($0.trimmingCharacters(in: .whitespaces)) }))
        default: set(.string(raw))
        }
    }

    private func set(_ value: JSONValue?) {
        let extras = model.extras(issueID)
        let previous = extras.properties
        var next = previous
        next[property.id] = value
        extras.properties = next
        Task {
            do {
                let r = value == nil
                    ? try await session.api.unsetIssueProperty(issueId: issueID, propertyId: property.id)
                    : try await session.api.setIssueProperty(issueId: issueID, propertyId: property.id, value: value!)
                extras.properties = r.properties
            } catch {
                extras.properties = previous
                model.toast?((error as? APIError)?.message ?? tr("issues", "detail.update_failed"), true)
            }
        }
    }
}

enum IssueListTableExport {
    @MainActor
    static func csv(issues: [Issue], columns: [IssueListTableColumn], model: IssueListSurfaceModel) -> String {
        let session = model.session
        let headers = columns.map { c -> String in
            if let pid = IssueListOptions.propertyID(fromKey: c.key) { return model.property(pid)?.name ?? "" }
            return tr("issues", "table.columns.\(c.key)")
        }
        let rows = issues.map { issue in
            columns.map { c -> String in
                if let pid = IssueListOptions.propertyID(fromKey: c.key), let p = model.property(pid) {
                    return IssueListPropertyText.display(p, model.extras(issue.id).properties[pid], session: session)
                }
                switch c.key {
                case "title": return issue.title
                case "identifier": return issue.identifier
                case "status": return session.issueListStatusLabel(issue.status)
                case "priority": return issue.priority.localizedName
                case "assignee": return issue.assignee.map { session.actorInfo(type: $0.type, id: $0.id).name } ?? ""
                case "labels": return issue.labels.map(\.name).joined(separator: ", ")
                case "project": return model.project(issue.projectID)?.title ?? ""
                case "start_date": return issue.startDate ?? ""
                case "due_date": return issue.dueDate ?? ""
                case "created_at": return issue.createdAt
                case "updated_at": return issue.updatedAt
                case "child_progress": return model.progress(issue.id).map { "\($0.done)/\($0.total)" } ?? ""
                case "creator": return issue.creator.map { session.actorInfo(type: $0.type, id: $0.id).name } ?? ""
                default: return ""
                }
            }
        }
        return IssueListCSV.build(headers: headers, rows: rows)
    }
}

enum IssueListPropertyText {
    @MainActor
    static func display(_ property: IssueProperty, _ value: JSONValue?, session: WorkspaceSession) -> String {
        guard let value else { return "" }
        func option(_ id: String) -> String { property.config?.options?.first { $0.id == id }?.name ?? id }
        func actor(_ ref: String) -> String {
            let parts = ref.split(separator: ":", maxSplits: 1).map(String.init)
            return parts.count == 2 ? session.actorInfo(type: parts[0], id: parts[1]).name : ref
        }
        switch property.type {
        case "select": return value.stringValue.map(option) ?? ""
        case "multi_select": return (value.arrayValue ?? []).compactMap(\.stringValue).map(option).joined(separator: ", ")
        case "checkbox":
            return value.boolValue == true ? tr("issues", "pickers.custom_property.true_label") : tr("issues", "pickers.custom_property.false_label")
        case "actor": return value.stringValue.map(actor) ?? ""
        case "multi_actor": return (value.arrayValue ?? []).compactMap(\.stringValue).map(actor).joined(separator: ", ")
        case "multi_text", "multi_url": return (value.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
        default: return value.stringValue ?? ""
        }
    }
}
