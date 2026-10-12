import MulticaCore
import Observation
import SwiftUI

/// Project Gantt data (upstream projectGanttIssuesOptions + ganttCanvasRows):
/// every scheduled issue of the project, filtered and ordered client-side.
@MainActor
@Observable
final class IssueListGanttModel {
    unowned let surface: IssueListSurfaceModel
    private(set) var items: [IssueListClientFilter.Item] = []
    private(set) var loading = true
    @ObservationIgnored private var raw: [IssueListClientFilter.Item] = []
    @ObservationIgnored private var running: Set<String>?

    init(surface: IssueListSurfaceModel) {
        self.surface = surface
    }

    var issueIDs: [String] { items.map(\.issue.id) }

    func reload() async {
        guard let projectID = surface.scope.projectID else { return }
        var all: [IssueListClientFilter.Item] = []
        var offset = 0
        while offset < 10_000 {
            var p = ListIssuesParams()
            surface.scope.applyListFilter(&p)
            p.projectId = projectID
            p.scheduled = true
            p.limit = 500
            p.offset = offset
            guard let page = try? await surface.session.api.listIssues(params: p) else { break }
            for issue in page.issues {
                surface.session.issues.upsert(issue)
                all.append(IssueListClientFilter.Item(issue: issue, properties: surface.extras(issue.id).properties))
            }
            if page.issues.count < 500 || all.count >= page.total { break }
            offset += 500
        }
        surface.markSelfInduced()
        raw = all
        if surface.state.agentRunningFilter {
            let agents = (try? await surface.session.api.getWorkspaceWorkingAgents(type: "issue")) ?? []
            running = Set(agents.flatMap(\.issueIds))
        }
        recompute()
        loading = false
    }

    func recompute() {
        let s = surface.state
        let live = raw.map { item -> IssueListClientFilter.Item in
            var copy = item
            if let issue = surface.session.issues.model(item.issue.id)?.issue { copy.issue = issue }
            return copy
        }
        let projectStatus = surface.projectsByID.isEmpty ? nil : surface.projectsByID.mapValues(\.status)
        let filtered = IssueListClientFilter.apply(live, state: s, ignoreProjects: true, runningIssueIDs: running, projectStatusByID: projectStatus)
        let canvas = IssueListClientFilter.ganttRows(filtered, showCompleted: s.ganttShowCompleted, catalog: surface.session.issues.catalog)
        let field = s.sortBy == "position" ? "start_date" : s.sortBy
        let order = IssueListStatusColumns.columnKeys(entries: surface.session.issueListStatusEntries, includeArchived: true)
        let sorted = IssueListClientFilter.sort(canvas, field: field, direction: s.sortBy == "position" ? .asc : s.sortDirection, statusOrder: order)
        if sorted != items { items = sorted }
    }
}

/// Project timeline (upstream gantt-view.tsx): zoomable day/week/month axis,
/// a bar per scheduled issue (a diamond for single-date issues).
struct IssueListGanttView: View {
    @Bindable var model: IssueListSurfaceModel
    @State private var didScroll = false

    private static let rowHeight: CGFloat = 36
    private static let headerHeight: CGFloat = 56
    private static let leftWidth: CGFloat = 320

    private var dayPx: CGFloat {
        switch model.state.ganttZoom {
        case .day: return 36
        case .week: return 14
        case .month: return 6
        }
    }

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private static func day(_ s: String?) -> Date? {
        s.flatMap { IssueListQuery.parseDay($0, utc) }
    }

    private func range(_ items: [IssueListClientFilter.Item], today: Date) -> (start: Date, end: Date) {
        let cal = Self.utc
        let pad: Int = { switch model.state.ganttZoom { case .day: return 21; case .week: return 60; case .month: return 180 } }()
        var lo = cal.date(byAdding: .day, value: -pad, to: today)!
        var hi = cal.date(byAdding: .day, value: pad, to: today)!
        for item in items {
            for d in [Self.day(item.issue.startDate), Self.day(item.issue.dueDate)].compactMap({ $0 }) {
                lo = min(lo, d)
                hi = max(hi, d)
            }
        }
        let edge = max(2, Int((Double(pad) / 6).rounded()))
        return (cal.date(byAdding: .day, value: -edge, to: lo)!, cal.date(byAdding: .day, value: edge + 1, to: hi)!)
    }

