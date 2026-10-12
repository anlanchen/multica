import MulticaCore
import SwiftUI

/// Every filter dimension with search and counts (upstream IssueFilterMenu).
/// A popover rather than a menu so multi-select edits never close it; the
/// left pane mirrors the dropdown's submenu triggers.
struct IssueListFilterMenu: View {
    @Binding var state: IssueListViewState
    let model: IssueListSurfaceModel
    var baseline: IssueListBaseline?
    var showCounts = true
    var showDate = true
    var onFacet: ((JSONValue?) -> Void)?

    @Environment(WorkspaceSession.self) private var session
    @State private var section: Section? = .status

    enum Section: Hashable {
        case status, priority, date, assignee, creator, project, projectStatus, label
        case property(String)
    }

    private var filterable: [IssueProperty] {
        model.activeProperties.filter { IssueListOptions.isFilterablePropertyType($0.type) }
    }

    private var counts: IssueListFacetCounts? {
        guard showCounts else { return nil }
        return model.submenuFacets ?? model.facets
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    trigger(.status, icon: "smallcircle.filled.circle", title: tr("issues", "filters.section_status"), count: state.statusFilters.count)
                    trigger(.priority, icon: "cellularbars", title: tr("issues", "filters.section_priority"), count: state.priorityFilters.count)
                    if showDate {
                        trigger(.date, icon: "calendar", title: tr("issues", "filters.section_date"), badge: dateLabel)
                    }
                    trigger(.assignee, icon: "person", title: tr("issues", "filters.section_assignee"),
                            count: state.assigneeFilters.count + (state.includeNoAssignee ? 1 : 0))
                    trigger(.creator, icon: "person.crop.square", title: tr("issues", "filters.section_creator"), count: state.creatorFilters.count)
                    if model.scope.projectID == nil {
                        trigger(.project, icon: "folder", title: tr("issues", "filters.section_project"),
                                count: state.projectFilters.count + (state.includeNoProject ? 1 : 0))
                    }
                    trigger(.projectStatus, icon: "circle.dashed", title: tr("issues", "filters.section_project_status"), count: state.projectStatusFilters.count)
                    trigger(.label, icon: "tag", title: tr("issues", "filters.section_label"), count: state.labelFilters.count)
                    if !filterable.isEmpty {
                        Divider().padding(.vertical, 4)
                        ForEach(filterable) { p in
                            trigger(.property(p.id), icon: "slider.horizontal.3", title: p.name, count: state.propertyFilters[p.id]?.count ?? 0)
                        }
                    }
                    if hasActiveFilters {
                        Divider().padding(.vertical, 4)
                        Button {
                            if let raw = baseline?.raw { state.resetFilters(to: raw) } else {
                                state.resetFilters(to: IssueListFilterSnapshot())
                            }
                            if showDate { state.dateFilter = nil }
                        } label: {
                            Text(tr("issues", "filters.reset")).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(HoverRowButtonStyle())
                    }
                }
                .padding(4)
            }
            .frame(width: 200)
            Divider()
            Group {
                if let section { pane(section) } else { Color.clear }
            }
            .frame(width: 272)
        }
        .font(Theme.Font.body)
        .frame(height: 380)
        .task { await loadCatalogs() }
        .onChange(of: section) { _, s in onFacet?(s.flatMap(facetSpec)) }
        .onAppear { onFacet?(section.flatMap(facetSpec)) }
    }

    private var hasActiveFilters: Bool {
        state.activeFilterCount(baseline: baseline, activePropertyIDs: model.activePropertyIDs, includeDate: showDate) > 0
    }

    private var dateLabel: String? {
        guard showDate, let d = state.dateFilter else { return nil }
        let field = tr("issues", d.field == "created_at" ? "filters.date_field_created" : "filters.date_field_updated")
        let range = d.from == d.to ? IssueListFormat.shortDay(d.from) : "\(IssueListFormat.shortDay(d.from)) - \(IssueListFormat.shortDay(d.to))"
        return "\(field): \(range)"
    }

    private func facetSpec(_ s: Section) -> JSONValue? {
        switch s {
        case .status: return IssueListQuery.facetSpec("status")
        case .priority: return IssueListQuery.facetSpec("priority")
        case .assignee: return IssueListQuery.facetSpec("assignee")
        case .creator: return IssueListQuery.facetSpec("creator")
        case .project: return IssueListQuery.facetSpec("project")
        case .label: return IssueListQuery.facetSpec("label")
        case .property(let id): return IssueListQuery.facetSpec("property", propertyID: id)
        case .date, .projectStatus: return nil
        }
    }

    private func loadCatalogs() async {
        async let a: Void = session.labels.loadIfNeeded()
        async let b: Void = session.projects.loadIfNeeded()
        async let c: Void = session.squads.loadIfNeeded()
        _ = await (a, b, c)
    }

    private func trigger(_ s: Section, icon: String, title: String, count: Int = 0, badge: String? = nil) -> some View {
        Button { section = s } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 14).foregroundStyle(.secondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(Theme.Font.caption.weight(.medium)).foregroundStyle(Theme.brand).lineLimit(1).frame(maxWidth: 90, alignment: .trailing)
                } else if count > 0 {
                    Text("\(count)").font(Theme.Font.caption.weight(.medium)).foregroundStyle(Theme.brand)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(HoverRowButtonStyle(selected: section == s))
    }

    @ViewBuilder
    private func pane(_ s: Section) -> some View {
        switch s {
        case .status: IssueListStatusFilterPane(state: $state, baseline: baseline, counts: counts?.statusCounts(selected: []))
        case .priority: IssueListPriorityFilterPane(state: $state, baseline: baseline, counts: counts?.priority)
        case .date: IssueListDateFilterPane(state: $state)
        case .assignee: IssueListActorFilterPane(state: $state, baseline: baseline, counts: counts, creator: false)
        case .creator: IssueListActorFilterPane(state: $state, baseline: baseline, counts: counts, creator: true)
        case .project: IssueListProjectFilterPane(state: $state, baseline: baseline, counts: counts)
        case .projectStatus: IssueListProjectStatusFilterPane(state: $state, baseline: baseline)
        case .label: IssueListLabelFilterPane(state: $state, baseline: baseline, counts: counts?.label)
        case .property(let id):
            if let p = model.property(id) {
                IssueListPropertyFilterPane(state: $state, property: p, baseline: baseline, counts: counts?.property[id])
            }
        }
    }
}

