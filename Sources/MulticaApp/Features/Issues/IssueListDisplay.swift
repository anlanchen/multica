import MulticaCore
import SwiftUI

/// Display settings popover (grouping, ordering, sub-issues, card properties).
struct IssueListDisplayPopover: View {
    @Binding var state: IssueListViewState
    let model: IssueListSurfaceModel
    let mode: IssueListViewMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if mode == .board {
                row(tr("issues", "display.grouping_section")) {
                    Picker("", selection: Binding(get: { state.grouping }, set: { state.setGrouping($0) })) {
                        ForEach(IssueListOptions.groupings, id: \.self) { g in
                            Text(tr("issues", "display.group_\(g)")).tag(g)
                        }
                        ForEach(model.activeProperties.filter { $0.type == "select" }) { p in
                            Text(p.name).tag("property:\(p.id)")
                        }
                        if IssueListOptions.propertyID(fromKey: state.grouping).map({ model.property($0) == nil }) == true {
                            Text(tr("issues", "display.group_status")).tag(state.grouping)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 128)
                }
            }
            if mode == .swimlane {
                row(tr("issues", "display.grouping_section")) {
                    Picker("", selection: $state.swimlaneGrouping) {
                        ForEach(IssueListSwimlaneGrouping.allCases, id: \.self) { g in
                            Text(tr("issues", "display.group_\(g.rawValue)")).tag(g)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 128)
                }
            }
            if mode == .table {
                Toggle(isOn: $state.tableHierarchy) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tr("issues", "table.hierarchy")).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text(tr("issues", "table.hierarchy_description")).font(Theme.Font.caption).foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("issues", "display.ordering_section")).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { state.sortBy }, set: { state.setSortBy($0) })) {
                        ForEach(IssueListOptions.sortFields(grouping: state.grouping), id: \.self) { f in
                            Text(tr("issues", "display.\(IssueListOptions.sortLabelKey(f) ?? "sort_manual")")).tag(f)
                        }
                        ForEach(model.activeProperties.filter { $0.type == "number" || $0.type == "date" }) { p in
                            Text(p.name).tag("property:\(p.id)")
                        }
                        if IssueListOptions.propertyID(fromKey: state.sortBy).map({ model.property($0) == nil }) == true {
                            Text(tr("issues", "display.sort_manual")).tag(state.sortBy)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    if state.sortBy != "position" {
                        let label = tr("issues", "display.\(IssueListOptions.sortDirectionLabelKey(field: state.sortBy, direction: state.sortDirection))")
                        Button(label) { state.setSortDirection(state.sortDirection.toggled) }
                            .controlSize(.small)
                            .help(label)
                            .fixedSize()
                    }
                }
            }
            Toggle(isOn: $state.showSubIssues) {
                Text(tr("issues", "display.show_sub_issues")).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            let keys = IssueListOptions.cardPropertyKeys(for: mode)
            if !keys.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("issues", "display.card_properties_section")).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                    IssueListFlowLayout(spacing: 4) {
                        ForEach(keys, id: \.self) { key in
                            IssueListChipToggle(title: tr("issues", "display.\(IssueListOptions.cardPropertyLabelKey(key))"),
                                                on: state.cardProperties[key]) { state.toggleCardProperty(key) }
                        }
                        ForEach(model.activeProperties) { p in
                            IssueListChipToggle(title: p.name, on: state.cardPropertyIds.contains(p.id)) { state.toggleCardPropertyID(p.id) }
                        }
                    }
                }
            }
        }
        .font(Theme.Font.body)
    }

    private func row<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        HStack {
            Text(label).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer()
            control()
        }
    }
}

