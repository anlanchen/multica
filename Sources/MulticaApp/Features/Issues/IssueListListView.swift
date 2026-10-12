import MulticaCore
import SwiftUI

/// List layout (upstream list-view.tsx): one collapsible, sticky section per
/// status with independent infinite scroll, drag between sections and
/// manual reordering.
struct IssueListListView: View {
    @Bindable var model: IssueListSurfaceModel
    @Environment(Navigator.self) private var nav
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.visibleStatuses, id: \.self) { status in
                        IssueListStatusSection(model: model, status: status, branch: model.statusBranch(status))
                    }
                    if !model.hiddenStatuses.isEmpty {
                        IssueListHiddenColumnsPanel(model: model)
                            .padding(.top, 16)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 16)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 80)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                IssueListKeyboard.handle(press, model: model, proxy: proxy, horizontal: false) { issue in
                    nav.push(.issue(issue.id), title: "\(issue.identifier) \(issue.title)")
                }
            }
            .onAppear { focused = true }
            .onChange(of: model.peekID) { focused = true }
        }
    }
}

private struct IssueListStatusSection: View {
    let model: IssueListSurfaceModel
    let status: IssueStatusKey
    let branch: IssueListBranch
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        let expanded = !model.state.listCollapsedStatuses.contains(status.rawValue)
        Section {
            if expanded {
                if branch.ids.isEmpty && !branch.hasMore {
                    if branch.isLoading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 12)
                    } else {
                        Text(tr("issues", "list.empty_status")).font(Theme.Font.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                            .dropDestination(for: String.self) { items, _ in drop(items, before: nil) }
                    }
                } else {
                    ForEach(branch.ids, id: \.self) { id in
                        if let m = session.issues.model(id) {
                            IssueListRowView(issueModel: m, model: model)
                                .id(id)
                                .draggable(IssueListSurfaceModel.dragPrefix + id) { IssueListDragPreview(issue: m.issue) }
                                .dropDestination(for: String.self) { items, _ in drop(items, before: id) }
                        }
                    }
                }
                IssueListLoadMoreFooter(branch: branch, onLoadMore: { model.loadMore(status: status) },
                                        onRetry: { model.retry(status: status) })
            }
        } header: {
            IssueListStatusSectionHeader(model: model, status: status, branch: branch, expanded: expanded)
                .dropDestination(for: String.self) { items, _ in drop(items, before: nil) }
        }
    }

    private func drop(_ items: [String], before: String?) -> Bool {
        guard let id = items.first.flatMap(IssueListSurfaceModel.draggedID), id != before else { return false }
        model.drop(id, intoStatus: status, before: before)
        return true
    }
}

private struct IssueListStatusSectionHeader: View {
    let model: IssueListSurfaceModel
    let status: IssueStatusKey
    let branch: IssueListBranch
    let expanded: Bool
    @Environment(WorkspaceSession.self) private var session
    @Environment(ModalCenter.self) private var modals
    @State private var hovering = false

