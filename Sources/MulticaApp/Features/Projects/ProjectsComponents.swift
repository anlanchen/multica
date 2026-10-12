import AppKit
import MulticaCore
import SwiftUI

/// Rows of a dropdown-style popover: icon, label, trailing check on the
/// current value (upstream DropdownMenuItem lists for status / priority).
struct ProjectsChoiceList<ID: Hashable, Icon: View>: View {
    let ids: [ID]
    let selected: ID?
    let label: (ID) -> String
    @ViewBuilder let icon: (ID) -> Icon
    let onPick: (ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ids, id: \.self) { id in
                Button { onPick(id) } label: {
                    HStack(spacing: 8) {
                        icon(id).frame(width: 14)
                        Text(label(id)).lineLimit(1)
                        Spacer(minLength: 8)
                        if id == selected {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .font(Theme.Font.body)
                }
                .buttonStyle(HoverRowButtonStyle())
            }
        }
        .padding(4)
        .frame(width: 176)
    }
}

struct ProjectsStatusDot: View {
    let status: String
    var body: some View {
        Circle().fill(ProjectsLabels.statusDot(status)).frame(width: 8, height: 8)
    }
}

/// Status menu content shared by the badge, the sidebar row and the create pill.
struct ProjectsStatusMenu: View {
    let current: String?
    let onPick: (String) -> Void

    var body: some View {
        ProjectsChoiceList(ids: ProjectsConfig.statusOrder, selected: current, label: ProjectsLabels.status) {
            ProjectsStatusDot(status: $0)
        } onPick: { onPick($0) }
    }
}

struct ProjectsPriorityMenu: View {
    let current: String?
    let onPick: (String) -> Void

    var body: some View {
        ProjectsChoiceList(ids: ProjectsConfig.priorityOrder, selected: current, label: ProjectsLabels.priority) {
            PriorityIcon(priority: IssuePriority(rawValue: $0) ?? .none)
        } onPick: { onPick($0) }
    }
}

/// Upstream `ProjectStatusBadge`: a filled status chip that opens the menu.
struct ProjectsStatusBadge: View {
    let status: String
    let onChange: (String) -> Void
    @State private var open = false

    var body: some View {
        let colors = ProjectsLabels.badge(status)
        Button { open.toggle() } label: {
            Text(ProjectsLabels.status(status))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(colors.foreground)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(colors.background))
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ProjectsStatusMenu(current: status) { s in
                open = false
                if s != status { onChange(s) }
            }
        }
    }
}

/// Upstream `ProjectPriorityBadge`: icon + colored label.
struct ProjectsPriorityBadge: View {
    let priority: String
    let onChange: (String) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                PriorityIcon(priority: IssuePriority(rawValue: priority) ?? .none, size: 13)
                Text(ProjectsLabels.priority(priority))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ProjectsLabels.priorityColor(priority))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            .fixedSize()
            .hoverHighlight(cornerRadius: Theme.Radius.small)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ProjectsPriorityMenu(current: priority) { p in
                open = false
                if p != priority { onChange(p) }
            }
        }
    }
}

/// Upstream `ProjectLeadPicker`: searchable members + agents with a
/// "No lead" row; the trigger is supplied by the caller.
struct ProjectsLeadPicker<Trigger: View>: View {
    @Environment(WorkspaceSession.self) private var session
    let leadType: String?
    let leadID: String?
    var noLeadLabel = tr("projects", "lead.no_lead")
    var placeholder = tr("projects", "lead.assign_placeholder")
    var membersGroup = tr("projects", "lead.members_group")
    var agentsGroup = tr("projects", "lead.agents_group")
    var noResults = tr("projects", "lead.no_results")
    let onChange: (ActorRef?) -> Void
    @ViewBuilder let trigger: (_ leadName: String?) -> Trigger
    @State private var open = false

