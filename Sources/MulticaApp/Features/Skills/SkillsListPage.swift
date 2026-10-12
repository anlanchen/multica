import MulticaCore
import SwiftUI

/// Column geometry shared by the header and rows (upstream GRID_COLS):
/// deterministic widths so rows never shift as they scroll into view.
struct SkillsColumnLayout: Equatable {
    var wide: Bool
    var columns: [SkillsColumn]

    static let edge: CGFloat = 12
    static let checkbox: CGFloat = 16
    static let kebab: CGFloat = 28
    static let gap: CGFloat = 12
    static let rowHeight: CGFloat = 40
    static let wideBreakpoint: CGFloat = 672

    static func width(_ column: SkillsColumn) -> CGFloat {
        switch column {
        case .usedBy: return 144
        case .source: return 152
        case .creator: return 144
        case .updated, .created: return 104
        }
    }

    /// Below the breakpoint only name + used-by render and toggles don't apply.
    init(containerWidth: CGFloat, view: SkillsViewState) {
        wide = containerWidth >= Self.wideBreakpoint
        let visible = SkillsColumn.allCases.filter { view.isVisible($0) }
        columns = wide ? visible : visible.filter { $0 == .usedBy }
    }

    var nameMinWidth: CGFloat { wide ? 200 : 120 }

    var minWidth: CGFloat {
        let tracks = 2 + 1 + 1 + columns.count
        return Self.edge * 2 + Self.checkbox + nameMinWidth + Self.kebab + columns.reduce(0) { $0 + Self.width($1) }
            + CGFloat(tracks - 1) * Self.gap
    }
}

struct SkillsListPage: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @State private var model: SkillsListModel?

    var body: some View {
        Group {
            if let model {
                SkillsListContent(model: model)
            } else {
                Color.clear
            }
        }
        .task {
            if model == nil {
                let m = SkillsListModel(session: session)
                m.start()
                model = m
            }
            async let skills: Void = session.skills.loadIfNeeded()
            async let support: Void = session.skillsLoadSupportingData()
            _ = await (skills, support)
        }
    }
}

private struct SkillsListContent: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Bindable var model: SkillsListModel

    var body: some View {
        let store = session.skills
        VStack(spacing: 0) {
            SkillsPageHeaderBar(total: store.isLoaded ? store.items.count : 0) { model.sheet = .create }
            if session.skillsSupportingDataFailed {
                SkillsBanner { Text(tr("skills", "page.supporting_data_warning")) }
            }
            if let error = store.error, !store.isLoaded {
                EmptyStateView(icon: "exclamationmark.circle", title: tr("skills", "page.list_error.title"),
                               message: error.isEmpty ? tr("skills", "page.list_error.fallback") : error) {
                    Button(tr("skills", "page.list_error.retry")) { Task { await store.load() } }
                }
            } else if !store.isLoaded {
                SkillsListSkeleton()
            } else if store.items.isEmpty {
                EmptyStateView(icon: skillsIcon, title: tr("skills", "page.empty.title"), message: tr("skills", "page.empty.description")) {
                    Button { model.sheet = .create } label: { Label(tr("skills", "page.new_skill"), systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            } else {
                SkillsListToolbar(model: model)
                SkillsGrid(model: model)
            }
        }
        .overlay(alignment: .bottom) {
            if !model.selection.isEmpty {
                SkillsBatchToolbar(model: model)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: model.selection.isEmpty)
        .sheet(item: $model.sheet) { sheet in
            SkillsListSheetHost(sheet: sheet, model: model)
        }
    }
}

/// Collection header: icon, title, count, tagline + docs link, New skill.
struct SkillsPageHeaderBar: View {
    let total: Int
    let onCreate: () -> Void

    var body: some View {
        PageHeader {
            HStack(spacing: 8) {
                Image(systemName: skillsIcon).foregroundStyle(.secondary)
                Text(tr("skills", "page.title")).font(Theme.Font.bodyMedium)
                if total > 0 {
                    Text("\(total)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(spacing: 4) {
                    Text(tr("skills", "page.tagline"))
                    Link(tr("skills", "page.learn_more"), destination: SkillsLinks.docsURL())
                        .underline()
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 6)
                .layoutPriority(-1)
            }
        } trailing: {
            Button(action: onCreate) {
                Label(tr("skills", "page.new_skill"), systemImage: "plus")
            }
            .controlSize(.small)
        }
    }
}

private struct SkillsListSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: 160, height: 10)
                    Spacer()
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: 56, height: 14)
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: 72, height: 10)
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: 40, height: 10)
                }
                .padding(.horizontal, 24)
                .frame(height: SkillsColumnLayout.rowHeight)
                Divider().opacity(0.5)
            }
            Spacer()
        }
        .padding(.top, 8)
    }
}

// MARK: - Grid

private struct SkillsGrid: View {
    @Bindable var model: SkillsListModel

