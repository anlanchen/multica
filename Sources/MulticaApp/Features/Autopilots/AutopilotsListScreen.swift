import MulticaCore
import Observation
import SwiftUI

private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
    tr("autopilots", key, args)
}

private typealias ListState = AutopilotsListState

/// The list's view preferences, persisted per workspace (upstream
/// useAutopilotsViewStore with workspace-aware storage).
@MainActor
@Observable
final class AutopilotsViewPrefs {
    var state: AutopilotsListState {
        didSet {
            if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    @ObservationIgnored private let key: String
    @ObservationIgnored private static var cache: [String: AutopilotsViewPrefs] = [:]

    private init(workspaceID: String) {
        key = "multica.autopilots.view.\(workspaceID)"
        state = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(AutopilotsListState.self, from: $0) } ?? AutopilotsListState()
    }

    static func forWorkspace(_ id: String) -> AutopilotsViewPrefs {
        if let hit = cache[id] { return hit }
        let p = AutopilotsViewPrefs(workspaceID: id)
        cache[id] = p
        return p
    }
}

/// Empty-state templates. Prompts stay raw English: they are the agent's
/// task input.
private struct AutopilotsTemplate: Identifiable {
    let id: String
    let symbol: String
    let prompt: String
    let time: String
    let days: AutopilotsSchedule.DayPattern

    static let weekdays = AutopilotsSchedule.DayPattern.weekly([1, 2, 3, 4, 5])
    static let monday = AutopilotsSchedule.DayPattern.weekly([1])

    static let all: [AutopilotsTemplate] = [
        AutopilotsTemplate(id: "daily_news", symbol: "newspaper", prompt: """
            1. Search the web for news and announcements published today only (strictly today's date)
            2. Filter for topics relevant to our team and industry
            3. For each item, write a short summary including: title, source, key takeaways
            4. Compile everything into a single digest post
            5. Post the digest as a comment on this issue and @mention all workspace members
            """, time: "09:00", days: .every),
        AutopilotsTemplate(id: "pr_review", symbol: "arrow.triangle.pull", prompt: """
            1. List all open pull requests in the repository
            2. Identify PRs that have been open for more than 24 hours without a review
            3. For each stale PR, note the author, age, and a one-line summary of the change
            4. Post a comment on this issue listing all stale PRs with links
            5. @mention the team to remind them to review
            """, time: "10:00", days: weekdays),
        AutopilotsTemplate(id: "bug_triage", symbol: "ladybug", prompt: """
            1. List all backlog issues that have not been prioritized
            2. For each issue, read the description and any attached logs or screenshots
            3. Assess severity (critical / high / medium / low) based on user impact and scope
            4. Set the priority field on the issue accordingly
            5. Add a comment explaining your assessment and suggested next steps
            """, time: "09:00", days: weekdays),
        AutopilotsTemplate(id: "weekly_progress", symbol: "chart.bar", prompt: """
            1. Gather all issues completed (status "done") in the past 7 days
            2. Gather all issues currently in progress
            3. Identify any blocked issues and their blockers
            4. Calculate key metrics: issues closed, issues opened, net change
            5. Write a structured weekly report with sections: Completed, In Progress, Blocked, Metrics
            6. Post the report as a comment on this issue
            """, time: "17:00", days: monday),
        AutopilotsTemplate(id: "dependency_audit", symbol: "shield", prompt: """
            1. Run dependency audit tools on the project (npm audit, go vuln check, etc.)
            2. Identify any packages with known security vulnerabilities
            3. List outdated packages that are more than 2 major versions behind
            4. For each finding, note the severity, affected package, and recommended fix
            5. Post a summary report as a comment with actionable items
            """, time: "08:00", days: monday),
        AutopilotsTemplate(id: "documentation_check", symbol: "doc.text.magnifyingglass", prompt: """
            1. List all code changes merged in the past 7 days (via git log)
            2. For each significant change, check if related documentation was updated
            3. Identify any new APIs, config options, or features missing documentation
            4. Create a list of documentation gaps with file paths and suggested content
            5. Post the findings as a comment on this issue
            """, time: "14:00", days: monday),
    ]
}

/// Column geometry, single source for header, rows and skeleton.
private enum AutopilotsColumns {
    static let widths: [ListState.Column: CGFloat] = [
        .assignee: 144, .trigger: 144, .lastRun: 120, .nextRun: 104, .mode: 104, .creator: 144, .created: 104,
    ]
    static let compactThreshold: CGFloat = 672
    static let spacing: CGFloat = 12