    var body: some View {
        let name: String? = {
            guard let leadType, let leadID, !leadType.isEmpty, !leadID.isEmpty else { return nil }
            return session.actorInfo(type: leadType, id: leadID).name
        }()
        Button { open.toggle() } label: { trigger(name) }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                ProjectsLeadList(
                    current: leadType.flatMap { t in leadID.map { ActorRef(type: t, id: $0) } },
                    noLeadLabel: noLeadLabel, placeholder: placeholder, membersGroup: membersGroup,
                    agentsGroup: agentsGroup, noResults: noResults
                ) { ref in
                    open = false
                    onChange(ref)
                }
            }
    }
}

struct ProjectsLeadList: View {
    @Environment(WorkspaceSession.self) private var session
    let current: ActorRef?
    let noLeadLabel: String
    let placeholder: String
    let membersGroup: String
    let agentsGroup: String
    let noResults: String
    let onPick: (ActorRef?) -> Void
    @State private var filter = ""
    @FocusState private var focused: Bool

    var body: some View {
        let q = filter.lowercased()
        let members = session.directory.members.filter { q.isEmpty || $0.name.lowercased().contains(q) || ProjectsPinyin.matches($0.name, q) }
        let agents = session.directory.agents.filter { $0.archivedAt == nil && (q.isEmpty || $0.name.lowercased().contains(q) || ProjectsPinyin.matches($0.name, q)) }
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: $filter)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .focused($focused)
                .padding(.horizontal, 10)
                .frame(height: 30)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    row(selected: current == nil, action: { onPick(nil) }) {
                        Image(systemName: "person.crop.circle.badge.minus").foregroundStyle(.secondary)
                        Text(noLeadLabel).foregroundStyle(.secondary)
                    }
                    if !members.isEmpty {
                        groupHeader(membersGroup)
                        ForEach(members) { m in
                            row(selected: current?.type == "member" && current?.id == m.userID, action: { onPick(ActorRef(type: "member", id: m.userID)) }) {
                                AvatarView(name: m.name, url: m.avatarURL, size: 18)
                                Text(m.name).lineLimit(1)
                            }
                        }
                    }
                    if !agents.isEmpty {
                        groupHeader(agentsGroup)
                        ForEach(agents) { a in
                            row(selected: current?.type == "agent" && current?.id == a.id, action: { onPick(ActorRef(type: "agent", id: a.id)) }) {
                                AvatarView(name: a.name, url: a.avatarURL, kind: .agent, size: 18)
                                Text(a.name).lineLimit(1)
                            }
                        }
                    }
                    if members.isEmpty && agents.isEmpty && !filter.isEmpty {
                        Text(noResults)
                            .font(Theme.Font.body).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 240)
        }
        .frame(width: 216)
        .onAppear { focused = true }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .medium))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
    }

    private func row<Content: View>(selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                content()
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
            }
            .font(Theme.Font.body)
        }
        .buttonStyle(HoverRowButtonStyle())
    }
}

/// Lead trigger used in table rows and cards: avatar (dashed ring when
/// empty) + name.
struct ProjectsLeadTrigger: View {
    let leadType: String?
    let leadID: String?
    let name: String?
    let emptyLabel: String
    var avatarSize: CGFloat = 18
    var maxNameWidth: CGFloat? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let leadType, let leadID, name != nil {
                ActorAvatar(type: leadType, id: leadID, size: avatarSize)
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: avatarSize, height: avatarSize)
            }
            Text(name ?? emptyLabel)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: maxNameWidth, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .hoverHighlight(cornerRadius: Theme.Radius.small)
    }
}

/// Upstream `DateOnlyPicker` as used by the project start/due pills: an
/// empty-value row above the calendar, picking a day commits and closes.
struct ProjectsDatePicker: View {
    let value: String?
    let placeholder: String
    let emptyLabel: String
    var icon = "calendar"
    var highlightOverdue = false
    var pill = false
    var isPresented: Binding<Bool>? = nil
    let onChange: (String?) -> Void
    @State private var localOpen = false

