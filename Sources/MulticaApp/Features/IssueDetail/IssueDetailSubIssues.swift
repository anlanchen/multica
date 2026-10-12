import AppKit
import MulticaCore
import SwiftUI

/// Which built-in fields sub-issue rows show (upstream SubIssueDisplay
/// store, per user), plus opted-in custom properties.
struct IssueDetailSubIssueDisplay: Codable, Equatable {
    var priority = true
    var labels = true
    var childProgress = true
    var dueDate = true
    var assignee = true
    var propertyIDs: [String] = []

    static let key = "multica.subIssueDisplay.v1"

    static func load() -> IssueDetailSubIssueDisplay {
        guard let data = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode(IssueDetailSubIssueDisplay.self, from: data) else { return IssueDetailSubIssueDisplay() }
        return v
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension IssueDetailStore {
    /// Field update for any issue (sub-issue rows), optimistic on the shared
    /// row model.
    func updateOther(_ id: String, _ fields: [String: JSONValue], optimistic: @escaping (inout Issue) -> Void, toaster: Toaster) async {
        let previous = session.issues.patch(id) { var i = $0; optimistic(&i); return i }
        do {
            let fetched = try await session.api.issueDetailUpdate(id, fields: fields)
            session.issues.upsert(fetched.issue)
            await loadChildren()
        } catch {
            if let previous { session.issues.restore(previous) }
            toaster.error((error as? APIError)?.message ?? tr("issues", "detail.update_failed"))
        }
    }

    func batchUpdateChildren(_ fields: [String: JSONValue], toaster: Toaster) async {
        let ids = Array(selectedChildren)
        guard !ids.isEmpty else { return }
        var record = UpdateIssueRequestRecord()
        record.status = fields["status"]?.stringValue
        record.priority = fields["priority"]?.stringValue
        record.assigneeType = fields["assignee_type"]?.stringValue
        record.assigneeId = fields["assignee_id"]?.stringValue
        do {
            let n: Int
            if fields.keys.contains("assignee_type") && fields["assignee_type"]?.isNull == true {
                let v: JSONValue = try await session.api.call(.post, "/api/issues/batch-update",
                                                              body: ["issue_ids": JSONValue(ids), "updates": JSONValue.object(fields)] as JSONValue)
                n = v["updated"]?.doubleValue.map { Int($0) } ?? ids.count
            } else {
                n = try await session.api.batchUpdateIssues(ids, updates: record)
            }
            toaster.success(tr("issues", "batch.update_success", ["count": n]))
            selectedChildren.removeAll()
            await loadChildren()
        } catch {
            toaster.error(tr("issues", "batch.update_failed"))
        }
    }
}

/// Upstream sub-issues block: "Add sub-issues" when empty, else the header
/// (collapse, progress, working chip, select-all, display, add), the inline
/// batch toolbar and the rows grouped by stage.
struct IssueDetailSubIssues: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(ModalCenter.self) private var modals
    let store: IssueDetailStore
    let parent: Issue
    @Binding var runConfirm: IssueDetailRunGate?
    @State private var display = IssueDetailSubIssueDisplay.load()
    @State private var hovering = false

    var body: some View {
        if let children = store.children {
            if children.isEmpty {
                Button { modals.createIssue(draft) } label: {
                    Label(tr("issues", "detail.add_sub_issues"), systemImage: "plus").font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 24)
            } else {
                content(children).padding(.top, 40)
            }
        }
    }

    private var draft: CreateIssueDraft {
        var d = CreateIssueDraft()
        d.parentIssueID = parent.id
        d.projectID = parent.projectID
        d.assignee = parent.assignee
        return d
    }

    @ViewBuilder private func content(_ children: [Issue]) -> some View {
        let catalog = session.issues.catalog
        let live = children.map { session.issues.model($0.id)?.issue ?? $0 }
        let done = live.filter { $0.category(in: catalog) == .done }.count
        let selected = store.selectedChildren.intersection(live.map(\.id))
        let working = live.reduce(0) { $0 + (session.issues.model($1.id)?.activeRuns ?? 0) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { store.subIssuesCollapsed.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(store.subIssuesCollapsed ? -90 : 0))
                        Text(tr("issues", "detail.sub_issues_label")).font(Theme.Font.bodyMedium)
                    }
                }
                .buttonStyle(.plain)
                IssueDetailProgressChip(done: done, total: live.count)
                if working > 0 {
                    HStack(spacing: 4) {
                        RunningIndicator(count: 1)
                        Text(tr("issues", "agent_activity.chip_agents_working", ["count": working])).font(Theme.Font.micro).foregroundStyle(Theme.info)
                    }
                }
                Toggle("", isOn: Binding(
                    get: { !selected.isEmpty && selected.count == live.count },
                    set: { on in if on { store.selectedChildren.formUnion(live.map(\.id)) } else { store.selectedChildren.subtract(live.map(\.id)) } }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .opacity(!selected.isEmpty || hovering ? 1 : 0)
                    .help(tr("issues", "detail.select_all_sub_issues_aria"))
                Spacer()
                IssueDetailSubIssueDisplayButton(display: $display)
                Button { modals.createIssue(draft) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help(tr("issues", "detail.add_sub_issue_tooltip"))
            }
            if !selected.isEmpty {
                IssueDetailSubIssueBatchBar(store: store, count: selected.count)
            }
            if !store.subIssuesCollapsed {
                let staged = live.contains { store.childRecords[$0.id]?.stage != nil }
                let groups = IssueDetailFormat.groupByStage(live) { store.childRecords[$0.id]?.stage }
                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                        if staged {
                            Text(group.stage.map { tr("issues", "stage.value", ["n": $0]) } ?? tr("issues", "stage.none"))
                                .font(Theme.Font.micro.weight(.medium))
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04))
                        }
                        ForEach(group.items, id: \.id) { child in
                            if child.id != group.items.first?.id || staged || index > 0 { Divider().opacity(0.6) }
                            IssueDetailSubIssueRow(store: store, child: child, record: store.childRecords[child.id],
                                                   progress: store.childProgress[child.id], display: display,
                                                   selected: store.selectedChildren.contains(child.id))
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            }
        }
        .onHover { hovering = $0 }
        .onChange(of: display) { display.save() }
        .onChange(of: store.issueID) { store.selectedChildren.removeAll() }
    }
}

