import AppKit
import MulticaCore
import SwiftUI

/// Manual-mode body of the create dialog (upstream ManualCreatePanel).
/// Field values live in local state seeded from the opener or the draft and
/// are written through to the draft as they change.
struct IssueModalManualPanel: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let store: IssueModalDraftStore
    let opener: CreateIssueDraft
    let carry: IssueModalCarry
    let stageSeed: Int?
    let source: IssueModalSourceContext?
    @Binding var expanded: Bool
    let onClose: () -> Void
    let onSwitchMode: (IssueModalCarry) -> Void
    let onLimitReached: () -> Void

    enum Field: String { case status, priority, assignee, labels, project }

    @State private var status: IssueStatusKey = .todo
    @State private var priority: IssuePriority = .none
    @State private var assignee: ActorRef?
    @State private var startDate: String?
    @State private var dueDate: String?
    @State private var labelIDs: [String] = []
    @State private var propertyValues: [String: JSONValue] = [:]
    @State private var projectID: String?
    @State private var parentIssueID: String?
    @State private var parentIssue: IssueModalPickedIssue?
    @State private var stage: Int?
    @State private var maxSiblingStage = 0
    @State private var childIssues: [IssueModalPickedIssue] = []
    @State private var fieldPickerOpen: Field?
    @State private var startPickerOpen = false
    @State private var duePickerOpen = false
    @State private var customPropertyPickerID: String?
    @State private var propertyErrorID: String?
    @State private var unavailablePropertyRemoved = false
    @State private var parentPickerOpen = false
    @State private var childPickerOpen = false
    @State private var submitting = false
    @State private var hasTitle = false
    @State private var settings = IssueModalCreateSettings()
    @State private var seeded = false
    @State private var formResetKey = 0
    @State private var target = IssueModalEditorTarget()
    @FocusState private var titleFocused: Bool

    private var parentLocked: Bool { source != nil && carry.parentIssueID != nil }

    var body: some View {
        VStack(spacing: 0) {
            IssueModalCreateHeader(breadcrumb: tr("modals", "create_issue.manual_breadcrumb"), expanded: $expanded, onClose: onClose)
            IssueModalTitleField(store: store, focused: $titleFocused, onHasTitle: { if hasTitle != $0 { hasTitle = $0 } })
                .id(formResetKey)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            GeometryReader { geo in
                IssueModalBodyEditor(store: store, mode: .manual, placeholder: tr("modals", "create_issue.description_placeholder"),
                                     target: target, minHeight: geo.size.height, maxHeight: geo.size.height,
                                     onSubmit: submit, onFiles: upload)
                    .id(formResetKey)
            }
            .padding(.horizontal, 15)
            .frame(minHeight: 40)
            IssueModalUploadChips(store: store)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            if let source {
                IssueModalSourceContextCard(source: source)
                    .frame(maxHeight: source.expanded ? 300 : nil)
            }
            IssueModalRunHint(assignee: assignee, status: status)
            toolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            if unavailablePropertyRemoved {
                Text(tr("modals", "create_issue.unavailable_property_removed"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
            Divider()
            IssueModalManualFooter(store: store, hasTitle: hasTitle, submitting: submitting,
                                   sourceUnavailable: source != nil && source?.usablePreview == nil,
                                   onUpload: upload, onSwitch: switchToAgent, onSubmit: submit)
        }
        .onAppear(perform: seed)
        .onExitCommand(perform: onClose)
        .sheet(isPresented: $parentPickerOpen) {
            IssueModalIssuePickerDialog(
                title: tr("modals", "create_issue.set_parent_picker.title"),
                description: tr("modals", "create_issue.set_parent_picker.description"),
                excludeIDs: Set(childIssues.map(\.id) + [parentIssueID].compactMap { $0 })
            ) { selected in
                parentIssueID = selected.id
                parentIssue = selected
                stage = nil
            }
        }
        .sheet(isPresented: $childPickerOpen) {
            IssueModalIssuePickerDialog(
                title: tr("modals", "create_issue.add_subissue_picker.title"),
                description: tr("modals", "create_issue.add_subissue_picker.description"),
                excludeIDs: Set(childIssues.map(\.id) + [parentIssueID].compactMap { $0 })
            ) { selected in
                if !childIssues.contains(where: { $0.id == selected.id }) { childIssues.append(selected) }
            }
        }
        .task(id: parentIssueID) { await hydrateParent() }
        .task { await session.properties.loadIfNeeded() }
    }

    // MARK: Toolbar

    private var showStatus: Bool { settings.manualFields.contains("status") || status != .todo || fieldPickerOpen == .status }
    private var showPriority: Bool { settings.manualFields.contains("priority") || priority != .none || fieldPickerOpen == .priority }
    private var showAssignee: Bool { settings.manualFields.contains("assignee") || assignee != nil || fieldPickerOpen == .assignee }
    private var showLabels: Bool { settings.manualFields.contains("labels") || !labelIDs.isEmpty || fieldPickerOpen == .labels }
    private var showProject: Bool { settings.manualFields.contains("project") || projectID != nil || fieldPickerOpen == .project }
    private var showDue: Bool { settings.manualFields.contains("due_date") || dueDate != nil || duePickerOpen }
    private var showStart: Bool { settings.manualFields.contains("start_date") || startDate != nil || startPickerOpen }

    private func fieldBinding(_ f: Field) -> Binding<Bool> {
        Binding(get: { fieldPickerOpen == f }, set: { open in
            if open { fieldPickerOpen = f } else if fieldPickerOpen == f { fieldPickerOpen = nil }
        })
    }

    private var activeProperties: [IssueProperty] {
        session.properties.items.filter { !$0.archived && $0.archivedAt == nil }
    }

    private var toolbar: some View {
        let catalog = session.issues.catalog
        return IssueModalFlowLayout(spacing: 6, lineSpacing: 6) {
            if showStatus {
                IssueModalPill(isPresented: fieldBinding(.status)) {
                    catalog.icon(for: status)
                    Text(catalog.localizedName(for: status)).lineLimit(1)
                } content: { dismiss in
                    IssueModalStatusMenu(current: status) { setStatus($0); dismiss() }
                }
            }
            if showPriority {
                IssueModalPill(isPresented: fieldBinding(.priority)) {
                    PriorityIcon(priority: priority, size: 13)
                    Text(priority.localizedName).lineLimit(1)
                } content: { dismiss in
                    IssueModalPriorityMenu(current: priority) { setPriority($0); dismiss() }
                }
            }
            if showAssignee {
                IssueModalPill(isPresented: fieldBinding(.assignee)) {
                    if let assignee {
                        ActorAvatar(type: assignee.type, id: assignee.id, size: 15, showName: true, nameFont: Theme.Font.caption)
                    } else {
                        IssueModalPlaceholder(text: tr("issues", "pickers.assignee.trigger_unassigned"))
                    }
                } content: { dismiss in
                    IssueModalAssigneeMenu(current: assignee) { setAssignee($0); dismiss() }
                }
            }
            if showLabels {
                IssueModalPill(isPresented: fieldBinding(.labels)) {
                    labelTrigger
                } content: { dismiss in
                    IssueModalLabelMenu(selectedIDs: labelIDs, onChange: setLabels, dismiss: dismiss)
                }
            }
            if showProject {
                IssueModalPill(isPresented: fieldBinding(.project), onClear: projectID == nil ? nil : { setProject(nil) },
                               clearLabel: tr("projects", "picker.clear_aria")) {
                    projectTrigger
                } content: { dismiss in
                    IssueModalProjectMenu(currentID: projectID) { setProject($0); dismiss() }
                }
            }
            if parentIssueID != nil {
                IssueModalPill {
                    Image(systemName: "signpost.right").foregroundStyle(.secondary)
                    Text(stage.map { tr("issues", "stage.value", ["n": $0]) } ?? tr("issues", "stage.none")).lineLimit(1)
                } content: { dismiss in
                    IssueModalStageMenu(stage: stage, maxStage: maxSiblingStage) { stage = $0; dismiss() }
                }
            }
            if showStart {
                IssueModalPill(isPresented: $startPickerOpen) {
                    Image(systemName: "calendar.badge.clock").foregroundStyle(.secondary)
                    if let startDate { Text(IssueModalDates.short(startDate)) } else { IssueModalPlaceholder(text: tr("issues", "pickers.start_date.trigger_label")) }
                } content: { dismiss in
                    IssueModalDateMenu(value: startDate, emptyLabel: tr("issues", "pickers.start_date.none")) { setStartDate($0); dismiss() }
                }
            }
            if showDue {
                IssueModalPill(isPresented: $duePickerOpen) {
                    Image(systemName: "calendar").foregroundStyle(.secondary)
                    if let dueDate {
                        Text(IssueModalDates.short(dueDate)).foregroundStyle(IssueModalDates.isPast(dueDate) ? Theme.destructive : .primary)
                    } else {
                        IssueModalPlaceholder(text: tr("issues", "pickers.due_date.trigger_label"))
                    }
                } content: { dismiss in
                    IssueModalDateMenu(value: dueDate, emptyLabel: tr("issues", "pickers.due_date.none")) { setDueDate($0); dismiss() }
                }
            }
            ForEach(activeProperties.filter { propertyValues[$0.id] != nil || customPropertyPickerID == $0.id }) { p in
                IssueModalPill(isPresented: Binding(get: { customPropertyPickerID == p.id },
                                                    set: { customPropertyPickerID = $0 ? p.id : (customPropertyPickerID == p.id ? nil : customPropertyPickerID) }),
                               highlighted: propertyErrorID == p.id) {
                    IssueModalPropertyIcon(key: p.icon)
                    Text(p.name).lineLimit(1).frame(maxWidth: 128, alignment: .leading)
                    if let v = propertyValues[p.id] {
                        IssueModalPropertyValueDisplay(property: p, value: v)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 160, alignment: .leading)
                    }
                } content: { dismiss in
                    IssueModalPropertyEditor(property: p, value: propertyValues[p.id], onChange: { setProperty(p.id, $0) }, dismiss: dismiss)
                }
            }
            parentChip
            ForEach(childIssues) { c in
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Text(tr("modals", "create_issue.subissue_chip", ["identifier": c.identifier])).lineLimit(1)
                    Button { childIssues.removeAll { $0.id == c.id } } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(tr("modals", "create_issue.remove_subissue_aria", ["identifier": c.identifier]))
                }
                .font(Theme.Font.caption)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14)))
                .fixedSize()
            }
            overflowMenu
        }
    }

    @ViewBuilder
    private var labelTrigger: some View {
        let chosen = labelIDs.compactMap { id in session.labels.items.first { $0.id == id } }
        if chosen.isEmpty {
            Image(systemName: "tag").foregroundStyle(.secondary)
            IssueModalPlaceholder(text: tr("issues", "pickers.label.trigger_label"))
        } else {
            ForEach(chosen) { l in
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: l.color)).frame(width: 7, height: 7)
                    Text(l.name).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var projectTrigger: some View {
        if let p = projectID.flatMap({ session.projects.item($0) }) {
            ProjectIconView(icon: p.icon, size: 13)
            Text(p.title).lineLimit(1)
        } else {
            ProjectIconView(icon: nil, size: 13)
            IssueModalPlaceholder(text: tr("projects", "picker.no_project"))
        }
    }

    @ViewBuilder
    private var parentChip: some View {
        if parentLocked {
            Text(tr("modals", "create_issue.subissue_of", ["identifier": parentIssue?.identifier ?? carry.parentIdentifier ?? ""]))
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .fixedSize()
        } else if parentIssueID != nil, let parentIssue {
            HStack(spacing: 0) {
                Button { parentPickerOpen = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        Text(tr("modals", "create_issue.subissue_of", ["identifier": parentIssue.identifier])).lineLimit(1)
                    }
                    .padding(.leading, 9)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { clearParent() } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 22, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tr("modals", "create_issue.remove_parent_aria"))
            }
            .font(Theme.Font.caption)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14)))
            .hoverHighlight(cornerRadius: 12)
            .fixedSize()
        }
    }

    private var overflowMenu: some View {
        Menu {
            if !showStatus { Button { fieldPickerOpen = .status } label: { Label(tr("modals", "create_issue.set_status"), systemImage: "circle.dashed") } }
            if !showPriority { Button { fieldPickerOpen = .priority } label: { Label(tr("modals", "create_issue.set_priority"), systemImage: "minus") } }
            if !showAssignee { Button { fieldPickerOpen = .assignee } label: { Label(tr("modals", "create_issue.set_assignee"), systemImage: "person.crop.circle") } }
            if !showLabels { Button { fieldPickerOpen = .labels } label: { Label(tr("modals", "create_issue.set_labels"), systemImage: "tag") } }
            if !showProject { Button { fieldPickerOpen = .project } label: { Label(tr("modals", "create_issue.set_project"), systemImage: "folder") } }
            if !showDue { Button { duePickerOpen = true } label: { Label(tr("modals", "create_issue.set_due_date"), systemImage: "calendar") } }
            if !showStart { Button { startPickerOpen = true } label: { Label(tr("modals", "create_issue.set_start_date"), systemImage: "calendar.badge.clock") } }
            if !parentLocked {
                if parentIssueID != nil, let parentIssue {
                    Button { parentPickerOpen = true } label: {
                        Label(tr("modals", "create_issue.parent_with_id", ["identifier": parentIssue.identifier]), systemImage: "arrow.up")
                    }
                } else {
                    Button { parentPickerOpen = true } label: { Label(tr("modals", "create_issue.set_parent"), systemImage: "arrow.up") }
                }
            }
            Button { childPickerOpen = true } label: { Label(tr("modals", "create_issue.add_subissue"), systemImage: "arrow.down") }
            if !activeProperties.isEmpty {
                Menu {
                    ForEach(activeProperties) { p in
                        let has = propertyValues[p.id] != nil
                        Button { customPropertyPickerID = p.id } label: {
                            if has { Label(p.name, systemImage: "checkmark") } else { Label(p.name, systemImage: IssueModalPropertyIcon.symbol(p.icon ?? "")) }
                        }
                        .disabled(has)
                    }
                } label: {
                    Label(tr("modals", "create_issue.custom_properties"), systemImage: "square.on.circle")
                }
            }
            Divider()
            Button {
                IssueModalNavigation.openFieldSettings(nav, close: onClose)
            } label: {
                Label(tr("modals", "create_issue.customize_fields"), systemImage: "slider.horizontal.3")
            }
            if !parentLocked && parentIssueID != nil && parentIssue != nil {
                Divider()
                Button(role: .destructive) { clearParent() } label: {
                    Label(tr("modals", "create_issue.remove_parent"), systemImage: "xmark")
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 7)
        .frame(height: 24)
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14)))
        .help(tr("modals", "create_issue.more_options_aria"))
        .accessibilityLabel(tr("modals", "create_issue.more_options_aria"))
    }

    // MARK: State

    private func seed() {
        guard !seeded else { return }
        seeded = true
        let d = store.draft
        status = opener.status ?? IssueStatusKey(rawValue: d.manual.status)
        priority = opener.priority ?? IssuePriority(rawValue: d.shared.priority) ?? .none
        if let a = opener.assignee {
            assignee = a
        } else if let t = d.manual.assigneeType, let i = d.manual.assigneeID {
            assignee = ActorRef(type: t, id: i)
        }
        startDate = opener.startDate ?? d.manual.startDate
        dueDate = opener.dueDate ?? d.shared.dueDate
        labelIDs = opener.labelIDs.isEmpty ? d.manual.labelIDs : opener.labelIDs
        propertyValues = d.manual.propertyValues
        projectID = opener.projectID ?? d.shared.projectID
        parentIssueID = carry.parentIssueID
        stage = stageSeed
        settings = IssueModalCreateSettings.load(workspaceID: session.workspace.id)
        store.update {
            $0.activeMode = "manual"
            $0.pruneUploads()
        }
    }

    private func setStatus(_ v: IssueStatusKey) { status = v; store.update { $0.manual.status = v.rawValue } }
    private func setPriority(_ v: IssuePriority) { priority = v; store.update { $0.shared.priority = v.rawValue } }
    private func setAssignee(_ v: ActorRef?) {
        assignee = v
        store.update { $0.manual.assigneeType = v?.type; $0.manual.assigneeID = v?.id }
    }
    private func setProject(_ v: String?) { projectID = v; store.update { $0.shared.projectID = v } }
    private func setStartDate(_ v: String?) { startDate = v; store.update { $0.manual.startDate = v } }
    private func setDueDate(_ v: String?) { dueDate = v; store.update { $0.shared.dueDate = v } }
    private func setLabels(_ v: [String]) { labelIDs = v; store.update { $0.manual.labelIDs = v } }
    private func setProperty(_ id: String, _ value: JSONValue?) {
        propertyValues[id] = value
        let next = propertyValues
        store.update { $0.manual.propertyValues = next }
        if propertyErrorID == id { propertyErrorID = nil }
    }

    private func clearParent() {
        parentIssueID = nil
        parentIssue = nil
        stage = nil
    }

    private func hydrateParent() async {
        guard let id = parentIssueID else {
            maxSiblingStage = 0
            return
        }
        if parentIssue?.id != id {
            if let m = session.issues.model(id) {
                parentIssue = IssueModalPickedIssue(issue: m.issue)
            } else if let r = try? await session.api.getIssue(id) {
                parentIssue = IssueModalPickedIssue(record: r)
            }
        }
        if let children = try? await session.api.issueModalChildRecords(id) {
            maxSiblingStage = IssueModalStage.maxSibling(children.map(\.stage))
        }
    }

    private func upload(_ urls: [URL]) {
        IssueModalUploads.upload(urls, session: session, store: store, mode: .manual, target: target, toaster: toaster)
    }

    private func resetForNextIssue() {
        status = .todo
        priority = .none
        startDate = nil
        dueDate = nil
        labelIDs = []
        propertyValues = [:]
        customPropertyPickerID = nil
        propertyErrorID = nil
        unavailablePropertyRemoved = false
        projectID = nil
        clearParent()
        childIssues = []
        hasTitle = false
        formResetKey += 1
    }

    // MARK: Mode switch

    private func switchToAgent() {
        guard !IssueModalUploadGate.uploading(store) else { return }
        let a = assignee
        store.update { d in
            d.shared.projectID = projectID
            d.shared.priority = priority.rawValue
            d.shared.dueDate = dueDate
            if d.agent.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let seeded = [d.manual.title.trimmingCharacters(in: .whitespacesAndNewlines),
                              d.manual.description.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: "\n\n")
                if !seeded.isEmpty { d.agent.prompt = seeded }
            }
            if d.agent.actorID == nil, let a, a.type == "agent" || a.type == "squad" {
                d.agent.actorType = a.type
                d.agent.actorID = a.id
            }
            d.activeMode = "agent"
        }
        onSwitchMode(IssueModalCarry(parentIssueID: parentIssueID, parentIdentifier: parentIssue?.identifier ?? carry.parentIdentifier))
    }

    // MARK: Submit

    private func submit() {
        if source != nil && source?.usablePreview == nil { return }
        let title = store.draft.manual.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            titleFocused = true
            return
        }
        guard !submitting, !IssueModalUploadGate.uploading(store) else { return }
        submitting = true
        unavailablePropertyRemoved = false
        let generation = store.generation
        let body = store.draft.manual.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentIDs = store.draft.shared.attachments.filter { $0.isReferenced(in: body) }.compactMap(\.attachmentID)
        let props = propertyValues
        let record = CreateIssueRequestRecord(
            title: title, description: body.isEmpty ? nil : body, status: status.rawValue, priority: priority.rawValue,
            assigneeType: assignee?.type, assigneeId: assignee?.id,
            parentIssueId: source == nil ? parentIssueID : nil, projectId: projectID,
            stage: parentIssueID != nil ? stage : nil, startDate: startDate, dueDate: dueDate,
            attachmentIds: attachmentIDs.isEmpty ? nil : attachmentIDs, labelIds: labelIDs.isEmpty ? nil : labelIDs,
            properties: props.isEmpty ? nil : props)
        let children = childIssues
        let labels = labelIDs
        let submittedAssignee = assignee
        Task {
            await perform(record, props: props, children: children, labels: labels, generation: generation, assignee: submittedAssignee)
            submitting = false
        }
    }

    private func perform(_ record: CreateIssueRequestRecord, props: [String: JSONValue], children: [IssueModalPickedIssue],
                         labels: [String], generation: Int, assignee submitted: ActorRef?) async {
        let api = session.api
        do {
            if !props.isEmpty, (try? await api.getConfig())?.issueCreatePropertiesSupported != true {
                throw IssueModalLocalError(message: "This server version does not support atomic custom properties on issue creation. Update the server before creating this issue.")
            }
            let issue: Issue
            if let source, let preview = source.usablePreview {
                issue = try await api.createCommentSubIssue(anchorCommentId: source.anchorCommentID,
                                                            manual: CreateCommentSubIssueManualRequest(mode: "manual", captureToken: preview.captureToken, issue: record))
                session.issues.upsert(issue, isNew: true)
            } else {
                issue = try await session.issueModalCreate(record)
            }
            if !children.isEmpty { await linkChildren(children, to: issue.id) }
            if !labels.isEmpty && issue.labels.isEmpty {
                var failed = 0
                for id in labels {
                    do { _ = try await api.attachLabel(issueId: issue.id, labelId: id) } catch { failed += 1 }
                }
                if failed > 0 { toaster.error(tr("modals", "create_issue.toast_link_labels_failed")) }
            }
            showCreated(issue)
            accepted(generation: generation, assignee: submitted)
        } catch {
            await handle(error, props: props)
        }
    }

    private func linkChildren(_ children: [IssueModalPickedIssue], to parentID: String) async {
        let session = session
        var failed = 0
        await withTaskGroup(of: Bool.self) { group in
            for c in children {
                group.addTask { @MainActor in
                    do {
                        try await session.issueModalUpdate(c.id, UpdateIssueRequestRecord(parentIssueId: parentID)) { $0.parentIssueID = parentID }
                        return true
                    } catch {
                        return false
                    }
                }
            }
            for await ok in group where !ok { failed += 1 }
        }
        if failed > 0 {
            toaster.error(failed == children.count
                          ? tr("modals", "create_issue.toast_link_subissues_all_failed")
                          : tr("modals", "create_issue.toast_link_subissues_partial", ["failed": failed, "total": children.count]))
        }
    }

    private func showCreated(_ issue: Issue) {
        let nav = nav
        toaster.show("\(tr("modals", "create_issue.toast_created"))\n\(issue.identifier) – \(issue.title)", kind: .success,
                     actionTitle: tr("modals", "create_issue.view_issue")) {
            nav.push(.issue(issue.id), title: issue.title)
        }
    }

    /// Success consumes only the draft it submitted: an edit made while the
    /// request was in flight survives and keeps the dialog open.
    private func accepted(generation: Int, assignee submitted: ActorRef?) {
        store.setLastAssignee(type: submitted?.type, id: submitted?.id)
        IssueModalPending.setLastMode(.manual)
        let untouched = store.generation == generation
        if untouched { store.clearDraft() }
        guard untouched else { return }
        if store.keepOpen {
            resetForNextIssue()
        } else {
            onClose()
        }
    }

    private func handle(_ error: Error, props: [String: JSONValue]) async {
        let code = source != nil ? session.issueModalSourceCode(error) : IssueModalErrors.code(error)
        if let source {
            switch code {
            case "source_context_changed", "anchor_comment_deleted", "source_issue_deleted":
                await source.load(session.api)
                toaster.error(IssueModalSourceContext.failureMessage(error) ?? tr("issues", "source_context.error_source_changed"))
                return
            case "source_context_server_unsupported":
                toaster.error(tr("issues", "source_context.error_server_unsupported"))
                return
            case "source_context_too_large":
                toaster.error(IssueModalSourceContext.failureMessage(error) ?? tr("issues", "source_context.error_too_large"))
                return
            default:
                break
            }
        }
        if code == "issue_limit_reached" {
            onLimitReached()
            return
        }
        if code == "invalid_issue_property" {
            if let pid = IssueModalErrors.body(error)?["property_id"]?.stringValue, props[pid] != nil, session.properties.isLoaded {
                if activeProperties.contains(where: { $0.id == pid }) {
                    propertyErrorID = pid
                    customPropertyPickerID = pid
                } else if propertyValues[pid] != nil {
                    propertyValues[pid] = nil
                    let next = propertyValues
                    store.update { $0.manual.propertyValues = next }
                    propertyErrorID = nil
                    customPropertyPickerID = nil
                    unavailablePropertyRemoved = true
                    return
                }
            }
            toaster.error(IssueModalErrors.message(error, fallback: tr("modals", "create_issue.toast_failed")))
            return
        }
        if IssueModalErrors.status(error) == 409, code == "active_duplicate_issue", let dup = IssueModalErrors.body(error)?["issue"],
           let id = dup["id"]?.stringValue, let identifier = dup["identifier"]?.stringValue {
            let title = dup["title"]?.stringValue ?? ""
            let nav = nav
            toaster.show("\(tr("modals", "create_issue.toast_duplicate_title"))\n\(identifier) – \(title)", kind: .info,
                         actionTitle: tr("modals", "create_issue.toast_duplicate_view")) {
                nav.push(.issue(id), title: title)
            }
            return
        }
        toaster.error(IssueModalErrors.message(error, fallback: tr("modals", "create_issue.toast_failed")))
    }
}

