import MulticaCore
import SwiftUI

/// What the save-view sheet edits: nil view = create.
struct IssueListSaveTarget: Identifiable {
    var view: IssueView?
    /// Seed from the view's own definition (manager-initiated edits) instead
    /// of the live surface state.
    var fromDefinition: Bool
    var id: String { (view?.id ?? "new") + (fromDefinition ? ":def" : ":live") }
}

/// One mounted issue surface: header, filter chips, the active layout, the
/// side peek and the batch toolbar (upstream issue-surface.tsx).
struct IssueListSurfaceView: View {
    let session: WorkspaceSession
    let scope: IssueListSurfaceScope
    let view: IssueView?
    let modes: [IssueListViewMode]
    let header: IssueListHeaderConfig
    var showHeader = true
    let empty: IssueListEmptyKind
    var batchAlways = false
    var actorHeader: IssueListActorHeader? = nil

    @State private var model: IssueListSurfaceModel?

    var body: some View {
        Group {
            if let model {
                IssueListSurfaceBody(model: model, header: header, showHeader: showHeader, empty: empty,
                                     batchAlways: batchAlways, actorHeader: actorHeader)
                    .onChange(of: view) { _, next in model.adoptView(next) }
            } else {
                Color.clear.onAppear {
                    model = IssueListSurfaceModel(session: session, scope: scope, modes: modes, view: view)
                }
            }
        }
    }
}

/// Header inputs for the actor issues panel (search + assigned/created).
struct IssueListActorHeader {
    var scope: String
    var onScopeChange: (String) -> Void
}

private struct IssueListSurfaceBody: View {
    @Bindable var model: IssueListSurfaceModel
    let header: IssueListHeaderConfig
    let showHeader: Bool
    let empty: IssueListEmptyKind
    let batchAlways: Bool
    let actorHeader: IssueListActorHeader?

