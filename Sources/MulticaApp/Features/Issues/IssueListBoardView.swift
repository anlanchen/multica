import MulticaCore
import SwiftUI

/// Board layout (upstream board-view.tsx / board-column.tsx): status columns
/// or assignee / project / select-property columns, each independently paged,
/// with drag between and within columns.
struct IssueListBoardView: View {
    @Bindable var model: IssueListSurfaceModel
    @Environment(Navigator.self) private var nav
    @FocusState private var focused: Bool

    static let columnWidth: CGFloat = 280

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    if model.usesStatusSurface {
                        ForEach(model.visibleStatuses, id: \.self) { status in
                            let column = IssueListColumn(id: IssueListDrag.statusGroupID(status.rawValue), title: "", kind: .status(status),
                                                         branchKeys: [], total: model.statusBranch(status).total)
                            IssueListBoardColumn(model: model, column: column, statusBranch: model.statusBranch(status))
                        }
                        if !model.hiddenStatuses.isEmpty {
                            IssueListHiddenColumnsPanel(model: model).frame(width: 240)
                        }
                    } else if model.groupColumns.isEmpty {
                        Group {
                            if model.groupsError {
                                Button(tr("issues", "table.load_more_failed_retry")) { model.retryGroups() }
                                    .buttonStyle(.plain).foregroundStyle(Theme.destructive)
                            } else {
                                Text(tr("issues", "board.empty_grouping")).foregroundStyle(.secondary)
                            }
                        }
                        .font(Theme.Font.body)
                        .frame(width: 600, height: 300)
                    } else {
                        ForEach(model.groupColumns) { column in
                            IssueListBoardColumn(model: model, column: column, statusBranch: nil)
                        }
                        if model.groupsNextCursor != nil {
                            ProgressView().controlSize(.small).frame(width: 32, height: 200)
                                .onAppear { model.loadMoreGroups() }
                        }
                    }
                    if model.peekID != nil { Color.clear.frame(width: 520) }
                }
                .padding(8)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                IssueListKeyboard.handle(press, model: model, proxy: proxy, horizontal: true) { issue in
                    nav.push(.issue(issue.id), title: "\(issue.identifier) \(issue.title)")
                }
            }
            .onAppear { focused = true }
            .onChange(of: model.peekID) { focused = true }
        }
    }
}

private struct IssueListBoardColumn: View {
    let model: IssueListSurfaceModel
    let column: IssueListColumn
    let statusBranch: IssueListBranch?
    @Environment(WorkspaceSession.self) private var session
    @Environment(ModalCenter.self) private var modals
    @State private var targeted = false

    private var ids: [String] { statusBranch?.ids ?? model.columnIDs(column) }

    private var total: Int { statusBranch?.total ?? column.total }

    private var archived: Bool {
        column.status.flatMap { session.issueListStatusEntry($0)?.archivedAt } != nil
    }

    var body: some View {
        let ids = ids
        let category = column.status.map { session.issueListStatusCategory($0) }
        VStack(alignment: .leading, spacing: 8) {
            header
            ZStack {
                ScrollViewReader { _ in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 8) {
                            ForEach(ids, id: \.self) { id in
                                if let m = session.issues.model(id) {
                                    IssueListCardView(issueModel: m, model: model, grouping: model.effectiveGrouping)
                                        .id(id)
                                        .draggable(IssueListSurfaceModel.dragPrefix + id) {
                                            IssueListCardView(issueModel: m, model: model, grouping: model.effectiveGrouping)
                                                .frame(width: IssueListBoardView.columnWidth - 24)
                                        }
                                        .dropDestination(for: String.self) { items, _ in drop(items, before: id) }
                                }
                            }
                            footer
                            if ids.isEmpty && !isLoadingHead && !hasMore {
                                Text(tr("issues", "board.empty_column")).font(Theme.Font.caption).foregroundStyle(.secondary)
                                    .padding(.vertical, 32)
                            }
                            Color.clear.frame(height: 40)
                        }
                        .padding(4)
                    }
                }
                if targeted, let label = model.sortLabel {
                    Text(label)
                        .font(Theme.Font.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                }
            }
            .frame(minHeight: 200, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(targeted && !archived ? Color.accentColor.opacity(0.08) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(targeted && model.sortLabel != nil ? Theme.brand.opacity(0.25) : .clear, lineWidth: 2))
            .dropDestination(for: String.self) { items, _ in drop(items, before: nil) } isTargeted: { targeted = $0 }
        }
        .padding(8)
        .frame(width: IssueListBoardView.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(IssueListFormat.columnBackground(category)))
    }

