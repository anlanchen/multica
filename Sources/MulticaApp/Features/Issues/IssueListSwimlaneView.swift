import MulticaCore
import SwiftUI

/// Swimlane layout (upstream swimlane-view.tsx): lanes by assignee, project
/// or parent issue, each a row of status cells paged independently; lanes
/// collapse and reorder, cards move across lanes and statuses.
struct IssueListSwimlaneView: View {
    @Bindable var model: IssueListSurfaceModel
    @Environment(Navigator.self) private var nav
    @Environment(WorkspaceSession.self) private var session
    @FocusState private var focused: Bool

    static let cellWidth: CGFloat = 280
    static let gap: CGFloat = 16

    var body: some View {
        let statuses = model.visibleStatuses
        let track = CGFloat(statuses.count) * Self.cellWidth + CGFloat(max(0, statuses.count - 1)) * Self.gap
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 16) {
                    LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                        Section {
                            if model.groupsError && model.lanes.isEmpty {
                                Button(tr("issues", "table.load_more_failed_retry")) { model.retryGroups() }
                                    .buttonStyle(.plain).foregroundStyle(Theme.destructive).padding(.vertical, 32)
                            }
                            ForEach(model.lanes) { lane in
                                IssueListSwimlane(model: model, lane: lane, statuses: statuses)
                            }
                            if model.groupsNextCursor != nil {
                                ProgressView().controlSize(.small).frame(width: track).padding(.vertical, 12)
                                    .onAppear { model.loadMoreGroups() }
                            }
                        } header: {
                            HStack(spacing: Self.gap) {
                                ForEach(statuses, id: \.self) { status in
                                    IssueListSwimlaneStatusHeader(model: model, status: status, total: model.laneStatusTotals[status] ?? 0)
                                }
                            }
                            .padding(.bottom, 8)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                        }
                    }
                    .frame(width: track)
                    if !model.hiddenStatuses.isEmpty {
                        IssueListHiddenColumnsPanel(model: model).frame(width: 240)
                    }
                    if model.peekID != nil { Color.clear.frame(width: 520, height: 1) }
                }
                .padding(16)
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

private struct IssueListSwimlaneStatusHeader: View {
    let model: IssueListSurfaceModel
    let status: IssueStatusKey
    let total: Int
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        HStack {
            IssueListStatusHeading(status: status, count: total)
            Spacer()
            Menu {
                let fixed = model.baseline?.status.contains(status.rawValue) == true
                Button { model.state.hideStatus(status.rawValue) } label: {
                    Label(tr("issues", "board.hide_column"), systemImage: "eye.slash")
                }
                .disabled(fixed)
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("issues", "board.hide_column"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: IssueListSwimlaneView.cellWidth)
        .background(RoundedRectangle(cornerRadius: 12).fill(IssueListFormat.columnBackground(session.issueListStatusCategory(status))))
    }
}

private struct IssueListSwimlane: View {
    let model: IssueListSurfaceModel
    let lane: IssueListLane
    let statuses: [IssueStatusKey]
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav

    var body: some View {
        let collapsed = (model.state.collapsedSwimlanes[model.state.swimlaneGrouping.rawValue] ?? []).contains(lane.rawID)
        let laneTotal = statuses.reduce(0) { sum, s in
            sum + (lane.cells[s].flatMap { model.groupBranches[$0]?.total } ?? 0)
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if !lane.pinned {
                    Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Button {
                    withAnimation(.snappy(duration: 0.15)) { model.state.toggleSwimlaneCollapsed(lane.rawID) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                        if let parent = lane.parent {
                            session.issues.catalog.icon(for: parent.status, size: 13)
                        }
                        if let pid = lane.projectID, let p = model.project(pid) { ProjectIconView(icon: p.icon, size: 15) }
                        if let actor = lane.actor { ActorAvatar(type: actor.type, id: actor.id, size: 18) }
                        Text(lane.title).font(Theme.Font.bodyMedium.weight(.semibold)).lineLimit(1)
                        if !lane.identifier.isEmpty {
                            Text(lane.identifier).font(Theme.Font.micro.weight(.medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                        Text("\(laneTotal)").font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("issues", "swimlane.toggle_collapse"))
                if let parent = lane.parent {
                    Button { nav.push(.issue(parent.id)) } label: {
                        Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(tr("issues", "swimlane.open_parent"))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .modifier(IssueListLaneDrag(model: model, lane: lane))
            if !collapsed {
                HStack(alignment: .top, spacing: IssueListSwimlaneView.gap) {
                    ForEach(statuses, id: \.self) { status in
                        IssueListSwimlaneCell(model: model, lane: lane, status: status,
                                              branch: lane.cells[status].flatMap { model.groupBranches[$0] })
                    }
                }
            }
        }
    }
}

/// Non-pinned lanes reorder by dragging their header.
private struct IssueListLaneDrag: ViewModifier {
    let model: IssueListSurfaceModel
    let lane: IssueListLane
    static let prefix = "multica-lane:"

    func body(content: Content) -> some View {
        if lane.pinned {
            content
        } else {
            content
                .draggable(Self.prefix + lane.rawID) { Text(lane.title).font(Theme.Font.bodyMedium).padding(6) }
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, raw.hasPrefix(Self.prefix) else { return false }
                    model.moveLane(String(raw.dropFirst(Self.prefix.count)), before: lane.rawID)
                    return true
                }
        }
    }
}

private struct IssueListSwimlaneCell: View {
    let model: IssueListSurfaceModel
    let lane: IssueListLane
    let status: IssueStatusKey
    let branch: IssueListBranch?
    @Environment(WorkspaceSession.self) private var session
    @Environment(ModalCenter.self) private var modals
    @State private var targeted = false

    var body: some View {
        let archived = session.issueListStatusEntry(status)?.archivedAt != nil
        let ids = branch?.ids ?? []
        VStack(spacing: 8) {
            VStack(spacing: 8) {
                ForEach(ids, id: \.self) { id in
                    if let m = session.issues.model(id) {
                        IssueListCardView(issueModel: m, model: model, grouping: model.state.swimlaneGrouping.rawValue)
                            .id(id)
                            .draggable(IssueListSurfaceModel.dragPrefix + id) {
                                IssueListCardView(issueModel: m, model: model, grouping: model.state.swimlaneGrouping.rawValue)
                                    .frame(width: IssueListSwimlaneView.cellWidth - 24)
                            }
                            .dropDestination(for: String.self) { items, _ in drop(items, before: id) }
                    }
                }
                if ids.isEmpty && !(branch?.isLoading ?? false) {
                    Text("—").font(Theme.Font.caption).foregroundStyle(.secondary).padding(.vertical, 20)
                }
                if let branch {
                    IssueListGroupFooter(model: model, branch: branch)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 6).fill(targeted && !lane.orphan && !archived ? Color.accentColor.opacity(0.1) : .clear))
            .dropDestination(for: String.self) { items, _ in drop(items, before: nil) } isTargeted: { targeted = $0 }
            if !lane.orphan && !archived {
                Button {
                    var draft = model.createDraft(status: status)
                    switch lane.patch.assignee {
                    case .set(let a): draft.assignee = a
                    case .clear: draft.assignee = nil
                    case .unchanged: break
                    }
                    if case .set(let p) = lane.patch.projectID { draft.projectID = p }
                    if case .clear = lane.patch.projectID, model.scope.projectID == nil { draft.projectID = nil }
                    if case .set(let parent) = lane.patch.parentIssueID { draft.parentIssueID = parent }
                    modals.createIssue(draft)
                } label: {
                    Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("issues", "board.add_issue_tooltip"))
            }
        }
        .padding(8)
        .frame(width: IssueListSwimlaneView.cellWidth)
        .frame(minHeight: 120, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(IssueListFormat.columnBackground(session.issueListStatusCategory(status))))
    }

    private func drop(_ items: [String], before: String?) -> Bool {
        guard !lane.orphan, let id = items.first.flatMap(IssueListSurfaceModel.draggedID), id != before else { return false }
        model.drop(id, intoLane: lane, status: status, before: before)
        return true
    }
}