    var body: some View {
        GeometryReader { geo in
            let layout = SkillsColumnLayout(containerWidth: geo.size.width, view: model.view)
            let overflow = layout.wide && geo.size.width < layout.minWidth
            ScrollView(overflow ? [.horizontal, .vertical] : .vertical) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        if model.rows.isEmpty {
                            Text(tr("skills", "page.no_matches.title"))
                                .font(Theme.Font.body)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 64)
                        }
                        ForEach(model.rows) { row in
                            SkillsRowView(row: row, selected: model.selection.contains(row.id), layout: layout, model: model)
                                .equatable()
                        }
                    } header: {
                        SkillsGridHeader(model: model, layout: layout)
                    }
                }
                .padding(.bottom, 96)
                .frame(width: overflow ? layout.minWidth : geo.size.width)
            }
        }
    }
}

private struct SkillsGridHeader: View {
    @Bindable var model: SkillsListModel
    let layout: SkillsColumnLayout
    @State private var hovering = false

    var body: some View {
        let rows = model.rows
        let selectedVisible = rows.filter { model.selection.contains($0.id) }.count
        let allSelected = !rows.isEmpty && selectedVisible == rows.count
        let someSelected = selectedVisible > 0 && !allSelected
        HStack(spacing: SkillsColumnLayout.gap) {
            Button { model.toggleAll() } label: {
                SkillsCheckbox(checked: allSelected, indeterminate: someSelected)
                    .frame(width: SkillsColumnLayout.checkbox)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(allSelected || someSelected || hovering ? 1 : 0)
            sortCell(tr("skills", "table.name"), field: .name)
                .frame(minWidth: layout.nameMinWidth, maxWidth: .infinity, alignment: .leading)
            ForEach(layout.columns, id: \.self) { column in
                Group {
                    switch column {
                    case .usedBy: sortCell(tr("skills", "table.used_by"), field: .usedBy)
                    case .source: plainCell(tr("skills", "table.source"))
                    case .creator: plainCell(tr("skills", "table.created_by"))
                    case .updated: sortCell(tr("skills", "table.updated"), field: .updated)
                    case .created: sortCell(tr("skills", "table.created"), field: .created)
                    }
                }
                .frame(width: SkillsColumnLayout.width(column), alignment: .leading)
            }
            Color.clear.frame(width: SkillsColumnLayout.kebab)
        }
        .padding(.horizontal, SkillsColumnLayout.edge)
        .frame(height: 32)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onHover { hovering = $0 }
    }

    private func plainCell(_ title: String) -> some View {
        Text(title).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    private func sortCell(_ title: String, field: SkillsSortField) -> some View {
        let active = model.view.sortField == field
        return Button {
            var v = model.view
            v.toggleSort(field)
            model.view = v
        } label: {
            HStack(spacing: 3) {
                Text(title).lineLimit(1)
                if active {
                    Image(systemName: model.view.sortDirection == .asc ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .font(Theme.Font.caption)
            .foregroundStyle(active ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One list row. Equatable on its data so a catalog change re-renders only
/// the rows whose values changed.
private struct SkillsRowView: View, Equatable {
    @Environment(Navigator.self) private var nav
    let row: SkillsListRow
    let selected: Bool
    let layout: SkillsColumnLayout
    let model: SkillsListModel
    @State private var hovering = false

    static func == (a: SkillsRowView, b: SkillsRowView) -> Bool {
        a.row == b.row && a.selected == b.selected && a.layout == b.layout
    }

    var body: some View {
        HStack(spacing: SkillsColumnLayout.gap) {
            Button { model.toggleSelected(row.id) } label: {
                SkillsCheckbox(checked: selected)
                    .frame(width: SkillsColumnLayout.checkbox, height: SkillsColumnLayout.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(selected || hovering ? 1 : 0)

            HStack(spacing: 6) {
                Text(row.skill.name).font(Theme.Font.bodyMedium).lineLimit(1)
                if !row.canEdit {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help(tr("skills", "table.lock_tooltip"))
                }
            }
            .frame(minWidth: layout.nameMinWidth, maxWidth: .infinity, alignment: .leading)

            ForEach(layout.columns, id: \.self) { column in
                cell(column).frame(width: SkillsColumnLayout.width(column), alignment: .leading)
            }

            Menu {
                SkillsRowMenuItems(row: row, model: model)
            } label: {
                Image(systemName: "ellipsis").frame(width: SkillsColumnLayout.kebab, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: SkillsColumnLayout.kebab)
            .opacity(hovering ? 1 : 0)
            .help(tr("skills", "actions.row_menu"))
        }
        .padding(.horizontal, SkillsColumnLayout.edge)
        .frame(height: SkillsColumnLayout.rowHeight)
        .background(selected ? Theme.brand.opacity(0.08) : hovering ? Theme.hover : Color.clear)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { nav.push(.skill(row.id), title: row.skill.name) }
        .contextMenu { SkillsRowMenuItems(row: row, model: model) }
    }

    @ViewBuilder private func cell(_ column: SkillsColumn) -> some View {
        switch column {
        case .usedBy: SkillsUsedByCell(agents: row.agents)
        case .source: SkillsSourceCell(row: row)
        case .creator:
            if let creator = row.creator {
                HStack(spacing: 6) {
                    AvatarView(name: creator.name, url: creator.avatarUrl, size: 20)
                    Text(creator.name).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Color.clear
            }
        case .updated:
            Text(Formatters.relative(row.skill.updatedAt)).font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                .help(Formatters.date(row.skill.updatedAt, style: .complete, time: .shortened))
        case .created:
            Text(Formatters.relative(row.skill.createdAt)).font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                .help(Formatters.date(row.skill.createdAt, style: .complete, time: .shortened))
        }
    }
}

private struct SkillsUsedByCell: View {
    let agents: [AgentRecord]

    var body: some View {
        if agents.isEmpty {
            Text(tr("skills", "table.unused")).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if agents.count == 1, let agent = agents.first {
            HStack(spacing: 6) {
                SkillsAgentAvatar(agent: agent)
                Text(agent.name).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            HStack(spacing: -6) {
                ForEach(agents.prefix(3), id: \.id) { agent in
                    SkillsAgentAvatar(agent: agent)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.canvas, lineWidth: 2))
                        .help(agent.name)
                }
                if agents.count > 3 {
                    Text("+\(agents.count - 3)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: 2))
                }
            }
        }
    }
}

private struct SkillsSourceCell: View {
    let row: SkillsListRow

    var body: some View {
        let label = SkillsOriginStyle.tableLabel(row.origin, runtime: row.runtime)
        HStack(spacing: 6) {
            Image(systemName: SkillsOriginStyle.icon(row.origin.type)).font(.system(size: 10))
            if let link = row.origin.linkURL, let url = URL(string: link) {
                Link(label, destination: url).lineLimit(1).help(link)
            } else {
                Text(label).lineLimit(1)
            }
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
    }
}

/// Kebab / context menu entries (upstream SkillRowActions).
struct SkillsRowMenuItems: View {
    @Environment(Navigator.self) private var nav
    let row: SkillsListRow
    let model: SkillsListModel

    var body: some View {
        Button {
            nav.openInNewTab(.skill(row.id), title: row.skill.name)
        } label: {
            Label(tr("common", "navigation.open_in_new_tab"), systemImage: "arrow.up.right.square")
        }
        Divider()
        Button {
            model.sheet = .addToAgent([row.skill])
        } label: {
            Label(tr("skills", "actions.add_to_agent"), systemImage: "plus")
        }
        if row.isRefreshable {
            Button {
                model.sheet = .refresh(row)
            } label: {
                Label(tr("skills", "actions.refresh"), systemImage: "arrow.clockwise")
            }
        }
        if row.canEdit {
            Divider()
            Button(role: .destructive) {
                model.sheet = .delete([row], clearsSelection: false)
            } label: {
                Label(tr("skills", "actions.delete"), systemImage: "trash")
            }
        }
    }
}

/// Floating bar for the multi-selection (upstream SkillBatchToolbar).
private struct SkillsBatchToolbar: View {
    @Bindable var model: SkillsListModel

    var body: some View {
        let rows = model.selectedRows
        let allDeletable = rows.allSatisfy(\.canEdit)
        let updatable = rows.filter(\.isRefreshable)
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(tr("skills", "actions.selected", ["count": rows.count])).font(Theme.Font.bodyMedium)
                Button { model.selection = [] } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(tr("skills", "actions.clear_selection"))
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .overlay(alignment: .trailing) { Divider().frame(height: 18) }

            Button { model.sheet = .addToAgent(rows.map(\.skill)) } label: {
                Label(tr("skills", "actions.add_to_agent"), systemImage: "plus")
            }
            Button { model.sheet = .update(updatable, skipped: rows.count - updatable.count) } label: {
                Label(tr("skills", "actions.update"), systemImage: "arrow.clockwise")
            }
            .disabled(updatable.isEmpty)
            .help(updatable.isEmpty ? tr("skills", "actions.update_none") : "")
            Button(role: .destructive) { model.sheet = .delete(rows, clearsSelection: true) } label: {
                Label(tr("skills", "actions.delete"), systemImage: "trash")
            }
            .foregroundStyle(Theme.destructive)
            .disabled(!allDeletable)
            .help(allDeletable ? "" : tr("skills", "actions.delete_no_permission"))
        }
        .buttonStyle(.borderless)
        .font(Theme.Font.body)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

/// Routes the list's sheet state to the matching dialog.
private struct SkillsListSheetHost: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let sheet: SkillsListSheet
    let model: SkillsListModel

    var body: some View {
        switch sheet {
        case .create:
            SkillsCreateSheet { skill in
                nav.push(.skill(skill.id), title: skill.name)
            }
        case .addToAgent(let skills):
            SkillsAddToAgentSheet(skills: skills)
        case .refresh(let row):
            SkillsRefreshSheet(skill: row.skill, origin: row.origin)
        case .delete(let rows, let clears):
            SkillsDeleteSheet(skills: rows.map(\.skill), agentCounts: rows.map(\.agents.count)) { ids in
                model.didDelete(ids)
                if clears { model.selection = [] }
            }
        case .update(let rows, let skipped):
            SkillsUpdateSheet(rows: rows, skipped: skipped) { model.selection = [] }
        case .manageLabels:
            SkillsLabelManagerSheet()
        }
    }
}