    var body: some View {
        let open = isPresented ?? $localOpen
        Group {
            if pill {
                Button { open.wrappedValue.toggle() } label: { triggerContent }.buttonStyle(PillButtonStyle())
            } else {
                Button { open.wrappedValue.toggle() } label: { triggerContent.hoverHighlight(cornerRadius: Theme.Radius.small) }
                    .buttonStyle(.plain)
            }
        }
        .popover(isPresented: open, arrowEdge: .bottom) {
            ProjectsCalendar(value: value, emptyLabel: emptyLabel) { v in
                open.wrappedValue = false
                if v != value { onChange(v) }
            }
        }
    }

    private var overdue: Bool {
        guard highlightOverdue, let value, let d = Formatters.dateOnly(value) else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }

    private var triggerContent: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
            if let value, let d = Formatters.dateOnly(value) {
                Text(d.formatted(.dateTime.month(.abbreviated).day()))
                    .foregroundStyle(overdue ? Theme.destructive : .primary)
            } else {
                Text(placeholder).foregroundStyle(.secondary)
            }
        }
        .font(Theme.Font.caption)
        .padding(.horizontal, pill ? 0 : 4)
        .padding(.vertical, pill ? 0 : 2)
    }
}

private struct ProjectsCalendar: View {
    let value: String?
    let emptyLabel: String
    let onPick: (String?) -> Void
    @State private var draft = Date()
    @State private var ready = false

    var body: some View {
        VStack(spacing: 0) {
            Button { onPick(nil) } label: {
                HStack {
                    Text(emptyLabel).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary).opacity(value == nil ? 1 : 0)
                }
                .font(Theme.Font.body)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 0)
            Divider()
            DatePicker("", selection: $draft, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(10)
                .onChange(of: draft) {
                    if ready { onPick(Formatters.dateOnlyString(draft)) }
                }
        }
        .onAppear {
            draft = value.flatMap(Formatters.dateOnly) ?? Date()
            DispatchQueue.main.async { ready = true }
        }
    }
}

/// Emoji grid with name search (upstream EmojiPicker / emoji-mart). The
/// catalog is built once from Unicode emoji-presentation scalars; search runs
/// against their Unicode names.
struct ProjectsEmojiPicker: View {
    let onSelect: (String) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        let items = q.isEmpty ? ProjectsEmojiCatalog.all : ProjectsEmojiCatalog.all.filter { $0.name.contains(q) }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).imageScale(.small)
                TextField(tr("common", "avatar_upload.emoji_label"), text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
            }
            .font(Theme.Font.body)
            .padding(.horizontal, 10)
            .frame(height: 32)
            Divider()
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 2), count: 9), spacing: 2) {
                    ForEach(items) { e in
                        Button { onSelect(e.value) } label: {
                            Text(e.value).font(.system(size: 20)).frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: Theme.Radius.small)
                        .help(e.name.capitalized)
                    }
                }
                .padding(6)
            }
            .frame(height: 280)
        }
        .frame(width: 300)
        .onAppear { focused = true }
    }
}

enum ProjectsEmojiCatalog {
    struct Item: Identifiable {
        var id: UInt32
        var value: String
        var name: String
    }

    static let all: [Item] = {
        let ranges: [ClosedRange<UInt32>] = [
            0x1F600...0x1F64F, 0x1F910...0x1F9FF, 0x1F300...0x1F5FF,
            0x1F680...0x1F6FF, 0x1FA70...0x1FAFF, 0x2600...0x27BF,
        ]
        var out: [Item] = []
        for r in ranges {
            for v in r {
                guard let s = Unicode.Scalar(v), s.properties.isEmojiPresentation, let name = s.properties.name else { continue }
                out.append(Item(id: v, value: String(s), name: name))
            }
        }
        return out
    }()
}

/// Upstream `ProjectIcon` at the detail/create sizes: the emoji, or 📁.
struct ProjectsIconGlyph: View {
    let icon: String?
    var size: CGFloat = 28

    var body: some View {
        Text(icon?.projectsNilIfEmpty ?? "📁").font(.system(size: size))
    }
}