    var body: some View {
        let gantt = model.gantt
        let items = gantt.items
        let cal = Self.utc
        let today = Self.day(IssueListQuery.day(offset: 0)) ?? Date()
        let r = range(items, today: today)
        let totalDays = max(1, cal.dateComponents([.day], from: r.start, to: r.end).day ?? 1)
        let todayOffset = cal.dateComponents([.day], from: r.start, to: today).day ?? 0
        let timelineWidth = CGFloat(totalDays) * dayPx
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $model.state.ganttZoom) {
                    Text(tr("issues", "gantt.zoom_day")).tag(IssueListGanttZoom.day)
                    Text(tr("issues", "gantt.zoom_week")).tag(IssueListGanttZoom.week)
                    Text(tr("issues", "gantt.zoom_month")).tag(IssueListGanttZoom.month)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                Spacer()
                Button(tr("issues", "gantt.show_completed")) { model.state.ganttShowCompleted.toggle() }
                    .buttonStyle(IssueListToolbarButtonStyle(active: model.state.ganttShowCompleted))
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .overlay(alignment: .bottom) { Divider() }
            if gantt.loading && items.isEmpty {
                IssueListSkeleton(mode: .list)
            } else if items.isEmpty {
                Text(tr("issues", "gantt.empty")).font(Theme.Font.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 0) {
                                Text(tr("issues", "gantt.header_issue")).font(Theme.Font.micro.weight(.medium)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 12).padding(.bottom, 6)
                                    .frame(width: Self.leftWidth, height: Self.headerHeight, alignment: .bottomLeading)
                                    .overlay(alignment: .trailing) { Divider() }
                                IssueListGanttAxis(start: r.start, days: totalDays, dayPx: dayPx, zoom: model.state.ganttZoom, todayOffset: todayOffset)
                                    .frame(width: timelineWidth, height: Self.headerHeight)
                            }
                            .overlay(alignment: .bottom) { Divider() }
                            ZStack(alignment: .topLeading) {
                                IssueListGanttGrid(start: r.start, days: totalDays, dayPx: dayPx, todayOffset: todayOffset,
                                                   height: CGFloat(items.count) * Self.rowHeight)
                                    .offset(x: Self.leftWidth)
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(items, id: \.issue.id) { item in
                                        if let m = model.session.issues.model(item.issue.id) {
                                            IssueListGanttRow(model: model, issueModel: m, start: r.start, totalDays: totalDays, dayPx: dayPx,
                                                              leftWidth: Self.leftWidth, height: Self.rowHeight)
                                        }
                                    }
                                }
                            }
                            .id("gantt-body")
                        }
                        .frame(width: Self.leftWidth + timelineWidth, alignment: .leading)
                        .background(alignment: .topLeading) {
                            Color.clear.frame(width: 1, height: 1)
                                .offset(x: max(0, Self.leftWidth + CGFloat(todayOffset) * dayPx - 240))
                                .id("gantt-today")
                        }
                    }
                    .onAppear {
                        guard !didScroll else { return }
                        didScroll = true
                        DispatchQueue.main.async { proxy.scrollTo("gantt-today", anchor: .topLeading) }
                    }
                }
            }
        }
        .onChange(of: model.state) { _, _ in gantt.recompute() }
    }
}

private struct IssueListGanttAxis: View {
    let start: Date
    let days: Int
    let dayPx: CGFloat
    let zoom: IssueListGanttZoom
    let todayOffset: Int

    var body: some View {
        Canvas { ctx, size in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            var monthFmt = Date.FormatStyle.dateTime.month(.abbreviated).year()
            monthFmt.timeZone = cal.timeZone
            var blockStart = 0
            for i in 0...days {
                let d = cal.date(byAdding: .day, value: i, to: start)!
                let comps = cal.dateComponents([.day, .weekday], from: d)
                let x = CGFloat(i) * dayPx
                if comps.day == 1 || i == days {
                    if i > blockStart {
                        let label = cal.date(byAdding: .day, value: blockStart, to: start)!.formatted(monthFmt)
                        ctx.draw(Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary),
                                 at: CGPoint(x: CGFloat(blockStart) * dayPx + 6, y: 14), anchor: .leading)
                    }
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(p, with: .color(.primary.opacity(0.08)), lineWidth: 1)
                    blockStart = i
                }
                guard i < days else { continue }
                let tick = zoom == .day || (zoom == .week && comps.weekday == 2) || (zoom == .month && comps.day == 1)
                if tick {
                    ctx.draw(Text("\(comps.day ?? 0)").font(.system(size: 10)).foregroundColor(i == todayOffset ? .accentColor : .secondary),
                             at: CGPoint(x: x + (zoom == .day ? dayPx / 2 : 2), y: size.height - 12), anchor: zoom == .day ? .center : .leading)
                }
            }
        }
    }
}

private struct IssueListGanttGrid: View {
    let start: Date
    let days: Int
    let dayPx: CGFloat
    let todayOffset: Int
    let height: CGFloat

