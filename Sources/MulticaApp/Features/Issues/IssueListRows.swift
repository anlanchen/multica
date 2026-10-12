import AppKit
import MulticaCore
import SwiftUI

/// What a click on a row/card opens: the preferred target, Shift+Click the
/// other one (peek ↔ page), ⌘-click a background tab.
@MainActor
enum IssueListOpen {
    static func click(_ issue: Issue, model: IssueListSurfaceModel, nav: Navigator) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            nav.openInNewTab(.issue(issue.id), title: issue.identifier, activate: false)
            return
        }
        let peekMode = IssueListPrefs.openMode == "peek"
        let wantsPeek = flags.contains(.shift) ? !peekMode : peekMode
        if wantsPeek {
            if flags.contains(.shift) && model.peekID == issue.id { model.peekID = nil } else { model.peekID = issue.id }
            model.focusedID = issue.id
            return
        }
        nav.push(.issue(issue.id), title: "\(issue.identifier) \(issue.title)")
    }
}

/// One list row (upstream list-row.tsx). Observes only its own issue model,
/// extras and activity entry.
struct IssueListRowView: View {
    let issueModel: IssueModel
    let model: IssueListSurfaceModel
    @Environment(Navigator.self) private var nav
    @State private var hovering = false

    var body: some View {
        let issue = issueModel.issue
        let extras = model.extras(issue.id)
        let card = model.state.cardProperties
        let selected = model.selection.contains(issue.id)
        let peeked = model.peekID == issue.id
        let focused = model.focusedID == issue.id
        HStack(spacing: 8) {
            ZStack {
                if selected || hovering {
                    Button { model.toggleSelection(issue.id) } label: {
                        Image(systemName: selected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selected ? Theme.brand : .secondary)
                    }
                    .buttonStyle(.plain)
                } else if card.priority && issue.priority != .none {
                    PriorityIcon(priority: issue.priority)
                }
            }
            .frame(width: 16, height: 16)
            Text(issue.identifier).font(Theme.Font.caption).foregroundStyle(.secondary).frame(minWidth: 64, alignment: .leading)
            IssueListActivityBadge(entry: model.activity.entry(issue.id), activeRuns: issueModel.activeRuns)
            HStack(spacing: 6) {
                Text(issue.title).lineLimit(1).truncationMode(.tail)
                IssueListCustomStatusChip(status: issue.status)
                if let dup = extras.duplicateOf { IssueListDuplicateMarker(identifier: dup) }
                if card.childProgress, let p = extras.childProgress ?? model.progress(issue.id) {
                    IssueListProgressPill(done: p.done, total: p.total)
                }
                if card.labels, !issue.labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(issue.labels.prefix(3)) { LabelChip(label: $0) }
                        if issue.labels.count > 3 {
                            Text("+\(issue.labels.count - 3)").font(Theme.Font.micro).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 4)
                    .frame(maxWidth: 260, alignment: .leading)
                }
                IssueListCardPropertyChips(model: model, extras: extras, limit: 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if card.project, let project = model.project(issue.projectID) {
                HStack(spacing: 4) {
                    ProjectIconView(icon: project.icon, size: 13)
                    Text(project.title).lineLimit(1)
                }
                .font(Theme.Font.caption).foregroundStyle(.secondary).frame(maxWidth: 140, alignment: .trailing).fixedSize(horizontal: true, vertical: false)
            }
            if card.startDate, let d = issue.startDate {
                Text(IssueListFormat.shortDay(d)).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            if card.dueDate, let d = issue.dueDate {
                Text(IssueListFormat.shortDay(d)).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            if card.assignee, let a = issue.assignee {
                ActorAvatar(type: a.type, id: a.id, size: 18)
            }
        }
        .font(Theme.Font.body)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Theme.brand.opacity(0.1) : (hovering || focused ? Theme.hover : .clear))
        )
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(peeked ? Theme.brand.opacity(0.5) : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { IssueListOpen.click(issue, model: model, nav: nav) }
        .contextMenu { IssueListActionsMenu(issue: issue, model: model) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// One board card (upstream board-card.tsx), with inline priority, assignee
/// and date pickers.
struct IssueListCardView: View {
    let issueModel: IssueModel
    let model: IssueListSurfaceModel
    /// The board's grouping, so the card hides what the column already says.
    var grouping: String = "status"
    @Environment(Navigator.self) private var nav
    @State private var hovering = false

    var body: some View {
        let issue = issueModel.issue
        let extras = model.extras(issue.id)
        let card = model.state.cardProperties
        let peeked = model.peekID == issue.id
        let focused = model.focusedID == issue.id
        let showAssignee = card.assignee && grouping != "assignee" && issue.assignee != nil
        let showStart = card.startDate && issue.startDate != nil
        let showDue = card.dueDate && issue.dueDate != nil
        let progress = card.childProgress ? (extras.childProgress ?? model.progress(issue.id)) : nil
        let showAssigneeName = showAssignee && !showStart && !showDue
        let showUpdated = showAssigneeName && progress == nil
        let project = card.project && grouping != "project" ? model.project(issue.projectID) : nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if card.priority && issue.priority != .none {
                    PriorityPicker(current: issue.priority, showLabel: false, style: nil) { p in
                        var patch = IssueListPatch()
                        patch.priority = p
                        model.update(issue.id, patch, errorMessage: tr("issues", "card.update_failed"))
                    }
                    .frame(width: 20, height: 20)
                }
                Text(issue.identifier).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                if let dup = extras.duplicateOf { IssueListDuplicateMarker(identifier: dup) }
                Spacer(minLength: 4)
                IssueListActivityBadge(entry: model.activity.entry(issue.id), activeRuns: issueModel.activeRuns)
            }
            Text(issue.title)
                .font(Theme.Font.bodyMedium)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            if card.description, let preview = extras.preview(issue.description), !preview.isEmpty {
                Text(preview).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1).padding(.top, 4)
            }
            let customStatus = IssueListStatusColumns.isCustom(issue.status, entry: model.session.issueListStatusEntry(issue.status))
            let customProps = model.cardCustomProperties(extras, excluding: grouping)
            if customStatus || project != nil || (card.labels && !issue.labels.isEmpty) || !customProps.isEmpty {
                IssueListFlowLayout(spacing: 6) {
                    IssueListCustomStatusChip(status: issue.status)
                    if let project {
                        HStack(spacing: 4) {
                            ProjectIconView(icon: project.icon, size: 12)
                            Text(project.title).lineLimit(1)
                        }
                        .font(Theme.Font.micro).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                        .frame(maxWidth: 160, alignment: .leading)
                    }
                    if card.labels {
                        ForEach(issue.labels.prefix(2)) { LabelChip(label: $0) }
                        if issue.labels.count > 2 {
                            Text("+\(issue.labels.count - 2)").font(Theme.Font.micro).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(customProps) { p in
                        IssueListPropertyChip(property: p, value: extras.properties[p.id])
                    }
                }
                .padding(.top, 6)
            }
            if showAssignee || showStart || showDue || progress != nil {
                HStack(spacing: 8) {
                    if showAssignee, let a = issue.assignee {
                        AssigneePicker(current: a, showLabel: showAssigneeName, style: nil) { ref in
                            var patch = IssueListPatch()
                            patch.assignee = IssueListField(ref)
                            model.update(issue.id, patch, errorMessage: tr("issues", "card.update_failed"))
                        }
                        .font(Theme.Font.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                    if showStart, let d = issue.startDate {
                        IssueListDayPicker(value: d, icon: "calendar.badge.clock", destructive: false) { v in
                            var patch = IssueListPatch()
                            patch.startDate = IssueListField(v)
                            model.update(issue.id, patch, errorMessage: tr("issues", "card.update_failed"))
                        }
                    }
                    if showDue, let d = issue.dueDate {
                        IssueListDayPicker(value: d, icon: "calendar", destructive: IssueListFormat.isPast(d)) { v in
                            var patch = IssueListPatch()
                            patch.dueDate = IssueListField(v)
                            model.update(issue.id, patch, errorMessage: tr("issues", "card.update_failed"))
                        }
                    }
                    if let progress {
                        HStack(spacing: 4) {
                            IssueListProgressRing(done: progress.done, total: progress.total)
                            Text("\(progress.done)/\(progress.total)").font(Theme.Font.micro.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    if showUpdated {
                        Text(tr("issues", "card.updated_ago", ["time": Formatters.relative(issue.updatedAt)]))
                            .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(peeked ? Theme.brand.opacity(0.5) : (hovering || focused ? Color.primary.opacity(0.15) : Theme.border), lineWidth: peeked ? 2 : 0.5))
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture { IssueListOpen.click(issue, model: model, nav: nav) }
        .contextMenu { IssueListActionsMenu(issue: issue, model: model) }
    }
}

extension IssueListRowExtras {
    /// Cached `descriptionPreview` (no Markdown work in `body`).
    func preview(_ description: String?) -> String? {
        guard let description, !description.isEmpty else { return nil }
        if previewSource == description { return previewText }
        let text = IssueListText.descriptionPreview(description)
        previewSource = description
        previewText = text
        return text
    }
}

extension IssueListSurfaceModel {
    /// Custom properties toggled onto cards that this issue has a value for.
    func cardCustomProperties(_ extras: IssueListRowExtras, excluding grouping: String) -> [IssueProperty] {
        let grouped = IssueListOptions.propertyID(fromKey: grouping)
        return state.cardPropertyIds.compactMap { id in
            guard id != grouped, let p = property(id), extras.properties[id] != nil else { return nil }
            return p
        }
    }
}

struct IssueListCardPropertyChips: View {
    let model: IssueListSurfaceModel
    let extras: IssueListRowExtras
    var limit = 3

    var body: some View {
        let props = model.cardCustomProperties(extras, excluding: "")
        if !props.isEmpty {
            HStack(spacing: 4) {
                ForEach(props.prefix(limit)) { p in IssueListPropertyChip(property: p, value: extras.properties[p.id]) }
            }
            .padding(.leading, 4)
        }
    }
}

/// A custom property value as a small pill (`CustomPropertyValueDisplay`).
struct IssueListPropertyChip: View {
    let property: IssueProperty
    let value: JSONValue?
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 8))
            Text(display).lineLimit(1)
        }
        .font(Theme.Font.micro)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .frame(maxWidth: 160, alignment: .leading)
        .help(property.name)
    }

    private var display: String {
        if property.type == "date" { return value?.stringValue.map(IssueListFormat.shortDay) ?? "" }
        return IssueListPropertyText.display(property, value, session: session)
    }
}

/// Names custom statuses on cards; built-ins stay silent.
struct IssueListCustomStatusChip: View {
    let status: IssueStatusKey
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        let entry = session.issueListStatusEntry(status)
        if IssueListStatusColumns.isCustom(status, entry: entry), let entry {
            HStack(spacing: 4) {
                StatusIcon(status: status, entry: entry, size: 11)
                Text(entry.name).lineLimit(1)
            }
            .font(Theme.Font.micro)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .frame(maxWidth: 160, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct IssueListDuplicateMarker: View {
    let identifier: String

    var body: some View {
        Image(systemName: "equal.circle")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .help(identifier)
    }
}

struct IssueListProgressPill: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            IssueListProgressRing(done: done, total: total)
            Text("\(done)/\(total)").font(Theme.Font.micro.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .fixedSize()
    }
}

struct IssueListProgressRing: View {
    let done: Int
    let total: Int

    var body: some View {
        ProgressRing(value: total > 0 ? Double(done) / Double(total) : 0, size: 13,
                     color: done >= total && total > 0 ? Theme.success : Theme.brand)
    }
}

/// Compact date trigger with a calendar popover and clear.
struct IssueListDayPicker: View {
    let value: String
    let icon: String
    let destructive: Bool
    let onChange: (String?) -> Void
    @State private var open = false
    @State private var draft = Date()

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9))
                Text(IssueListFormat.shortDay(value))
            }
            .font(Theme.Font.caption)
            .foregroundStyle(destructive ? Theme.destructive : .secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                DatePicker("", selection: $draft, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                HStack {
                    Button(tr("issues", "actions.due_clear")) { open = false; onChange(nil) }
                    Spacer()
                    Button(tr("common", "save")) { open = false; onChange(IssueListQuery.dayString(draft)) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .onAppear { draft = IssueListQuery.parseDay(value) ?? Date() }
        }
    }
}
