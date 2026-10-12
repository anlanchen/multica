import AppKit
import MulticaCore
import SwiftUI

private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
    tr("autopilots", key, args)
}

/// Prefilled fields of the create / edit dialog.
struct AutopilotsDialogInitial {
    var title = ""
    var description = ""
    var projectID: String?
    var assigneeType = "agent"
    var assigneeID = ""
    var executionMode = "create_issue"
    var subscriberUserIDs: [String] = []
    /// A template's schedule (time and days only).
    var scheduleTime: AutopilotsSchedule.TimePattern?
    var scheduleDays: AutopilotsSchedule.DayPattern?

    init() {}

    init(_ a: Autopilot) {
        title = a.title
        description = a.description ?? ""
        projectID = a.projectId
        assigneeType = a.assigneeType
        assigneeID = a.assigneeId
        executionMode = a.executionMode
        subscriberUserIDs = (a.subscribers ?? []).filter { $0.userType == "member" }.map(\.userId)
    }
}

enum AutopilotsDialogMode {
    case create(AutopilotsDialogInitial)
    case edit(AutopilotsDetailModel, canManageAccess: Bool)
}

/// Create / edit an autopilot (upstream autopilot-dialog): the runbook on the
/// left, assignee, output mode, project, subscribers and trigger on the right.
struct AutopilotsDialog: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let mode: AutopilotsDialogMode

    @State private var title: String
    @State private var description: String
    @State private var projectID: String?
    @State private var assigneeType: String
    @State private var assigneeID: String
    @State private var executionMode: String
    @State private var subscriberIDs: [String]
    @State private var schedule: AutopilotsSchedule.Config
    @State private var scheduleAdded = false
    @State private var triggerKind: String
    @State private var eventFilters: [WebhookEventFilter]
    @State private var submitting = false
    @State private var showErrors = false
    @State private var expanded = false
    @State private var accessOpen = false
    @State private var createdWebhook: AutopilotTrigger?
    @FocusState private var titleFocused: Bool

    private let isCreate: Bool
    private let autopilotID: String?
    private let initialCron: String
    private let initialTimezone: String
    private let initialFilters: String
    private let firstTriggerID: String?
    private let scheduleTriggerID: String?
    private let scheduleTriggerCount: Int
    private let hasExistingSchedule: Bool

    init(mode: AutopilotsDialogMode) {
        self.mode = mode
        let initial: AutopilotsDialogInitial
        var triggers: [AutopilotTrigger] = []
        switch mode {
        case .create(let i):
            initial = i
            isCreate = true
            autopilotID = nil
        case .edit(let model, _):
            initial = model.autopilot.map(AutopilotsDialogInitial.init) ?? AutopilotsDialogInitial()
            triggers = model.triggers
            isCreate = false
            autopilotID = model.id
        }
        let existing = triggers.first { $0.kind == "schedule" }
        let local = AutopilotsSchedule.localTimezone()
        var cfg = AutopilotsSchedule.defaultConfig(timezone: local)
        if isCreate {
            if let time = initial.scheduleTime { cfg.time = time }
            if let days = initial.scheduleDays { cfg.days = days }
        } else if let cron = existing?.cronExpression, !cron.isEmpty {
            cfg = AutopilotsSchedule.parseCron(cron, timezone: existing?.timezone ?? "UTC")
        }
        let filters = (!isCreate ? triggers.first?.eventFilters : nil) ?? []
        _title = State(initialValue: initial.title)
        _description = State(initialValue: initial.description)
        _projectID = State(initialValue: initial.projectID)
        _assigneeType = State(initialValue: initial.assigneeType)
        _assigneeID = State(initialValue: initial.assigneeID)
        _executionMode = State(initialValue: initial.executionMode)
        _subscriberIDs = State(initialValue: initial.subscriberUserIDs)
        _schedule = State(initialValue: cfg)
        _triggerKind = State(initialValue: !isCreate && triggers.first?.kind == "webhook" ? "webhook" : "schedule")
        _eventFilters = State(initialValue: filters)
        initialCron = AutopilotsSchedule.toCron(cfg)
        initialTimezone = cfg.timezone
        initialFilters = AutopilotsWebhook.serialize(filters)
        firstTriggerID = triggers.first?.id
        scheduleTriggerID = existing?.id
        scheduleTriggerCount = triggers.filter { $0.kind == "schedule" }.count
        hasExistingSchedule = existing != nil
    }

    private var schedulePillDisabled: Bool { !isCreate && scheduleTriggerCount >= 2 }
    private var showScheduleEmptyState: Bool { !isCreate && !hasExistingSchedule && !scheduleAdded }
    private var scheduleDirty: Bool { AutopilotsSchedule.toCron(schedule) != initialCron || schedule.timezone != initialTimezone }
    private var scheduleWillBeWritten: Bool {
        triggerKind == "schedule" && !schedulePillDisabled && (isCreate || (hasExistingSchedule ? scheduleDirty : scheduleAdded))
    }

    var body: some View {
        let size = dialogSize
        VStack(spacing: 0) {
            header
            Divider()
            if let createdWebhook {
                AutopilotsWebhookCreatedPanel(trigger: createdWebhook) { dismiss() }
            } else {
                HStack(spacing: 0) {
                    runbook
                    Divider()
                    ScrollView {
                        configuration.padding(20)
                    }
                    .frame(width: 380)
                    .background(Color.primary.opacity(0.025))
                }
                .frame(maxHeight: .infinity)
                Divider()
                footer
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.25), value: expanded)
        .onAppear { if isCreate { titleFocused = true } }
        .task {
            await session.projects.loadIfNeeded()
            await session.agentRecords.loadIfNeeded()
            await session.squads.loadIfNeeded()
        }
    }

    private var dialogSize: CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let width = min(expanded ? 1152 : 1024, screen.width - 32)
        let height = expanded ? screen.height - 64 : min(720, screen.height - 64)
        return CGSize(width: width, height: height)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "paperplane")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.brand.opacity(0.15)))
                Text(isCreate ? t("dialog.header_create") : t("dialog.header_edit")).fontWeight(.medium)
            }
            Text("·").foregroundStyle(.tertiary)
            Text(t("dialog.subtitle")).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            Text(session.workspace.name).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if case .edit(let model, let canManageAccess) = mode, canManageAccess {
                Button { accessOpen.toggle() } label: {
                    Label(t("access.title"), systemImage: "person.2").font(Theme.Font.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .hoverHighlight()
                .popover(isPresented: $accessOpen, arrowEdge: .bottom) { AutopilotsAccessManager(model: model) }
                Divider().frame(height: 16)
            }
            headerButton(expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         help: expanded ? t("dialog.collapse") : t("dialog.expand")) { expanded.toggle() }
            headerButton("xmark", help: t("dialog.close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .font(Theme.Font.caption)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .hoverHighlight()
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Runbook

    private var runbook: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(t("dialog.title_placeholder"), text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .focused($titleFocused)
                    .onSubmit { Task { await submit() } }
                if showErrors && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(t("dialog.error_title_required")).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AutopilotsFieldLabel(text: t("dialog.runbook_label"))
                Text(t("dialog.runbook_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            GeometryReader { geo in
                MarkdownEditor(text: $description, placeholder: t("dialog.description_placeholder"),
                               minHeight: max(120, geo.size.height - 24), maxHeight: max(120, geo.size.height - 24),
                               onSubmit: { Task { await submit() } },
                               mentions: { session.mentionCandidates($0) })
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border.opacity(1.5)))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Configuration

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 20) {
            assigneeSection
            outputModeSection
            projectSection
            if executionMode == "create_issue" {
                VStack(alignment: .leading, spacing: 8) {
                    AutopilotsFieldLabel(text: t("dialog.section_subscribers"))
                    Text(t("dialog.subscribers_hint")).font(.system(size: 10)).foregroundStyle(.secondary)
                    AutopilotsSubscriberSelect(selectedIDs: subscriberIDs) { subscriberIDs = $0 }
                }
            }
            if isCreate {
                VStack(alignment: .leading, spacing: 8) {
                    AutopilotsFieldLabel(text: t("dialog.section_trigger_kind"))
                    SegmentedToggle(selection: $triggerKind, options: [
                        ("schedule", t("dialog.trigger_kind_schedule"), "clock"),
                        ("webhook", t("dialog.trigger_kind_webhook"), "point.3.connected.trianglepath.dotted"),
                    ])
                }
            }
            if triggerKind == "schedule" {
                VStack(alignment: .leading, spacing: 8) {
                    AutopilotsFieldLabel(text: t("dialog.section_schedule"))
                    if schedulePillDisabled {
                        AutopilotsDashedBox(padding: 12) {
                            Text(t("dialog.schedule_multiple_notice", ["count": scheduleTriggerCount])).font(Theme.Font.caption)
                                .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                        }
                    } else if showScheduleEmptyState {
                        AutopilotsDashedBox(padding: 12) {
                            VStack(spacing: 10) {
                                Text(t("dialog.schedule_empty")).font(Theme.Font.caption)
                                Button { scheduleAdded = true } label: { Label(t("dialog.schedule_add"), systemImage: "plus") }
                                    .controlSize(.small)
                            }
                        }
                    } else {
                        AutopilotsScheduleEditor(value: $schedule, disabled: submitting)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        AutopilotsFieldLabel(text: t("dialog.section_webhook"))
                        Text(isCreate ? t("dialog.webhook_help_create") : t("dialog.webhook_help_edit"))
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
                    }
                    AutopilotsEventFilterSection(filters: $eventFilters)
                }
            }
        }
    }

    private var assigneeSection: some View {
        let invalid = showErrors && assigneeID.isEmpty
        let info: (name: String, description: String?)? = {
            guard !assigneeID.isEmpty else { return nil }
            if assigneeType == "squad" {
                return session.squads.item(assigneeID).map { ($0.name, $0.description.isEmpty ? nil : $0.description) }
            }
            if let a = session.agentRecords.item(assigneeID) { return (a.name, a.description.isEmpty ? nil : a.description) }
            return session.directory.agent(assigneeID).map { ($0.name, $0.description.isEmpty ? nil : $0.description) }
        }()
        return VStack(alignment: .leading, spacing: 8) {
            AutopilotsFieldLabel(text: t("dialog.section_assignee"), required: true)
            AutopilotsAgentPicker(assignee: assigneeID.isEmpty ? nil : AutopilotsAssignee(type: assigneeType, id: assigneeID)) { next in
                assigneeType = next.type
                assigneeID = next.id
            } label: {
                HStack(spacing: 10) {
                    if assigneeID.isEmpty {
                        Image(systemName: "paperplane").font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(width: 28, height: 28).background(Circle().fill(Color.primary.opacity(0.06)))
                    } else {
                        ActorAvatar(type: assigneeType, id: assigneeID, size: 28)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(info?.name ?? t("dialog.select_assignee")).font(Theme.Font.bodyMedium).lineLimit(1)
                        if let d = info?.description {
                            Text(d).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .modifier(AutopilotsPickerBox(invalid: invalid))
            }
            if invalid {
                Text(t("dialog.error_assignee_required")).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
            }
        }
    }

    private var outputModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            AutopilotsFieldLabel(text: t("dialog.section_output_mode"))
            VStack(spacing: 6) {
                ForEach(["create_issue", "run_only"], id: \.self) { key in
                    let selected = key == executionMode
                    Button { executionMode = key } label: {
                        HStack(alignment: .top, spacing: 10) {
                            ZStack {
                                Circle().strokeBorder(selected ? Theme.brand : Color.secondary.opacity(0.4))
                                    .background(Circle().fill(selected ? Theme.brand : Color.clear))
                                if selected {
                                    Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(.white)
                                }
                            }
                            .frame(width: 15, height: 15)
                            .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t("dialog.output_modes.\(key).label")).font(Theme.Font.bodyMedium)
                                Text(t("dialog.output_modes.\(key).description")).font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium)
                            .fill(selected ? Theme.brand.opacity(0.05) : Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(selected ? Theme.brand : Theme.border.opacity(1.5)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var projectSection: some View {
        let project = projectID.flatMap { session.projects.item($0) }
        return VStack(alignment: .leading, spacing: 8) {
            AutopilotsFieldLabel(text: t("dialog.section_project"))
            Text(t("dialog.project_hint")).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            PopoverButton(label: {
                HStack(spacing: 10) {
                    if let project {
                        ProjectIconView(icon: project.icon, size: 20)
                    } else {
                        Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(width: 20, height: 20).background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.06)))
                    }
                    Text(project?.title ?? t("dialog.no_project")).font(Theme.Font.bodyMedium).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .modifier(AutopilotsPickerBox(invalid: false))
            }, content: { close in
                OptionList(
                    options: [PickerOption(id: "", title: tr("projects", "picker.no_project"),
                                           icon: AnyView(Image(systemName: "folder.badge.minus").foregroundStyle(.secondary)))]
                        + session.projects.items.map { PickerOption(id: $0.id, title: $0.title, icon: AnyView(ProjectIconView(icon: $0.icon, size: 14))) },
                    selected: [projectID ?? ""],
                    searchPlaceholder: tr("projects", "picker.search_placeholder")
                ) { id in
                    close()
                    projectID = id.isEmpty ? nil : id
                }
            }, style: nil)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                if !showScheduleEmptyState {
                    Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(.orange)
                    Text(t("dialog.auto_run_hint")).lineLimit(1)
                }
            }
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button(t("dialog.cancel")) { dismiss() }
            Button {
                Task { await submit() }
            } label: {
                Text(submitting ? (isCreate ? t("dialog.creating") : t("dialog.saving")) : (isCreate ? t("dialog.create") : t("dialog.save")))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(submitting)
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Submit

    private func submit() async {
        guard !submitting else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty || assigneeID.isEmpty {
            showErrors = true
            if trimmedTitle.isEmpty { titleFocused = true }
            return
        }
        submitting = true
        defer { submitting = false }
        if scheduleWillBeWritten, let rejection = await AutopilotsSchedule.findRejection(api: session.api, config: schedule) {
            autopilotsToastRejection(rejection, toaster: toaster)
            return
        }
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let subscribers = subscriberIDs.map { AutopilotSubscriberInput(userType: "member", userId: $0) }
        do {
            if isCreate {
                let created = try await session.api.createAutopilot(CreateAutopilotRequest(
                    title: trimmedTitle, description: trimmedDescription.isEmpty ? nil : trimmedDescription, projectId: projectID,
                    assigneeType: assigneeType, assigneeId: assigneeID, executionMode: executionMode, subscribers: subscribers))
                if session.autopilots.isLoaded { session.autopilots.upsert(created) }
                var failure: String?
                var webhook: AutopilotTrigger?
                do {
                    if triggerKind == "webhook" {
                        webhook = try await session.api.createAutopilotTrigger(autopilotId: created.id, CreateAutopilotTriggerRequest(
                            kind: "webhook", eventFilters: eventFilters.isEmpty ? nil : eventFilters))
                    } else {
                        _ = try await session.api.createAutopilotTrigger(autopilotId: created.id, CreateAutopilotTriggerRequest(
                            kind: "schedule", cronExpression: AutopilotsSchedule.toCron(schedule), timezone: schedule.timezone))
                    }
                } catch {
                    failure = (error as? APIError)?.message ?? ""
                }
                Task { await session.autopilots.load() }
                if let webhook {
                    createdWebhook = webhook
                    toaster.success(t("dialog.toast_created"))
                    return
                }
                dismiss()
                if let failure {
                    toaster.error(partialFailure("create", failure))
                } else {
                    toaster.success(t("dialog.toast_created"))
                }
            } else if let autopilotID {
                var patch: [String: JSONValue] = [
                    "title": JSONValue(trimmedTitle),
                    "description": trimmedDescription.isEmpty ? .null : JSONValue(trimmedDescription),
                    "project_id": JSONValue(projectID),
                    "assignee_type": JSONValue(assigneeType),
                    "assignee_id": JSONValue(assigneeID),
                    "execution_mode": JSONValue(executionMode),
                ]
                patch["subscribers"] = JSONValue(encoding: subscribers)
                let updated = try await session.api.updateAutopilot(autopilotID, patch: patch)
                if case .edit(let model, _) = mode { model.apply(updated, session: session) }
                var failure: String?
                if scheduleWillBeWritten {
                    do {
                        if let triggerID = scheduleTriggerID {
                            _ = try await session.api.updateAutopilotTrigger(autopilotId: autopilotID, triggerId: triggerID, UpdateAutopilotTriggerRequest(
                                cronExpression: AutopilotsSchedule.toCron(schedule), timezone: schedule.timezone))
                        } else {
                            _ = try await session.api.createAutopilotTrigger(autopilotId: autopilotID, CreateAutopilotTriggerRequest(
                                kind: "schedule", cronExpression: AutopilotsSchedule.toCron(schedule), timezone: schedule.timezone))
                        }
                    } catch {
                        failure = (error as? APIError)?.message ?? ""
                    }
                }
                if triggerKind == "webhook", AutopilotsWebhook.serialize(eventFilters) != initialFilters, let triggerID = firstTriggerID {
                    do {
                        _ = try await session.api.updateAutopilotTrigger(autopilotId: autopilotID, triggerId: triggerID,
                                                                         UpdateAutopilotTriggerRequest(eventFilters: eventFilters))
                    } catch {
                        failure = (error as? APIError)?.message ?? ""
                    }
                }
                if case .edit(let model, _) = mode { Task { await model.load(session) } }
                dismiss()
                if let failure {
                    toaster.error(partialFailure("update", failure))
                } else {
                    toaster.success(t("dialog.toast_updated"))
                }
            }
        } catch {
            let message = (error as? APIError)?.message ?? ""
            toaster.error(!message.isEmpty ? message : isCreate ? t("dialog.toast_create_failed") : t("dialog.toast_update_failed"))
        }
    }

    /// Partial success: the autopilot saved, its schedule did not.
    private func partialFailure(_ kind: String, _ reason: String) -> String {
        reason.isEmpty
            ? t("dialog.toast_\(kind)_partial")
            : t("dialog.toast_\(kind)_partial_with_reason", ["reason": reason])
    }
}

/// Full-width bordered picker trigger of the dialog's right column.
private struct AutopilotsPickerBox: ViewModifier {
    let invalid: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(invalid ? Theme.destructive : Theme.border.opacity(1.5)))
            .contentShape(Rectangle())
    }
}

/// After a webhook autopilot is created: its URL, inline, ready to copy.
private struct AutopilotsWebhookCreatedPanel: View {
    @Environment(WorkspaceSession.self) private var session
    let trigger: AutopilotTrigger
    let onDone: () -> Void

    var body: some View {
        let url = AutopilotsWebhook.url(for: trigger, apiBaseURL: session.api.config.apiURL.absoluteString) ?? ""
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.brand.opacity(0.15)))
                        Text(t("dialog.webhook_created_title")).font(.system(size: 17, weight: .semibold))
                    }
                    Text(t("dialog.webhook_created_description")).font(Theme.Font.body).foregroundStyle(.secondary).lineSpacing(2)
                    VStack(alignment: .leading, spacing: 8) {
                        AutopilotsFieldLabel(text: t("trigger_row.webhook_url_label"))
                        AutopilotsWebhookURLField(url: url, large: true)
                    }
                    Text(t("dialog.webhook_created_warning"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Color.orange)
                        .lineSpacing(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.orange.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.orange.opacity(0.3)))
                }
                .frame(maxWidth: 576)
                .padding(.horizontal, 32)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button(t("dialog.webhook_created_done"), action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}
