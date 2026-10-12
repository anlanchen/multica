import MulticaCore
import SwiftUI

/// Search, result count, filter menu and display settings (upstream
/// SkillListToolbar).
struct SkillsListToolbar: View {
    @Bindable var model: SkillsListModel
    @State private var filterOpen = false
    @State private var displayOpen = false

    var body: some View {
        let view = model.view
        let active = view.filters.activeDimensionCount
        HStack(spacing: 8) {
            SearchField(text: $model.search, prompt: tr("skills", "page.search_placeholder"))
                .frame(width: 256)
            if model.isNarrowed {
                Text("\(model.rows.count) / \(model.allRows.count)")
                    .font(Theme.Font.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(tr("skills", "toolbar.result_count_title"))
            }
            Spacer(minLength: 8)

            HStack(spacing: 0) {
                Button { filterOpen.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text(active > 0 ? tr("skills", "toolbar.filter_active_count", ["count": active]) : tr("skills", "toolbar.filter_label"))
                    }
                    .padding(.leading, 9)
                    .padding(.trailing, active > 0 ? 4 : 9)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if active > 0 {
                    Button { model.clearFilters() } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tr("skills", "toolbar.clear_filters"))
                    .padding(.trailing, 4)
                }
            }
            .font(Theme.Font.caption)
            .foregroundStyle(active > 0 ? Color.white : Color.secondary)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(active > 0 ? Theme.brand : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(active > 0 ? Color.clear : Theme.border))
            .popover(isPresented: $filterOpen, arrowEdge: .bottom) {
                SkillsFilterPanel(model: model) { filterOpen = false }
            }

            Button { displayOpen.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: view.sortDirection == .asc ? "arrow.up" : "arrow.down")
                    Text(Self.sortLabel(view.sortField))
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("skills", "toolbar.display"))
            .popover(isPresented: $displayOpen, arrowEdge: .bottom) {
                SkillsDisplayPanel(model: model)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Divider() }
    }

    static func sortLabel(_ field: SkillsSortField) -> String {
        switch field {
        case .name: return tr("skills", "table.name")
        case .usedBy: return tr("skills", "table.used_by")
        case .updated: return tr("skills", "table.updated")
        case .created: return tr("skills", "table.created")
        }
    }

    static func columnLabel(_ column: SkillsColumn) -> String {
        switch column {
        case .usedBy: return tr("skills", "table.used_by")
        case .source: return tr("skills", "table.source")
        case .creator: return tr("skills", "table.created_by")
        case .updated: return tr("skills", "table.updated")
        case .created: return tr("skills", "table.created")
        }
    }
}

/// Display popover: sort field + direction, column switches.
private struct SkillsDisplayPanel: View {
    @Bindable var model: SkillsListModel

    var body: some View {
        let view = model.view
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("skills", "toolbar.sort_by")).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { view.sortField }, set: { field in
                        var v = model.view
                        v.setSortField(field)
                        model.view = v
                    })) {
                        ForEach(SkillsSortField.allCases, id: \.self) { field in
                            Text(SkillsListToolbar.sortLabel(field)).tag(field)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    Button {
                        var v = model.view
                        v.sortDirection = v.sortDirection.toggled
                        model.view = v
                    } label: {
                        Image(systemName: view.sortDirection == .asc ? "arrow.up" : "arrow.down").frame(width: 18)
                    }
                    .help(view.sortDirection == .asc ? tr("skills", "toolbar.direction_asc") : tr("skills", "toolbar.direction_desc"))
                }
            }
            .padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("skills", "toolbar.section_columns")).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(SkillsColumn.allCases, id: \.self) { column in
                    Toggle(isOn: Binding(get: { view.isVisible(column) }, set: { _ in
                        var v = model.view
                        v.toggleColumn(column)
                        model.view = v
                    })) {
                        Text(SkillsListToolbar.columnLabel(column)).font(Theme.Font.body)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
            .padding(12)
        }
        .frame(width: 256)
    }
}

/// Filter popover: dimension list, then a dimension's options (the native
/// counterpart of upstream's nested submenus).
private struct SkillsFilterPanel: View {
    @Environment(WorkspaceSession.self) private var session
    @Bindable var model: SkillsListModel
    let dismiss: () -> Void
    @State private var dimension: SkillsFilterDimension?
    @State private var labelSearch = ""