/// Footer: attach, switch to agent, keep-open, Create (upstream manual footer).
private struct IssueModalManualFooter: View {
    let store: IssueModalDraftStore
    let hasTitle: Bool
    let submitting: Bool
    let sourceUnavailable: Bool
    let onUpload: ([URL]) -> Void
    let onSwitch: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        let uploading = IssueModalUploadGate.uploading(store)
        let missingTitle = !submitting && !uploading && !sourceUnavailable && !hasTitle
        HStack(spacing: 8) {
            IssueModalAttachButton(onFiles: onUpload)
            Spacer(minLength: 8)
            Button(action: onSwitch) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(Theme.brand)
                    Text(tr("modals", "create_issue.switch_to_agent"))
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.brand.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Theme.brand.opacity(0.25)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(uploading)
            .help(tr("modals", "create_issue.switch_to_agent_tooltip"))
            IssueModalKeepOpenToggle(store: store)
            Button(action: onSubmit) {
                HStack(spacing: 6) {
                    if submitting {
                        Text(tr("modals", "create_issue.submitting"))
                    } else if uploading {
                        Text(tr("editor", "upload.in_progress"))
                    } else {
                        Text(tr("modals", "create_issue.submit"))
                        IssueModalSendKeyCaps()
                    }
                }
            }
            .buttonStyle(IssueModalPrimaryButtonStyle(dimmed: missingTitle || sourceUnavailable))
            .modifier(IssueModalSendShortcut())
            .disabled(submitting || uploading)
            .help(missingTitle ? tr("modals", "create_issue.title_required") : "")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Passive pre-trigger caption: whether saving will start a run, from the
/// server's predicate (upstream CreateRunHint, MUL-3375).
struct IssueModalRunHint: View {
    @Environment(WorkspaceSession.self) private var session
    let assignee: ActorRef?
    let status: IssueStatusKey
    @State private var preview: IssueTriggerPreview?
    @State private var resolvedFor: String?

    private var agentLike: Bool { assignee.map { $0.type == "agent" || $0.type == "squad" } ?? false }
    private var key: String { "\(assignee?.type ?? ""):\(assignee?.id ?? ""):\(status.rawValue)" }

    var body: some View {
        Group {
            if agentLike, let assignee, resolvedFor != nil {
                let willStart = (preview?.totalCount ?? 0) > 0
                let isSquad = assignee.type == "squad"
                let triggerAgent = preview?.triggers.first?.agentId ?? assignee.id
                HStack(spacing: 6) {
                    if !willStart {
                        ActorAvatar(type: assignee.type, id: assignee.id, size: 14)
                        Text(tr("modals", "run_confirm.create_parked"))
                    } else if isSquad {
                        ActorAvatar(type: "squad", id: assignee.id, size: 14)
                        Text(tr("modals", "run_confirm.create_will_start_squad", ["name": session.actorInfo(type: "squad", id: assignee.id).name]))
                    } else {
                        ActorAvatar(type: "agent", id: triggerAgent, size: 14)
                        Text(tr("modals", "run_confirm.create_will_start", ["name": session.actorInfo(type: "agent", id: triggerAgent).name]))
                    }
                }
                .lineLimit(1)
                .font(Theme.Font.micro)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: resolvedFor != nil && agentLike)
        .task(id: key) {
            guard agentLike, let assignee else {
                resolvedFor = nil
                preview = nil
                return
            }
            let params = IssueTriggerPreviewParams(isCreate: true, assigneeType: assignee.type, assigneeId: assignee.id, status: status.rawValue)
            if let p = try? await session.api.previewIssueTrigger(params), !Task.isCancelled {
                preview = p
                resolvedFor = key
            } else if !Task.isCancelled {
                preview = nil
                resolvedFor = key
            }
        }
    }
}
