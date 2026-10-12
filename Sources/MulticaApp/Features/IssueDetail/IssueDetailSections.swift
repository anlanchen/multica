import AppKit
import MulticaCore
import SwiftUI

/// Upstream QuickActionsSection: the workspace's active quick actions,
/// three at a time; running one posts its comment and reports the outcome.
struct IssueDetailQuickActions: View {
    @Environment(WorkspaceSession.self) private var session
    let store: IssueDetailStore
    @State private var open = true
    @State private var showAll = false
    @State private var blocked: QuickAction?

    var body: some View {
        let actions = session.quickActions.items.filter { $0.status == "active" }
        Group {
            if !actions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    IssueDetailSectionHeader(title: tr("issues", "detail.section_quick_actions"), open: $open)
                    if open {
                        let visible = showAll ? actions : Array(actions.prefix(3))
                        ForEach(visible) { a in IssueDetailQuickActionRow(store: store, action: a) { blocked = a } }
                        if actions.count > visible.count {
                            Button(tr("issues", "detail.quick_actions_more", ["count": actions.count - visible.count])) { showAll = true }
                                .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 2)
                        }
                    }
                }
            }
        }
        .task { await session.quickActions.loadIfNeeded() }
        .alert(tr("issues", "detail.quick_action_blocked_title"), isPresented: Binding(get: { blocked != nil }, set: { if !$0 { blocked = nil } })) {
            Button(tr("issues", "detail.quick_action_blocked_ok"), role: .cancel) {}
        } message: {
            Text(tr("issues", "detail.quick_action_blocked_body", ["name": blocked?.name ?? ""]))
        }
    }
}

private struct IssueDetailQuickActionRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    let action: QuickAction
    let onBlocked: () -> Void
    @State private var running = false

    var body: some View {
        let target = action.targetName.flatMap { $0.isEmpty ? nil : $0 } ?? tr("issues", "detail.quick_action_target_fallback")
        Button(action: run) {
            HStack(spacing: 8) {
                if running { ProgressView().controlSize(.mini).frame(width: 14) } else {
                    Image(systemName: "bolt").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.name).font(Theme.Font.caption).lineLimit(1)
                    if !action.description.isEmpty {
                        Text(action.description).font(Theme.Font.micro).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(HoverRowButtonStyle())
        .disabled(running)
        .help(tr("issues", "detail.quick_action_runs_as", ["name": target]))
    }

    private func run() {
        let target = action.targetName.flatMap { $0.isEmpty ? nil : $0 } ?? tr("issues", "detail.quick_action_target_fallback")
        running = true
        Task {
            defer { running = false }
            do {
                let result = try await session.api.issueDetailRunQuickAction(issueId: store.issueID, quickActionId: action.id)
                store.model.issueDetailApply(result.comment)
                switch result.outcome?.status {
                case "queued": toaster.success(tr("issues", "detail.quick_action_queued", ["name": target]))
                case "coalesced": toaster.show(tr("issues", "detail.quick_action_coalesced", ["name": target]))
                case "deferred": toaster.show(tr("issues", "detail.quick_action_deferred", ["name": target]))
                case "blocked": toaster.error(tr("issues", "detail.quick_action_blocked", ["name": target]))
                default: toaster.show(tr("issues", "detail.quick_action_posted"))
                }
            } catch let e as APIError where e.status == 403 {
                onBlocked()
            } catch {
                toaster.error(error)
            }
        }
    }
}

/// Upstream IssueDuplicatesSection: issues marked as duplicates of this one.
struct IssueDetailDuplicatesSection: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let store: IssueDetailStore
    @State private var open = true

    var body: some View {
        if let dups = store.duplicates?.duplicates, !dups.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                IssueDetailSectionHeader(title: tr("issues", "duplicates.section_title"), open: $open)
                if open {
                    ForEach(dups) { d in
                        Button { nav.push(.issue(d.id), title: d.identifier) } label: {
                            HStack(spacing: 6) {
                                session.issues.catalog.icon(for: d.status)
                                Text(d.identifier).foregroundStyle(.secondary)
                                Text(d.title).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(Theme.Font.caption)
                        }
                        .buttonStyle(HoverRowButtonStyle())
                    }
                }
            }
        }
    }
}