    var body: some View {
        Group {
            if let dimension {
                VStack(alignment: .leading, spacing: 0) {
                    Button { self.dimension = nil } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                            Text(title(dimension)).font(Theme.Font.bodyMedium)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    Divider()
                    options(dimension)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach([SkillsFilterDimension.usage, .origins, .agents, .creators, .labels], id: \.self) { d in
                        Button { dimension = d } label: {
                            HStack {
                                Text(title(d))
                                Spacer()
                                let n = model.view.filters.count(d)
                                if n > 0 { Text("\(n)").font(Theme.Font.caption.weight(.medium)).foregroundStyle(Theme.brand) }
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            .font(Theme.Font.body)
                        }
                        .buttonStyle(HoverRowButtonStyle())
                    }
                }
                .padding(4)
            }
        }
        .frame(width: 260)
        .task { await session.skillsStore.labels.loadIfNeeded() }
    }

    private func title(_ d: SkillsFilterDimension) -> String {
        switch d {
        case .usage: return tr("skills", "toolbar.section_usage")
        case .origins: return tr("skills", "table.source")
        case .agents: return tr("skills", "table.used_by")
        case .creators: return tr("skills", "table.created_by")
        case .labels: return tr("skills", "toolbar.section_labels")
        }
    }

    @ViewBuilder private func options(_ d: SkillsFilterDimension) -> some View {
        let o = model.options
        let filters = model.view.filters
        switch d {
        case .usage:
            optionList {
                row(checked: filters.usage.contains(.used), title: tr("skills", "page.scopes.used.label"), count: o.usedCount) {
                    model.toggleFilter(.usage, SkillsUsage.used.rawValue)
                }
                row(checked: filters.usage.contains(.unused), title: tr("skills", "page.scopes.unused.label"), count: o.unusedCount) {
                    model.toggleFilter(.usage, SkillsUsage.unused.rawValue)
                }
            }
        case .origins:
            optionList {
                ForEach(SkillsOriginType.menuOrder.filter { o.originCounts[$0] != nil }, id: \.self) { type in
                    row(checked: filters.origins.contains(type), icon: AnyView(Image(systemName: SkillsOriginStyle.icon(type)).foregroundStyle(.secondary)),
                        title: SkillsOriginStyle.filterLabel(type), count: o.originCounts[type] ?? 0) {
                        model.toggleFilter(.origins, type.rawValue)
                    }
                }
            }
        case .agents:
            optionList {
                ForEach(o.agents, id: \.agent.id) { entry in
                    row(checked: filters.agents.contains(entry.agent.id), icon: AnyView(SkillsAgentAvatar(agent: entry.agent, size: 16)),
                        title: entry.agent.name, count: entry.count) {
                        model.toggleFilter(.agents, entry.agent.id)
                    }
                }
            }
        case .creators:
            optionList {
                ForEach(o.creators, id: \.member.userId) { entry in
                    row(checked: filters.creators.contains(entry.member.userId),
                        icon: AnyView(AvatarView(name: entry.member.name, url: entry.member.avatarUrl, size: 16)),
                        title: entry.member.name, count: entry.count) {
                        model.toggleFilter(.creators, entry.member.userId)
                    }
                }
            }
        case .labels:
            let catalog = session.skillsStore.labels.items
            let q = labelSearch.trimmingCharacters(in: .whitespaces).lowercased()
            let visible = catalog.filter { q.isEmpty || $0.name.lowercased().contains(q) }
            VStack(alignment: .leading, spacing: 0) {
                TextField(tr("skills", "toolbar.filter_search_placeholder"), text: $labelSearch)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                Divider()
                optionList {
                    ForEach(visible) { label in
                        let count = o.labelCounts[label.id] ?? 0
                        row(checked: filters.labels.contains(label.id), label: AnyView(SkillsLabelChip(name: label.name, color: label.color)),
                            count: count > 0 ? count : nil) {
                            model.toggleFilter(.labels, label.id)
                        }
                    }
                    if visible.isEmpty {
                        Text(labelSearch.isEmpty ? tr("skills", "toolbar.no_labels") : tr("skills", "toolbar.no_results"))
                            .font(Theme.Font.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                Divider()
                Button {
                    dismiss()
                    Task { @MainActor in model.sheet = .manageLabels }
                } label: {
                    Label(tr("skills", "toolbar.manage_labels"), systemImage: "tag").font(Theme.Font.body)
                }
                .buttonStyle(HoverRowButtonStyle())
                .padding(4)
            }
        }
    }

    private func optionList<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 0) { content() }.padding(4)
        }
        .frame(maxHeight: 288)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(checked: Bool, icon: AnyView? = nil, title: String? = nil, label: AnyView? = nil, count: Int?,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                    .opacity(checked ? 1 : 0)
                    .frame(width: 12)
                if let icon { icon.frame(width: 16) }
                if let label { label } else if let title { Text(title).lineLimit(1) }
                Spacer(minLength: 8)
                if let count { Text("\(count)").font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            .font(Theme.Font.body)
        }
        .buttonStyle(HoverRowButtonStyle())
    }
}
