import AppKit
import MulticaCore
import SwiftUI

extension IssueDetailStore {
    func categoryOf(_ key: String) -> StatusCategory? {
        let k = IssueStatusKey(rawValue: key)
        return k.builtInCategory ?? session.issues.catalog.entry(for: k)?.category
    }

    /// Upstream runConfirmIntent for this issue.
    func runGate(assignee: ActorRef? = nil, status: IssueStatusKey? = nil) -> IssueDetailRunGate? {
        guard let issue else { return nil }
        return IssueDetailRunGate.intent(currentStatus: issue.status.rawValue, currentCategory: issue.statusCategory,
                                         owner: issue.assignee, newAssignee: assignee, newStatus: status?.rawValue,
                                         categoryOf: categoryOf)
    }

    /// Status write behind the run-confirm gate (upstream updateField).
    func requestStatus(_ key: IssueStatusKey, runConfirm: Binding<IssueDetailRunGate?>, toaster: Toaster) {
        if let gate = runGate(status: key) {
            runConfirm.wrappedValue = gate
        } else {
            Task { await updateStatus(key, toaster: toaster) }
        }
    }

    func requestAssignee(_ ref: ActorRef?, runConfirm: Binding<IssueDetailRunGate?>, toaster: Toaster) {
        if let gate = runGate(assignee: ref) {
            runConfirm.wrappedValue = gate
        } else {
            Task { await updateAssignee(ref, toaster: toaster) }
        }
    }

    func shareURL(nav: Navigator, appURL: URL, commentID: String? = nil) -> String {
        let ref = issue?.identifier.isEmpty == false ? issue!.identifier : issueID
        let base = nav.webURL(.issue(ref), appURL: appURL).absoluteString
        return commentID.map { "\(base)#comment-\($0)" } ?? base
    }
}

struct IssueDetailHeader: View {
    let store: IssueDetailStore
    @Binding var runConfirm: IssueDetailRunGate?

    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(ShellState.self) private var shell
    @Environment(Toaster.self) private var toaster