    @Environment(Toaster.self) private var toaster
    @Environment(IssueListPageStatus.self) private var pageStatus: IssueListPageStatus?
    @State private var saveTarget: IssueListSaveTarget?

    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                if let actorHeader {
                    IssueListActorHeaderBar(model: model, header: actorHeader)
                } else {
                    IssueListHeaderBar(model: model, config: header, showRefresh: pageStatus == nil,
                                       onSaveView: { saveTarget = $0 })
                }
                IssueListFilterChipsBar(model: model, saveLabel: saveLabel, onSave: onSave)
            }
            ZStack(alignment: .bottom) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if let id = model.peekID {
                            IssueListPeekPanel(model: model, issueID: id)
                                .padding(8)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.snappy(duration: 0.18), value: model.peekID == nil)
                if batchAlways || model.viewMode == .list || model.viewMode == .table {
                    IssueListBatchBar(model: model)
                        .padding(.bottom, 24)
                }
            }
        }
        .task {
            model.toast = { [toaster] message, isError in
                if isError { toaster.error(message) } else { toaster.success(message) }
            }
            await model.start()
        }
        .onDisappear { model.stop() }
        .onChange(of: model.isRefreshing) { _, v in pageStatus?.refreshing = v }
        .sheet(item: $model.runConfirm) { intent in
            IssueListRunConfirmSheet(model: model, intent: intent)
        }
        .sheet(item: $saveTarget) { target in
            if let scope = header.saveScope, let views = header.views {
                IssueListSaveViewSheet(model: model, views: views, scope: scope, target: target)
            }
        }
    }

    private var isViewOwner: Bool {
        model.activeView?.ownerId == model.session.currentUser.id
    }

    private var saveLabel: String? {
        guard header.saveScope != nil, model.activeView != nil else { return nil }
        if case .my = header.saveScope { return tr("issues", "filters.chip_edit") }
        return isViewOwner ? tr("issues", "filters.chip_edit") : tr("issues", "filters.chip_save_as")
    }

    private var onSave: (() -> Void)? {
        guard header.saveScope != nil, actorHeader == nil else { return nil }
        return {
            if let v = model.activeView, isViewOwner || { if case .my = header.saveScope { return true } else { return false } }() {
                saveTarget = IssueListSaveTarget(view: v, fromDefinition: false)
            } else {
                saveTarget = IssueListSaveTarget(view: nil, fromDefinition: false)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.statusCatalogError {
            IssueListDependencyError(kind: .status) {
                Task {
                    await model.session.issueStatusEntries.load()
                    await model.reload()
                }
            }
        } else if model.workingFilterError {
            IssueListDependencyError(kind: .working) { Task { await model.reload() } }
        } else if model.viewMode == .table {
            IssueListTableView(model: model)
        } else if model.viewMode == .gantt {
            IssueListGanttView(model: model)
        } else if model.isLoading {
            IssueListSkeleton(mode: model.viewMode)
        } else if model.isEmpty {
            if model.hasActiveFilters {
                IssueListFilteredEmpty(model: model)
            } else {
                IssueListEmptyState(model: model, kind: empty)
            }
        } else {
            switch model.viewMode {
            case .board: IssueListBoardView(model: model)
            case .swimlane: IssueListSwimlaneView(model: model)
            default: IssueListListView(model: model)
            }
        }
    }
}

/// Missing filter dependencies offer recovery instead of claiming the
/// filter matched nothing.
struct IssueListDependencyError: View {
    enum Kind { case status, working }
    let kind: Kind
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(kind == .working ? tr("issues", "working_filter_error.title") : tr("issues", "status_catalog_error.title"))
                .font(Theme.Font.body).foregroundStyle(.secondary)
            if kind == .status {
                Text(tr("issues", "status_catalog_error.hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Button(tr("issues", "status_catalog_error.retry"), action: retry).controlSize(.small).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A filtered-empty surface is not an empty surface.
struct IssueListFilteredEmpty: View {
    let model: IssueListSurfaceModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(tr("issues", "filtered_empty.title")).font(Theme.Font.body).foregroundStyle(.secondary)
            Button(tr("issues", "filtered_empty.clear_button")) {
                if let raw = model.baseline?.raw {
                    model.state.resetFilters(to: raw)
                    model.state.dateFilter = nil
                    model.state.agentRunningFilter = false
                } else {
                    model.state.clearFilters()
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct IssueListEmptyState: View {
    let model: IssueListSurfaceModel
    let kind: IssueListEmptyKind
    @Environment(ModalCenter.self) private var modals

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            switch kind {
            case .issues:
                Text(tr("issues", "page.empty_title")).font(Theme.Font.body).foregroundStyle(.secondary)
            case .my:
                Text(tr("my-issues", "page.empty_title")).font(Theme.Font.body).foregroundStyle(.secondary)
                Text(tr("my-issues", "page.empty_description")).font(Theme.Font.caption).foregroundStyle(.secondary)
            case .actor(let relation):
                if model.search.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(tr("issues", "actor_issues.empty.\(relation).title")).font(Theme.Font.body).foregroundStyle(.secondary)
                } else {
                    Text(tr("issues", "actor_issues.search_empty")).font(Theme.Font.body).foregroundStyle(.secondary)
                }
            case .project:
                Text(tr("projects", "detail.empty_issues_title")).font(Theme.Font.body).foregroundStyle(.secondary)
                Text(tr("projects", "detail.empty_issues_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                Button {
                    modals.createIssue(model.createDraft())
                } label: {
                    Label(tr("projects", "detail.empty_issues_new_button"), systemImage: "plus")
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Loading placeholders shaped like the layout they precede.
struct IssueListSkeleton: View {
    let mode: IssueListViewMode
    @State private var pulse = false

    var body: some View {
        Group {
            if mode == .list {
                VStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)).frame(height: 40)
                    }
                    Spacer()
                }
                .padding(8)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<5, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)).frame(width: 80, height: 14)
                            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)).frame(height: 96)
                            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)).frame(height: 96)
                        }
                        .frame(minWidth: 200, maxWidth: .infinity)
                    }
                }
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .opacity(pulse ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}

/// Handoff confirmation for the writes that start agent runs (upstream
/// modals/run-confirm.tsx), local to the surface so it can carry the intent.
struct IssueListRunConfirmSheet: View {
    let model: IssueListSurfaceModel
    let intent: IssueListRunConfirm
    @Environment(\.dismiss) private var dismiss
    @State private var pending: Bool?

    private var name: String {
        model.session.actorInfo(type: intent.assignee.type == "squad" ? "squad" : "agent", id: intent.assignee.id).name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(intent.mode == .promote ? tr("modals", "run_confirm.title_promote") : tr("modals", "run_confirm.title_assign"))
                .font(Theme.Font.title)
            Text(headline).font(Theme.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                        Text(intent.mode == .promote ? tr("modals", "run_confirm.confirm_promote") : tr("modals", "run_confirm.confirm_assign"))
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(pending != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var headline: AttributedString {
        let raw: String
        if intent.mode == .promote, let status = intent.status {
            raw = tr("modals", "run_confirm.promote_single", ["name": "\u{0}\(name)\u{0}", "status": "\u{0}\(model.session.issueListStatusLabel(status))\u{0}"])
        } else if intent.issueIDs.count > 1 {
            raw = tr("modals", "run_confirm.assign_batch", ["name": "\u{0}\(name)\u{0}", "count": intent.issueIDs.count])
        } else {
            raw = tr("modals", "run_confirm.assign_single", ["name": "\u{0}\(name)\u{0}"])
        }
        var out = AttributedString()
        for (i, part) in raw.split(separator: "\u{0}", omittingEmptySubsequences: false).enumerated() {
            var a = AttributedString(String(part))
            if i % 2 == 1 {
                a.font = .system(size: 13, weight: .semibold)
                a.foregroundColor = .primary
            }
            out += a
        }
        return out
    }

    private func submit(suppress: Bool) {
        pending = suppress
        var patch = IssueListPatch()
        if intent.mode == .promote {
            patch.status = intent.status
        } else {
            patch.assignee = .set(intent.assignee)
        }
        patch.suppressRun = suppress
        Task {
            if intent.issueIDs.count == 1 {
                model.update(intent.issueIDs[0], patch)
            } else {
                await model.batchUpdate(intent.issueIDs, patch)
            }
            dismiss()
        }
    }
}
