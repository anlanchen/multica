import AppKit
import MulticaCore
import SwiftUI

/// The properties sidebar (upstream issue-detail sidebarContent).
struct IssueDetailSidebar: View {
    let store: IssueDetailStore
    @Binding var runConfirm: IssueDetailRunGate?

    @Environment(WorkspaceSession.self) private var session
    @State private var propertiesOpen = true
    @State private var parentOpen = true
    @State private var detailsOpen = true
    @State private var metadataOpen = false

    var body: some View {
        ScrollView {
            if let issue = store.issue {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 0) {
                        IssueDetailSectionHeader(title: tr("issues", "detail.section_properties"), open: $propertiesOpen)
                        if propertiesOpen { IssueDetailProperties(store: store, issue: issue, runConfirm: $runConfirm).padding(.leading, 8) }
                    }
                    IssueDetailQuickActions(store: store)
                    IssueDetailWakeupsSection(store: store, issue: issue)
                    if let parentID = issue.parentIssueID, let parent = session.issues.model(parentID)?.issue {
                        VStack(alignment: .leading, spacing: 0) {
                            IssueDetailSectionHeader(title: tr("issues", "detail.section_parent_issue"), open: $parentOpen)
                            if parentOpen { IssueDetailParentRow(store: store, parent: parent).padding(.leading, 8) }
                        }
                    }
                    IssueDetailDuplicatesSection(store: store)
                    if store.prSidebarEnabled { IssueDetailPullRequestsSection(store: store) }
                    IssueDetailDeliverablesSection(store: store)
                    IssueDetailExecutionLog(store: store)
                    VStack(alignment: .leading, spacing: 0) {
                        IssueDetailSectionHeader(title: tr("issues", "detail.section_details"), open: $detailsOpen)
                        if detailsOpen { details(issue).padding(.leading, 8) }
                    }
                    if let metadata = store.record?.metadata, !metadata.isEmpty {
                        Button { metadataOpen = true } label: {
                            HStack(spacing: 4) {
                                Text(tr("issues", "detail.section_metadata"))
                                Text("· \(metadata.count)").monospacedDigit()
                                Spacer()
                            }
                            .font(Theme.Font.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                        .sheet(isPresented: $metadataOpen) { IssueDetailMetadataSheet(metadata: metadata) }
                    }
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func details(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            IssueDetailPropRow(tr("issues", "detail.prop_created_by")) {
                if let creator = issue.creator {
                    ActorAvatar(type: creator.type, id: creator.id, size: 18, showName: true, nameFont: Theme.Font.caption)
                }
            }
            IssueDetailPropRow(tr("issues", "detail.prop_created")) {
                Text(IssueDetailDates.short(issue.createdAt)).font(Theme.Font.caption).foregroundStyle(.secondary)
                    .help(Formatters.date(issue.createdAt, style: .complete, time: .shortened))
            }
            IssueDetailPropRow(tr("issues", "detail.prop_updated")) {
                Text(IssueDetailDates.short(issue.updatedAt)).font(Theme.Font.caption).foregroundStyle(.secondary)
                    .help(Formatters.date(issue.updatedAt, style: .complete, time: .shortened))
            }
        }
    }
}

/// Property row: fixed-width label (text or icon + name), value cell.
struct IssueDetailPropRow<Label: View, Content: View>: View {
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 5) { label() }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 30)
    }
}

extension IssueDetailPropRow where Label == Text {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = { Text(title) }
        self.content = content
    }
}

/// A value cell that opens a popover editor; `autoOpen` drops the user
/// straight into the editor after "Add property".
struct IssueDetailPropertyCell<Label: View, Content: View>: View {
    var autoOpen = false
    var disabled = false
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: (_ dismiss: @escaping () -> Void) -> Content
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) { label() }
                .font(Theme.Font.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
        .disabled(disabled)
        .popover(isPresented: $open, arrowEdge: .leading) { content { open = false } }
        .onAppear { if autoOpen { DispatchQueue.main.async { open = true } } }
    }
}

enum IssueDetailOptionalProp: String, CaseIterable {
    case priority, stage, startDate = "start_date", dueDate = "due_date", labels