    var body: some View {
        HStack(spacing: 8) {
            breadcrumb
            Spacer(minLength: 8)
            IssueDetailAgentChip(store: store)
            IssueDetailWakeupChip(store: store) { shell.rightPanelOpen = true }
            Button { Task { await store.togglePin(toaster: toaster) } } label: {
                Image(systemName: store.isPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(store.isPinned ? .primary : .secondary)
            .help(tr("issues", store.isPinned ? "detail.unpin_tooltip" : "detail.pin_tooltip"))
            IssueDetailActionsMenu(store: store, runConfirm: $runConfirm)
            Button { shell.rightPanelOpen.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.borderless)
                .foregroundStyle(shell.rightPanelOpen ? .primary : .secondary)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(shell.rightPanelOpen ? Theme.selected : .clear))
                .help(tr("issues", "detail.sidebar_tooltip"))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Divider() }
        .task { await session.pins.loadIfNeeded() }
    }

    @ViewBuilder private var breadcrumb: some View {
        if let issue = store.issue {
            HStack(spacing: 6) {
                if let parentID = issue.parentIssueID, let parent = session.issues.model(parentID)?.issue {
                    Button(parent.identifier) { nav.push(.issue(parent.id), title: parent.identifier) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    chevron
                } else if let projectID = issue.projectID, let project = session.projects.item(projectID) {
                    Button { nav.push(.project(project.id), title: project.title) } label: {
                        HStack(spacing: 4) {
                            ProjectIconView(icon: project.icon, size: 13)
                            Text(project.title).lineLimit(1)
                        }
                        .frame(maxWidth: 280, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    chevron
                }
                Button { nav.push(.issue(issue.id), title: issue.identifier) } label: {
                    Text("\(issue.identifier) \(issue.title)").font(Theme.Font.bodyMedium).lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
            }
            .font(Theme.Font.body)
            .task(id: issue.projectID) { if issue.projectID != nil { await session.projects.loadIfNeeded() } }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
    }
}

/// Upstream IssueDetailActionsDropdown + issue-actions-menu-items.
struct IssueDetailActionsMenu: View {
    let store: IssueDetailStore
    @Binding var runConfirm: IssueDetailRunGate?

    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(ModalCenter.self) private var modals
    @Environment(Toaster.self) private var toaster
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @State private var assigneeOpen = false

    var body: some View {
        Menu {
            if let issue = store.issue { items(issue) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(isPresented: $assigneeOpen, arrowEdge: .bottom) {
            IssueDetailAssigneeList(current: store.issue?.assignee) { ref in
                assigneeOpen = false
                store.requestAssignee(ref, runConfirm: $runConfirm, toaster: toaster)
            }
        }
    }

    @ViewBuilder private func items(_ issue: Issue) -> some View {
        let catalog = session.issues.catalog
        Menu {
            ForEach(catalog.entries, id: \.key) { e in
                Button {
                    store.requestStatus(e.key, runConfirm: $runConfirm, toaster: toaster)
                } label: {
                    Text(catalog.localizedName(for: e.key) + (issue.status == e.key ? "  ✓" : ""))
                }
            }
        } label: { Label(tr("issues", "actions.status"), systemImage: "circle.dashed") }
        Menu {
            ForEach(IssuePriority.displayOrder, id: \.self) { p in
                Button(p.localizedName + (issue.priority == p ? "  ✓" : "")) {
                    Task { await store.updatePriority(p, toaster: toaster) }
                }
            }
        } label: { Label(tr("issues", "actions.priority"), systemImage: "chart.bar") }
        Button { assigneeOpen = true } label: { Label(tr("issues", "actions.assignee"), systemImage: "person.crop.circle") }
        dateMenu(field: "start_date", title: "actions.start_date", icon: "calendar.badge.clock", keys: ("start_today", "start_tomorrow", "start_next_week", "start_clear"), current: issue.startDate)
        dateMenu(field: "due_date", title: "actions.due_date", icon: "calendar", keys: ("due_today", "due_tomorrow", "due_next_week", "due_clear"), current: issue.dueDate)
        Divider()
        Button { nav.openInNewTab(.issue(issue.identifier.isEmpty ? issue.id : issue.identifier), title: issue.identifier) } label: {
            Label(tr("issues", "actions.open_in_new_tab"), systemImage: "arrow.up.forward.square")
        }
        Button { openWindow(id: "issue", value: IssueWindowTarget(slug: nav.slug, issueID: issue.id)) } label: {
            Label(trd("issues", "actions.open_in_new_window", "Open in new window"), systemImage: "macwindow.badge.plus")
        }
        Button { Task { await store.togglePin(toaster: toaster) } } label: {
            Label(tr("issues", store.isPinned ? "actions.unpin_from_sidebar" : "actions.pin_to_sidebar"), systemImage: store.isPinned ? "pin.slash" : "pin")
        }
        Button {
            IssueDetailFiles.copy(store.shareURL(nav: nav, appURL: env.app.config.appURL))
            toaster.success(tr("issues", "detail.link_copied"))
        } label: { Label(tr("issues", "actions.copy_link"), systemImage: "link") }
        Button {
            IssueDetailFiles.copy(issue.identifier)
            toaster.success(tr("issues", "comment.copied_toast"))
        } label: { Label(tr("search", "copy_identifier", ["identifier": issue.identifier]), systemImage: "number") }
        workdirButton
        Divider()
        Menu {
            Button { modals.createIssue(subIssueDraft(issue)) } label: { Label(tr("issues", "actions.create_sub_issue"), systemImage: "plus") }
            Button { modals.present(.setParentIssue(issueID: issue.id)) } label: { Label(tr("issues", "actions.set_parent_issue"), systemImage: "arrow.up") }
            if issue.parentIssueID != nil {
                Button { Task { await store.removeParent(toaster: toaster) } } label: {
                    Label(tr("issues", "actions.remove_parent_issue"), systemImage: "link.badge.plus")
                }
            }
            Button { modals.present(.addChildIssue(parentID: issue.id)) } label: { Label(tr("issues", "actions.add_sub_issue"), systemImage: "arrow.down") }
            Button { modals.present(.markDuplicateIssue(issueID: issue.id)) } label: { Label(tr("issues", "actions.mark_duplicate"), systemImage: "equal.circle") }
        } label: { Label(tr("issues", "actions.relations"), systemImage: "point.3.connected.trianglepath.dotted") }
        Divider()
        Button(role: .destructive) { modals.present(.deleteIssues(issueIDs: [issue.id])) } label: {
            Label(tr("issues", "actions.delete_issue"), systemImage: "trash")
        }
    }

    @ViewBuilder private var workdirButton: some View {
        let target = IssueDetailFormat.workdirTarget(store.tasks)
        Button {
            guard let target else {
                toaster.error(tr("issues", "detail.workdir_path_unavailable"))
                return
            }
            IssueDetailFiles.copy(target.path)
            if target.isProjectDirectory {
                toaster.success(target.branchName.map { tr("issues", "detail.project_directory_path_copied_with_branch", ["branch": $0]) }
                                ?? tr("issues", "detail.project_directory_path_copied"))
            } else {
                toaster.success(tr("issues", "detail.workdir_path_copied"))
            }
        } label: {
            Label(tr("issues", target?.isProjectDirectory == true ? "actions.copy_project_directory_path" : "actions.copy_workdir_path"), systemImage: "folder")
        }
    }

    @ViewBuilder private func dateMenu(field: String, title: String, icon: String, keys: (String, String, String, String), current: String?) -> some View {
        Menu {
            Button(tr("issues", "actions.\(keys.0)")) { Task { await store.updateDate(field, IssueDetailDates.dateOnly(addingDays: 0), toaster: toaster) } }
            Button(tr("issues", "actions.\(keys.1)")) { Task { await store.updateDate(field, IssueDetailDates.dateOnly(addingDays: 1), toaster: toaster) } }
            Button(tr("issues", "actions.\(keys.2)")) { Task { await store.updateDate(field, IssueDetailDates.dateOnly(addingDays: 7), toaster: toaster) } }
            if current != nil {
                Divider()
                Button(tr("issues", "actions.\(keys.3)")) { Task { await store.updateDate(field, nil, toaster: toaster) } }
            }
        } label: { Label(tr("issues", title), systemImage: icon) }
    }

    private func subIssueDraft(_ issue: Issue) -> CreateIssueDraft {
        var d = CreateIssueDraft()
        d.parentIssueID = issue.id
        d.projectID = issue.projectID
        d.assignee = issue.assignee
        return d
    }
}

/// The assignee option list (members, agents with a runtime, squads) for
/// entry points that are not the sidebar picker.
struct IssueDetailAssigneeList: View {
    @Environment(WorkspaceSession.self) private var session
    let current: ActorRef?
    let onPick: (ActorRef?) -> Void

    var body: some View {
        OptionList(options: options, selected: current.map { ["\($0.type):\($0.id)"] } ?? ["none"],
                   searchPlaceholder: tr("issues", "pickers.assignee.search_placeholder")) { key in
            if key == "none" { onPick(nil); return }
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            onPick(ActorRef(type: parts[0], id: parts[1]))
        }
        .task { await session.squads.loadIfNeeded() }
    }

    private var options: [PickerOption<String>] {
        var out: [PickerOption<String>] = [
            PickerOption(id: "none", title: tr("issues", "pickers.assignee.trigger_unassigned"),
                         icon: AnyView(Image(systemName: "person.crop.circle.dashed").foregroundStyle(.secondary))),
        ]
        let members = tr("issues", "pickers.assignee.members_group")
        for m in session.directory.members {
            out.append(PickerOption(id: "member:\(m.userID)", title: m.name, group: members,
                                    icon: AnyView(AvatarView(name: m.name, url: m.avatarURL, size: 16))))
        }
        let agents = tr("issues", "pickers.assignee.agents_group")
        for a in session.directory.agents where a.archivedAt == nil {
            let bound = !a.runtimeID.isEmpty
            out.append(PickerOption(id: "agent:\(a.id)", title: a.name, group: agents, disabled: !bound,
                                    help: bound ? nil : tr("issues", "pickers.assignee.agent_runtime_required"),
                                    icon: AnyView(AvatarView(name: a.name, url: a.avatarURL, kind: .agent, size: 16))))
        }
        let squads = tr("issues", "pickers.assignee.squads_group")
        for s in session.squads.items where s.archivedAt == nil {
            out.append(PickerOption(id: "squad:\(s.id)", title: s.name, group: squads,
                                    icon: AnyView(AvatarView(name: s.name, url: s.avatarUrl, kind: .squad, size: 16))))
        }
        return out
    }
}

/// Upstream IssueAgentHeaderChip: who is working on the issue right now,
/// with a popover of active runs (transcript, stop).
struct IssueDetailAgentChip: View {
    @Environment(WorkspaceSession.self) private var session
    let store: IssueDetailStore
    @State private var open = false

    var body: some View {
        let active = store.activeTasks
        if !active.isEmpty {
            let agentIDs = active.map(\.agentId).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let running = active.contains { $0.status == "running" }
            let label = agentIDs.count == 1
                ? tr("issues", running ? "agent_live.is_working" : "agent_live.is_queued", ["name": session.actorInfo(type: "agent", id: agentIDs[0]).name])
                : tr("issues", running ? "agent_activity.hover_header" : "agent_activity.hover_header_queued", ["count": agentIDs.count])
            HStack(spacing: 8) {
                Button { open.toggle() } label: {
                    HStack(spacing: 6) {
                        IssueDetailAvatarStack(actors: agentIDs.prefix(3).map { ActorRef(type: "agent", id: $0) }, max: 3, size: 16)
                            .opacity(running ? 1 : 0.5)
                        Text(label).font(Theme.Font.caption).foregroundStyle(running ? Theme.info : .secondary).lineLimit(1)
                        if running { RunningIndicator(count: 1) }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .frame(maxWidth: 200)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(running ? Theme.brand.opacity(0.06) : .clear))
                }
                .buttonStyle(.plain)
                .help(label)
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("issues", running ? "agent_activity.hover_header" : "agent_activity.hover_header_queued", ["count": agentIDs.count]))
                            .font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                        ForEach(active, id: \.id) { task in IssueDetailActiveTaskRow(store: store, task: task) }
                    }
                    .padding(12)
                    .frame(width: 320)
                }
                Divider().frame(height: 16)
            }
        }
    }
}

/// Upstream ActiveTaskRow (execution log + header chip).
struct IssueDetailActiveTaskRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    let task: AgentTaskRecord
    @State private var transcript = false
    @State private var confirmStop = false

    var body: some View {
        HStack(spacing: 8) {
            ActorAvatar(type: "agent", id: task.agentId, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(Theme.Font.caption.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(IssueDetailRunText.status(task.status))
                    IssueDetailElapsed(start: task.startedAt ?? task.dispatchedAt ?? task.createdAt, end: nil)
                }
                .font(Theme.Font.micro).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { transcript = true } label: { Image(systemName: "text.alignleft") }
                .buttonStyle(.borderless)
                .help(tr("issues", "execution_log.transcript_tooltip"))
            Button { confirmStop = true } label: { Image(systemName: "stop.circle") }
                .buttonStyle(.borderless)
                .help(tr("issues", "execution_log.cancel_task_tooltip"))
        }
        .padding(.vertical, 3)
        .sheet(isPresented: $transcript) { IssueDetailTranscriptSheet(store: store, taskID: task.id) }
        .modifier(IssueDetailStopConfirm(isPresented: $confirmStop, running: task.status != "queued") {
            Task { await store.cancelTask(task.id, toaster: toaster) }
        })
    }

    private var headline: String {
        let name = session.actorInfo(type: "agent", id: task.agentId).name
        switch task.status {
        case "running": return tr("issues", "agent_live.is_working", ["name": name])
        case "waiting_local_directory": return tr("issues", "agent_live.is_waiting_local_directory", ["name": name])
        default: return tr("issues", "agent_live.is_queued", ["name": name])
        }
    }
}

/// Upstream IssueWakeupHeaderChip: what the issue is waiting for.
struct IssueDetailWakeupChip: View {
    @Environment(WorkspaceSession.self) private var session
    let store: IssueDetailStore
    let onOpen: () -> Void

    var body: some View {
        Group {
            if let primary {
                Button(action: onOpen) {
                    HStack(spacing: 5) {
                        Image(systemName: primary.paused ? "exclamationmark.triangle" : "bell").font(.system(size: 11))
                        Text(primary.label).lineLimit(1)
                        if primary.count > 1 { Text("+\(primary.count - 1)").foregroundStyle(.secondary).monospacedDigit() }
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(primary.paused ? Theme.warning : .primary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .frame(maxWidth: 280)
                    .overlay(Capsule().strokeBorder(Theme.border))
                }
                .buttonStyle(.plain)
                .help(primary.label + " · " + tr("issues", "wakeups.wait.open"))
            }
        }
        .task(id: session.revision("issue_wakeup") &+ session.revision("wakeup")) { await store.loadWakeups() }
    }

    private var primary: (label: String, count: Int, paused: Bool)? {
        let rules = store.wakeups ?? []
        let names = session.issueDetailNames
        let enabled = rules.filter(\.enabled)
        let waiting = enabled.filter { $0.kind == "event" }
        let scheduled = enabled.filter { $0.kind != "event" }.sorted { ($0.nextFireAt ?? "") < ($1.nextFireAt ?? "") }
        let systemRule = store.systemWakeups.first { $0.enabled && $0.blocked.isEmpty && $0.target != nil }
        let count = enabled.count + (systemRule == nil ? 0 : 1)
        if let rule = waiting.first ?? scheduled.first {
            return (IssueDetailWakeups.spec(rule).headline(names), count, false)
        }
        if let s = systemRule {
            let what = s.staged && s.stage != nil
                ? tr("issues", "wakeups.wait.children_stage", ["stage": s.stage ?? 0])
                : tr("issues", "wakeups.wait.children_all")
            return (tr("issues", "wakeups.wait.header", ["agent": s.target?["name"]?.stringValue ?? "", "what": what]), count, false)
        }
        if rules.contains(where: { !$0.enabled && $0.pausedReason != nil }) {
            return (tr("issues", "wakeups.wait.paused"), 1, true)
        }
        return nil
    }
}

enum IssueDetailWakeups {
    static func spec(_ w: IssueWakeup) -> IssueDetailWakeupSpec {
        IssueDetailWakeupSpec(kind: w.kind, mode: w.mode, eventTypes: w.eventTypes, agentID: w.agentId,
                              intervalSeconds: w.intervalSeconds, nextFireAt: w.nextFireAt, condition: w.condition,
                              filterActorType: w.filterActorType, filterActorID: w.filterActorId, filterAgentID: w.filterAgentId)
    }
}

/// Upstream TerminateTaskConfirmDialog.
struct IssueDetailStopConfirm: ViewModifier {
    @Binding var isPresented: Bool
    var running = true
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.alert(tr("issues", "terminate_dialog.title"), isPresented: $isPresented) {
            Button(tr("issues", "terminate_dialog.keep"), role: .cancel) {}
            Button(tr("issues", "terminate_dialog.confirm"), role: .destructive, action: onConfirm)
        } message: {
            Text(tr("issues", "terminate_dialog.body") + (running ? tr("issues", "terminate_dialog.running_note") : ""))
        }
    }
}

/// Upstream RunConfirmModal, local to the detail page because the shared
/// `.runConfirm(issueID:)` registry case carries no pending change.
struct IssueDetailRunConfirmSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let store: IssueDetailStore
    let intent: IssueDetailRunGate
    @State private var pending: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("modals", isPromote ? "run_confirm.title_promote" : "run_confirm.title_assign")).font(Theme.Font.title)
            Text(message).font(Theme.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button {
                    submit(suppress: true)
                } label: {
                    if pending == true { ProgressView().controlSize(.small) } else { Text(tr("modals", "run_confirm.dont_start")) }
                }
                .disabled(pending != nil)
                Button {
                    submit(suppress: false)
                } label: {
                    if pending == false { ProgressView().controlSize(.small) } else {
                        Text(tr("modals", isPromote ? "run_confirm.confirm_promote" : "run_confirm.confirm_assign"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pending != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var isPromote: Bool {
        if case .promote = intent { return true }
        return false
    }

    private var message: String {
        switch intent {
        case .assign(let type, let id):
            return tr("modals", "run_confirm.assign_single", ["name": session.actorInfo(type: type, id: id).name])
        case .promote(let status, let type, let id):
            return tr("modals", "run_confirm.promote_single", [
                "status": session.issues.catalog.localizedName(for: IssueStatusKey(rawValue: status)),
                "name": session.actorInfo(type: type, id: id).name,
            ])
        }
    }

    private func submit(suppress: Bool) {
        pending = suppress
        var fields: [String: JSONValue]
        var change: (inout Issue) -> Void
        switch intent {
        case .assign(let type, let id):
            fields = ["assignee_type": JSONValue(type), "assignee_id": JSONValue(id)]
            change = { $0.assignee = ActorRef(type: type, id: id) }
        case .promote(let status, _, _):
            fields = ["status": JSONValue(status)]
            change = { $0.status = IssueStatusKey(rawValue: status) }
        }
        if suppress { fields["suppress_run"] = true }
        Task {
            let ok = await store.update(fields, optimistic: change)
            pending = nil
            if ok { dismiss() } else { toaster.error(tr("modals", "run_confirm.toast_failed")) }
        }
    }
}