/// Completion ring + `done/total`, or an em dash when there are no issues.
struct ProjectsProgressRing: View {
    let project: Project
    var size: CGFloat = 14
    var font: Font = Theme.Font.caption

    var body: some View {
        let m = ProjectsIssueMetrics(project)
        if m.totalCount == 0 {
            Text("—").font(Theme.Font.caption).foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 6) {
                ProgressRing(value: m.fraction, size: size, color: ProjectsLabels.emerald)
                Text("\(m.completedCount)/\(m.totalCount)")
                    .font(font).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

/// Upstream `ProjectChip`: bordered `<emoji> <title>`, resolving the project
/// from the catalog and fetching it when it is not there.
struct ProjectsChip: View {
    @Environment(WorkspaceSession.self) private var session
    let projectID: String
    var fallbackLabel: String? = nil
    @State private var fetched: Project?

    var body: some View {
        let project = session.projects.item(projectID) ?? fetched
        HStack(spacing: 6) {
            ProjectIconView(icon: project?.icon, size: 14)
            Text(project?.title ?? fallbackLabel ?? tr("projects", "chip.fallback_label"))
                .foregroundStyle(project == nil ? .secondary : .primary)
                .lineLimit(1)
        }
        .font(Theme.Font.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: 288, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
        .task(id: projectID) {
            await session.projects.loadIfNeeded()
            if session.projects.item(projectID) == nil { fetched = try? await session.api.getProject(projectID) }
        }
    }
}

/// Upstream `ProjectMentionCard`: the chip as a link to the project.
struct ProjectsMentionCard: View {
    @Environment(Navigator.self) private var nav
    let projectID: String
    var fallbackLabel: String? = nil

    var body: some View {
        Button { nav.push(.project(projectID), title: fallbackLabel) } label: {
            ProjectsChip(projectID: projectID, fallbackLabel: fallbackLabel).hoverHighlight()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(tr("common", "navigation.open_in_new_tab")) { nav.openInNewTab(.project(projectID), title: fallbackLabel) }
        }
    }
}

/// Row kebab: open in new tab, pin/unpin, delete (workspace admin).
struct ProjectsRowActions: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let project: Project
    let pinned: Bool
    let canDelete: Bool
    var alwaysVisible = false
    @State private var confirmDelete = false

    var body: some View {
        Menu {
            Button {
                nav.openInNewTab(.project(project.id), title: project.title)
            } label: { Label(tr("common", "navigation.open_in_new_tab"), systemImage: "arrow.up.right.square") }
            Divider()
            Button {
                let next = !pinned
                Task {
                    do { try await session.projectsSetPinned(project.id, next) } catch { toaster.error(error) }
                }
            } label: {
                Label(pinned ? tr("projects", "page.unpin") : tr("projects", "page.pin"), systemImage: pinned ? "pin.slash" : "pin")
            }
            if canDelete {
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(tr("projects", "page.delete"), systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("projects", "page.row_menu"))
        .projectsDeleteConfirmation(isPresented: $confirmDelete) {
            let id = project.id
            Task {
                do { try await session.projectsDelete(id) } catch { toaster.error(error) }
            }
        }
    }
}

extension View {
    /// Upstream delete dialog copy (`projects:delete_dialog.*`).
    func projectsDeleteConfirmation(isPresented: Binding<Bool>, onConfirm: @escaping () -> Void) -> some View {
        alert(tr("projects", "delete_dialog.title"), isPresented: isPresented) {
            Button(tr("projects", "delete_dialog.cancel"), role: .cancel) {}
            Button(tr("projects", "delete_dialog.confirm"), role: .destructive, action: onConfirm)
        } message: {
            Text(tr("projects", "delete_dialog.description"))
        }
    }
}

/// Collapsible sidebar section header (title + rotating chevron).
struct ProjectsSectionHeader: View {
    let title: String
    @Binding var isOpen: Bool

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Spacer()
            }
            .foregroundStyle(isOpen ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(.plain)
    }
}