/// Upstream PullRequestsSection + PullRequestList: linked PRs with their
/// state/check verdicts, link by URL, unlink with undo, and the
/// merge-to-status automation line.
struct IssueDetailPullRequestsSection: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    @State private var open = true
    @State private var linkOpen = false
    @State private var url = ""
    @State private var linking = false
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IssueDetailSectionHeader(title: tr("issues", "detail.section_pull_requests"), open: $open) {
                Button { linkOpen = true } label: { Image(systemName: "plus").font(.system(size: 10)) }
                    .buttonStyle(.borderless)
                    .help(tr("issues", "pr_automation.link_action"))
                    .popover(isPresented: $linkOpen, arrowEdge: .bottom) { linkForm }
                if let auto = store.pullRequests?.autoComplete {
                    Menu {
                        Button(tr("issues", auto.issueDisabled ? "pr_automation.enable" : "pr_automation.disable")) {
                            setAutoComplete(disabled: !auto.issueDisabled)
                        }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 10)) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(tr("issues", "pr_automation.section_menu"))
                }
            }
            if open {
                if let prs = store.pullRequests?.pullRequests {
                    if prs.isEmpty {
                        Text(tr("issues", "detail.pull_requests_empty_title")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    } else {
                        let visible = showAll || prs.count <= 4 ? prs : Array(prs.prefix(3))
                        ForEach(visible, id: \.id) { pr in IssueDetailPullRequestRow(store: store, pr: pr) }
                        if prs.count > 4 {
                            Button(showAll ? tr("issues", "detail.pull_request_card_show_less")
                                   : tr("issues", "detail.pull_request_card_show_more", ["count": prs.count - 3])) { showAll.toggle() }
                                .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                        }
                        if let auto = store.pullRequests?.autoComplete { automationLine(auto, prs: prs) }
                    }
                } else {
                    Text(tr("issues", "detail.pull_requests_loading")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
            }
        }
        .task(id: session.revision("pull_request")) { await store.loadPullRequests() }
    }

    private var linkForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("issues", "pr_automation.link_action")).font(Theme.Font.bodyMedium)
            TextField(tr("issues", "pr_automation.link_placeholder"), text: $url)
                .textFieldStyle(.roundedBorder)
                .onSubmit(link)
            Text(tr("issues", "pr_automation.link_hint", ["identifier": store.issue?.identifier ?? ""]))
                .font(Theme.Font.micro).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("issues", "pr_automation.link_submit"), action: link)
                    .keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || linking)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    @ViewBuilder private func automationLine(_ auto: PRAutoComplete, prs: [GitHubPullRequest]) -> some View {
        let named = prs.filter { auto.pullRequestIds.contains($0.id) }
        let list = named.map { "#\($0.number)" }.joined(separator: ", ")
        let target = session.issues.catalog.localizedName(for: IssueStatusKey(rawValue: auto.targetStatus ?? "done"))
        Group {
            switch auto.state {
            case "waiting" where !named.isEmpty:
                Label(tr("issues", "pr_automation.waiting_to", ["count": named.count, "prs": list, "status": target]), systemImage: "circle.dashed")
            case "not_merged" where !named.isEmpty:
                HStack(spacing: 4) {
                    Label(tr("issues", "pr_automation.not_merged", ["prs": list]), systemImage: "exclamationmark.triangle")
                    if named.count == 1, let only = named.first {
                        Button(tr("issues", "pr_automation.not_merged_action")) { unlink(only) }.buttonStyle(.link)
                    }
                }
            case "all_merged":
                Label(tr("issues", "pr_automation.all_merged_to", ["status": target]), systemImage: "checkmark.circle")
            case "issue_disabled":
                HStack(spacing: 4) {
                    Label(tr("issues", "pr_automation.issue_disabled"), systemImage: "circle.slash")
                    Button(tr("issues", "pr_automation.issue_disabled_action")) { setAutoComplete(disabled: false) }.buttonStyle(.link)
                }
            default:
                EmptyView()
            }
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func link() {
        let u = url.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { return }
        linking = true
        Task {
            defer { linking = false }
            do {
                _ = try await session.api.linkIssuePullRequest(issueId: store.issueID, url: u)
                url = ""
                linkOpen = false
                await store.loadPullRequests()
            } catch let e as APIError where e.status == 404 {
                toaster.error(tr("issues", "pr_automation.link_not_found"))
            } catch {
                toaster.error(tr("issues", "pr_automation.link_failed"))
            }
        }
    }

    private func unlink(_ pr: GitHubPullRequest) {
        IssueDetailPullRequestRow.unlink(pr, store: store, session: session, toaster: toaster)
    }

    private func setAutoComplete(disabled: Bool) {
        Task {
            do {
                _ = try await session.api.setIssuePRAutoComplete(issueId: store.issueID, disabled: disabled)
                await store.loadPullRequests()
            } catch {
                toaster.error(tr("issues", "pr_automation.update_failed"))
            }
        }
    }
}

struct IssueDetailPullRequestRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    let pr: GitHubPullRequest

    var body: some View {
        let verdict = Self.verdict(pr)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: stateSymbol).foregroundStyle(stateColor).font(.system(size: 12)).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Button { if let url = URL(string: pr.htmlUrl) { NSWorkspace.shared.open(url) } } label: {
                    Text(pr.title).font(Theme.Font.caption.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                HStack(spacing: 4) {
                    Text("\(pr.repoOwner)/\(pr.repoName)#\(pr.number)")
                    if let files = pr.changedFiles, files > 0 {
                        Text("· " + tr("issues", "detail.pull_request_card_files_count", ["count": Int(files)]))
                    }
                    if let a = pr.additions, let d = pr.deletions {
                        Text("+\(Int(a))").foregroundStyle(Theme.success)
                        Text("−\(Int(d))").foregroundStyle(Theme.destructive)
                    }
                }
                .font(Theme.Font.micro).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Text(verdict.label).foregroundStyle(verdict.color)
                    if pr.snapshotStale == true {
                        Text("· " + (pr.snapshotFetchedAt.map { tr("issues", "detail.pull_request_snapshot_stale", ["time": Formatters.relative($0)]) }
                                     ?? tr("issues", "detail.pull_request_snapshot_stale_unknown")))
                    }
                }
                .font(Theme.Font.micro)
                .foregroundStyle(.secondary)
                .help(verdict.title)
                if let failed = pr.failedCheckNames, !failed.isEmpty {
                    Text(failed.prefix(3).joined(separator: ", ") + (failed.count > 3 ? " " + tr("issues", "detail.pull_request_checks_more", ["count": failed.count - 3]) : ""))
                        .font(Theme.Font.micro).foregroundStyle(Theme.destructive).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Text(sourceLabel)
                Button(tr("issues", "pr_automation.unlink"), role: .destructive) {
                    Self.unlink(pr, store: store, session: session, toaster: toaster)
                }
            } label: { Image(systemName: "ellipsis").font(.system(size: 10)) }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("issues", "pr_automation.row_menu"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .hoverHighlight()
    }

    private var sourceLabel: String {
        switch pr.linkSource {
        case "manual": return tr("issues", "pr_automation.source_manual")
        case "title": return tr("issues", "pr_automation.source_title", ["identifier": store.issue?.identifier ?? ""])
        case "branch": return tr("issues", "pr_automation.source_branch")
        default: return tr("issues", "pr_automation.source_auto")
        }
    }

    private var stateSymbol: String {
        if pr.state == "merged" || pr.mergedAt != nil { return "arrow.triangle.merge" }
        if pr.state == "closed" { return "xmark.circle" }
        if pr.state == "draft" { return "circle.dashed" }
        return "arrow.triangle.pull"
    }

    private var stateColor: Color {
        if pr.state == "merged" || pr.mergedAt != nil { return .purple }
        if pr.state == "closed" || pr.state == "draft" { return .secondary }
        return Theme.success
    }

    struct Verdict {
        var label: String
        var title: String
        var color: Color
    }

    static func verdict(_ pr: GitHubPullRequest) -> Verdict {
        let total = pr.checksTotal ?? 0
        let passed = Int(pr.checksPassed ?? 0), failed = Int(pr.checksFailed ?? 0), running = Int(pr.checksRunning ?? pr.checksPending ?? 0)
        if pr.state == "merged" || pr.mergedAt != nil {
            let s = tr("issues", "detail.pull_request_state_merged")
            return Verdict(label: s, title: s, color: .purple)
        }
        if pr.state == "closed" {
            let s = tr("issues", "detail.pull_request_state_closed")
            return Verdict(label: s, title: s, color: .secondary)
        }
        if failed > 0 {
            let s = tr("issues", "detail.pull_request_checks_failed_count", ["failed": failed, "total": total])
            return Verdict(label: s, title: s, color: Theme.destructive)
        }
        let merge = (pr.mergeStateStatus ?? pr.mergeableState ?? "").lowercased()
        if pr.mergeable?.lowercased() == "conflicting" || merge == "dirty" {
            return Verdict(label: tr("issues", "detail.pull_request_verdict_conflicting"), title: tr("issues", "detail.pull_request_merge_conflicting"), color: Theme.warning)
        }
        if running > 0 {
            return Verdict(label: "\(passed)/\(total)", title: tr("issues", "detail.pull_request_checks_running", ["passed": passed, "total": total, "running": running]), color: Theme.info)
        }
        if merge == "behind" {
            let s = tr("issues", "detail.pull_request_merge_behind")
            return Verdict(label: s, title: s, color: .secondary)
        }
        if merge == "blocked" {
            let s = tr("issues", "detail.pull_request_merge_blocked")
            return Verdict(label: s, title: s, color: .secondary)
        }
        if pr.state == "draft" || merge == "draft" {
            let s = tr("issues", "detail.pull_request_state_draft")
            return Verdict(label: s, title: s, color: .secondary)
        }
        if merge == "clean" {
            return Verdict(label: tr("issues", "detail.pull_request_verdict_ready"), title: tr("issues", "detail.pull_request_merge_ready"), color: Theme.success)
        }
        if total > 0 && passed == total {
            return Verdict(label: tr("issues", "detail.pull_request_verdict_passed"), title: tr("issues", "detail.pull_request_checks_all_passed", ["total": total]), color: Theme.success)
        }
        let s = tr("issues", "detail.pull_request_checks_none")
        return Verdict(label: s, title: s, color: .secondary)
    }

    @MainActor
    static func unlink(_ pr: GitHubPullRequest, store: IssueDetailStore, session: WorkspaceSession, toaster: Toaster) {
        Task {
            do {
                _ = try await session.api.unlinkIssuePullRequest(issueId: store.issueID, pullRequestId: pr.id)
                await store.loadPullRequests()
                toaster.show(tr("issues", "pr_automation.unlinked", ["pr": "#\(pr.number)"]), kind: .success,
                             actionTitle: tr("issues", "pr_automation.undo")) {
                    Task {
                        _ = try? await session.api.linkIssuePullRequest(issueId: store.issueID, url: pr.htmlUrl)
                        await store.loadPullRequests()
                    }
                }
            } catch {
                toaster.error(tr("issues", "pr_automation.unlink_failed"))
            }
        }
    }
}

/// Upstream DeliverablesSection: the files this issue's comments delivered,
/// newest first, with the overview one click away.
struct IssueDetailDeliverablesSection: View {
    @Environment(Navigator.self) private var nav
    let store: IssueDetailStore
    @State private var open = true
    @State private var overview = false

    var body: some View {
        let files = store.deliverables
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                IssueDetailSectionHeader(title: tr("issues", "deliverables.section_title"), open: $open) {
                    Button(tr("issues", "deliverables.view_all", ["count": files.count])) { overview = true }
                        .buttonStyle(.plain).font(Theme.Font.micro).foregroundStyle(.secondary)
                }
                if open {
                    ForEach(files.prefix(5), id: \.attachment.id) { f in
                        Button { nav.push(.attachmentPreview(f.attachment.id)) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: f.attachment.contentType.hasPrefix("image/") ? "photo" : "doc").foregroundStyle(.secondary).frame(width: 14)
                                Text(f.attachment.filename).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(Formatters.relative(f.attachment.createdAt)).foregroundStyle(.secondary)
                            }
                            .font(Theme.Font.caption)
                        }
                        .buttonStyle(HoverRowButtonStyle())
                    }
                }
            }
            .sheet(isPresented: $overview) { IssueDetailDeliverablesOverview(store: store, files: files) }
        }
    }
}