    var body: some View {
        Canvas { ctx, size in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            for i in 0..<days {
                let d = cal.date(byAdding: .day, value: i, to: start)!
                let comps = cal.dateComponents([.day, .weekday], from: d)
                let x = CGFloat(i) * dayPx
                if comps.weekday == 1 || comps.weekday == 7, dayPx >= 14 {
                    ctx.fill(Path(CGRect(x: x, y: 0, width: dayPx, height: size.height)), with: .color(.primary.opacity(0.025)))
                }
                if comps.day == 1 || (dayPx >= 14 && comps.weekday == 2) {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(p, with: .color(.primary.opacity(comps.day == 1 ? 0.08 : 0.04)), lineWidth: 1)
                }
            }
            let tx = CGFloat(todayOffset) * dayPx + dayPx / 2
            var t = Path()
            t.move(to: CGPoint(x: tx, y: 0)); t.addLine(to: CGPoint(x: tx, y: size.height))
            ctx.stroke(t, with: .color(.accentColor.opacity(0.7)), lineWidth: 1.5)
        }
        .frame(width: CGFloat(days) * dayPx, height: height)
        .allowsHitTesting(false)
    }
}

private struct IssueListGanttRow: View {
    let model: IssueListSurfaceModel
    let issueModel: IssueModel
    let start: Date
    let totalDays: Int
    let dayPx: CGFloat
    let leftWidth: CGFloat
    let height: CGFloat
    @Environment(Navigator.self) private var nav
    @Environment(WorkspaceSession.self) private var session
    @State private var hovering = false

    var body: some View {
        let issue = issueModel.issue
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let s = issue.startDate.flatMap { IssueListQuery.parseDay($0, cal) }
        let d = issue.dueDate.flatMap { IssueListQuery.parseDay($0, cal) }
        let inverted = s != nil && d != nil && s! > d!
        let lo = (s != nil && d != nil) ? min(s!, d!) : (s ?? d)
        let hi = (s != nil && d != nil) ? max(s!, d!) : (s ?? d)
        let category = issue.category(in: session.issues.catalog)
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                session.issues.catalog.icon(for: issue.status, size: 13)
                PriorityIcon(priority: issue.priority)
                Text(issue.identifier).font(Theme.Font.caption).foregroundStyle(.secondary).frame(width: 56, alignment: .leading).lineLimit(1)
                Text(issue.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if let p = model.project(issue.projectID) { ProjectIconView(icon: p.icon, size: 13) }
                if let a = issue.assignee { ActorAvatar(type: a.type, id: a.id, size: 18) }
            }
            .font(Theme.Font.body)
            .padding(.horizontal, 12)
            .frame(width: leftWidth, height: height)
            .background(model.peekID == issue.id ? Theme.brand.opacity(0.06) : Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .trailing) { Divider() }
            .contentShape(Rectangle())
            .onTapGesture { IssueListOpen.click(issue, model: model, nav: nav) }
            ZStack(alignment: .leading) {
                if let lo, let hi {
                    let sIdx = max(0, cal.dateComponents([.day], from: start, to: lo).day ?? 0)
                    let eIdx = min(totalDays, (cal.dateComponents([.day], from: start, to: hi).day ?? 0) + 1)
                    if eIdx > sIdx {
                        let single = s == nil || d == nil
                        let width = single ? max(dayPx, 12) : CGFloat(eIdx - sIdx) * dayPx
                        Group {
                            if single {
                                RoundedRectangle(cornerRadius: 2).fill(Self.color(category)).frame(width: 12, height: 12).rotationEffect(.degrees(45))
                            } else {
                                RoundedRectangle(cornerRadius: 6).fill(Self.color(category))
                                    .frame(width: width, height: 20)
                                    .overlay(alignment: .leading) {
                                        if width > 60 {
                                            Text(issue.title).font(Theme.Font.micro).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 8)
                                        }
                                    }
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(inverted ? Theme.destructive : .clear, lineWidth: 2))
                            }
                        }
                        .offset(x: CGFloat(sIdx) * dayPx)
                        .help("\(issue.title)\n\(lo.formatted(date: .abbreviated, time: .omitted)) → \(hi.formatted(date: .abbreviated, time: .omitted))"
                              + (inverted ? "\n" + tr("issues", "gantt.inverted_dates_warning") : ""))
                        .onTapGesture { IssueListOpen.click(issue, model: model, nav: nav) }
                    }
                }
            }
            .frame(width: CGFloat(totalDays) * dayPx, height: height, alignment: .leading)
        }
        .frame(height: height)
        .background(hovering ? Theme.hover : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
        .onHover { hovering = $0 }
        .contextMenu { IssueListActionsMenu(issue: issue, model: model) }
    }

    static func color(_ category: StatusCategory) -> Color {
        switch category {
        case .started: return Theme.warning
        case .done: return Theme.info
        case .closed: return Color.secondary
        default: return Color.secondary.opacity(0.7)
        }
    }
}