    var title: String {
        switch self {
        case .priority: return tr("issues", "detail.prop_priority")
        case .stage: return tr("issues", "detail.prop_stage")
        case .startDate: return tr("issues", "detail.prop_start_date")
        case .dueDate: return tr("issues", "detail.prop_due_date")
        case .labels: return tr("issues", "detail.prop_labels")
        }
    }

    var icon: String {
        switch self {
        case .priority: return "chart.bar"
        case .stage: return "flag"
        case .startDate: return "calendar.badge.clock"
        case .dueDate: return "calendar"
        case .labels: return "tag"
        }
    }

    func isSet(_ issue: Issue, stage: Int?) -> Bool {
        switch self {
        case .priority: return issue.priority != .none
        case .stage: return stage != nil
        case .startDate: return issue.startDate != nil
        case .dueDate: return issue.dueDate != nil
        case .labels: return !issue.labels.isEmpty
        }
    }
}

/// Status, assignee and project always; optional fields and custom
/// properties once set or added this session (upstream progressive
/// disclosure: clearing a value does not hide its row).
struct IssueDetailProperties: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(ModalCenter.self) private var modals
    let store: IssueDetailStore
    let issue: Issue
    @Binding var runConfirm: IssueDetailRunGate?

    @State private var visible: Set<IssueDetailOptionalProp> = []
    @State private var visibleCustom: Set<String> = []
    @State private var seededFor: String?
    @State private var autoOpen: String?
    @State private var addOpen = false

    var body: some View {
        let stage = store.record?.stage
        let properties = session.properties.items
        let values = store.record?.properties ?? [:]
        VStack(alignment: .leading, spacing: 0) {
            IssueDetailPropRow(tr("issues", "detail.prop_status")) {
                IssueDetailStatusCell(store: store, issue: issue, runConfirm: $runConfirm)
            }
            IssueDetailPropRow(tr("issues", "detail.prop_assignee")) {
                IssueDetailPropertyCell(label: {
                    if let a = issue.assignee {
                        ActorAvatar(type: a.type, id: a.id, size: 18, showName: true, nameFont: Theme.Font.caption)
                    } else {
                        Image(systemName: "person.crop.circle.dashed").foregroundStyle(.secondary)
                        Text(tr("issues", "pickers.assignee.trigger_unassigned")).foregroundStyle(.secondary)
                    }
                }, content: { dismiss in
                    IssueDetailAssigneeList(current: issue.assignee) { ref in
                        dismiss()
                        guard ref != issue.assignee else { return }
                        store.requestAssignee(ref, runConfirm: $runConfirm, toaster: toaster)
                    }
                })
            }
            IssueDetailPropRow(tr("issues", "detail.prop_project")) {
                IssueDetailPropertyCell(label: {
                    let project = issue.projectID.flatMap { session.projects.item($0) }
                    ProjectIconView(icon: project?.icon, size: 14)
                    Text(project?.title ?? tr("projects", "picker.no_project")).foregroundStyle(project == nil ? .secondary : .primary).lineLimit(1)
                }, content: { dismiss in
                    OptionList(
                        options: [PickerOption(id: "", title: tr("projects", "picker.no_project"),
                                               icon: AnyView(Image(systemName: "folder.badge.minus").foregroundStyle(.secondary)))]
                            + session.projects.items.map { PickerOption(id: $0.id, title: $0.title, icon: AnyView(ProjectIconView(icon: $0.icon, size: 14))) },
                        selected: [issue.projectID ?? ""],
                        searchPlaceholder: tr("projects", "picker.search_placeholder")
                    ) { id in
                        dismiss()
                        Task { await store.updateProject(id.isEmpty ? nil : id, toaster: toaster) }
                    }
                    .task { await session.projects.loadIfNeeded() }
                })
            }
            ForEach(IssueDetailOptionalProp.allCases, id: \.self) { key in
                if visible.contains(key) && (key != .stage || issue.parentIssueID != nil) {
                    IssueDetailPropRow(key.title) { optionalCell(key, stage: stage) }
                }
            }
            ForEach(properties.filter { values[$0.id] != nil || (!$0.archived && visibleCustom.contains($0.id)) }) { p in
                IssueDetailPropRow(label: {
                    IssueDetailPropertyIcon(property: p)
                    Text(p.name)
                }, content: {
                    IssueDetailCustomPropertyCell(store: store, property: p, value: values[p.id], autoOpen: autoOpen == "custom:\(p.id)")
                })
            }
            if hasAddable(properties: properties, values: values) {
                Button { addOpen.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 10))
                        Text(tr("issues", "detail.add_property_action"))
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .popover(isPresented: $addOpen, arrowEdge: .bottom) { addMenu(properties: properties, values: values) }
            }
        }
        .onAppear { seed() }
        .onChange(of: issue) { seed() }
        .onChange(of: store.record?.properties) { seed() }
        .onChange(of: autoOpen) {
            guard autoOpen != nil else { return }
            DispatchQueue.main.async { autoOpen = nil }
        }
        .task { await session.labels.loadIfNeeded() }
    }

    private func seed() {
        let stage = store.record?.stage
        let set = Set(IssueDetailOptionalProp.allCases.filter { $0.isSet(issue, stage: stage) })
        let custom = Set((store.record?.properties ?? [:]).keys)
        if seededFor != issue.id {
            seededFor = issue.id
            visible = set
            visibleCustom = custom
        } else {
            visible.formUnion(set)
            visibleCustom.formUnion(custom)
        }
    }

    private func hasAddable(properties: [IssueProperty], values: [String: JSONValue]) -> Bool {
        IssueDetailOptionalProp.allCases.contains { !visible.contains($0) && ($0 != .stage || issue.parentIssueID != nil) }
            || properties.contains { !$0.archived && !visibleCustom.contains($0.id) && values[$0.id] == nil }
    }

    private func addMenu(properties: [IssueProperty], values: [String: JSONValue]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(IssueDetailOptionalProp.allCases.filter { !visible.contains($0) && ($0 != .stage || issue.parentIssueID != nil) }, id: \.self) { key in
                Button {
                    visible.insert(key)
                    addOpen = false
                    autoOpen = key.rawValue
                } label: {
                    Label(key.title, systemImage: key.icon).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(HoverRowButtonStyle())
            }
            let addable = properties.filter { !$0.archived && !visibleCustom.contains($0.id) && values[$0.id] == nil }
            if !addable.isEmpty {
                Divider().padding(.vertical, 4)
                ForEach(addable) { p in
                    Button {
                        visibleCustom.insert(p.id)
                        addOpen = false
                        autoOpen = "custom:\(p.id)"
                    } label: {
                        HStack(spacing: 6) {
                            IssueDetailPropertyIcon(property: p)
                            Text(p.name).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(HoverRowButtonStyle())
                }
            }
        }
        .font(Theme.Font.caption)
        .padding(4)
        .frame(width: 180)
    }

    @ViewBuilder private func optionalCell(_ key: IssueDetailOptionalProp, stage: Int?) -> some View {
        let open = autoOpen == key.rawValue
        switch key {
        case .priority:
            IssueDetailPropertyCell(autoOpen: open, label: {
                PriorityIcon(priority: issue.priority)
                Text(issue.priority.localizedName)
            }, content: { dismiss in
                OptionList(options: IssuePriority.displayOrder.map { PickerOption(id: $0, title: $0.localizedName, icon: AnyView(PriorityIcon(priority: $0))) },
                           selected: [issue.priority]) { p in
                    dismiss()
                    if p != issue.priority { Task { await store.updatePriority(p, toaster: toaster) } }
                }
            })
        case .stage:
            IssueDetailPropertyCell(autoOpen: open, label: {
                Image(systemName: "flag").foregroundStyle(.secondary)
                Text(stage.map { tr("issues", "stage.value", ["n": $0]) } ?? tr("issues", "stage.none"))
                    .foregroundStyle(stage == nil ? .secondary : .primary)
            }, content: { dismiss in
                let maxStage = store.parentChildStages.max() ?? 0
                OptionList(options: [PickerOption(id: 0, title: tr("issues", "stage.none"))]
                           + (1...max(1, maxStage + 1)).map { PickerOption(id: $0, title: tr("issues", "stage.value", ["n": $0])) },
                           selected: [stage ?? 0]) { n in
                    dismiss()
                    Task { await store.updateStage(n == 0 ? nil : n, toaster: toaster) }
                }
            })
        case .startDate:
            IssueDetailDateCell(value: issue.startDate, icon: "calendar.badge.clock", placeholder: tr("issues", "pickers.start_date.trigger_label"),
                                noneLabel: tr("issues", "pickers.start_date.none"), autoOpen: open, overdue: false) { v in
                Task { await store.updateDate("start_date", v, toaster: toaster) }
            }
        case .dueDate:
            IssueDetailDateCell(value: issue.dueDate, icon: "calendar", placeholder: tr("issues", "pickers.due_date.trigger_label"),
                                noneLabel: tr("issues", "pickers.due_date.none"), autoOpen: open,
                                overdue: IssueDetailDates.isPast(issue.dueDate) && !issue.status.issueDetailIsFinished(session.issues.catalog)) { v in
                Task { await store.updateDate("due_date", v, toaster: toaster) }
            }
        case .labels:
            IssueDetailLabelsCell(store: store, issue: issue, autoOpen: open)
        }
    }
}

/// Status cell with upstream's extra "Mark as duplicate" entry.
struct IssueDetailStatusCell: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(ModalCenter.self) private var modals
    let store: IssueDetailStore
    let issue: Issue
    @Binding var runConfirm: IssueDetailRunGate?

    var body: some View {
        let catalog = session.issues.catalog
        IssueDetailPropertyCell(label: {
            catalog.icon(for: issue.status)
            Text(catalog.localizedName(for: issue.status)).lineLimit(1)
        }, content: { dismiss in
            OptionList(
                options: catalog.entries.map { e in
                    PickerOption(id: e.key, title: catalog.localizedName(for: e.key), icon: AnyView(StatusIcon(status: e.key, entry: e)))
                },
                selected: [issue.status],
                searchPlaceholder: tr("issues", "filters.search_status"),
                footer: AnyView(
                    Button {
                        dismiss()
                        modals.present(.markDuplicateIssue(issueID: issue.id))
                    } label: {
                        Label(tr("issues", store.record?.duplicateOf == nil ? "pickers.status.mark_duplicate" : "pickers.status.change_original"),
                              systemImage: "equal.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(HoverRowButtonStyle())
                )
            ) { key in
                dismiss()
                if key != issue.status { store.requestStatus(key, runConfirm: $runConfirm, toaster: toaster) }
            }
        })
    }
}

/// Start/due date cell: graphical calendar with clear.
struct IssueDetailDateCell: View {
    let value: String?
    let icon: String
    let placeholder: String
    let noneLabel: String
    var autoOpen = false
    var overdue = false
    let onChange: (String?) -> Void
    @State private var draft = Date()

    var body: some View {
        IssueDetailPropertyCell(autoOpen: autoOpen, label: {
            Image(systemName: icon).foregroundStyle(overdue ? Theme.destructive : .secondary)
            Text(value.map { IssueDetailDates.short($0) } ?? placeholder)
                .foregroundStyle(overdue ? Theme.destructive : (value == nil ? .secondary : .primary))
        }, content: { dismiss in
            VStack(alignment: .leading, spacing: 8) {
                DatePicker("", selection: $draft, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                HStack {
                    if value != nil {
                        Button(noneLabel) { dismiss(); onChange(nil) }
                    }
                    Spacer()
                    Button(tr("common", "save")) { dismiss(); onChange(Formatters.dateOnlyString(draft)) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .onAppear { draft = value.flatMap(Formatters.dateOnly) ?? Date() }
        })
    }
}

/// Labels: chips plus a multi-select picker with inline create.
struct IssueDetailLabelsCell: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    let issue: Issue
    var autoOpen = false

    var body: some View {
        IssueDetailPropertyCell(autoOpen: autoOpen, label: {
            if issue.labels.isEmpty {
                Image(systemName: "tag").foregroundStyle(.secondary)
                Text(tr("issues", "pickers.label.trigger_label")).foregroundStyle(.secondary)
            } else {
                FlowRow(spacing: 4) {
                    ForEach(issue.labels) { LabelChip(label: $0) }
                }
            }
        }, content: { _ in
            OptionList(
                options: session.labels.items.map { l in
                    PickerOption(id: l.id, title: l.name, icon: AnyView(Circle().fill(Color(hex: l.color)).frame(width: 8, height: 8)))
                },
                selected: Set(issue.labels.map(\.id)),
                searchPlaceholder: tr("issues", "pickers.label.search_placeholder"),
                multiSelect: true,
                createLabel: { "\(tr("issues", "pickers.label.create_action")) “\($0)”" },
                onCreate: { name in
                    Task {
                        let palette = ["#ef4444", "#f97316", "#eab308", "#22c55e", "#06b6d4", "#3b82f6", "#8b5cf6", "#ec4899"]
                        let color = palette[abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count]
                        do {
                            let label = try await session.api.createLabel(CreateLabelRequest(resourceType: "issue", name: name, description: nil, color: color))
                            session.labels.upsert(label)
                            await store.toggleLabel(label, on: true, toaster: toaster)
                        } catch {
                            toaster.error(tr("issues", "pickers.label.create_failed"))
                        }
                    }
                }
            ) { id in
                guard let label = session.labels.item(id) else { return }
                let on = !issue.labels.contains { $0.id == id }
                Task { await store.toggleLabel(label, on: on, toaster: toaster) }
            }
        })
    }
}

/// Wrapping horizontal layout for chips.
struct FlowRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A custom property's icon (emoji or type glyph).
struct IssueDetailPropertyIcon: View {
    let property: IssueProperty

    var body: some View {
        if let icon = property.icon, !icon.isEmpty {
            Text(icon).font(.system(size: 11))
        } else {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var symbol: String {
        switch property.type {
        case "select": return "chevron.down.circle"
        case "multi_select": return "list.bullet"
        case "date": return "calendar"
        case "checkbox": return "checkmark.square"
        case "number": return "number"
        case "url", "multi_url": return "link"
        case "actor", "multi_actor": return "person"
        default: return "text.alignleft"
        }
    }
}

/// Value editor for one custom property, by type (upstream
/// CustomPropertyValueEditor); archived or unknown types are read-only
/// with Clear still offered.
struct IssueDetailCustomPropertyCell: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    let property: IssueProperty
    let value: JSONValue?
    var autoOpen = false
    @State private var draft = ""
    @State private var date = Date()

    static let editable: Set<String> = ["select", "multi_select", "date", "checkbox", "text", "number", "url", "actor", "multi_actor", "multi_text", "multi_url"]

    private var readOnly: Bool {
        if property.archived || !Self.editable.contains(property.type) { return true }
        if property.type == "actor", let s = value?.stringValue, !s.hasPrefix("member:") { return true }
        return false
    }

    var body: some View {
        IssueDetailPropertyCell(autoOpen: autoOpen, label: { display }, content: { dismiss in editor(dismiss) })
            .help(property.archived ? tr("issues", "pickers.custom_property.archived_hint") : "")
    }

    private var options: [IssuePropertyOption] { property.config?.options ?? [] }

    @ViewBuilder private var display: some View {
        let empty = Text(tr("issues", "pickers.custom_property.empty")).foregroundStyle(.secondary)
        switch property.type {
        case _ where value == nil || value?.isNull == true:
            empty
        case "select":
            if let o = options.first(where: { $0.id == value?.stringValue }) {
                Circle().fill(Color(hex: o.color)).frame(width: 7, height: 7)
                Text(o.name).lineLimit(1)
            } else { Text(tr("issues", "pickers.custom_property.unknown_value")).foregroundStyle(.secondary) }
        case "multi_select":
            let ids = value?.arrayValue?.compactMap(\.stringValue) ?? []
            FlowRow(spacing: 4) {
                ForEach(options.filter { ids.contains($0.id) }, id: \.id) { o in LabelChip(name: o.name, color: o.color) }
            }
        case "checkbox":
            Text(tr("issues", value?.boolValue == true ? "pickers.custom_property.true_label" : "pickers.custom_property.false_label"))
        case "date":
            Image(systemName: "calendar").foregroundStyle(.secondary)
            Text(IssueDetailDates.short(value?.stringValue))
        case "url":
            Image(systemName: "link").foregroundStyle(.secondary)
            Text(value?.stringValue ?? "").lineLimit(1).truncationMode(.middle)
        case "actor", "multi_actor":
            let refs = actorIDs
            if refs.isEmpty { empty } else {
                IssueDetailAvatarStack(actors: refs.map { ActorRef(type: "member", id: $0) }, max: 4, size: 18)
                if refs.count == 1 { Text(session.actorInfo(type: "member", id: refs[0]).name).lineLimit(1) }
            }
        case "multi_text", "multi_url":
            let items = value?.arrayValue?.compactMap(\.stringValue) ?? []
            if items.isEmpty { empty } else {
                FlowRow(spacing: 4) { ForEach(items, id: \.self) { Text($0).font(Theme.Font.micro).padding(.horizontal, 5).overlay(Capsule().strokeBorder(Theme.border)) } }
            }
        default:
            Text(value?.stringValue ?? value?.preview(limit: 60) ?? "").lineLimit(1)
        }
    }

    private var actorIDs: [String] {
        let raw: [String] = value?.arrayValue?.compactMap(\.stringValue) ?? value?.stringValue.map { [$0] } ?? []
        return raw.compactMap { $0.hasPrefix("member:") ? String($0.dropFirst(7)) : nil }
    }

    @ViewBuilder private func editor(_ dismiss: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if readOnly {
                Text(property.archived ? tr("issues", "pickers.custom_property.archived_hint") : tr("issues", "pickers.custom_property.unknown_value_hint"))
                    .font(Theme.Font.caption).foregroundStyle(.secondary).padding(10).frame(width: 240, alignment: .leading)
            } else {
                switch property.type {
                case "select":
                    OptionList(options: options.map { o in PickerOption(id: o.id, title: o.name, icon: AnyView(Circle().fill(Color(hex: o.color)).frame(width: 8, height: 8))) },
                               selected: Set([value?.stringValue].compactMap { $0 })) { id in
                        dismiss()
                        set(id == value?.stringValue ? nil : JSONValue(id))
                    }
                case "multi_select":
                    let ids = value?.arrayValue?.compactMap(\.stringValue) ?? []
                    OptionList(options: options.map { o in PickerOption(id: o.id, title: o.name, icon: AnyView(Circle().fill(Color(hex: o.color)).frame(width: 8, height: 8))) },
                               selected: Set(ids), multiSelect: true) { id in
                        let next = ids.contains(id) ? ids.filter { $0 != id } : ids + [id]
                        set(next.isEmpty ? nil : JSONValue(next))
                    }
                case "checkbox":
                    OptionList(options: [PickerOption(id: true, title: tr("issues", "pickers.custom_property.true_label")),
                                         PickerOption(id: false, title: tr("issues", "pickers.custom_property.false_label"))],
                               selected: Set([value?.boolValue].compactMap { $0 })) { b in
                        dismiss()
                        set(.bool(b))
                    }
                case "date":
                    DatePicker("", selection: $date, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden().padding(12)
                        .onAppear { date = value?.stringValue.flatMap(Formatters.dateOnly) ?? Date() }
                    HStack {
                        Spacer()
                        Button(tr("common", "save")) { dismiss(); set(JSONValue(Formatters.dateOnlyString(date))) }.keyboardShortcut(.defaultAction)
                    }
                    .padding([.horizontal, .bottom], 12)
                case "actor", "multi_actor":
                    let multi = property.type == "multi_actor"
                    let raw: [String] = value?.arrayValue?.compactMap(\.stringValue) ?? value?.stringValue.map { [$0] } ?? []
                    OptionList(options: session.directory.members.map { m in
                        PickerOption(id: "member:\(m.userID)", title: m.name, icon: AnyView(AvatarView(name: m.name, url: m.avatarURL, size: 16)))
                    }, selected: Set(raw), searchPlaceholder: tr("issues", "pickers.custom_property.actor_search_placeholder"), multiSelect: multi) { ref in
                        if multi {
                            let next = raw.contains(ref) ? raw.filter { $0 != ref } : raw + [ref]
                            set(next.isEmpty ? nil : JSONValue(next))
                        } else {
                            dismiss()
                            set(raw.first == ref ? nil : JSONValue(ref))
                        }
                    }
                case "multi_text", "multi_url":
                    listEditor
                default:
                    scalarEditor(dismiss)
                }
            }
            if value != nil && value?.isNull == false {
                Divider()
                Button {
                    dismiss()
                    set(nil)
                } label: {
                    Text(tr("issues", "pickers.custom_property.none")).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(HoverRowButtonStyle())
                .padding(4)
            }
        }
    }

    private func scalarEditor(_ dismiss: @escaping () -> Void) -> some View {
        let placeholder = property.type == "url" ? tr("issues", "pickers.custom_property.url_placeholder")
            : property.type == "number" ? tr("issues", "pickers.custom_property.number_placeholder")
            : tr("issues", "pickers.custom_property.value_placeholder")
        return VStack(alignment: .leading, spacing: 6) {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard let v = scalarValue() else { return }
                    dismiss()
                    set(v)
                }
            if property.type == "url", !draft.isEmpty, !draft.lowercased().hasPrefix("http://"), !draft.lowercased().hasPrefix("https://") {
                Text(tr("issues", "pickers.custom_property.url_scheme_required")).font(Theme.Font.micro).foregroundStyle(Theme.destructive)
            }
            if property.type == "url", let s = value?.stringValue, let url = URL(string: s) {
                Link(tr("issues", "pickers.custom_property.open_link"), destination: url).font(Theme.Font.caption)
            }
        }
        .padding(10)
        .frame(width: 240)
        .onAppear { draft = value?.stringValue ?? "" }
    }

    @ViewBuilder private var listEditor: some View {
        let items = value?.arrayValue?.compactMap(\.stringValue) ?? []
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack {
                    Text(item).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { set(items.count == 1 ? nil : JSONValue(items.filter { $0 != item })) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help(tr("issues", "pickers.custom_property.remove_item", ["value": item]))
                }
                .font(Theme.Font.caption)
            }
            TextField(property.type == "multi_url" ? tr("issues", "pickers.custom_property.url_placeholder") : tr("issues", "pickers.custom_property.value_placeholder"),
                      text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty, !items.contains(t) else { return }
                    if property.type == "multi_url" && !(t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://")) { return }
                    draft = ""
                    set(JSONValue(items + [t]))
                }
        }
        .padding(10)
        .frame(width: 260)
    }

    private func scalarValue() -> JSONValue? {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        switch property.type {
        case "number": return Double(t).map(JSONValue.number)
        case "url": return t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") ? JSONValue(t) : nil
        default: return JSONValue(t)
        }
    }

    private func set(_ v: JSONValue?) {
        Task { await store.setProperty(property.id, v, toaster: toaster) }
    }
}

/// The parent issue row with "Remove parent issue" on hover.
private struct IssueDetailParentRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    let parent: Issue
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button { nav.push(.issue(parent.id), title: parent.identifier) } label: {
                HStack(spacing: 6) {
                    session.issues.catalog.icon(for: parent.status)
                    Text(parent.identifier).foregroundStyle(.secondary)
                    Text(parent.title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(Theme.Font.caption)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { Task { await store.removeParent(toaster: toaster) } } label: { Image(systemName: "link.badge.plus") }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
                .help(tr("issues", "actions.remove_parent_issue"))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .hoverHighlight()
        .onHover { hovering = $0 }
    }
}

/// The raw metadata bag (upstream metadata dialog).
private struct IssueDetailMetadataSheet: View {
    @Environment(\.dismiss) private var dismiss
    let metadata: [String: JSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr("issues", "detail.section_metadata")).font(Theme.Font.title)
                Spacer()
                Button(tr("agents", "transcript.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(JSONValue.object(metadata).prettyPrinted)
                    .font(Theme.Font.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.04)))
        }
        .padding(18)
        .frame(width: 640, height: 480)
    }
}