/// Checkbox row: checked state on the left, a count on the right; values a
/// saved view fixes render checked and disabled ("Already in this view").
struct IssueListCheckRow<Content: View>: View {
    let checked: Bool
    var fixed = false
    var count: Int? = nil
    var countLabel: ((Int) -> String)? = nil
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Theme.brand : Color.secondary.opacity(0.6))
                    .font(.system(size: 12))
                content()
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text(countLabel?(count) ?? "\(count)").font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .lineLimit(1)
        }
        .buttonStyle(HoverRowButtonStyle())
        .disabled(fixed)
        .help(fixed ? tr("issues", "filters.in_view") : "")
    }
}

private struct IssueListPaneSearch: View {
    @Binding var text: String

    var body: some View {
        TextField(tr("issues", "filters.placeholder"), text: $text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 30)
        Divider()
    }
}

private struct IssueListGroupLabel: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.Font.micro.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
    }
}

private struct IssueListNoResults: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.Font.body).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 12)
    }
}

struct IssueListStatusFilterPane: View {
    @Binding var state: IssueListViewState
    let baseline: IssueListBaseline?
    let counts: [String: Int]?
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(IssueListStatusColumns.options(entries: session.issueListStatusEntries), id: \.self) { key in
                    IssueListCheckRow(checked: state.statusFilters.contains(key.rawValue),
                                      fixed: baseline?.status.contains(key.rawValue) == true,
                                      count: counts?[key.rawValue], countLabel: { tr("issues", "filters.issue_count", ["count": $0]) },
                                      action: { state.toggleStatusFilter(key.rawValue) }) {
                        session.issues.catalog.icon(for: key, size: 13)
                        Text(session.issueListStatusLabel(key))
                    }
                }
            }
            .padding(4)
        }
    }
}

struct IssueListPriorityFilterPane: View {
    @Binding var state: IssueListViewState
    let baseline: IssueListBaseline?
    let counts: [String: Int]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(IssueListOptions.priorityDisplayOrder, id: \.self) { raw in
                    let p = IssuePriority(rawValue: raw) ?? .none
                    IssueListCheckRow(checked: state.priorityFilters.contains(raw), fixed: baseline?.priority.contains(raw) == true,
                                      count: counts?[raw], countLabel: { tr("issues", "filters.issue_count", ["count": $0]) },
                                      action: { state.togglePriorityFilter(raw) }) {
                        PriorityIcon(priority: p, size: 13)
                        Text(p.localizedName)
                    }
                }
            }
            .padding(4)
        }
    }
}