/// Upstream DeliverablesOverview: every delivered file with a type filter
/// and a way back to the comment that delivered it.
private struct IssueDetailDeliverablesOverview: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Navigator.self) private var nav
    let store: IssueDetailStore
    let files: [IssueDetailDeliverable]
    @State private var filter = "all"

    var body: some View {
        let shown = files.filter { f in
            switch filter {
            case "image": return f.attachment.contentType.hasPrefix("image/")
            case "video": return f.attachment.contentType.hasPrefix("video/")
            case "document": return f.attachment.contentType.contains("pdf") || f.attachment.contentType.hasPrefix("text/") || f.attachment.contentType.contains("document")
            case "misc": return !(f.attachment.contentType.hasPrefix("image/") || f.attachment.contentType.hasPrefix("video/"))
            default: return true
            }
        }
        let size = files.reduce(0) { $0 + $1.attachment.sizeBytes }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("issues", "deliverables.overview_title")).font(Theme.Font.title)
                    Text(tr("issues", "deliverables.overview_summary_with_size", ["count": files.count, "size": Formatters.bytes(Int64(size))]))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(tr("issues", "deliverables.overview_close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("", selection: $filter) {
                ForEach(["all", "image", "document", "video", "misc"], id: \.self) { f in Text(tr("issues", "deliverables.filter_\(f)")).tag(f) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if shown.isEmpty {
                Text(tr("issues", "deliverables.overview_empty")).font(Theme.Font.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(shown, id: \.attachment.id) { f in
                    HStack(spacing: 8) {
                        Image(systemName: f.attachment.contentType.hasPrefix("image/") ? "photo" : "doc").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.attachment.filename).font(Theme.Font.body).lineLimit(1)
                            Text(Formatters.bytes(Int64(f.attachment.sizeBytes)) + " · " + Formatters.relative(f.attachment.createdAt))
                                .font(Theme.Font.micro).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(tr("issues", "deliverables.locate_comment")) {
                            dismiss()
                            store.jump(to: f.commentID)
                        }
                        .buttonStyle(.link)
                        .font(Theme.Font.caption)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        dismiss()
                        nav.push(.attachmentPreview(f.attachment.id))
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(18)
        .frame(width: 640, height: 520)
    }
}
