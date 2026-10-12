import AppKit
import MulticaCore
import SwiftUI

/// Every right-click action on an issue row or card (upstream
/// issue-actions-menu-items.tsx). The assignee picker becomes a submenu: a
/// context menu cannot host the anchored picker popover.
struct IssueListActionsMenu: View {
    let issue: Issue
    let model: IssueListSurfaceModel

    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(ModalCenter.self) private var modals
    @Environment(Toaster.self) private var toaster
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            ForEach(IssueListStatusColumns.options(entries: session.issueListStatusEntries), id: \.self) { key in
                Button {
                    var p = IssueListPatch()
                    p.status = key
                    model.updateField(issue, p)
                } label: {
                    Text(session.issueListStatusLabel(key) + (issue.status == key ? "  ✓" : ""))
                }
            }
        } label: {
            Label(tr("issues", "actions.status"), systemImage: "circle.dashed")
        }
        Menu {
            ForEach(IssuePriority.displayOrder, id: \.self) { p in
                Button {
                    var patch = IssueListPatch()
                    patch.priority = p
                    model.updateField(issue, patch)
                } label: {
                    Text(p.localizedName + (issue.priority == p ? "  ✓" : ""))
                }
            }
        } label: {
            Label(tr("issues", "actions.priority"), systemImage: "cellularbars")
        }
        Menu {
            Button(tr("issues", "actions.unassigned") + (issue.assignee == nil ? "  ✓" : "")) { assign(nil) }
            Section(tr("issues", "pickers.assignee.members_group")) {
                ForEach(session.directory.members) { m in
                    Button(m.name + (issue.assignee == ActorRef(type: "member", id: m.userID) ? "  ✓" : "")) {
                        assign(ActorRef(type: "member", id: m.userID))
                    }
                }
            }
            Section(tr("issues", "pickers.assignee.agents_group")) {
                ForEach(session.directory.agents.filter { $0.archivedAt == nil }) { a in
                    Button(a.name + (issue.assignee == ActorRef(type: "agent", id: a.id) ? "  ✓" : "")) {
                        assign(ActorRef(type: "agent", id: a.id))
                    }
                    .disabled(a.runtimeID.isEmpty)
                }
            }
            let squads = session.squads.items.filter { $0.archivedAt == nil }
            if !squads.isEmpty {
                Section(tr("issues", "pickers.assignee.squads_group")) {
                    ForEach(squads) { s in
                        Button(s.name + (issue.assignee == ActorRef(type: "squad", id: s.id) ? "  ✓" : "")) {
                            assign(ActorRef(type: "squad", id: s.id))
                        }
                    }
                }
            }
        } label: {
            Label(tr("issues", "actions.assignee"), systemImage: "person.crop.circle")
        }
        Menu {
            Button(tr("issues", "actions.start_today")) { setStart(IssueListQuery.day(offset: 0)) }
            Button(tr("issues", "actions.start_tomorrow")) { setStart(IssueListQuery.day(offset: 1)) }
            Button(tr("issues", "actions.start_next_week")) { setStart(IssueListQuery.day(offset: 7)) }
            if issue.startDate != nil {
                Divider()
                Button(tr("issues", "actions.start_clear")) { setStart(nil) }
            }
        } label: {
            Label(tr("issues", "actions.start_date"), systemImage: "calendar.badge.clock")
        }
        Menu {
            Button(tr("issues", "actions.due_today")) { setDue(IssueListQuery.day(offset: 0)) }
            Button(tr("issues", "actions.due_tomorrow")) { setDue(IssueListQuery.day(offset: 1)) }
            Button(tr("issues", "actions.due_next_week")) { setDue(IssueListQuery.day(offset: 7)) }
            if issue.dueDate != nil {
                Divider()
                Button(tr("issues", "actions.due_clear")) { setDue(nil) }
            }
        } label: {
            Label(tr("issues", "actions.due_date"), systemImage: "calendar")
        }
        Divider()
        Button {
            nav.openInNewTab(.issue(issue.identifier.isEmpty ? issue.id : issue.identifier), title: issue.identifier, activate: true)
        } label: {
            Label(tr("issues", "actions.open_in_new_tab"), systemImage: "arrow.up.forward.square")
        }
        Button {
            openWindow(id: "issue", value: IssueWindowTarget(slug: nav.slug, issueID: issue.id))
        } label: {
            Label(trd("common", "navigation.open_in_new_window", "Open in new window"), systemImage: "macwindow.badge.plus")
        }
        let pinned = session.pins.items.contains { $0.itemType == "issue" && $0.itemId == issue.id }
        Button { togglePin(pinned) } label: {
            Label(pinned ? tr("issues", "actions.unpin_from_sidebar") : tr("issues", "actions.pin_to_sidebar"),
                  systemImage: pinned ? "pin.slash" : "pin")
        }
        Button { copyLink() } label: {
            Label(tr("issues", "actions.copy_link"), systemImage: "link")
        }
        Button { copyWorkdir() } label: {
            Label(tr("issues", "actions.copy_workdir_path"), systemImage: "folder")
        }
        Divider()
        Menu {
            Button {
                var draft = CreateIssueDraft()
                draft.parentIssueID = issue.id
                draft.projectID = issue.projectID
                draft.assignee = issue.assignee
                modals.createIssue(draft)
            } label: {
                Label(tr("issues", "actions.create_sub_issue"), systemImage: "plus")
            }
            Button { modals.present(.setParentIssue(issueID: issue.id)) } label: {
                Label(tr("issues", "actions.set_parent_issue"), systemImage: "arrow.up")
            }
            if issue.parentIssueID != nil {
                Button { removeParent() } label: {
                    Label(tr("issues", "actions.remove_parent_issue"), systemImage: "link.badge.plus")
                }
            }
            Button { modals.present(.addChildIssue(parentID: issue.id)) } label: {
                Label(tr("issues", "actions.add_sub_issue"), systemImage: "arrow.down")
            }
            Button { modals.present(.markDuplicateIssue(issueID: issue.id)) } label: {
                Label(tr("issues", "actions.mark_duplicate"), systemImage: "equal.circle")
            }
        } label: {
            Label(tr("issues", "actions.relations"), systemImage: "point.3.connected.trianglepath.dotted")
        }
        ConnectionsPluginHookMenuItems(issueID: issue.id)
        ConnectionsPluginModalMenuItems(issueID: issue.id)
        Divider()
        Button(role: .destructive) {
            modals.present(.deleteIssues(issueIDs: [issue.id]))
        } label: {
            Label(tr("issues", "actions.delete_issue"), systemImage: "trash")
        }
    }

    private func assign(_ ref: ActorRef?) {
        var p = IssueListPatch()
        p.assignee = IssueListField(ref)
        model.updateField(issue, p)
    }

    private func setStart(_ day: String?) {
        var p = IssueListPatch()
        p.startDate = IssueListField(day)
        model.updateField(issue, p)
    }

    private func setDue(_ day: String?) {
        var p = IssueListPatch()
        p.dueDate = IssueListField(day)
        model.updateField(issue, p)
    }

    private func removeParent() {
        var p = IssueListPatch()
        p.parentIssueID = .clear
        model.update(issue.id, p) { [toaster] in
            toaster.success(tr("issues", "actions.remove_parent_issue_success"))
        }
    }

    private func togglePin(_ pinned: Bool) {
        if pinned {
            if let pin = session.pins.items.first(where: { $0.itemType == "issue" && $0.itemId == issue.id }) {
                session.pins.remove(pin.id)
            }
            Task { try? await session.api.deletePin(itemType: "issue", itemId: issue.id) }
        } else {
            Task {
                if let pin = try? await session.api.createPin(CreatePinRequest(itemType: "issue", itemId: issue.id)) {
                    session.pins.upsert(pin)
                }
            }
        }
    }

    private func copyLink() {
        let url = nav.webURL(.issue(issue.identifier.isEmpty ? issue.id : issue.identifier), appURL: env.app.config.appURL)
        if IssueListFormat.copy(url.absoluteString) {
            toaster.success(tr("issues", "detail.link_copied"))
        } else {
            toaster.error(tr("issues", "detail.link_copy_failed"))
        }
    }

    /// `resolveWorkdirCopyTarget`: the latest task's durable project
    /// directory once finalized, else its working directory.
    private func copyWorkdir() {
        let id = issue.id
        Task {
            let tasks = (try? await session.api.list("/api/issues/\(id.pathEscaped)/task-runs", of: AgentTaskRecord.self)) ?? []
            let terminal: Set<String> = ["completed", "failed", "cancelled"]
            let candidates = tasks.filter { t in
                !(t.workDir ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                    || (terminal.contains(t.status) && !(t.durableWorkDir ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
            guard let latest = candidates.max(by: { $0.createdAt < $1.createdAt }) else {
                toaster.error(tr("issues", "detail.workdir_path_unavailable"))
                return
            }
            let durable = (latest.durableWorkDir ?? "").trimmingCharacters(in: .whitespaces)
            let branch = (latest.branchName ?? "").trimmingCharacters(in: .whitespaces)
            if terminal.contains(latest.status) && !durable.isEmpty {
                guard IssueListFormat.copy(durable) else { return toaster.error(tr("issues", "detail.workdir_path_copy_failed")) }
                toaster.success(branch.isEmpty ? tr("issues", "detail.project_directory_path_copied")
                                : tr("issues", "detail.project_directory_path_copied_with_branch", ["branch": branch]))
                return
            }
            let work = (latest.workDir ?? "").trimmingCharacters(in: .whitespaces)
            guard !work.isEmpty, IssueListFormat.copy(work) else {
                return toaster.error(tr("issues", work.isEmpty ? "detail.workdir_path_unavailable" : "detail.workdir_path_copy_failed"))
            }
            toaster.success(tr("issues", "detail.workdir_path_copied"))
        }
    }
}