struct IssueListDateFilterPane: View {
    @Binding var state: IssueListViewState
    @State private var field = "created_at"
    @State private var from = Date()
    @State private var to = Date()
    @State private var customOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            IssueListGroupLabel(text: tr("issues", "filters.date_field"))
            ForEach(["created_at", "updated_at"], id: \.self) { f in
                Button {
                    field = f
                    if var d = state.dateFilter { d.field = f; state.dateFilter = d }
                } label: {
                    HStack {
                        Image(systemName: field == f ? "largecircle.fill.circle" : "circle").font(.system(size: 11))
                            .foregroundStyle(field == f ? Theme.brand : .secondary)
                        Text(tr("issues", f == "created_at" ? "filters.date_field_created" : "filters.date_field_updated"))
                        Spacer()
                    }
                }
                .buttonStyle(HoverRowButtonStyle())
            }
            Divider().padding(.vertical, 4)
            preset(tr("issues", "filters.date_today"), days: 1)
            preset(tr("issues", "filters.date_last_3_days"), days: 3)
            preset(tr("issues", "filters.date_last_7_days"), days: 7)
            Button { customOpen.toggle() } label: {
                HStack {
                    Text(tr("issues", "filters.date_custom_range"))
                    Spacer()
                    Image(systemName: customOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(HoverRowButtonStyle())
            if customOpen {
                VStack(alignment: .leading, spacing: 6) {
                    DatePicker("", selection: $from, displayedComponents: .date).labelsHidden()
                    DatePicker("", selection: $to, displayedComponents: .date).labelsHidden()
                    HStack {
                        Spacer()
                        Button(tr("issues", "filters.date_apply")) {
                            let a = min(from, to), b = max(from, to)
                            state.dateFilter = IssueListDateFilter(field: field, from: IssueListQuery.dayString(a), to: IssueListQuery.dayString(b))
                            customOpen = false
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 8)
            }
            if state.dateFilter != nil {
                Divider().padding(.vertical, 4)
                Button {
                    state.dateFilter = nil
                } label: {
                    Text(tr("issues", "filters.date_clear")).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(HoverRowButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .onAppear {
            if let d = state.dateFilter {
                field = d.field
                from = IssueListQuery.parseDay(d.from) ?? Date()
                to = IssueListQuery.parseDay(d.to) ?? Date()
            }
        }
    }

    private func preset(_ title: String, days: Int) -> some View {
        Button {
            state.dateFilter = IssueListDateFilter(field: field, from: IssueListQuery.day(offset: 1 - days), to: IssueListQuery.day(offset: 0))
        } label: {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HoverRowButtonStyle())
    }
}

struct IssueListActorFilterPane: View {
    @Binding var state: IssueListViewState
    let baseline: IssueListBaseline?
    let counts: IssueListFacetCounts?
    let creator: Bool
    @Environment(WorkspaceSession.self) private var session
    @State private var query = ""

    var body: some View {
        let members = session.directory.members.filter { IssueListText.matches($0.name, query) }
        let agents = session.directory.agents.filter { $0.archivedAt == nil && IssueListText.matches($0.name, query) }
        let squads = creator ? [] : session.squads.items.filter { $0.archivedAt == nil && IssueListText.matches($0.name, query) }
        let selected = creator ? state.creatorFilters : state.assigneeFilters
        let fixed = creator ? baseline?.creator : baseline?.assignee
        let countMap = creator ? counts?.creator : counts?.assignee
        VStack(spacing: 0) {
            IssueListPaneSearch(text: $query)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
                    if !creator && (q.isEmpty || "no assignee".contains(q) || "unassigned".contains(q)) {
                        IssueListCheckRow(checked: state.includeNoAssignee, fixed: baseline?.includeNoAssignee == true,
                                          count: counts?.noAssignee, action: { state.includeNoAssignee.toggle() }) {
                            Image(systemName: "person.crop.circle.badge.minus").foregroundStyle(.secondary)
                            Text(tr("issues", "filters.no_assignee"))
                        }
                    }
                    if !members.isEmpty {
                        IssueListGroupLabel(text: tr("issues", "filters.members_group"))
                        ForEach(members) { m in
                            row(IssueListActorFilter(type: "member", id: m.userID), name: m.name, selected: selected, fixed: fixed, counts: countMap)
                        }
                    }
                    if !agents.isEmpty {
                        IssueListGroupLabel(text: tr("issues", "filters.agents_group"))
                        ForEach(agents) { a in
                            row(IssueListActorFilter(type: "agent", id: a.id), name: a.name, selected: selected, fixed: fixed, counts: countMap)
                        }
                    }
                    if !squads.isEmpty {
                        IssueListGroupLabel(text: tr("issues", "filters.squads_group"))
                        ForEach(squads) { s in
                            row(IssueListActorFilter(type: "squad", id: s.id), name: s.name, selected: selected, fixed: fixed, counts: countMap)
                        }
                    }
                    if members.isEmpty && agents.isEmpty && squads.isEmpty && !query.isEmpty {
                        IssueListNoResults(text: tr("issues", "filters.no_results"))
                    }
                }
                .padding(4)
            }
        }
    }

    private func row(_ actor: IssueListActorFilter, name: String, selected: [IssueListActorFilter], fixed: Set<String>?, counts: [String: Int]?) -> some View {
        IssueListCheckRow(checked: selected.contains(actor), fixed: fixed?.contains(actor.key) == true, count: counts?[actor.key],
                          action: { creator ? state.toggleCreatorFilter(actor) : state.toggleAssigneeFilter(actor) }) {
            ActorAvatar(type: actor.type, id: actor.id, size: 16)
            Text(name).lineLimit(1)
        }
    }
}

struct IssueListProjectFilterPane: View {
    @Binding var state: IssueListViewState
    let baseline: IssueListBaseline?
    let counts: IssueListFacetCounts?
    @Environment(WorkspaceSession.self) private var session
    @State private var query = ""

    var body: some View {
        let projects = session.projects.items.filter { IssueListText.matches($0.title, query) }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        VStack(spacing: 0) {
            IssueListPaneSearch(text: $query)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if q.isEmpty || "no project".contains(q) || "unassigned".contains(q) {
                        IssueListCheckRow(checked: state.includeNoProject, fixed: baseline?.includeNoProject == true,
                                          count: counts?.noProject, action: { state.includeNoProject.toggle() }) {
                            Image(systemName: "folder.badge.minus").foregroundStyle(.secondary)
                            Text(tr("issues", "filters.no_project"))
                        }
                    }
                    ForEach(projects) { p in
                        IssueListCheckRow(checked: state.projectFilters.contains(p.id), fixed: baseline?.project.contains(p.id) == true,
                                          count: counts?.project[p.id], action: { state.toggleProjectFilter(p.id) }) {
                            ProjectIconView(icon: p.icon, size: 14)
                            Text(p.title).lineLimit(1)
                        }
                    }
                    if projects.isEmpty && !query.isEmpty {
                        IssueListNoResults(text: tr("issues", "filters.no_results"))
                    }
                }
                .padding(4)
            }
        }
    }
}

struct IssueListProjectStatusFilterPane: View {
    @Binding var state: IssueListViewState
    let baseline: IssueListBaseline?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(IssueListOptions.projectStatusOrder, id: \.self) { s in
                IssueListCheckRow(checked: state.projectStatusFilters.contains(s), fixed: baseline?.projectStatus.contains(s) == true,
                                  action: { state.toggleProjectStatusFilter(s) }) {
                    Circle().fill(IssueListFormat.projectStatusColor(s)).frame(width: 8, height: 8)
                    Text(IssueListFormat.projectStatusLabel(s))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(4)
    }
}

struct IssueListLabelFilterPane: View {
    @Binding var state: IssueListViewState
    let baseline: IssueListBaseline?
    let counts: [String: Int]?
    @Environment(WorkspaceSession.self) private var session
    @State private var query = ""

    var body: some View {
        let labels = session.labels.items.filter { IssueListText.matches($0.name, query) }
        VStack(spacing: 0) {
            IssueListPaneSearch(text: $query)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(labels) { l in
                        IssueListCheckRow(checked: state.labelFilters.contains(l.id), fixed: baseline?.label.contains(l.id) == true,
                                          count: counts?[l.id], action: { state.toggleLabelFilter(l.id) }) {
                            LabelChip(label: l)
                        }
                    }
                    if labels.isEmpty {
                        IssueListNoResults(text: query.isEmpty ? tr("issues", "filters.no_labels") : tr("issues", "filters.no_results"))
                    }
                }
                .padding(4)
            }
        }
    }
}

/// One custom property: options (select / multi-select / checkbox / actor)
/// or a value input with operators (text / number / date / url / lists),
/// plus "No value".
struct IssueListPropertyFilterPane: View {
    @Binding var state: IssueListViewState
    let property: IssueProperty
    let baseline: IssueListBaseline?
    let counts: [String: Int]?
    @Environment(WorkspaceSession.self) private var session
    @State private var draft = ""
    @State private var pendingOp: String?

    private var selected: [IssueListPropertyFilterValue] { state.propertyFilters[property.id] ?? [] }
    private var fixed: Set<String>? { baseline?.property[property.id] }
    private var hasNoValue: Bool { selected.contains(.equals(IssueListPropertyFilterValue.noValue)) }

    private var committed: IssueListPropertyFilterValue? { selected.first { !$0.isNoValue } }

    private var committedOp: String {
        if case .op(let op, _)? = committed { return op }
        return "is"
    }

    private var committedValue: String {
        switch committed {
        case .equals(let v)?: return v
        case .op(_, let v)?: return v
        case nil: return ""
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if IssueListOptions.isScalarPropertyType(property.type) || IssueListOptions.isListPropertyType(property.type) {
                    scalar
                } else {
                    ForEach(options, id: \.id) { o in
                        IssueListCheckRow(checked: selected.contains(.equals(o.id)), fixed: fixed?.contains(o.id) == true,
                                          count: counts?[o.id], action: { state.togglePropertyFilter(property.id, o.id) }) {
                            if let actor = o.actor { ActorAvatar(type: actor.type, id: actor.id, size: 16) }
                            if let color = o.color { Circle().fill(Color(hex: color)).frame(width: 9, height: 9) }
                            Text(o.name).lineLimit(1)
                        }
                    }
                }
            }
            .padding(4)
        }
        .onAppear { draft = committedValue }
        .onChange(of: committedValue) { _, v in draft = v; pendingOp = nil }
    }

    private struct Option {
        var id: String
        var name: String
        var color: String?
        var actor: ActorRef?
    }

    private var options: [Option] {
        var out: [Option]
        if IssueListOptions.isActorPropertyType(property.type) {
            let me = session.currentUser.id
            let members = session.directory.members
            out = (members.filter { $0.userID == me } + members.filter { $0.userID != me })
                .map { Option(id: "member:\($0.userID)", name: $0.name, actor: ActorRef(type: "member", id: $0.userID)) }
        } else if property.type == "checkbox" {
            out = [Option(id: "true", name: tr("issues", "pickers.custom_property.true_label")),
                   Option(id: "false", name: tr("issues", "pickers.custom_property.false_label"))]
        } else {
            out = (property.config?.options ?? []).map { Option(id: $0.id, name: $0.name, color: $0.color) }
        }
        out.append(Option(id: IssueListPropertyFilterValue.noValue, name: tr("issues", "pickers.custom_property.none")))
        return out
    }

    @ViewBuilder
    private var scalar: some View {
        let locked = !(fixed?.isEmpty ?? true)
        let ops = IssueListPropertyFilterValue.opsForType(property.type)
        let effective = pendingOp ?? committedOp
        if !ops.isEmpty {
            HStack(spacing: 4) {
                ForEach(["is"] + ops, id: \.self) { op in
                    Button {
                        pendingOp = op
                        commit(draft, op: op)
                    } label: {
                        Text(opLabel(op)).font(Theme.Font.caption)
                            .padding(.horizontal, 6).frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 5).fill(effective == op ? Theme.selected : .clear))
                            .foregroundStyle(effective == op ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(locked)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .accessibilityLabel(tr("issues", "pickers.custom_property.operator_label"))
        }
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .disabled(locked)
            .onSubmit { commit(draft, op: effective) }
            .padding(6)
        IssueListCheckRow(checked: hasNoValue, fixed: locked, count: counts?[IssueListPropertyFilterValue.noValue], action: {
            let values = selected.filter { !$0.isNoValue }
            state.setPropertyFilterValues(property.id, hasNoValue ? values : values + [.equals(IssueListPropertyFilterValue.noValue)])
        }) {
            Text(tr("issues", "pickers.custom_property.none"))
        }
    }

    private var placeholder: String {
        switch property.type {
        case "url", "multi_url": return tr("issues", "pickers.custom_property.url_placeholder")
        case "number": return tr("issues", "pickers.custom_property.number_placeholder")
        default: return tr("issues", "pickers.custom_property.value_placeholder")
        }
    }

    private func opLabel(_ op: String) -> String {
        switch op {
        case "is": return property.type == "number" ? "=" : tr("issues", "pickers.custom_property.op_is")
        case "contains": return tr("issues", "pickers.custom_property.op_contains")
        case "before": return tr("issues", "pickers.custom_property.op_before")
        case "after": return tr("issues", "pickers.custom_property.op_after")
        default: return IssueListPropertyFilterValue.opSymbol(op) ?? op
        }
    }

    /// Committing replaces only the value member and keeps "No value".
    private func commit(_ raw: String, op: String) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value != IssueListPropertyFilterValue.noValue else { return }
        var next: [IssueListPropertyFilterValue] = []
        if !value.isEmpty { next.append(op == "is" ? .equals(value) : .op(op, value)) }
        if hasNoValue { next.append(.equals(IssueListPropertyFilterValue.noValue)) }
        state.setPropertyFilterValues(property.id, next)
    }
}