    /// The hideable columns on screen, in order; the compact zone shows the
    /// assignee only.
    static func visible(_ state: ListState, compact: Bool) -> [ListState.Column] {
        if compact { return [.assignee] }
        return ListState.Column.allCases.filter { state.isVisible($0) }
    }

    static func minWidth(_ columns: [ListState.Column]) -> CGFloat {
        let fixed: CGFloat = 12 + 16 + 200 + 28 + 12
        return fixed + columns.reduce(0) { $0 + (widths[$1] ?? 0) } + CGFloat(columns.count + 3) * spacing
    }
}

private struct AutopilotsDerived: Equatable {
    var counts: [ListState.Scope: Int] = [:]
    var scopeRows: [Autopilot] = []
    var rows: [Autopilot] = []
    var options = AutopilotsList.Options()
}

/// The autopilots page (upstream autopilots-page): Autopilot and Issue
/// wakeups tabs; the first is a sortable, filterable list with batch actions
/// and a templates empty state.
struct AutopilotsListScreen: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    @State private var derived = AutopilotsDerived()
    @State private var selected: Set<String> = []
    @State private var createInitial: AutopilotsDialogInitial?
    @State private var createOpen = false
    @State private var wakeupCreateOpen = false
    @State private var deleteRows: [Autopilot] = []
    @State private var deleteOpen = false

    private var prefs: AutopilotsViewPrefs { AutopilotsViewPrefs.forWorkspace(session.workspace.id) }
    private var tab: String { nav.query("tab") == "wakeups" ? "wakeups" : "autopilots" }

    var body: some View {
        let store = session.autopilots
        VStack(spacing: 0) {
            pageHeader(total: store.items.count)
            tabStrip
            if tab == "wakeups" {
                AutopilotsWakeupsView()
            } else if let error = store.error, !store.isLoaded {
                ErrorStateView(message: error) { Task { await store.load() } }
            } else if !store.isLoaded {
                skeleton
            } else if store.items.isEmpty {
                ScrollView { templates }
            } else {
                AutopilotsListToolbar(prefs: prefs, counts: derived.counts, options: derived.options,
                                      scopeTotal: derived.scopeRows.count, visibleCount: derived.rows.count)
                list
            }
        }
        .overlay(alignment: .bottom) {
            if tab == "autopilots" && !selected.isEmpty { batchToolbar }
        }
        .task(id: session.revision("autopilot")) {
            if session.revision("autopilot") == 0 { await store.loadIfNeeded() } else { await store.load() }
        }
        .onChange(of: store.items, initial: true) { recompute() }
        .onChange(of: prefs.state) { recompute() }
        .sheet(isPresented: $createOpen) {
            AutopilotsDialog(mode: .create(createInitial ?? AutopilotsDialogInitial()))
        }
        .sheet(isPresented: $deleteOpen) { deleteSheet }
        .sheet(isPresented: $wakeupCreateOpen) { AutopilotsWakeupCreateFlow() }
    }

    private func recompute() {
        let state = prefs.state
        let all = session.autopilots.items
        var d = AutopilotsDerived()
        d.counts = AutopilotsList.scopeCounts(all)
        d.scopeRows = AutopilotsList.scopeRows(all, scope: state.scope)
        d.rows = AutopilotsList.visibleRows(d.scopeRows, state: state)
        d.options = AutopilotsList.options(d.scopeRows)
        if d != derived { derived = d }
        let ids = Set(all.map(\.id))
        if !selected.isSubset(of: ids) { selected = selected.intersection(ids) }
    }