/// Pressed = shown on cards; unpressed chips dim.
struct IssueListChipToggle: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.Font.caption).lineLimit(1)
                .padding(.horizontal, 8).frame(height: 22).frame(maxWidth: 160)
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(on ? Theme.selected : .clear))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(on ? Color.clear : Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Wrapping row layout for chips.
struct IssueListFlowLayout: Layout {
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
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
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

/// Table column chooser (upstream TableColumnPicker).
struct IssueListColumnPicker: View {
    @Bindable var model: IssueListSurfaceModel
    @State private var query = ""

    var body: some View {
        let system = IssueListOptions.tableSystemColumns.filter { IssueListText.matches(tr("issues", "table.columns.\($0)"), query) }
        let props = model.activeProperties.filter { IssueListText.matches($0.name, query) }
        VStack(spacing: 0) {
            TextField(tr("issues", "table.columns.search_placeholder"), text: $query)
                .textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 30)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !system.isEmpty {
                        Text(tr("issues", "table.columns.system_section")).font(Theme.Font.micro.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.top, 6)
                        ForEach(system, id: \.self) { key in
                            toggle(key, title: tr("issues", "table.columns.\(key)"), disabled: key == "title")
                        }
                    }
                    if !props.isEmpty {
                        Text(tr("issues", "table.columns.property_section")).font(Theme.Font.micro.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.top, 6)
                        ForEach(props) { p in toggle("property:\(p.id)", title: p.name, disabled: false) }
                    }
                    if system.isEmpty && props.isEmpty {
                        Text(tr("issues", "table.columns.no_results")).font(Theme.Font.body).foregroundStyle(.secondary).padding(12)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 240)
    }

    private func toggle(_ key: String, title: String, disabled: Bool) -> some View {
        IssueListCheckRow(checked: model.state.tableColumns.contains { $0.key == key }, fixed: disabled,
                          action: { model.state.toggleTableColumn(key) }) {
            Text(title).lineLimit(1)
        }
    }
}

// MARK: - Filter chips

/// Active-filter chips under the header (upstream FilterChipsBar). Inside a
/// saved view the chips show only what the user layered on top.
struct IssueListFilterChipsBar: View {
    @Bindable var model: IssueListSurfaceModel
    var saveLabel: String?
    var onSave: (() -> Void)?

    var body: some View {
        let chips = IssueListChips.build(state: model.state, baseline: model.baseline, model: model, showDate: true)
        if !chips.isEmpty {
            HStack(spacing: 6) {
                IssueListFlowLayout(spacing: 6) {
                    ForEach(chips) { chip in
                        IssueListChipView(chip: chip) { remove(chip) }
                    }
                }
                Spacer(minLength: 6)
                Button(tr("issues", "filters.chip_clear")) { clearAll() }
                    .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                if let onSave {
                    Button(saveLabel ?? tr("issues", "filters.chip_save"), action: onSave)
                        .buttonStyle(IssueListToolbarButtonStyle(active: true))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.035)))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func remove(_ chip: IssueListChip) {
        if let d = chip.dimension {
            model.state.clearFilterDimension(d, baseline: model.baseline)
        } else {
            model.state.dateFilter = nil
        }
    }

    private func clearAll() {
        if let raw = model.baseline?.raw {
            model.state.resetFilters(to: raw)
        } else {
            model.state.resetFilters(to: IssueListFilterSnapshot())
        }
        model.state.dateFilter = nil
    }
}

struct IssueListChip: Identifiable {
    enum Icons {
        case statuses([IssueStatusKey])
        case priorities([IssuePriority])
        case actors([ActorRef])
        case emojis([String])
        case colors([Color])
        case none
    }

    var id: String
    var icon: String
    var label: String
    var value: String
    var icons: Icons = .none
    /// nil = the date chip.
    var dimension: IssueListFilterDimension?
}

enum IssueListChips {
    private static func summarize(_ names: [String?]) -> String {
        guard let first = names.compactMap({ $0 }).first else { return "\(names.count)" }
        return names.count > 1 ? "\(first) +\(names.count - 1)" : first
    }

    @MainActor
    static func build(state s: IssueListViewState, baseline b: IssueListBaseline?, model: IssueListSurfaceModel, showDate: Bool) -> [IssueListChip] {
        let session = model.session
        func delta(_ v: [String], _ fixed: Set<String>?) -> [String] { fixed.map { f in v.filter { !f.contains($0) } } ?? v }
        func actorName(_ a: IssueListActorFilter) -> String? {
            let info = session.actorInfo(type: a.type, id: a.id)
            return info.name.isEmpty ? nil : info.name
        }
        var chips: [IssueListChip] = []
        let status = delta(s.statusFilters, b?.status)
        if !status.isEmpty {
            chips.append(IssueListChip(
                id: "status", icon: "smallcircle.filled.circle", label: tr("issues", "filters.section_status"),
                value: status.count == 1 ? session.issueListStatusLabel(IssueStatusKey(rawValue: status[0])) : tr("issues", "filters.chip_status_count", ["count": status.count]),
                icons: .statuses(status.prefix(3).map(IssueStatusKey.init(rawValue:))), dimension: .status))
        }
        let priority = delta(s.priorityFilters, b?.priority)
        if !priority.isEmpty {
            chips.append(IssueListChip(
                id: "priority", icon: "cellularbars", label: tr("issues", "filters.section_priority"),
                value: priority.count == 1 ? (IssuePriority(rawValue: priority[0]) ?? .none).localizedName : tr("issues", "filters.chip_priority_count", ["count": priority.count]),
                icons: .priorities(priority.prefix(3).map { IssuePriority(rawValue: $0) ?? .none }), dimension: .priority))
        }
        let assignees = s.assigneeFilters.filter { !(b?.assignee.contains($0.key) ?? false) }
        let noAssignee = s.includeNoAssignee && !(b?.includeNoAssignee ?? false)
        if !assignees.isEmpty || noAssignee {
            var names = assignees.map(actorName)
            if noAssignee { names.append(tr("issues", "filters.no_assignee")) }
            chips.append(IssueListChip(id: "assignee", icon: "person", label: tr("issues", "filters.section_assignee"), value: summarize(names),
                                       icons: assignees.isEmpty ? .none : .actors(assignees.prefix(3).map { ActorRef(type: $0.type, id: $0.id) }),
                                       dimension: .assignee))
        }
        let creators = s.creatorFilters.filter { !(b?.creator.contains($0.key) ?? false) }
        if !creators.isEmpty {
            chips.append(IssueListChip(id: "creator", icon: "person.crop.square", label: tr("issues", "filters.section_creator"),
                                       value: summarize(creators.map(actorName)),
                                       icons: .actors(creators.prefix(3).map { ActorRef(type: $0.type, id: $0.id) }), dimension: .creator))
        }
        let projects = delta(s.projectFilters, b?.project)
        let noProject = s.includeNoProject && !(b?.includeNoProject ?? false)
        if model.scope.projectID == nil && (!projects.isEmpty || noProject) {
            var names = projects.map { model.project($0)?.title }
            if noProject { names.append(tr("issues", "filters.no_project")) }
            let emojis = projects.compactMap { model.project($0)?.icon }.filter { !$0.isEmpty }
            chips.append(IssueListChip(id: "project", icon: "folder", label: tr("issues", "filters.section_project"), value: summarize(names),
                                       icons: emojis.isEmpty ? .none : .emojis(Array(emojis.prefix(3))), dimension: .project))
        }
        let projectStatuses = delta(s.projectStatusFilters, b?.projectStatus).filter { IssueListOptions.projectStatusOrder.contains($0) }
        if !projectStatuses.isEmpty {
            chips.append(IssueListChip(id: "projectStatus", icon: "circle.dashed", label: tr("issues", "filters.section_project_status"),
                                       value: summarize(projectStatuses.map(IssueListFormat.projectStatusLabel)),
                                       icons: .colors(projectStatuses.prefix(3).map(IssueListFormat.projectStatusColor)), dimension: .projectStatus))
        }
        let labels = delta(s.labelFilters, b?.label)
        if !labels.isEmpty {
            let byID = Dictionary(session.labels.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            chips.append(IssueListChip(id: "label", icon: "tag", label: tr("issues", "filters.section_label"),
                                       value: summarize(labels.map { byID[$0]?.name }),
                                       icons: .colors(labels.compactMap { byID[$0].map { Color(hex: $0.color) } }.prefix(3).map { $0 }), dimension: .label))
        }
        for (pid, members) in s.propertyFilters.sorted(by: { $0.key < $1.key }) {
            let fixed = b?.property[pid]
            let delta = fixed.map { f in members.filter { !f.contains($0.key) } } ?? members
            guard !delta.isEmpty, let p = model.property(pid) else { continue }
            let actorProp = IssueListOptions.isActorPropertyType(p.type)
            func name(_ m: IssueListPropertyFilterValue) -> String? {
                switch m {
                case .equals(let v) where v == IssueListPropertyFilterValue.noValue: return tr("issues", "pickers.custom_property.none")
                case .op(let op, let v):
                    switch op {
                    case "contains": return tr("issues", "filters.chip_op_contains", ["value": v])
                    case "before": return tr("issues", "filters.chip_op_before", ["value": v])
                    case "after": return tr("issues", "filters.chip_op_after", ["value": v])
                    default: return "\(IssueListPropertyFilterValue.opSymbol(op) ?? op) \(v)"
                    }
                case .equals(let v):
                    if actorProp {
                        let parts = v.split(separator: ":", maxSplits: 1).map(String.init)
                        return parts.count == 2 ? session.actorInfo(type: parts[0], id: parts[1]).name : nil
                    }
                    if p.type == "checkbox" {
                        return v == "true" ? tr("issues", "pickers.custom_property.true_label") : tr("issues", "pickers.custom_property.false_label")
                    }
                    if IssueListOptions.isScalarPropertyType(p.type) || IssueListOptions.isListPropertyType(p.type) { return v }
                    return p.config?.options?.first { $0.id == v }?.name
                }
            }
            var icons: IssueListChip.Icons = .none
            if actorProp {
                let refs = delta.compactMap { m -> ActorRef? in
                    guard case .equals(let v) = m else { return nil }
                    let parts = v.split(separator: ":", maxSplits: 1).map(String.init)
                    return parts.count == 2 && parts[0] == "member" ? ActorRef(type: "member", id: parts[1]) : nil
                }
                if !refs.isEmpty { icons = .actors(Array(refs.prefix(3))) }
            } else if p.type != "checkbox" {
                let colors = delta.compactMap { m -> Color? in
                    guard case .equals(let v) = m, let o = p.config?.options?.first(where: { $0.id == v }) else { return nil }
                    return Color(hex: o.color)
                }
                if !colors.isEmpty { icons = .colors(Array(colors.prefix(3))) }
            }
            chips.append(IssueListChip(id: "property:\(pid)", icon: "tag", label: p.name, value: summarize(delta.map(name)),
                                       icons: icons, dimension: .property(pid)))
        }
        if showDate, let d = s.dateFilter {
            func short(_ day: String) -> String {
                let parts = day.split(separator: "-")
                guard parts.count == 3, let m = Int(parts[1]), let dd = Int(parts[2]) else { return day }
                return "\(m)/\(dd)"
            }
            chips.append(IssueListChip(
                id: "date", icon: "calendar",
                label: tr("issues", d.field == "created_at" ? "filters.date_field_created" : "filters.date_field_updated"),
                value: d.from == d.to ? short(d.from) : "\(short(d.from)) - \(short(d.to))", dimension: nil))
        }
        return chips
    }
}

struct IssueListChipView: View {
    let chip: IssueListChip
    let onRemove: () -> Void
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: chip.icon).font(.system(size: 9))
                Text(chip.label)
            }
            .foregroundStyle(.secondary)
            icons
            Text(chip.value).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("issues", "filters.chip_remove", ["name": chip.label]))
        }
        .font(Theme.Font.caption)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 24)
        .frame(maxWidth: 288)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
    }

    @ViewBuilder
    private var icons: some View {
        switch chip.icons {
        case .statuses(let keys):
            HStack(spacing: -3) { ForEach(keys, id: \.self) { session.issues.catalog.icon(for: $0, size: 11) } }
        case .priorities(let ps):
            HStack(spacing: -3) { ForEach(ps, id: \.self) { PriorityIcon(priority: $0, size: 11) } }
        case .actors(let refs):
            IssueListAvatarStack(refs: refs, size: 14)
        case .emojis(let e):
            HStack(spacing: 0) { ForEach(Array(e.enumerated()), id: \.offset) { Text($0.element).font(.system(size: 10)) } }
        case .colors(let c):
            HStack(spacing: -2) { ForEach(Array(c.enumerated()), id: \.offset) { Circle().fill($0.element).frame(width: 9, height: 9) } }
        case .none:
            EmptyView()
        }
    }
}