    private var isLoadingHead: Bool {
        if let statusBranch { return statusBranch.isLoading }
        return column.branchKeys.contains { model.groupBranches[$0]?.isLoading == true }
    }

    private var hasMore: Bool {
        if let statusBranch { return statusBranch.hasMore }
        return column.branchKeys.contains { b in
            guard let branch = model.groupBranches[b] else { return false }
            return branch.hasMore || !branch.activated
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let statusBranch, let status = column.status {
            IssueListLoadMoreFooter(branch: statusBranch, onLoadMore: { model.loadMore(status: status) },
                                    onRetry: { model.retry(status: status) })
        } else {
            ForEach(column.branchKeys, id: \.self) { key in
                if let branch = model.groupBranches[key] {
                    IssueListGroupFooter(model: model, branch: branch)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            heading
            Spacer(minLength: 4)
            if let status = column.status {
                Menu {
                    let fixed = model.baseline?.status.contains(status.rawValue) == true
                    Button { model.state.hideStatus(status.rawValue) } label: {
                        Label(tr("issues", "board.hide_column"), systemImage: "eye.slash")
                    }
                    .disabled(fixed)
                    .help(fixed ? tr("issues", "filters.in_view") : "")
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if !archived {
                Button { modals.createIssue(createDraft) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(tr("issues", "board.add_issue_tooltip"))
            }
        }
        .padding(.horizontal, 6)
    }

    private var createDraft: CreateIssueDraft {
        switch column.kind {
        case .status(let s): return model.createDraft(status: s)
        case .assignee(let ref): return model.createDraft(assignee: IssueListField(ref))
        case .project(let pid): return model.createDraft(projectID: IssueListField(pid))
        case .property: return model.createDraft()
        }
    }

    @ViewBuilder
    private var heading: some View {
        switch column.kind {
        case .status(let s):
            IssueListStatusHeading(status: s, count: total)
        case .property(_, _, let color):
            HStack(spacing: 8) {
                Circle().fill(color.map { Color(hex: $0) } ?? Color.secondary.opacity(0.3)).frame(width: 10, height: 10)
                Text(column.title).font(Theme.Font.bodyMedium).lineLimit(1)
                IssueListCountBadge(count: total)
            }
        case .project(let pid):
            HStack(spacing: 8) {
                if let pid, let p = model.project(pid) {
                    ProjectIconView(icon: p.icon, size: 16)
                } else {
                    Image(systemName: "folder.badge.minus").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 18, height: 18)
                }
                Text(column.title).font(Theme.Font.bodyMedium).lineLimit(1)
                IssueListCountBadge(count: total)
            }
        case .assignee(let ref):
            HStack(spacing: 8) {
                if let ref {
                    ActorAvatar(type: ref.type, id: ref.id, size: 18)
                } else {
                    Image(systemName: "person.crop.circle.badge.minus").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 18, height: 18)
                }
                Text(column.title).font(Theme.Font.bodyMedium).lineLimit(1)
                IssueListCountBadge(count: total)
            }
        }
    }

    private func drop(_ items: [String], before: String?) -> Bool {
        guard !archived, let id = items.first.flatMap(IssueListSurfaceModel.draggedID), id != before else { return false }
        model.drop(id, intoColumn: column, before: before)
        return true
    }
}

/// Footer of one lazily activated group branch.
struct IssueListGroupFooter: View {
    let model: IssueListSurfaceModel
    let branch: IssueListBranch

    var body: some View {
        if !branch.activated {
            Color.clear.frame(height: 1).onAppear { model.loadMore(group: branch.key) }
        } else if branch.isLoading && branch.ids.isEmpty {
            ProgressView().controlSize(.small).padding(.vertical, 12)
        } else {
            IssueListLoadMoreFooter(branch: branch, onLoadMore: { model.loadMore(group: branch.key) },
                                    onRetry: { model.retry(group: branch.key) })
        }
    }
}

struct IssueListCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(Theme.Font.micro.weight(.medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
    }
}
