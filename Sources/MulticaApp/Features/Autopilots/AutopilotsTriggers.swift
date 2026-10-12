import MulticaCore
import SwiftUI

private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
    tr("autopilots", key, args)
}

/// Shows a schedule rejection the way both submit paths must: the control at
/// fault as the headline, the parser's own words underneath.
@MainActor
func autopilotsToastRejection(_ rejection: AutopilotsSchedule.Rejection, toaster: Toaster) {
    let headline = rejection.code == .invalidTimezone ? t("schedule_editor.timezone_invalid") : t("schedule_editor.cron_invalid")
    toaster.error("\(headline)\n\(rejection.detail)")
}

/// One trigger of an autopilot (upstream TriggerRow).
struct AutopilotsTriggerRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let trigger: AutopilotTrigger
    let autopilotID: String
    let canWrite: Bool
    let onChanged: () -> Void
    @State private var confirmDelete = false
    @State private var confirmRotate = false
    @State private var editing = false
    @State private var rotating = false

    var body: some View {
        let isWebhook = trigger.kind == "webhook"
        let isAPI = trigger.kind == "api"
        let webhookURL = isWebhook ? AutopilotsWebhook.url(for: trigger, apiBaseURL: session.api.config.apiURL.absoluteString) : nil
        let config = trigger.cronExpression.map { AutopilotsSchedule.parseCron($0, timezone: trigger.timezone ?? "UTC") }
        let description = config.flatMap { AutopilotsSchedule.describe($0) }
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isWebhook ? "point.3.connected.trianglepath.dotted" : isAPI ? "bolt" : "clock")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(AutopilotsLabels.triggerKind(trigger.kind)).font(Theme.Font.bodyMedium)
                    if let label = trigger.label, !label.isEmpty {
                        Text("(\(label))").font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                    if !trigger.enabled { tag(t("trigger_row.disabled_badge")) }
                    if isAPI { tag(t("trigger_row.deprecated_badge")) }
                }
                if let cron = trigger.cronExpression {
                    VStack(alignment: .leading, spacing: 1) {
                        Text((description ?? cron) + (trigger.timezone.map { " (\($0))" } ?? ""))
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                        if description != nil, let config {
                            Text(AutopilotsSchedule.cronFields(config)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 1)
                }
                if let next = trigger.nextRunAt, trigger.enabled {
                    Text(t("trigger_row.next_label", ["date": AutopilotsFormat.instant(next, timeZone: trigger.timezone)]))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                if let webhookURL {
                    AutopilotsWebhookURLField(url: webhookURL) {
                        if canWrite {
                            iconButton(rotating ? "arrow.clockwise.circle" : "arrow.clockwise", help: t("trigger_row.rotate_url")) { confirmRotate = true }
                                .disabled(rotating)
                        }
                        deleteButton
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if webhookURL == nil {
                HStack(spacing: 2) {
                    if canWrite && trigger.kind == "schedule" {
                        iconButton("pencil", help: t("trigger_row.edit_schedule")) { editing = true }
                    }
                    deleteButton
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
        .sheet(isPresented: $confirmDelete) {
            AutopilotsConfirmSheet(
                title: t("trigger_row.delete_dialog.title"),
                message: t("trigger_row.delete_dialog.description"),
                cancelLabel: t("trigger_row.delete_dialog.cancel"),
                confirmLabel: t("trigger_row.delete_dialog.confirm"),
                busyLabel: t("trigger_row.delete_dialog.deleting")
            ) {
                do {
                    try await session.api.deleteAutopilotTrigger(autopilotId: autopilotID, triggerId: trigger.id)
                    toaster.success(t("trigger_row.toast_deleted"))
                    onChanged()
                    return true
                } catch {
                    toaster.error((error as? APIError)?.message ?? t("trigger_row.toast_delete_failed"))
                    return false
                }
            }
        }
        .sheet(isPresented: $confirmRotate) {
            AutopilotsConfirmSheet(
                title: t("trigger_row.rotate_confirm_title"),
                message: t("trigger_row.rotate_confirm_description"),
                cancelLabel: t("trigger_row.rotate_confirm_cancel"),
                confirmLabel: t("trigger_row.rotate_confirm_action"),
                busyLabel: t("trigger_row.rotate_in_progress"),
                destructive: false
            ) {
                rotating = true
                defer { rotating = false }
                do {
                    _ = try await session.api.rotateAutopilotTriggerWebhookToken(autopilotId: autopilotID, triggerId: trigger.id)
                    toaster.success(t("trigger_row.toast_rotated"))
                    onChanged()
                    return true
                } catch {
                    toaster.error((error as? APIError)?.message ?? t("trigger_row.toast_rotate_failed"))
                    return false
                }
            }
        }
        .sheet(isPresented: $editing) {
            AutopilotsEditScheduleTriggerSheet(autopilotID: autopilotID, trigger: trigger, onSaved: onChanged)
        }
    }

    @ViewBuilder private var deleteButton: some View {
        if canWrite {
            iconButton("trash", help: t("trigger_row.delete_dialog.confirm")) { confirmDelete = true }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(Theme.Font.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)))
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// "Add trigger" (upstream AddTriggerDialog): a schedule or a webhook.
struct AutopilotsAddTriggerSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let autopilotID: String
    let onAdded: () -> Void
    @State private var kind = "schedule"
    @State private var config = AutopilotsSchedule.defaultConfig(timezone: AutopilotsSchedule.localTimezone())
    @State private var label = ""
    @State private var submitting = false
    @State private var scheduleValid = true

    var body: some View {
        let canSubmit = !submitting && (kind != "schedule" || scheduleValid)
        VStack(alignment: .leading, spacing: 16) {
            Text(t("add_trigger_dialog.title")).font(Theme.Font.title)
            VStack(alignment: .leading, spacing: 4) {
                Text(t("add_trigger_dialog.type_label")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                SegmentedToggle(selection: $kind, options: [
                    ("schedule", t("add_trigger_dialog.type_schedule"), "clock"),
                    ("webhook", t("add_trigger_dialog.type_webhook"), "point.3.connected.trianglepath.dotted"),
                ])
            }
            if kind == "schedule" {
                AutopilotsScheduleEditor(value: Binding(get: { config }, set: { scheduleValid = true; config = $0 }),
                                         disabled: submitting, onValidityChange: { scheduleValid = $0 })
            } else {
                Text(t("add_trigger_dialog.webhook_help"))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.04)))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(t("add_trigger_dialog.label_field")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField(t("add_trigger_dialog.label_placeholder"), text: $label).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button(t("dialog.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(submitting ? t("add_trigger_dialog.submitting") : t("add_trigger_dialog.submit")) { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .controlSize(.regular)
        .padding(20)
        .frame(width: 400)
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if kind == "schedule" {
                if let rejection = await AutopilotsSchedule.findRejection(api: session.api, config: config) {
                    scheduleValid = false
                    autopilotsToastRejection(rejection, toaster: toaster)
                    return
                }
                let cron = AutopilotsSchedule.toCron(config)
                guard !cron.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                _ = try await session.api.createAutopilotTrigger(autopilotId: autopilotID, CreateAutopilotTriggerRequest(
                    kind: "schedule", cronExpression: cron, timezone: config.timezone.isEmpty ? nil : config.timezone,
                    label: trimmedLabel.isEmpty ? nil : trimmedLabel))
                toaster.success(t("add_trigger_dialog.toast_added_schedule"))
            } else {
                _ = try await session.api.createAutopilotTrigger(autopilotId: autopilotID, CreateAutopilotTriggerRequest(
                    kind: "webhook", label: trimmedLabel.isEmpty ? nil : trimmedLabel))
                toaster.success(t("add_trigger_dialog.toast_added_webhook"))
            }
            onAdded()
            dismiss()
        } catch {
            toaster.error((error as? APIError)?.message ?? t("add_trigger_dialog.toast_add_failed"))
        }
    }
}

/// Edits one schedule trigger in place (upstream EditScheduleTriggerDialog):
/// only the fields that moved are sent, measured against the values as they
/// stood when the dialog opened.
struct AutopilotsEditScheduleTriggerSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let autopilotID: String
    let trigger: AutopilotTrigger
    let onSaved: () -> Void
    @State private var config: AutopilotsSchedule.Config
    @State private var label: String
    @State private var enabled: Bool
    @State private var submitting = false
    @State private var scheduleValid = true
    private let baseline: (cron: String, timezone: String, label: String, enabled: Bool)

    init(autopilotID: String, trigger: AutopilotTrigger, onSaved: @escaping () -> Void) {
        self.autopilotID = autopilotID
        self.trigger = trigger
        self.onSaved = onSaved
        let initial = AutopilotsSchedule.parseCron(trigger.cronExpression ?? "", timezone: trigger.timezone ?? "UTC")
        _config = State(initialValue: initial)
        _label = State(initialValue: trigger.label ?? "")
        _enabled = State(initialValue: trigger.enabled)
        baseline = (AutopilotsSchedule.toCron(initial), initial.timezone,
                    (trigger.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines), trigger.enabled)
    }

    var body: some View {
        let scheduleDirty = AutopilotsSchedule.toCron(config) != baseline.cron || config.timezone != baseline.timezone
        let labelDirty = label.trimmingCharacters(in: .whitespacesAndNewlines) != baseline.label
        let enabledDirty = enabled != baseline.enabled
        let canSubmit = !submitting && (scheduleDirty || labelDirty || enabledDirty) && (!scheduleDirty || scheduleValid)
        VStack(alignment: .leading, spacing: 16) {
            Text(t("edit_trigger_dialog.title")).font(Theme.Font.title)
            AutopilotsScheduleEditor(value: Binding(get: { config }, set: { scheduleValid = true; config = $0 }),
                                     disabled: submitting, onValidityChange: { scheduleValid = $0 })
            VStack(alignment: .leading, spacing: 4) {
                Text(t("edit_trigger_dialog.label_field")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField(t("edit_trigger_dialog.label_placeholder"), text: $label).textFieldStyle(.roundedBorder).disabled(submitting)
            }
            HStack {
                Text(t("edit_trigger_dialog.enabled_label")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: $enabled).toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(submitting)
                    .accessibilityLabel(t("edit_trigger_dialog.enabled_label"))
            }
            HStack {
                Button(t("dialog.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(submitting ? t("edit_trigger_dialog.submitting") : t("edit_trigger_dialog.submit")) {
                    Task { await submit(scheduleDirty: scheduleDirty, labelDirty: labelDirty, enabledDirty: enabledDirty) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func submit(scheduleDirty: Bool, labelDirty: Bool, enabledDirty: Bool) async {
        submitting = true
        defer { submitting = false }
        var request = UpdateAutopilotTriggerRequest()
        if scheduleDirty {
            if let rejection = await AutopilotsSchedule.findRejection(api: session.api, config: config) {
                scheduleValid = false
                autopilotsToastRejection(rejection, toaster: toaster)
                return
            }
            let cron = AutopilotsSchedule.toCron(config)
            guard !cron.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            request.cronExpression = cron
            request.timezone = config.timezone.isEmpty ? nil : config.timezone
        }
        if labelDirty { request.label = label.trimmingCharacters(in: .whitespacesAndNewlines) }
        if enabledDirty { request.enabled = enabled }
        do {
            _ = try await session.api.updateAutopilotTrigger(autopilotId: autopilotID, triggerId: trigger.id, request)
            toaster.success(t("edit_trigger_dialog.toast_updated"))
            onSaved()
            dismiss()
        } catch {
            toaster.error((error as? APIError)?.message ?? t("edit_trigger_dialog.toast_update_failed"))
        }
    }
}