    var body: some View {
        let ids = branch.ids
        let selectedCount = ids.filter { model.selection.contains($0) }.count
        let all = !ids.isEmpty && selectedCount == ids.count
        let archived = session.issueListStatusEntry(status)?.archivedAt != nil
        HStack(spacing: 8) {
            Button {
                if all { model.deselect(ids) } else { model.select(ids) }
            } label: {
                Image(systemName: all ? "checkmark.square.fill" : (selectedCount > 0 ? "minus.square.fill" : "square"))
                    .foregroundStyle(selectedCount > 0 ? Theme.brand : .secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            Button {
                withAnimation(.snappy(duration: 0.15)) { model.state.toggleListCollapsed(status.rawValue) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    IssueListStatusHeading(status: status, count: branch.total)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !archived {
                Button {
                    modals.createIssue(model.createDraft(status: status))
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .help(tr("issues", "list.add_issue_tooltip"))
                .padding(.trailing, 8)
            }
        }
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor)))
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }
}

/// Status icon + label + count (upstream StatusHeading).
struct IssueListStatusHeading: View {
    let status: IssueStatusKey
    let count: Int
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                session.issues.catalog.icon(for: status, size: 12)
                Text(session.issueListStatusLabel(status)).font(Theme.Font.caption.weight(.semibold))
            }
            Text("\(count)").font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// End-of-branch footer: retry on error, a sentinel while more pages exist,
/// a "No more" marker for branches that actually paginated.
struct IssueListLoadMoreFooter: View {
    let branch: IssueListBranch
    let onLoadMore: () -> Void
    let onRetry: () -> Void

    var body: some View {
        if branch.isError {
            Button(tr("issues", "table.load_more_failed_retry"), action: onRetry)
                .buttonStyle(.plain)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.destructive)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        } else if branch.hasMore {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(tr("issues", "table.loading_branch")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .onAppear(perform: onLoadMore)
        } else if branch.total > 50 && branch.loaded {
            Text(tr("issues", "table.no_more")).font(Theme.Font.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }
}

/// "Hidden columns" panel shared by board and list.
struct IssueListHiddenColumnsPanel: View {
    let model: IssueListSurfaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tr("issues", "board.hidden_columns_label")).font(Theme.Font.bodyMedium).foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.bottom, 6)
            ForEach(model.hiddenStatuses, id: \.self) { status in
                IssueListHiddenColumnRow(model: model, status: status)
            }
        }
    }
}

private struct IssueListHiddenColumnRow: View {
    let model: IssueListSurfaceModel
    let status: IssueStatusKey
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        HStack(spacing: 8) {
            session.issues.catalog.icon(for: status, size: 13)
            Text(session.issueListStatusLabel(status))
            Spacer()
            if let total = model.facets?.status[status.rawValue] {
                Text("\(total)").font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Menu {
                Button { model.state.showStatus(status.rawValue) } label: {
                    Label(tr("issues", "board.show_column"), systemImage: "eye")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("issues", "board.show_column"))
        }
        .font(Theme.Font.body)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .hoverHighlight(cornerRadius: 8)
    }
}

struct IssueListDragPreview: View {
    let issue: Issue

    var body: some View {
        HStack(spacing: 8) {
            Text(issue.identifier).font(Theme.Font.caption).foregroundStyle(.secondary)
            Text(issue.title).font(Theme.Font.body).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// J/K (↑/↓) step through rows, H/L (←/→) across columns, ↩ opens, Space
/// peeks, X selects, Esc closes the peek or clears the selection.
@MainActor
enum IssueListKeyboard {
    static func handle(_ press: KeyPress, model: IssueListSurfaceModel, proxy: ScrollViewProxy?, horizontal: Bool,
                       open: (Issue) -> Void) -> KeyPress.Result {
        guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
        let current = model.peekID ?? model.focusedID
        func go(_ step: IssueListStep) -> KeyPress.Result {
            guard let next = model.step(step, from: current) else { return .handled }
            model.focusedID = next
            if model.peekID != nil { model.peekID = next }
            proxy?.scrollTo(next)
            return .handled
        }
        switch press.key {
        case .downArrow: return go(.next)
        case .upArrow: return go(.previous)
        case .leftArrow: return horizontal ? go(.left) : .ignored
        case .rightArrow: return horizontal ? go(.right) : .ignored
        case .escape:
            if model.peekID != nil { model.peekID = nil; return .handled }
            if !model.selection.isEmpty { model.clearSelection(); return .handled }
            return .ignored
        case .return:
            guard let id = model.focusedID ?? model.peekID, let issue = model.session.issues.model(id)?.issue else { return .ignored }
            open(issue)
            return .handled
        case .space:
            guard let id = model.hoveredID ?? model.focusedID else { return .ignored }
            model.focusedID = id
            model.peekID = model.peekID == id ? nil : id
            return .handled
        default:
            break
        }
        switch press.characters.lowercased() {
        case "j": return go(.next)
        case "k": return go(.previous)
        case "h": return horizontal ? go(.left) : .ignored
        case "l": return horizontal ? go(.right) : .ignored
        case "x":
            guard let id = model.focusedID else { return .ignored }
            model.toggleSelection(id)
            return .handled
        default:
            return .ignored
        }
    }
}