    private func openCreate(_ template: AutopilotsTemplate? = nil) {
        var initial = AutopilotsDialogInitial()
        if let template {
            initial.title = t("templates.\(template.id).title")
            initial.description = template.prompt
            initial.scheduleTime = .at(template.time)
            initial.scheduleDays = template.days
        }
        createInitial = initial
        createOpen = true
    }

    // MARK: Header & tabs

    private func pageHeader(total: Int) -> some View {
        PageHeader {
            HStack(spacing: 8) {
                Image(systemName: "bolt").foregroundStyle(.secondary)
                Text(t("page.title")).font(Theme.Font.bodyMedium)
                if tab == "autopilots" {
                    Text("\(total)").font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } trailing: {
            Button {
                if tab == "autopilots" { openCreate() } else { wakeupCreateOpen = true }
            } label: {
                Label(tab == "autopilots" ? t("page.new_autopilot") : t("wakeups.create"), systemImage: "plus")
            }
            .controlSize(.small)
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 16) {
            tabButton("autopilots", t("page.title"))
            tabButton("wakeups", t("wakeups.title"))
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(t("page.title"))
    }

    private func tabButton(_ id: String, _ label: String) -> some View {
        let active = tab == id
        return Button { nav.setQuery("tab", id == "wakeups" ? "wakeups" : nil) } label: {
            Text(label)
                .font(active ? Theme.Font.bodyMedium : Theme.Font.body)
                .foregroundStyle(active ? .primary : .secondary)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(active ? Color.primary : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: Empty / loading

    private var templates: some View {
        VStack(spacing: 0) {
            Image(systemName: "bolt").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary).padding(.bottom, 12)
            Text(t("page.empty.title")).font(Theme.Font.body).foregroundStyle(.secondary)
            Text(t("page.empty.hint")).font(Theme.Font.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 4).padding(.bottom, 24)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(AutopilotsTemplate.all) { tpl in
                    Button { openCreate(tpl) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: tpl.symbol).font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 20).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t("templates.\(tpl.id).title")).font(Theme.Font.bodyMedium).foregroundStyle(.primary)
                                Text(t("templates.\(tpl.id).summary")).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .multilineTextAlignment(.leading)
                        .padding(12)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border.opacity(1.5)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(cornerRadius: Theme.Radius.large)
                }
            }
            .frame(maxWidth: 768)
            Button { openCreate() } label: { Label(t("page.start_blank"), systemImage: "plus") }
                .controlSize(.small)
                .padding(.top, 16)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 64)
        .frame(maxWidth: .infinity)
    }

    private var skeleton: some View {
        let columns = AutopilotsColumns.visible(ListState(), compact: false)
        return VStack(spacing: 0) {
            HStack(spacing: AutopilotsColumns.spacing) {
                Color.clear.frame(width: 16)
                AutopilotsSkeleton(width: 48).frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                ForEach(columns, id: \.self) { c in
                    AutopilotsSkeleton(width: 48).frame(width: AutopilotsColumns.widths[c], alignment: .leading)
                }
                Color.clear.frame(width: 28)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            Divider()
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: AutopilotsColumns.spacing) {
                    Color.clear.frame(width: 16)
                    AutopilotsSkeleton(width: 160, height: 14).frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                    ForEach(columns, id: \.self) { c in
                        HStack(spacing: 6) {
                            if c == .assignee { AutopilotsSkeleton(width: 20, height: 20, cornerRadius: 10) }
                            AutopilotsSkeleton(width: 56)
                        }
                        .frame(width: AutopilotsColumns.widths[c], alignment: .leading)
                    }
                    Color.clear.frame(width: 28)
                }
                .padding(.horizontal, 12)
                .frame(height: 48)
            }
            Spacer()
        }
    }

    // MARK: List

    private var list: some View {
        GeometryReader { geo in
            let state = prefs.state
            let compact = geo.size.width < AutopilotsColumns.compactThreshold
            let columns = AutopilotsColumns.visible(state, compact: compact)
            let minWidth = compact ? 0 : AutopilotsColumns.minWidth(columns)
            let width = max(geo.size.width, minWidth)
            ScrollView(minWidth > geo.size.width ? [.horizontal, .vertical] : .vertical) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        if derived.rows.isEmpty {
                            Text(t("page.no_matches")).font(Theme.Font.body).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 64)
                        }
                        ForEach(derived.rows) { a in
                            AutopilotsListRow(
                                autopilot: a,
                                selected: selected.contains(a.id),
                                columns: columns,
                                onToggle: { toggle(a.id) },
                                onDelete: { requestDelete([a]) }
                            )
                            .equatable()
                        }
                    } header: {
                        listHeader(state: state, columns: columns)
                    }
                }
                .padding(.bottom, 96)
                .frame(width: width)
            }
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func listHeader(state: ListState, columns: [ListState.Column]) -> some View {
        let rowIDs = derived.rows.map(\.id)
        let selectedCount = rowIDs.filter { selected.contains($0) }.count
        let all = !rowIDs.isEmpty && selectedCount == rowIDs.count
        let some = selectedCount > 0 && !all
        return AutopilotsListHeader(state: state, columns: columns, allSelected: all, someSelected: some,
                                    onToggleAll: { selected = all ? [] : Set(rowIDs) },
                                    onSort: { field in prefs.state.toggleSort(field) })
    }

    // MARK: Batch & delete

    private var selectedRows: [Autopilot] { derived.rows.filter { selected.contains($0.id) } }

    private var batchToolbar: some View {
        let rows = selectedRows
        return HStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(t("actions.selected", ["count": rows.count])).font(Theme.Font.bodyMedium)
                Button { selected = [] } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: Theme.Radius.small)
                .help(t("actions.clear_selection"))
                .accessibilityLabel(t("actions.clear_selection"))
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .overlay(alignment: .trailing) { Divider().frame(height: 16) }
            if rows.contains(where: { $0.status == "active" }) {
                Button { Task { await AutopilotsActions.setStatus(rows, "paused", session: session, toaster: toaster) } } label: {
                    Label(t("actions.pause"), systemImage: "pause")
                }
            }
            if rows.contains(where: { $0.status == "paused" }) {
                Button { Task { await AutopilotsActions.setStatus(rows, "active", session: session, toaster: toaster) } } label: {
                    Label(t("actions.resume"), systemImage: "play")
                }
            }
            Button { requestDelete(rows) } label: { Label(t("actions.delete"), systemImage: "trash") }
                .foregroundStyle(Theme.destructive)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border.opacity(1.5)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.bottom, 24)
    }

    private func requestDelete(_ rows: [Autopilot]) {
        guard !rows.isEmpty else { return }
        deleteRows = rows
        deleteOpen = true
    }

    private var deleteSheet: some View {
        let rows = deleteRows
        return AutopilotsConfirmSheet(
            title: t("actions.delete_dialog.title"),
            message: t("actions.delete_dialog.description", ["count": rows.count, "name": rows.first?.title ?? ""]),
            warning: t("actions.delete_dialog.warning"),
            cancelLabel: t("actions.delete_dialog.cancel"),
            confirmLabel: t("actions.delete_dialog.confirm"),
            busyLabel: t("actions.delete_dialog.deleting")
        ) {
            do {
                try await AutopilotsActions.delete(rows, session: session)
                selected.subtract(rows.map(\.id))
                return true
            } catch {
                toaster.error(error)
                return false
            }
        }
    }
}