/// Upstream SubIssueRow: priority/checkbox slot, status picker, link,
/// labels, custom-property chips, nested progress, due date, assignee;
/// right-click for the issue actions.
struct IssueDetailSubIssueRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    @Environment(ModalCenter.self) private var modals
    @Environment(AppEnvironment.self) private var env
    let store: IssueDetailStore
    let child: Issue
    let record: IssueRecord?
    let progress: ChildProgress?
    let display: IssueDetailSubIssueDisplay
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let catalog = session.issues.catalog
        let finished = child.status.issueDetailIsFinished(catalog)
        HStack(spacing: 10) {
            ZStack {
                if display.priority && !(hovering || selected) { PriorityIcon(priority: child.priority) }
                if hovering || selected {
                    Toggle("", isOn: Binding(get: { selected }, set: { on in
                        if on { store.selectedChildren.insert(child.id) } else { store.selectedChildren.remove(child.id) }
                    }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(tr("issues", "detail.select_sub_issue_aria", ["identifier": child.identifier]))
                }
            }
            .frame(width: 16, height: 16)
            StatusPicker(current: child.status, showLabel: false, style: nil) { key in
                Task { await store.updateOther(child.id, ["status": JSONValue(key.rawValue)], optimistic: { $0.status = key }, toaster: toaster) }
            }
            Button { nav.push(.issue(child.id), title: child.identifier) } label: {
                HStack(spacing: 8) {
                    Text(child.identifier).font(Theme.Font.micro.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                    if let m = session.issues.model(child.id), m.activeRuns > 0 { RunningIndicator(count: m.activeRuns) }
                    Text(child.title).font(Theme.Font.body).foregroundStyle(finished ? .secondary : .primary).lineLimit(1)
                    if display.labels && !child.labels.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(child.labels.prefix(2)) { LabelChip(label: $0) }
                            if child.labels.count > 2 { Text("+\(child.labels.count - 2)").font(Theme.Font.micro).foregroundStyle(.secondary) }
                        }
                    }
                    customChips
                    if display.childProgress, let p = progress, p.total > 0 {
                        IssueDetailProgressChip(done: p.done, total: p.total)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if display.dueDate, let due = child.dueDate {
                let overdue = !finished && IssueDetailDates.isPast(due)
                DateOnlyPicker(value: due, label: tr("issues", "pickers.due_date.trigger_label"), noneLabel: tr("issues", "pickers.due_date.none")) { v in
                    Task { await store.updateOther(child.id, ["due_date": JSONValue(v)], optimistic: { $0.dueDate = v }, toaster: toaster) }
                }
                .foregroundStyle(overdue ? Theme.destructive : .secondary)
            }
            if display.assignee {
                AssigneePicker(current: child.assignee, showLabel: false, style: nil) { ref in
                    Task {
                        await store.updateOther(child.id, ["assignee_type": JSONValue(ref?.type), "assignee_id": JSONValue(ref?.id)],
                                                optimistic: { $0.assignee = ref }, toaster: toaster)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selected ? Theme.selected : (hovering ? Theme.hover : .clear))
        .onHover { hovering = $0 }
        .contextMenu { IssueDetailIssueContextMenu(store: store, issue: child) }
    }

    @ViewBuilder private var customChips: some View {
        let props = display.propertyIDs.compactMap { id in session.properties.items.first { $0.id == id && !$0.archived } }
            .filter { record?.properties[$0.id] != nil }
        if !props.isEmpty {
            HStack(spacing: 4) {
                ForEach(props.prefix(3)) { p in
                    HStack(spacing: 3) {
                        IssueDetailPropertyIcon(property: p)
                        Text(IssueDetailPropertyValueText.text(p, record?.properties[p.id], session: session)).lineLimit(1)
                    }
                    .font(Theme.Font.micro)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .frame(maxWidth: 120)
                }
            }
        }
    }
}

enum IssueDetailPropertyValueText {
    @MainActor
    static func text(_ p: IssueProperty, _ v: JSONValue?, session: WorkspaceSession) -> String {
        guard let v, !v.isNull else { return "" }
        switch p.type {
        case "select": return p.config?.options?.first { $0.id == v.stringValue }?.name ?? ""
        case "multi_select":
            let ids = v.arrayValue?.compactMap(\.stringValue) ?? []
            return (p.config?.options ?? []).filter { ids.contains($0.id) }.map(\.name).joined(separator: ", ")
        case "checkbox": return tr("issues", v.boolValue == true ? "pickers.custom_property.true_label" : "pickers.custom_property.false_label")
        case "date": return IssueDetailDates.short(v.stringValue)
        case "actor", "multi_actor":
            let raw = v.arrayValue?.compactMap(\.stringValue) ?? v.stringValue.map { [$0] } ?? []
            return raw.compactMap { $0.hasPrefix("member:") ? session.actorInfo(type: "member", id: String($0.dropFirst(7))).name : nil }.joined(separator: ", ")
        case "multi_text", "multi_url": return (v.arrayValue?.compactMap(\.stringValue) ?? []).joined(separator: ", ")
        default: return v.stringValue ?? v.preview(limit: 40)
        }
    }
}

/// Right-click issue actions for sub-issue rows (upstream
/// IssueActionsContextMenu).
struct IssueDetailIssueContextMenu: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    @Environment(ModalCenter.self) private var modals
    @Environment(AppEnvironment.self) private var env
    let store: IssueDetailStore
    let issue: Issue

    var body: some View {
        let catalog = session.issues.catalog
        Menu(tr("issues", "actions.status")) {
            ForEach(catalog.entries, id: \.key) { e in
                Button(catalog.localizedName(for: e.key) + (issue.status == e.key ? "  ✓" : "")) {
                    Task { await store.updateOther(issue.id, ["status": JSONValue(e.key.rawValue)], optimistic: { $0.status = e.key }, toaster: toaster) }
                }
            }
        }
        Menu(tr("issues", "actions.priority")) {
            ForEach(IssuePriority.displayOrder, id: \.self) { p in
                Button(p.localizedName + (issue.priority == p ? "  ✓" : "")) {
                    Task { await store.updateOther(issue.id, ["priority": JSONValue(p.rawValue)], optimistic: { $0.priority = p }, toaster: toaster) }
                }
            }
        }
        Menu(tr("issues", "actions.due_date")) {
            Button(tr("issues", "actions.due_today")) { setDue(0) }
            Button(tr("issues", "actions.due_tomorrow")) { setDue(1) }
            Button(tr("issues", "actions.due_next_week")) { setDue(7) }
            if issue.dueDate != nil {
                Button(tr("issues", "actions.due_clear")) {
                    Task { await store.updateOther(issue.id, ["due_date": .null], optimistic: { $0.dueDate = nil }, toaster: toaster) }
                }
            }
        }
        Divider()
        Button(tr("issues", "actions.open_in_new_tab")) { nav.openInNewTab(.issue(issue.id), title: issue.identifier) }
        Button(tr("issues", "actions.copy_link")) {
            let base = nav.webURL(.issue(issue.identifier.isEmpty ? issue.id : issue.identifier), appURL: env.app.config.appURL).absoluteString
            IssueDetailFiles.copy(base)
            toaster.success(tr("issues", "detail.link_copied"))
        }
        Divider()
        Button(tr("issues", "actions.set_parent_issue")) { modals.present(.setParentIssue(issueID: issue.id)) }
        Button(tr("issues", "actions.remove_parent_issue")) {
            Task {
                await store.updateOther(issue.id, ["parent_issue_id": .null, "stage": .null], optimistic: { $0.parentIssueID = nil }, toaster: toaster)
                toaster.success(tr("issues", "actions.remove_parent_issue_success"))
            }
        }
        Divider()
        Button(tr("issues", "actions.delete_issue"), role: .destructive) { modals.present(.deleteIssues(issueIDs: [issue.id])) }
    }

    private func setDue(_ days: Int) {
        let v = IssueDetailDates.dateOnly(addingDays: days)
        Task { await store.updateOther(issue.id, ["due_date": JSONValue(v)], optimistic: { $0.dueDate = v }, toaster: toaster) }
    }
}

/// Inline batch toolbar for selected sub-issues (upstream
/// BatchActionToolbar placement="inline").
private struct IssueDetailSubIssueBatchBar: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(ModalCenter.self) private var modals
    let store: IssueDetailStore
    let count: Int
    @State private var assigneeOpen = false

    var body: some View {
        let catalog = session.issues.catalog
        HStack(spacing: 8) {
            Text(tr("issues", "batch.selected", ["count": count])).font(Theme.Font.caption.weight(.medium))
            Menu(tr("issues", "batch.status")) {
                ForEach(catalog.entries, id: \.key) { e in
                    Button(catalog.localizedName(for: e.key)) { Task { await store.batchUpdateChildren(["status": JSONValue(e.key.rawValue)], toaster: toaster) } }
                }
            }
            .fixedSize()
            Menu(tr("issues", "batch.priority")) {
                ForEach(IssuePriority.displayOrder, id: \.self) { p in
                    Button(p.localizedName) { Task { await store.batchUpdateChildren(["priority": JSONValue(p.rawValue)], toaster: toaster) } }
                }
            }
            .fixedSize()
            Button(tr("issues", "batch.assignee")) { assigneeOpen = true }
                .popover(isPresented: $assigneeOpen, arrowEdge: .bottom) {
                    IssueDetailAssigneeList(current: nil) { ref in
                        assigneeOpen = false
                        Task { await store.batchUpdateChildren(["assignee_type": JSONValue(ref?.type), "assignee_id": JSONValue(ref?.id)], toaster: toaster) }
                    }
                }
            Button(tr("issues", "batch.delete"), role: .destructive) {
                modals.present(.deleteIssues(issueIDs: Array(store.selectedChildren)))
            }
            Spacer()
            Button { store.selectedChildren.removeAll() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(tr("issues", "batch.cancel"))
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.brand.opacity(0.06)))
    }
}

/// Upstream SubIssueDisplayPopover: which properties sub-issue rows show.
private struct IssueDetailSubIssueDisplayButton: View {
    @Environment(WorkspaceSession.self) private var session
    @Binding var display: IssueDetailSubIssueDisplay
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "slider.horizontal.3") }
            .buttonStyle(.borderless)
            .help(tr("issues", "display.tooltip"))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    toggle("display.card_priority", $display.priority)
                    toggle("display.card_labels", $display.labels)
                    toggle("display.card_child_progress", $display.childProgress)
                    toggle("display.card_due_date", $display.dueDate)
                    toggle("display.card_assignee", $display.assignee)
                    let props = session.properties.items.filter { !$0.archived }
                    ForEach(props) { p in
                        Toggle(isOn: Binding(get: { display.propertyIDs.contains(p.id) }, set: { on in
                            if on { display.propertyIDs.append(p.id) } else { display.propertyIDs.removeAll { $0 == p.id } }
                        })) {
                            HStack(spacing: 5) {
                                IssueDetailPropertyIcon(property: p)
                                Text(p.name).lineLimit(1)
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                }
                .font(Theme.Font.body)
                .padding(12)
                .frame(width: 224)
            }
    }

    private func toggle(_ key: String, _ binding: Binding<Bool>) -> some View {
        Toggle(tr("issues", key), isOn: binding).toggleStyle(.switch).controlSize(.mini)
    }
}
