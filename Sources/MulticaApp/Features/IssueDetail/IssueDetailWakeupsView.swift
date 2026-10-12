import AppKit
import MulticaCore
import SwiftUI

/// Upstream WakeupsSection: system rules, enabled rules (expandable with
/// wake now / delete / turn off), history, and "New wakeup".
struct IssueDetailWakeupsSection: View {
    @Environment(WorkspaceSession.self) private var session
    let store: IssueDetailStore
    let issue: Issue
    @State private var open = true
    @State private var historyOpen = false
    @State private var creating = false

    var body: some View {
        let rules = store.wakeups ?? []
        let closed = issue.status.issueDetailIsFinished(session.issues.catalog)
        let current = rules.filter { $0.enabled || $0.pausedReason != nil }
        let history = rules.filter { !$0.enabled && $0.pausedReason == nil }
        let system = closed ? [] : store.systemWakeups
        if !rules.isEmpty || !system.isEmpty || store.wakeupsFailed || !closed {
            VStack(alignment: .leading, spacing: 2) {
                IssueDetailSectionHeader(title: tr("issues", "wakeups.title") + " \(current.count + system.count)", open: $open) {
                    if !closed {
                        Button { creating = true } label: { Image(systemName: "plus").font(.system(size: 10)) }
                            .buttonStyle(.borderless)
                            .help(tr("issues", "wakeups.create.open"))
                    }
                }
                if open {
                    if store.wakeupsFailed {
                        Button(tr("issues", "wakeups.retry")) { Task { await store.loadWakeups() } }
                            .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                    if closed {
                        Text(tr("issues", "wakeups.closed_hint")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                    ForEach(system, id: \.rule) { rule in IssueDetailSystemWakeupRow(store: store, rule: rule) }
                    ForEach(current, id: \.id) { w in IssueDetailWakeupRow(store: store, wakeup: w, closed: closed) }
                    if !history.isEmpty {
                        Button { historyOpen.toggle() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(historyOpen ? 90 : 0))
                                Text(tr("issues", "wakeups.ended", ["count": history.count]))
                            }
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        if historyOpen {
                            ForEach(history, id: \.id) { w in IssueDetailWakeupRow(store: store, wakeup: w, closed: closed) }
                        }
                    }
                }
            }
            .sheet(isPresented: $creating) {
                IssueDetailWakeupCreateSheet(store: store, defaultAgentID: issue.assignee?.type == "agent" ? issue.assignee?.id : nil)
            }
        }
    }
}

private struct IssueDetailWakeupRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    let wakeup: IssueWakeup
    let closed: Bool
    @State private var expanded = false
    @State private var pending = false
    @State private var confirmDelete = false
    @State private var editing = false
    @State private var instruction = ""

    var body: some View {
        let names = session.issueDetailNames
        let spec = IssueDetailWakeups.spec(wakeup)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: wakeup.pausedReason != nil ? "exclamationmark.triangle" : (wakeup.kind == "event" ? "bell" : "clock"))
                    .font(.system(size: 11))
                    .foregroundStyle(wakeup.pausedReason != nil ? Theme.warning : .secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.describe(names)).font(Theme.Font.caption).lineLimit(2)
                    HStack(spacing: 4) {
                        ActorAvatar(type: "agent", id: wakeup.agentId, size: 14)
                        Text(tr("issues", "wakeups.wake_agent", ["agent": wakeup.agentName.isEmpty ? names.actor("agent", wakeup.agentId) : wakeup.agentName]))
                        Text("·")
                        Text(state)
                    }
                    .font(Theme.Font.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !closed {
                    Toggle("", isOn: Binding(get: { wakeup.enabled }, set: { setEnabled($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(pending)
                        .help(tr("issues", "wakeups.toggle", ["agent": wakeup.agentName]))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let reason = wakeup.pausedReason {
                        Text(tr("issues", "wakeups.paused.\(reason)", ["count": wakeup.maxFires ?? 0])).foregroundStyle(Theme.warning)
                        Text(tr("issues", "wakeups.paused.hint")).foregroundStyle(.secondary)
                    }
                    Text(tr("issues", "wakeups.instruction_title")).foregroundStyle(.secondary)
                    if editing {
                        TextEditor(text: $instruction).font(Theme.Font.caption).frame(minHeight: 60, maxHeight: 140)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Theme.border))
                        Text(tr("issues", "wakeups.instruction_effect")).font(Theme.Font.micro).foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button(tr("issues", "wakeups.instruction_cancel")) { editing = false }
                            Button(tr("issues", pending ? "wakeups.instruction_saving" : "wakeups.instruction_save")) { saveInstruction() }
                                .disabled(pending || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || instruction.utf8.count > 12000)
                        }
                    } else {
                        Text(wakeup.instruction).textSelection(.enabled).lineLimit(6)
                        if !closed {
                            Button(tr("issues", "wakeups.edit_instruction")) {
                                instruction = wakeup.instruction
                                editing = true
                            }
                            .buttonStyle(.link)
                        }
                    }
                    if let fires = wakeup.fireCount, fires > 0 {
                        Text(wakeup.maxFires.map { tr("issues", "wakeups.detail.fires_max", ["count": fires, "max": $0]) }
                             ?? tr("issues", "wakeups.detail.fires", ["count": fires])).foregroundStyle(.secondary)
                    }
                    if let next = wakeup.nextFireAt, wakeup.enabled {
                        Text(tr("issues", "wakeups.next_at", ["time": names.time(next)])).foregroundStyle(.secondary)
                    }
                    if let expires = wakeup.expiresAt {
                        Text(tr("issues", "wakeups.expiry_title") + ": " + names.time(expires)).foregroundStyle(.secondary)
                    }
                    if let error = wakeup.lastError, !error.isEmpty {
                        Text(error).foregroundStyle(Theme.destructive).lineLimit(3)
                    }
                    if !closed {
                        HStack {
                            if wakeup.disabledAt == nil {
                                Button {
                                    Task {
                                        do {
                                            try await session.api.triggerIssueWakeup(issueId: store.issueID, wakeupId: wakeup.id)
                                            toaster.success(tr("issues", "wakeups.detail.wake_now_done", ["agent": wakeup.agentName]))
                                        } catch {
                                            toaster.error(errorText(error, fallback: "wakeups.detail.wake_now_error"))
                                        }
                                        await store.loadWakeups()
                                    }
                                } label: { Label(tr("issues", "wakeups.detail.wake_now"), systemImage: "play.fill") }
                            }
                            Spacer()
                            Button(tr("issues", "wakeups.detail.delete"), role: .destructive) { confirmDelete = true }
                        }
                        .controlSize(.small)
                    }
                }
                .font(Theme.Font.caption)
                .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .hoverHighlight()
        .alert(tr("issues", "wakeups.detail.delete_title"), isPresented: $confirmDelete) {
            Button(tr("issues", "wakeups.create.cancel"), role: .cancel) {}
            Button(tr("issues", "wakeups.detail.delete"), role: .destructive) {
                Task {
                    do { try await session.api.deleteIssueWakeup(issueId: store.issueID, wakeupId: wakeup.id) } catch {
                        toaster.error(errorText(error, fallback: "wakeups.detail.delete_error"))
                    }
                    await store.loadWakeups()
                }
            }
        } message: {
            Text(tr("issues", "wakeups.detail.delete_body", ["agent": wakeup.agentName]))
        }
    }

    private var state: String {
        if wakeup.pausedReason != nil { return tr("issues", "wakeups.rule_states.paused") }
        if wakeup.timedOutAt != nil { return tr("issues", "wakeups.rule_states.timed_out") }
        if !wakeup.enabled { return tr("issues", "wakeups.rule_states.disabled") }
        return tr("issues", wakeup.kind == "event" ? "wakeups.rule_states.waiting" : "wakeups.rule_states.scheduled")
    }

    private func errorText(_ error: Error, fallback: String) -> String {
        guard let e = error as? APIError else { return tr("issues", fallback) }
        if e.status == 403 { return tr("issues", "wakeups.permission_error") }
        if e.status == 409 { return tr("issues", "wakeups.conflict_error") }
        return tr("issues", fallback)
    }

    private func setEnabled(_ on: Bool) {
        pending = true
        Task {
            defer { pending = false }
            do {
                if on {
                    try await session.api.enableIssueWakeup(issueId: store.issueID, wakeupId: wakeup.id, revision: wakeup.revision ?? 0,
                                                            rearm: wakeup.kind == "event" ? true : nil)
                } else {
                    try await session.api.disableIssueWakeup(issueId: store.issueID, wakeupId: wakeup.id)
                }
            } catch {
                toaster.error(errorText(error, fallback: on ? "wakeups.enable_error" : "wakeups.disable_error"))
            }
            await store.loadWakeups()
        }
    }

    private func saveInstruction() {
        pending = true
        Task {
            defer { pending = false }
            do {
                try await session.api.editIssueWakeupInstruction(issueId: store.issueID, wakeupId: wakeup.id, instruction: instruction,
                                                                 expectedInstruction: wakeup.instruction, revision: wakeup.revision ?? 0)
                editing = false
            } catch {
                toaster.error(errorText(error, fallback: "wakeups.instruction_save_error"))
            }
            await store.loadWakeups()
        }
    }
}

/// The platform's child-done rule for this issue (upstream SystemWakeupRow).
private struct IssueDetailSystemWakeupRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let store: IssueDetailStore
    let rule: SystemWakeup
    @State private var pending = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checklist").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(rule.staged && rule.stage != nil ? tr("issues", "wakeups.system.title_stage", ["stage": rule.stage ?? 0])
                         : tr("issues", "wakeups.system.title_all")).lineLimit(2)
                    Badge(text: tr("issues", "wakeups.system.badge"))
                }
                .font(Theme.Font.caption)
                Text(detail).font(Theme.Font.micro).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in
                pending = true
                Task {
                    defer { pending = false }
                    do { try await session.api.updateIssueSystemWakeup(issueId: store.issueID, rule: rule.rule, enabled: on) } catch {
                        toaster.error(tr("issues", "wakeups.system.save_error"))
                    }
                    await store.loadWakeups()
                }
            }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(pending)
            .help(tr("issues", "wakeups.system.toggle"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var detail: String {
        if !rule.enabled { return tr("issues", "wakeups.system.turned_off") }
        if let reason = rule.pausedReason { return tr("issues", "wakeups.system.paused", ["reason": tr("issues", "wakeups.paused_reason.\(reason)", ["count": 0])]) }
        switch rule.blocked {
        case "backlog": return tr("issues", "wakeups.system.blocked_backlog")
        case "member": return tr("issues", "wakeups.system.blocked_member")
        case "none": return tr("issues", "wakeups.system.blocked_none")
        default: break
        }
        let name = rule.target?["name"]?.stringValue ?? ""
        let done = rule.total - Int(rule.remaining)
        return tr("issues", "wakeups.system.wake_assignee", ["name": name]) + " · " + tr("issues", "wakeups.system.progress", ["done": done, "total": rule.total])
    }
}

/// Upstream WakeupCreate: choose a condition, the agent to wake and what it
/// should do. Builds the same request as upstream buildWakeupInput.
struct IssueDetailWakeupCreateSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let store: IssueDetailStore
    let defaultAgentID: String?

    enum Condition: String, CaseIterable {
        case at, recurring, reply, runEnd, field, children, pr, custom
    }

    @State private var condition: Condition?
    @State private var atPreset = "10m"
    @State private var atCustom = Date().addingTimeInterval(3600)
    @State private var recurrence = "hourly"
    @State private var until = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var replyActor = ""
    @State private var runAgentID = ""
    @State private var fieldStatus: IssueStatusKey = .done
    @State private var stage = 0
    @State private var prEvent = "checks_finished"
    @State private var events: Set<String> = []
    @State private var agentID = ""
    @State private var instruction = ""
    @State private var continuous = false
    @State private var maxFires = 10
    @State private var waitDays = 7
    @State private var onTimeout = "wake"
    @State private var submitting = false
    @State private var error: String?

    static let customEvents = [
        "issue.updated", "issue.assignee_changed", "issue.parent_changed", "issue.project_changed", "issue.labels_changed",
        "issue.properties_changed", "issue.metadata_changed", "comment.created", "comment.updated", "comment.deleted",
        "comment.resolved", "comment.unresolved", "reaction.added", "reaction.removed", "attachment.attached", "attachment.detached",
        "task.queued", "task.dispatched", "task.started", "task.completed", "task.failed", "task.cancelled",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("issues", "wakeups.create.title")).font(Theme.Font.title)
            Form {
                Picker(tr("issues", "wakeups.create.when"), selection: $condition) {
                    Text(tr("issues", "wakeups.create.choose_condition")).tag(Condition?.none)
                    Section(tr("issues", "wakeups.create.group_time")) {
                        Text(tr("issues", "wakeups.create.cond_at")).tag(Condition?.some(.at))
                        Text(tr("issues", "wakeups.create.cond_recurring")).tag(Condition?.some(.recurring))
                    }
                    Section(tr("issues", "wakeups.create.group_collaboration")) {
                        Text(tr("issues", "wakeups.create.cond_reply")).tag(Condition?.some(.reply))
                        Text(tr("issues", "wakeups.create.cond_field")).tag(Condition?.some(.field))
                    }
                    Section(tr("issues", "wakeups.create.group_runs")) {
                        Text(tr("issues", "wakeups.create.cond_run_end")).tag(Condition?.some(.runEnd))
                        Text(tr("issues", "wakeups.create.cond_children")).tag(Condition?.some(.children))
                    }
                    Section(tr("issues", "wakeups.create.group_linked")) {
                        Text(tr("issues", "wakeups.create.cond_pr")).tag(Condition?.some(.pr))
                        Text(tr("issues", "wakeups.create.cond_custom")).tag(Condition?.some(.custom))
                    }
                }
                conditionFields
                Picker(tr("issues", "wakeups.create.wake"), selection: $agentID) {
                    Text(tr("issues", "wakeups.create.choose_agent")).tag("")
                    ForEach(session.directory.agents.filter { !$0.runtimeID.isEmpty }) { a in Text(a.name).tag(a.id) }
                }
                if isEvent {
                    Picker(tr("issues", "wakeups.create.trigger_count"), selection: $continuous) {
                        Text(tr("issues", "wakeups.once")).tag(false)
                        Text(tr("issues", "wakeups.continuous")).tag(true)
                    }
                    if continuous {
                        Stepper(tr("issues", "wakeups.create.max_fires") + " " + tr("issues", "wakeups.create.max_fires_times", ["count": maxFires]),
                                value: $maxFires, in: 1...100)
                    }
                    Stepper(tr("issues", "wakeups.create.max_wait") + " " + tr("issues", "wakeups.create.wait_days", ["count": waitDays]),
                            value: $waitDays, in: 1...30)
                    Picker(tr("issues", "wakeups.create.on_timeout"), selection: $onTimeout) {
                        Text(tr("issues", "wakeups.create.timeout_wake", ["agent": agentName])).tag("wake")
                        Text(tr("issues", "wakeups.create.timeout_end")).tag("end")
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("issues", "wakeups.instruction_title")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    TextEditor(text: $instruction).font(Theme.Font.body).frame(minHeight: 80)
                        .overlay(alignment: .topLeading) {
                            if instruction.isEmpty {
                                Text(tr("issues", "wakeups.create.instruction_placeholder")).foregroundStyle(.tertiary).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                            }
                        }
                }
                Text(tr("issues", "wakeups.create.on_behalf")).font(Theme.Font.micro).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            if let error { Text(error).font(Theme.Font.caption).foregroundStyle(Theme.destructive) }
            HStack {
                Spacer()
                Button(tr("issues", "wakeups.create.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("issues", submitting ? "wakeups.create.submitting" : "wakeups.create.submit"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitting)
            }
        }
        .padding(18)
        .frame(width: 520, height: 620)
        .onAppear { agentID = defaultAgentID ?? "" }
    }

    private var isEvent: Bool {
        guard let condition else { return false }
        return condition != .at && condition != .recurring
    }

    private var agentName: String {
        agentID.isEmpty ? tr("issues", "wakeups.create.the_agent") : session.actorInfo(type: "agent", id: agentID).name
    }

    @ViewBuilder private var conditionFields: some View {
        switch condition {
        case .at:
            Picker("", selection: $atPreset) {
                Text(tr("issues", "wakeups.create.at_10m")).tag("10m")
                Text(tr("issues", "wakeups.create.at_1h")).tag("1h")
                Text(tr("issues", "wakeups.create.at_tomorrow")).tag("tomorrow")
                Text(tr("issues", "wakeups.create.at_custom")).tag("custom")
            }
            if atPreset == "custom" {
                DatePicker(tr("issues", "wakeups.local_time", ["timezone": TimeZone.current.identifier]), selection: $atCustom, in: Date()...)
            }
        case .recurring:
            Picker("", selection: $recurrence) {
                Text(tr("issues", "wakeups.create.hourly")).tag("hourly")
                Text(tr("issues", "wakeups.create.daily")).tag("daily")
                Text(tr("issues", "wakeups.create.weekdays")).tag("weekdays")
            }
            DatePicker(tr("issues", "wakeups.create.until"), selection: $until, in: Date()..., displayedComponents: .date)
        case .reply:
            Picker(tr("issues", "wakeups.source_actor"), selection: $replyActor) {
                Text(tr("issues", "wakeups.create.anyone")).tag("")
                Section(tr("issues", "wakeups.create.members")) {
                    ForEach(session.directory.members) { m in Text(m.name).tag("member:\(m.userID)") }
                }
                Section(tr("issues", "wakeups.create.agents")) {
                    ForEach(session.directory.agents) { a in Text(a.name).tag("agent:\(a.id)") }
                }
            }
        case .runEnd:
            Picker(tr("issues", "wakeups.create.agents"), selection: $runAgentID) {
                Text(tr("issues", "wakeups.create.any_agent")).tag("")
                ForEach(session.directory.agents) { a in Text(a.name).tag(a.id) }
            }
        case .field:
            Picker(tr("issues", "wakeups.create.field_status"), selection: $fieldStatus) {
                ForEach(session.issues.catalog.entries, id: \.key) { e in Text(session.issues.catalog.localizedName(for: e.key)).tag(e.key) }
            }
        case .children:
            Picker("", selection: $stage) {
                Text(tr("issues", "wakeups.create.children_all")).tag(0)
                ForEach(Array(Set(store.childRecords.values.compactMap(\.stage))).sorted(), id: \.self) { s in
                    Text(tr("issues", "wakeups.create.children_stage", ["stage": s])).tag(s)
                }
            }
        case .pr:
            Picker("", selection: $prEvent) {
                Text(tr("issues", "wakeups.create.pr_checks")).tag("checks_finished")
                Text(tr("issues", "wakeups.create.pr_merged")).tag("merged")
            }
        case .custom:
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("issues", "wakeups.create.events_selected", ["count": events.count])).font(Theme.Font.caption).foregroundStyle(.secondary)
                ForEach(Self.customEvents, id: \.self) { ev in
                    Toggle(eventLabel(ev), isOn: Binding(get: { events.contains(ev) }, set: { on in
                        if on { events.insert(ev) } else { events.remove(ev) }
                    }))
                    .toggleStyle(.checkbox)
                }
            }
        case nil:
            EmptyView()
        }
    }

    private func eventLabel(_ ev: String) -> String {
        let key: String
        if ev.hasPrefix("task.") { key = "wakeups.run_" + ev.dropFirst(5) }
        else if ev == "issue.updated" { key = "wakeups.issue_updated" }
        else if ev.hasPrefix("issue.") { key = "wakeups." + ev.dropFirst(6) }
        else { key = "wakeups." + ev.replacingOccurrences(of: ".", with: "_") }
        let s = tr("issues", key)
        return s == key ? ev : s
    }

    private func submit() {
        guard let condition else { return error = tr("issues", "wakeups.create.missing_condition") }
        guard !agentID.isEmpty else { return error = tr("issues", "wakeups.create.missing_agent") }
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 12000 else { return error = tr("issues", "wakeups.instruction_invalid") }
        var body: [String: JSONValue] = ["agent_id": JSONValue(agentID), "instruction": JSONValue(text)]
        let iso = ISO8601DateFormatter()
        switch condition {
        case .at:
            let at: Date
            switch atPreset {
            case "10m": at = Date().addingTimeInterval(600)
            case "1h": at = Date().addingTimeInterval(3600)
            case "tomorrow":
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
                at = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
            default: at = atCustom
            }
            guard at > Date() else { return error = tr("issues", "wakeups.future_time") }
            body["kind"] = "at"
            body["mode"] = "once"
            body["at"] = JSONValue(iso.string(from: at))
        case .recurring:
            let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: until) ?? until
            guard end > Date() else { return error = tr("issues", "wakeups.create.until_future") }
            if recurrence == "hourly" {
                body["kind"] = "every"
                body["interval_seconds"] = 3600
            } else {
                body["kind"] = "cron"
                body["cron_expression"] = JSONValue(recurrence == "daily" ? "0 9 * * *" : "0 9 * * 1-5")
                body["timezone"] = JSONValue(TimeZone.current.identifier)
            }
            body["mode"] = "continuous"
            body["expires_at"] = JSONValue(iso.string(from: end))
        default:
            body["kind"] = "event"
            body["mode"] = JSONValue(continuous ? "continuous" : "once")
            body["expires_in_seconds"] = JSONValue(waitDays * 86400)
            body["on_timeout"] = JSONValue(onTimeout)
            if continuous { body["max_fires"] = JSONValue(maxFires) }
            switch condition {
            case .reply:
                body["event_types"] = JSONValue(["comment.created"])
                let parts = replyActor.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    body["filter_actor_type"] = JSONValue(parts[0])
                    body["filter_actor_id"] = JSONValue(parts[1])
                }
            case .runEnd:
                body["event_types"] = JSONValue(["task.completed", "task.failed", "task.cancelled"])
                if !runAgentID.isEmpty { body["filter_agent_id"] = JSONValue(runAgentID) }
            case .field:
                body["condition"] = ["type": "issue_field", "field": "status", "value": JSONValue(fieldStatus.rawValue)]
            case .children:
                body["condition"] = stage > 0 ? ["type": "children_done", "stage": JSONValue(stage)] : ["type": "children_done"]
            case .pr:
                body["condition"] = ["type": "pull_request", "event": JSONValue(prEvent)]
            default:
                guard !events.isEmpty else { return error = tr("issues", "wakeups.create.missing_events") }
                body["event_types"] = JSONValue(events.sorted())
            }
        }
        error = nil
        submitting = true
        Task {
            defer { submitting = false }
            do {
                try await session.api.callVoid(.post, "/api/issues/\(store.issueID.pathEscaped)/wakeups", body: JSONValue.object(body))
                await store.loadWakeups()
                dismiss()
            } catch let e as APIError where e.status == 409 || e.status == 429 {
                error = tr("issues", "wakeups.create.capacity_error")
            } catch {
                self.error = tr("issues", "wakeups.create.error")
            }
        }
    }
}