// MARK: - Header row

private struct AutopilotsListHeader: View {
    let state: ListState
    let columns: [ListState.Column]
    let allSelected: Bool
    let someSelected: Bool
    let onToggleAll: () -> Void
    let onSort: (ListState.SortField) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: AutopilotsColumns.spacing) {
            Button(action: onToggleAll) {
                Image(systemName: allSelected ? "checkmark.square.fill" : someSelected ? "minus.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(allSelected || someSelected ? Theme.brand : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 16)
            .opacity(allSelected || someSelected || hovering ? 1 : 0)
            sortable(.name, t("page.table.name")).frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            ForEach(columns, id: \.self) { c in
                Group {
                    switch c {
                    case .assignee: plain(t("page.table.assignee"))
                    case .trigger: plain(t("page.table.trigger"))
                    case .lastRun: sortable(.lastRun, t("page.table.last_run"))
                    case .nextRun: sortable(.nextRun, t("page.table.next_run"))
                    case .mode: plain(t("page.table.mode"))
                    case .creator: plain(t("page.table.created_by"))
                    case .created: sortable(.created, t("page.table.created"))
                    }
                }
                .frame(width: AutopilotsColumns.widths[c], alignment: .leading)
            }
            Color.clear.frame(width: 28)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .onHover { hovering = $0 }
    }

    private func plain(_ label: String) -> some View {
        Text(label).lineLimit(1)
    }

    private func sortable(_ field: ListState.SortField, _ label: String) -> some View {
        Button { onSort(field) } label: {
            HStack(spacing: 3) {
                Text(label).lineLimit(1)
                if state.sortField == field {
                    Image(systemName: state.sortDirection == .asc ? "arrow.up" : "arrow.down").font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(state.sortField == field ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row

private struct AutopilotsListRow: View, Equatable {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let autopilot: Autopilot
    let selected: Bool
    let columns: [ListState.Column]
    let onToggle: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    static func == (a: Self, b: Self) -> Bool {
        a.autopilot == b.autopilot && a.selected == b.selected && a.columns == b.columns
    }

    var body: some View {
        let a = autopilot
        HStack(spacing: AutopilotsColumns.spacing) {
            Button(action: onToggle) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.brand : .secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 16)
            .opacity(selected || hovering ? 1 : 0)
            HStack(spacing: 6) {
                Text(a.title).font(Theme.Font.bodyMedium).lineLimit(1)
                if a.status == "paused" {
                    Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(.orange)
                        .help(a.pauseReason == "agent_runtime_required" ? t("status.paused_runtime_required") : t("status.paused"))
                }
            }
            .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            ForEach(columns, id: \.self) { c in
                cell(c).frame(width: AutopilotsColumns.widths[c], alignment: .leading)
            }
            kebab.frame(width: 28)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(selected ? Theme.brand.opacity(0.06) : hovering ? Theme.hover : .clear)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { nav.push(.autopilot(a.id), title: a.title) }
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private func cell(_ column: ListState.Column) -> some View {
        let a = autopilot
        switch column {
        case .assignee:
            actor(type: a.assigneeType, id: a.assigneeId)
        case .trigger:
            let kinds = a.triggerKinds ?? []
            if kinds.isEmpty {
                Text("—").font(Theme.Font.caption).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 8) {
                    ForEach(kinds, id: \.self) { kind in
                        HStack(spacing: 3) {
                            Image(systemName: AutopilotsLabels.triggerSymbol(kind)).font(.system(size: 9))
                            Text(AutopilotsLabels.triggerKind(kind)).lineLimit(1)
                        }
                    }
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
            }
        case .lastRun:
            if let last = a.lastRunAt {
                HStack(spacing: 6) {
                    Circle().fill(AutopilotsRunVisual.dot(a.lastRunStatus)).frame(width: 6, height: 6)
                        .help(a.lastRunStatus.map(AutopilotsLabels.runStatus) ?? "")
                    RelativeTime(timestamp: last).font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Text("—").font(Theme.Font.caption).foregroundStyle(.tertiary)
            }
        case .nextRun:
            if let next = a.nextRunAt {
                Text(AutopilotsFormat.instant(next)).font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            } else {
                Text("—").font(Theme.Font.caption).foregroundStyle(.tertiary)
            }
        case .mode:
            Text(AutopilotsLabels.executionMode(a.executionMode)).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
        case .creator:
            actor(type: a.createdByType, id: a.createdById)
        case .created:
            Text(AutopilotsFormat.shortDate(a.createdAt)).font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func actor(type: String, id: String) -> some View {
        HStack(spacing: 6) {
            ActorAvatar(type: type, id: id, size: 20)
            Text(session.actorInfo(type: type, id: id).name).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// Hidden for members without write access; an absent can_write keeps it.
    @ViewBuilder private var kebab: some View {
        if autopilot.canWrite != false {
            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
            .help(t("actions.row_menu"))
            .accessibilityLabel(t("actions.row_menu"))
        }
    }

    @ViewBuilder private var menuItems: some View {
        let a = autopilot
        Button { nav.openInNewTab(.autopilot(a.id), title: a.title) } label: {
            Label(tr("common", "navigation.open_in_new_tab"), systemImage: "arrow.up.right.square")
        }
        if a.canWrite != false {
            Divider()
            if a.status == "active" {
                Button { Task { await AutopilotsActions.setStatus([a], "paused", session: session, toaster: toaster) } } label: {
                    Label(t("actions.pause"), systemImage: "pause")
                }
            }
            if a.status == "paused" {
                Button { Task { await AutopilotsActions.setStatus([a], "active", session: session, toaster: toaster) } } label: {
                    Label(t("actions.resume"), systemImage: "play")
                }
            }
            Divider()
            Button(role: .destructive, action: onDelete) { Label(t("actions.delete"), systemImage: "trash") }
        }
    }
}

// MARK: - Toolbar

/// Scope buttons, filter menu and display popover (upstream
/// autopilot-list-toolbar).
private struct AutopilotsListToolbar: View {
    @Environment(WorkspaceSession.self) private var session
    let prefs: AutopilotsViewPrefs
    let counts: [ListState.Scope: Int]
    let options: AutopilotsList.Options
    let scopeTotal: Int
    let visibleCount: Int
    @State private var displayOpen = false

    private static let modes = ["create_issue", "run_only"]
    private static let triggerKinds = ["schedule", "webhook", "api"]

    var body: some View {
        let state = prefs.state
        let activeCount = state.filters.activeDimensions
        ViewThatFits(in: .horizontal) {
            content(state: state, activeCount: activeCount, wide: true)
            content(state: state, activeCount: activeCount, wide: false)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private func content(state: ListState, activeCount: Int, wide: Bool) -> some View {
        HStack(spacing: 8) {
            if wide {
                HStack(spacing: 4) {
                    ForEach(ListState.Scope.allCases, id: \.self) { scope in
                        Button { prefs.state.scope = scope } label: {
                            HStack(spacing: 6) {
                                Text(scopeLabel(scope))
                                Text("\(counts[scope] ?? 0)").font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .foregroundStyle(state.scope == scope ? .primary : .secondary)
                        }
                        .buttonStyle(PillButtonStyle(active: state.scope == scope))
                    }
                }
                if activeCount > 0 {
                    Text("\(visibleCount) / \(scopeTotal)").font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                        .help(t("toolbar.result_count_title"))
                }
            } else {
                Menu {
                    Picker("", selection: Binding(get: { state.scope }, set: { prefs.state.scope = $0 })) {
                        ForEach(ListState.Scope.allCases, id: \.self) { scope in
                            Text("\(scopeLabel(scope))  \(counts[scope] ?? 0)").tag(scope)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(scopeLabel(state.scope))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer(minLength: 8)
            filterMenu(state: state, activeCount: activeCount, wide: wide)
            displayButton(state: state, wide: wide)
        }
    }

    private func scopeLabel(_ scope: ListState.Scope) -> String {
        switch scope {
        case .all: return t("page.scope_all")
        case .active: return t("status.active")
        case .paused: return t("status.paused")
        }
    }

    private func filterMenu(state: ListState, activeCount: Int, wide: Bool) -> some View {
        HStack(spacing: 0) {
            Menu {
                Menu(section(t("toolbar.section_assignee"), state.filters.assignees.count)) {
                    ForEach(options.assignees) { o in
                        toggle(state.filters.assignees.contains(o.value), "\(session.actorInfo(type: o.type, id: o.id).name)", o.count) {
                            prefs.state.toggleFilter(.assignees, o.value)
                        }
                    }
                }
                Menu(section(t("toolbar.section_trigger"), state.filters.triggerKinds.count)) {
                    ForEach(Self.triggerKinds.filter { options.triggerKindCounts[$0] != nil }, id: \.self) { kind in
                        toggle(state.filters.triggerKinds.contains(kind), AutopilotsLabels.triggerKind(kind), options.triggerKindCounts[kind] ?? 0) {
                            prefs.state.toggleFilter(.triggerKinds, kind)
                        }
                    }
                }
                Menu(section(t("toolbar.section_mode"), state.filters.modes.count)) {
                    ForEach(Self.modes, id: \.self) { mode in
                        toggle(state.filters.modes.contains(mode), AutopilotsLabels.executionMode(mode), options.modeCounts[mode] ?? 0) {
                            prefs.state.toggleFilter(.modes, mode)
                        }
                    }
                }
                Menu(section(t("toolbar.section_creator"), state.filters.creators.count)) {
                    ForEach(options.creators) { o in
                        toggle(state.filters.creators.contains(o.value), "\(session.actorInfo(type: o.type, id: o.id).name)", o.count) {
                            prefs.state.toggleFilter(.creators, o.value)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease")
                    if wide {
                        Text(activeCount > 0 ? t("toolbar.filter_active_count", ["count": activeCount]) : t("toolbar.filter_label"))
                    } else if activeCount > 0 {
                        Text("\(activeCount)").monospacedDigit()
                    }
                }
                .foregroundStyle(activeCount > 0 ? Color.white : .secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            if activeCount > 0 && wide {
                Button { prefs.state.clearFilters() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t("toolbar.clear_filters"))
                .accessibilityLabel(t("toolbar.clear_filters"))
                .padding(.leading, 4)
            }
        }
        .font(Theme.Font.caption)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(activeCount > 0 ? Theme.brand : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(activeCount > 0 ? .clear : Theme.border))
    }

    private func section(_ label: String, _ n: Int) -> String {
        n > 0 ? "\(label)  (\(n))" : label
    }

    private func toggle(_ on: Bool, _ label: String, _ count: Int, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { _ in action() })) {
            Text("\(label)    \(count)")
        }
    }

    private func displayButton(state: ListState, wide: Bool) -> some View {
        Button { displayOpen.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: state.sortDirection == .asc ? "arrow.up" : "arrow.down")
                if wide { Text(sortLabel(state.sortField)) }
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(PillButtonStyle())
        .help(t("toolbar.display"))
        .popover(isPresented: $displayOpen, arrowEdge: .bottom) { displayPanel }
    }

    private func sortLabel(_ field: ListState.SortField) -> String {
        switch field {
        case .name: return t("page.table.name")
        case .lastRun: return t("page.table.last_run")
        case .nextRun: return t("page.table.next_run")
        case .created: return t("page.table.created")
        }
    }

    private func columnLabel(_ c: ListState.Column) -> String {
        switch c {
        case .assignee: return t("page.table.assignee")
        case .trigger: return t("page.table.trigger")
        case .lastRun: return t("page.table.last_run")
        case .nextRun: return t("page.table.next_run")
        case .mode: return t("page.table.mode")
        case .creator: return t("page.table.created_by")
        case .created: return t("page.table.created")
        }
    }

    private var displayPanel: some View {
        let state = prefs.state
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(t("toolbar.sort_by")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { state.sortField }, set: { prefs.state.setSortField($0) })) {
                        ForEach(ListState.SortField.allCases, id: \.self) { Text(sortLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    Button {
                        prefs.state.sortDirection = state.sortDirection == .asc ? .desc : .asc
                    } label: {
                        Image(systemName: state.sortDirection == .asc ? "arrow.up" : "arrow.down").frame(width: 16)
                    }
                    .help(state.sortDirection == .asc ? t("toolbar.direction_asc") : t("toolbar.direction_desc"))
                }
            }
            .padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(t("toolbar.section_columns")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(ListState.Column.allCases, id: \.self) { c in
                    Toggle(isOn: Binding(get: { state.isVisible(c) }, set: { _ in prefs.state.toggleColumn(c) })) {
                        Text(columnLabel(c)).font(Theme.Font.body).frame(maxWidth: .infinity, alignment: .leading)
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
