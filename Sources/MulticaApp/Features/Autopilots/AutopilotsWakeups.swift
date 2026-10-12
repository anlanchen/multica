import MulticaCore
import SwiftUI

private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
    tr("autopilots", key, args)
}

private func ti(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
    tr("issues", key, args)
}

/// Plain-language wakeup text (upstream wakeup-presentation useWakeupText).
@MainActor
struct AutopilotsWakeupText {
    let session: WorkspaceSession

    private var locale: Locale { AutopilotsFormat.locale }
    private var viewZone: TimeZone { .current }

    private static let eventKeys: [String: String] = [
        "task.queued": "run_queued", "task.dispatched": "run_dispatched", "task.started": "run_started",
        "task.deferred": "run_deferred", "task.waiting_local_directory": "run_waiting_local_directory",
        "issue.updated": "issue_updated", "issue.assignee_changed": "assignee_changed", "issue.parent_changed": "parent_changed",
        "issue.project_changed": "project_changed", "issue.labels_changed": "labels_changed",
        "issue.properties_changed": "properties_changed", "issue.metadata_changed": "metadata_changed",
        "comment.updated": "comment_updated", "comment.deleted": "comment_deleted", "comment.resolved": "comment_resolved",
        "comment.unresolved": "comment_unresolved", "reaction.added": "reaction_added", "reaction.removed": "reaction_removed",
        "attachment.attached": "attachment_attached", "attachment.detached": "attachment_detached",
        "task.completed": "run_completed", "task.failed": "run_failed", "task.cancelled": "run_cancelled",
        "comment.created": "comment_created", "issue.status_changed": "status_changed",
    ]

    func eventName(_ event: String, agent: String? = nil) -> String {
        let subject = agent ?? ti("wakeups.agent_subject")
        guard let key = Self.eventKeys[event] else { return ti("wakeups.unknown_event", ["event": event]) }
        return ti("wakeups.conditions.\(key)", ["agent": subject])
    }

    func frequency(_ w: WorkspaceWakeup) -> String {
        w.mode == "once" ? ti("wakeups.once") : ti("wakeups.continuous")
    }

    func schedule(_ w: WorkspaceWakeup) -> String {
        if w.kind == "every" {
            let seconds = w.intervalSeconds ?? 0
            if seconds == 3600 { return ti("wakeups.hourly") }
            if seconds % 3600 == 0 { return ti("wakeups.every_hours", ["hours": seconds / 3600]) }
            if seconds % 60 == 0 { return ti("wakeups.every", ["minutes": seconds / 60]) }
            return ti("wakeups.every_seconds", ["seconds": seconds])
        }
        if w.kind == "cron" {
            let cron = w.cronExpression ?? ""
            return AutopilotsSchedule.describe(AutopilotsSchedule.parseCron(cron, timezone: w.timezone)) ?? "\(cron) · \(w.timezone)"
        }
        return frequency(w)
    }

    private func formatTime(_ date: Date, now: Date = Date()) -> String {
        var cal = Calendar.current
        cal.timeZone = viewZone
        let sameDay = cal.isDate(date, inSameDayAs: now)
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: now)
        var style = Date.FormatStyle.dateTime.hour().minute()
        if !sameDay { style = style.month(.abbreviated).day() }
        if !sameYear { style = style.year() }
        style.locale = locale
        style.timeZone = viewZone
        return date.formatted(style)
    }

    func time(_ iso: String) -> String {
        guard let date = Timestamp.parse(iso) else { return iso }
        var cal = Calendar.current
        cal.timeZone = viewZone
        let formatted = formatTime(date)
        return cal.isDateInToday(date) ? ti("wakeups.today_time", ["time": formatted]) : formatted
    }

    private func actorName(_ w: WorkspaceWakeup) -> String {
        if let name = w.filterActorName, !name.isEmpty { return name }
        return w.filterActorType == "member" ? ti("wakeups.selected_member") : ti("wakeups.selected_agent")
    }

    private func eventCondition(_ event: String, _ w: WorkspaceWakeup) -> String {
        let agentName = w.filterAgentName.flatMap { $0.isEmpty ? nil : $0 }
        let label = eventName(event, agent: agentName)
        let actor = w.filterActorType != nil ? actorName(w) : agentName
        if let actor, !event.hasPrefix("task.") { return ti("wakeups.by_actor", ["condition": label, "agent": actor]) }
        return label
    }

    private func statusName(_ key: String) -> String {
        session.issues.catalog.localizedName(for: IssueStatusKey(rawValue: key))
    }

    func condition(_ c: JSONValue) -> String {
        let type = c["type"]?.stringValue
        func cond(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String { ti("wakeups.cond.\(key)", args) }
        switch type {
        case "issue_field":
            switch c["field"]?.stringValue {
            case "status": return cond("status", ["status": statusName(c["value"]?.stringValue ?? "")])
            case "assignee":
                return cond("assignee", ["name": session.actorInfo(type: c["assignee_type"]?.stringValue ?? "", id: c["assignee_id"]?.stringValue ?? "").name])
            case "label":
                let name = session.labels.item(c["label_id"]?.stringValue ?? "")?.name ?? cond("unknown_label")
                return cond("label", ["label": name])
            case "property":
                let property = session.properties.item(c["property_id"]?.stringValue ?? "")
                let raw = c["value"]
                let value: String
                if let b = raw?.boolValue {
                    value = b ? cond("checked") : cond("unchecked")
                } else if let s = raw?.stringValue {
                    value = property?.config?.options?.first { $0.id == s }?.name ?? s
                } else if let n = raw?.doubleValue {
                    value = n == n.rounded() ? String(Int(n)) : String(n)
                } else {
                    value = ""
                }
                return cond("property", ["property": property?.name ?? cond("unknown_property"), "value": value])
            default: break
            }
        case "children_done":
            if let stage = c["stage"]?.doubleValue, stage != 0 { return cond("children_stage", ["stage": Int(stage)]) }
            return cond("children_all")
        case "pull_request":
            return c["event"]?.stringValue == "merged" ? cond("pr_merged") : cond("pr_checks")
        case "other_issue":
            let state = c["state"]?.stringValue
            let key = state == "ended" ? "other_ended" : state == "in_review" ? "other_in_review" : "other_done"
            let identifier = c["identifier"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? cond("another_issue")
            return cond(key, ["issue": identifier])
        default: break
        }
        return cond("children_all")
    }

    func trigger(_ w: WorkspaceWakeup) -> String {
        if let c = w.condition, !c.isNull { return condition(c) }
        if w.kind == "every" || w.kind == "cron" { return schedule(w) }
        if w.kind == "at" {
            return w.nextFireAt.map { ti("wakeups.at_time", ["time": time($0)]) } ?? ti("wakeups.scheduled_time")
        }
        let event = w.eventTypes.first ?? ""
        var label = eventCondition(event, w)
        if let task = w.filterTaskId { label += " · \(ti("wakeups.specific_run", ["id": String(task.prefix(8))]))" }
        return label + (w.eventTypes.count > 1 ? " +\(w.eventTypes.count - 1)" : "")
    }

    func runState(_ status: String?) -> String {
        guard let status else { return ti("wakeups.no_run") }
        let known = ["queued", "deferred", "dispatched", "running", "waiting_local_directory", "completed", "failed", "cancelled"]
        return known.contains(status) ? ti("wakeups.run_states.\(status)") : status
    }

    func state(_ w: WorkspaceWakeup, closed: Bool = false) -> String {
        let key = AutopilotsWakeupState.state(w, closed: closed)
        if key == "scheduled", let next = w.nextFireAt { return ti("wakeups.next_at", ["time": time(next)]) }
        return ti("wakeups.rule_states.\(key)")
    }

    private func remaining(_ iso: String, now: Date = Date()) -> String? {
        guard let date = Timestamp.parse(iso) else { return nil }
        let ms = date.timeIntervalSince(now) * 1000
        guard ms > 0 else { return nil }
        let minute = 60_000.0, hour = 60 * minute, day = 24 * hour
        let days = Int(ms / day)
        let hours = Int(ms.truncatingRemainder(dividingBy: day) / hour)
        if days >= 3 { return ti("wakeups.remaining_days", ["days": days]) }
        if days >= 1 { return ti("wakeups.remaining_days_hours", ["days": days, "hours": hours]) }
        if hours >= 1 { return ti("wakeups.remaining_hours", ["hours": hours]) }
        return ti("wakeups.remaining_minutes", ["minutes": max(1, Int((ms / minute).rounded(.up)))])
    }

    func ending(_ w: WorkspaceWakeup) -> String? {
        guard w.enabled, let expires = w.expiresAt else { return nil }
        if w.kind == "event" || w.expirySeconds != nil { return remaining(expires) }
        guard let date = Timestamp.parse(expires) else { return nil }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.locale = locale
        style.timeZone = viewZone
        return ti("wakeups.until_date", ["date": date.formatted(style)])
    }

    func paused(_ w: WorkspaceWakeup) -> String? {
        switch w.pausedReason {
        case "max_fires": return ti("wakeups.paused.max_fires", ["count": w.maxFires ?? w.fireCount ?? 0])
        case "loop": return ti("wakeups.paused.loop")
        case "rate": return ti("wakeups.paused.rate")
        default: return nil
        }
    }

    func pausedReason(_ w: WorkspaceWakeup) -> String? {
        switch w.pausedReason {
        case "max_fires": return ti("wakeups.paused_reason.max_fires", ["count": w.maxFires ?? w.fireCount ?? 0])
        case "loop": return ti("wakeups.paused_reason.loop")
        case "rate": return ti("wakeups.paused_reason.rate")
        default: return nil
        }
    }

    func error(_ err: Error, fallback: String) -> String {
        switch (err as? APIError)?.status {
        case 403: return ti("wakeups.permission_error")
        case 409: return ti("wakeups.conflict_error")
        default: return fallback
        }
    }

    static func icon(_ w: WorkspaceWakeup) -> String {
        switch w.condition?["type"]?.stringValue {
        case "children_done": return "checklist"
        case "pull_request": return "arrow.triangle.pull"
        case "other_issue": return "link"
        case "issue_field": return "smallcircle.filled.circle"
        default: return w.kind == "event" ? "bell" : "clock"
        }
    }
}

// MARK: - List

/// Bumped after a wakeup is created from the list's "New wakeup" flow.
@MainActor
@Observable
final class AutopilotsWakeupsSignal {
    static let shared = AutopilotsWakeupsSignal()
    var created = 0
}

private struct AutopilotsWakeupFilters: Equatable {
    var scope = "active"
    var kind = "all"
    var source = ""
    var search = ""
    var agentID = ""
    var offset = 0
    let limit = 50

    var api: WorkspaceWakeupFilters {
        WorkspaceWakeupFilters(scope: scope, kind: kind, source: source, search: search, agentId: agentID, offset: offset, limit: limit)
    }

    var narrowed: Bool { scope != "all" || !search.isEmpty || kind != "all" || !source.isEmpty || !agentID.isEmpty }
}

/// Issue wakeups across the workspace (upstream workspace-wakeups): scope,
/// filters and search, batch turn-off, pagination. Polls every 10 s while
/// on screen, like upstream.
struct AutopilotsWakeupsView: View {
    @Environment(WorkspaceSession.self) private var session
    @State private var filters = AutopilotsWakeupFilters()
    @State private var search = ""
    @State private var page: WorkspaceWakeupPage?
    @State private var loadFailed = false
    @State private var latestPaused: WorkspaceWakeup?
    @State private var selected: Set<String> = []
    @State private var confirmRows: [WorkspaceWakeup] = []
    @State private var confirmOpen = false
    @State private var batchPending = false
    @State private var batchResult: (failed: [String], succeeded: Int)?
    @State private var reload = 0

    private static let scopes = ["active", "paused", "disabled", "ended", "all"]

    var body: some View {
        let rows = page?.items ?? []
        let selectable = rows.filter { $0.enabled && $0.canManage && $0.source != "system" }
        let picked = selectable.filter { selected.contains($0.id) }
        let text = AutopilotsWakeupText(session: session)
        VStack(spacing: 0) {
            if let paused = latestPaused, (page?.counts["paused"] ?? 0) > 0, filters.scope != "paused" {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.destructive)
                    Text(t("wakeups.banner", ["count": page?.counts["paused"] ?? 0, "issue": paused.issueIdentifier,
                                              "condition": text.trigger(paused), "reason": text.pausedReason(paused) ?? ""]))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(t("wakeups.banner_view")) { change { $0.scope = "paused" } }.controlSize(.small)
                }
                .font(Theme.Font.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Theme.destructive.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.destructive.opacity(0.3)))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            filterBar
            if let result = batchResult {
                Text(result.failed.isEmpty
                     ? t("wakeups.batch_success", ["count": result.succeeded])
                     : t("wakeups.batch_partial", ["count": result.succeeded, "succeeded": result.succeeded, "failed": result.failed.count]))
                    .font(Theme.Font.caption)
                    .foregroundStyle(result.failed.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.destructive))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            content(rows: rows, selectable: selectable, picked: picked, text: text)
            footer(picked: picked)
        }
        .task(id: TaskKey(filters: filters, reload: reload, created: AutopilotsWakeupsSignal.shared.created)) { await poll() }
        .task(id: search) {
            let next = search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard next != filters.search else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            change { $0.search = next }
        }
        .sheet(isPresented: $confirmOpen) {
            AutopilotsConfirmSheet(
                title: t("wakeups.confirm_title", ["count": confirmRows.count]),
                message: t("wakeups.confirm_body"),
                cancelLabel: t("wakeups.cancel"),
                confirmLabel: t("wakeups.confirm"),
                busyLabel: t("wakeups.disabling"),
                destructive: false
            ) {
                await disable(confirmRows)
                return true
            }
        }
    }

    private struct TaskKey: Equatable {
        var filters: AutopilotsWakeupFilters
        var reload: Int
        var created: Int
    }

    private func change(_ patch: (inout AutopilotsWakeupFilters) -> Void) {
        var next = filters
        next.offset = 0
        patch(&next)
        filters = next
        selected = []
        batchResult = nil
    }

    private func poll() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func load() async {
        do {
            let p = try await session.api.listWorkspaceWakeups(filters.api)
            guard !Task.isCancelled else { return }
            if p != page { page = p }
            loadFailed = false
            if (p.counts["paused"] ?? 0) > 0 {
                let latest = try? await session.api.listWorkspaceWakeups(
                    WorkspaceWakeupFilters(scope: "paused", kind: "all", source: "", search: "", agentId: "", offset: 0, limit: 1))
                latestPaused = latest?.items.first
            } else {
                latestPaused = nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }

    private func disable(_ rows: [WorkspaceWakeup]) async {
        batchPending = true
        var failed: [String] = []
        for row in rows {
            do {
                try await session.api.disableIssueWakeup(issueId: row.issueId, wakeupId: row.id)
            } catch {
                failed.append(row.id)
            }
        }
        batchResult = (failed, rows.count - failed.count)
        selected = Set(failed)
        batchPending = false
        reload += 1
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Self.scopes, id: \.self) { scope in
                    let active = filters.scope == scope
                    Button { change { $0.scope = scope } } label: {
                        HStack(spacing: 4) {
                            Text(t("wakeups.scopes.\(scope)"))
                            Text(page.map { "\($0.counts[scope] ?? 0)" } ?? "—").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(active ? .system(size: 11, weight: .medium) : Theme.Font.caption)
                        .foregroundStyle(active ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(active ? Color(nsColor: .controlBackgroundColor) : .clear)
                            .shadow(color: active ? .black.opacity(0.08) : .clear, radius: 1, y: 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(batchPending)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.06)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(t("wakeups.scope"))
            Spacer(minLength: 8)
            picker(t("wakeups.source"), selection: Binding(get: { filters.source }, set: { v in change { $0.source = v } }), items: [
                ("", t("wakeups.sources.all")), ("member", t("wakeups.sources.member")),
                ("agent", t("wakeups.sources.agent")), ("system", t("wakeups.sources.system")),
            ])
            picker(t("wakeups.trigger"), selection: Binding(get: { filters.kind }, set: { v in change { $0.kind = v } }), items: [
                ("all", t("wakeups.all_triggers")), ("event", t("wakeups.event")), ("at", t("wakeups.at")), ("recurring", t("wakeups.recurring")),
            ])
            picker(t("wakeups.target_agent"), selection: Binding(get: { filters.agentID }, set: { v in change { $0.agentID = v } }),
                   items: [("", t("wakeups.all_agents"))] + (page?.agents ?? []).compactMap { a in
                       guard let id = a["id"]?.stringValue else { return nil }
                       return (id, a["name"]?.stringValue ?? id)
                   })
            SearchField(text: $search, prompt: t("wakeups.search"))
                .frame(width: 208)
                .disabled(batchPending)
                .onChange(of: search) { _, v in if v.count > 256 { search = String(v.prefix(256)) } }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func picker(_ label: String, selection: Binding<String>, items: [(String, String)]) -> some View {
        Picker(label, selection: selection) {
            ForEach(items, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(maxWidth: 176)
        .fixedSize()
        .disabled(batchPending)
        .accessibilityLabel(label)
    }

    // MARK: Body

    @ViewBuilder
    private func content(rows: [WorkspaceWakeup], selectable: [WorkspaceWakeup], picked: [WorkspaceWakeup], text: AutopilotsWakeupText) -> some View {
        if loadFailed && page == nil {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.destructive)
                Text(t("wakeups.load_error")).font(Theme.Font.body)
                Button(t("page.retry")) { reload += 1 }.controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if page == nil {
            EmptyStateView(icon: "clock", title: t("wakeups.loading"))
        } else if rows.isEmpty {
            let hasAny = (page?.counts["all"] ?? 0) > 0
            EmptyStateView(icon: "bell", title: hasAny || filters.narrowed ? t("wakeups.empty_filtered") : t("wakeups.empty")) {
                if filters.narrowed && hasAny {
                    Button(t("wakeups.clear_filters")) {
                        search = ""
                        change { $0 = AutopilotsWakeupFilters(scope: "all") }
                    }
                    .controlSize(.small)
                }
            }
        } else {
            let selecting = !picked.isEmpty
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows) { row in
                            AutopilotsWakeupRow(
                                row: row,
                                selected: selected.contains(row.id),
                                selecting: selecting,
                                busy: batchPending,
                                onSelect: {
                                    if selected.contains(row.id) { selected.remove(row.id) } else { selected.insert(row.id) }
                                },
                                onChanged: { reload += 1 }
                            )
                            .equatable()
                        }
                    } header: {
                        AutopilotsWakeupHeader(selectable: selectable, picked: picked, busy: batchPending, selecting: selecting) {
                            selected = picked.count == selectable.count ? [] : Set(selectable.map(\.id))
                        }
                    }
                }
                .frame(minWidth: 900)
            }
        }
    }

    private func footer(picked: [WorkspaceWakeup]) -> some View {
        HStack(spacing: 8) {
            if !picked.isEmpty {
                Text(t("wakeups.selected", ["count": picked.count]))
                Button(t("wakeups.disable_selected")) {
                    confirmRows = picked
                    confirmOpen = true
                }
                .disabled(batchPending)
                Button(t("wakeups.clear")) { selected = [] }.buttonStyle(.borderless).disabled(batchPending)
            }
            Spacer()
            Text(page.map { t("wakeups.results", ["count": $0.total, "page": filters.offset / filters.limit + 1]) } ?? "—").monospacedDigit()
            Button(t("wakeups.previous")) { change { $0.offset = max(0, filters.offset - filters.limit) } }
                .buttonStyle(.borderless)
                .disabled(batchPending || filters.offset == 0)
            Button(t("wakeups.next_page")) {
                let next = filters.offset + filters.limit
                change { $0.offset = next }
            }
            .buttonStyle(.borderless)
            .disabled(batchPending || page == nil || filters.offset + filters.limit >= (page?.total ?? 0))
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }
}

private enum AutopilotsWakeupColumns {
    static let select: CGFloat = 24
    static let trigger: CGFloat = 220
    static let agent: CGFloat = 160
    static let source: CGFloat = 150
    static let ends: CGFloat = 170
    static let runs: CGFloat = 110
    static let controls: CGFloat = 130
}

private struct AutopilotsWakeupHeader: View {
    let selectable: [WorkspaceWakeup]
    let picked: [WorkspaceWakeup]
    let busy: Bool
    let selecting: Bool
    let onToggleAll: () -> Void
    @State private var hovering = false

    var body: some View {
        let all = !picked.isEmpty && picked.count == selectable.count
        let some = !picked.isEmpty && picked.count < selectable.count
        HStack(spacing: 12) {
            Button(action: onToggleAll) {
                Image(systemName: all ? "checkmark.square.fill" : some ? "minus.square.fill" : "square")
                    .foregroundStyle(all || some ? Theme.brand : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(selectable.isEmpty || busy)
            .opacity(selecting || hovering ? 1 : 0)
            .frame(width: AutopilotsWakeupColumns.select)
            .accessibilityLabel(t("wakeups.select_page"))
            Text(t("wakeups.issue")).frame(maxWidth: .infinity, alignment: .leading)
            Text(t("wakeups.trigger")).frame(width: AutopilotsWakeupColumns.trigger, alignment: .leading)
            Text(t("wakeups.target_agent")).frame(width: AutopilotsWakeupColumns.agent, alignment: .leading)
            Text(t("wakeups.source")).frame(width: AutopilotsWakeupColumns.source, alignment: .leading)
            Text(t("wakeups.ends")).frame(width: AutopilotsWakeupColumns.ends, alignment: .leading)
            Text(t("wakeups.runs_7d")).frame(width: AutopilotsWakeupColumns.runs, alignment: .leading)
            Text(t("wakeups.enabled")).frame(width: AutopilotsWakeupColumns.controls, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .onHover { hovering = $0 }
    }
}

private struct AutopilotsWakeupRow: View, Equatable {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let row: WorkspaceWakeup
    let selected: Bool
    let selecting: Bool
    let busy: Bool
    let onSelect: () -> Void
    let onChanged: () -> Void
    @State private var hovering = false
    @State private var pending = false
    @State private var instructionOpen = false
    @State private var transcriptTask: AgentTask?
    @State private var rescheduleOpen = false

    static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.selected == b.selected && a.selecting == b.selecting && a.busy == b.busy
    }

    var body: some View {
        let text = AutopilotsWakeupText(session: session)
        let system = row.source == "system"
        HStack(spacing: 12) {
            Group {
                if system {
                    Color.clear
                } else {
                    Button(action: onSelect) {
                        Image(systemName: selected ? "checkmark.square.fill" : "square").foregroundStyle(selected ? Theme.brand : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || !row.canManage || !row.enabled)
                    .opacity(selected || selecting || hovering ? 1 : 0)
                    .accessibilityLabel(t("wakeups.select_row", ["issue": row.issueIdentifier, "agent": row.agentName]))
                }
            }
            .frame(width: AutopilotsWakeupColumns.select)
            Button { nav.push(.issue(row.issueId), title: row.issueTitle) } label: {
                HStack(spacing: 8) {
                    Text(row.issueIdentifier).font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text(row.issueTitle).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(row.issueIdentifier) \(row.issueTitle)")
            .frame(maxWidth: .infinity, alignment: .leading)
            triggerCell(text: text, system: system)
            agentCell(system: system)
            sourceCell.frame(width: AutopilotsWakeupColumns.source, alignment: .leading)
            endsCell(text: text, system: system).frame(width: AutopilotsWakeupColumns.ends, alignment: .leading)
            runsCell(text: text).frame(width: AutopilotsWakeupColumns.runs, alignment: .leading)
            controls(text: text, system: system).frame(width: AutopilotsWakeupColumns.controls, alignment: .trailing)
        }
        .font(Theme.Font.body)
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .background(selected ? Theme.brand.opacity(0.06) : hovering ? Theme.hover : .clear)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        .onHover { hovering = $0 }
        .sheet(isPresented: $instructionOpen) {
            AutopilotsWakeupInstructionSheet(issueID: row.issueId, wakeupID: row.id, onSaved: onChanged)
        }
        .sheet(item: $transcriptTask) { TaskTranscriptSheet(task: $0) }
        .sheet(isPresented: $rescheduleOpen) {
            AutopilotsWakeupRescheduleSheet { at in try await enable(at: at, rearm: true) }
        }
    }

    private func triggerCell(text: AutopilotsWakeupText, system: Bool) -> some View {
        let label = system
            ? (row.systemStage.map { ti("wakeups.system.title_stage", ["stage": $0]) } ?? ti("wakeups.system.title_all"))
            : text.trigger(row)
        let detail = system ? nil : row.kind == "cron" ? row.timezone : text.frequency(row)
        return HStack(spacing: 6) {
            Image(systemName: system ? "checklist" : AutopilotsWakeupText.icon(row)).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(label).lineLimit(1)
        }
        .help(detail.map { "\(label) · \($0)" } ?? label)
        .frame(width: AutopilotsWakeupColumns.trigger, alignment: .leading)
    }

    @ViewBuilder
    private func agentCell(system: Bool) -> some View {
        Group {
            if system && row.agentId.isEmpty {
                Text(t("wakeups.no_target")).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    AvatarView(name: row.agentName, url: session.actorInfo(type: "agent", id: row.agentId).avatarURL, kind: .agent, size: 20)
                    Text(system ? t("wakeups.assignee_target", ["name": row.agentName]) : row.agentName).lineLimit(1)
                }
            }
        }
        .frame(width: AutopilotsWakeupColumns.agent, alignment: .leading)
    }

    @ViewBuilder private var sourceCell: some View {
        if row.source == "system" {
            Text(t("wakeups.sources.system")).font(Theme.Font.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)))
        } else {
            let agent = row.source == "agent" && row.sourceAgentId != nil
            let name = agent ? (row.sourceAgentName ?? "") : (row.createdByName ?? "")
            HStack(spacing: 6) {
                AvatarView(name: name, url: agent ? session.actorInfo(type: "agent", id: row.sourceAgentId ?? "").avatarURL : nil,
                           kind: agent ? .agent : .member, size: 20)
                Text(name).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func endsCell(text: AutopilotsWakeupText, system: Bool) -> some View {
        if system {
            Text(t("wakeups.until_issue_ends")).foregroundStyle(.secondary)
        } else {
            let ends: String = row.enabled && !row.issueClosed
                ? (text.ending(row) ?? (row.mode == "once" ? t("wakeups.fires_once") : text.state(row)))
                : (text.paused(row) ?? text.state(row, closed: row.issueClosed))
            HStack(spacing: 6) {
                Text(ends).lineLimit(1).foregroundStyle(row.pausedReason != nil ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.primary))
                if row.lastError != nil {
                    Button(ti("wakeups.needs_attention")) { nav.push(.issue(row.issueId), title: row.issueTitle) }
                        .buttonStyle(.plain)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.destructive)
                }
            }
            .help(row.enabled ? row.nextFireAt.flatMap(Timestamp.parse).map {
                "\($0.formatted(date: .abbreviated, time: .shortened)) · \(TimeZone.current.identifier)"
            } ?? "" : "")
        }
    }

    private func runsCell(text: AutopilotsWakeupText) -> some View {
        let status = row.task?.status.rawValue
        let active = AutopilotsWakeupState.isActiveRun(status)
        return HStack(spacing: 4) {
            Text("\(row.runs7d)").monospacedDigit()
            if let task = row.task {
                if active {
                    Text("·").foregroundStyle(.secondary)
                    Text(text.runState(status)).foregroundStyle(Theme.brand)
                        .help(row.activeRuns > 1 ? t("wakeups.active_runs", ["count": row.activeRuns]) : "")
                }
                Button { transcriptTask = task } label: {
                    Image(systemName: "text.alignleft").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(active || hovering ? 1 : 0)
                .help(ti("wakeups.last_run"))
                .accessibilityLabel(ti("wakeups.last_run"))
            }
        }
    }

    @ViewBuilder
    private func controls(text: AutopilotsWakeupText, system: Bool) -> some View {
        if system {
            Toggle("", isOn: Binding(get: { row.enabled }, set: { on in Task { await setSystem(on) } }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .disabled(busy || pending)
                .accessibilityLabel("\(row.issueIdentifier) · \(ti("wakeups.system.toggle"))")
        } else {
            let (control, canEnable) = AutopilotsWakeupState.control(row)
            HStack(spacing: 4) {
                Button { instructionOpen = true } label: {
                    Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy || !row.canManage)
                .opacity(hovering ? 1 : 0)
                .help(ti("wakeups.edit_instruction"))
                .accessibilityLabel(ti("wakeups.edit_instruction"))
                let locked = busy || !row.canManage || pending
                switch control {
                case .toggle:
                    Toggle("", isOn: Binding(get: { row.enabled }, set: { on in
                        Task { if on { await enableWithToast() } else { await disable() } }
                    }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(locked || (!row.enabled && !canEnable))
                    .accessibilityLabel(ti("wakeups.toggle", ["agent": row.agentName]))
                case .withdraw:
                    Button(ti("wakeups.withdraw")) { Task { await disable() } }.buttonStyle(.borderless).controlSize(.small).disabled(locked)
                case .reschedule:
                    Button(ti("wakeups.reschedule")) { rescheduleOpen = true }.buttonStyle(.borderless).controlSize(.small).disabled(locked || !canEnable)
                case .resubscribe:
                    Button(ti("wakeups.resubscribe")) { Task { await enableWithToast(rearm: true) } }
                        .buttonStyle(.borderless).controlSize(.small).disabled(locked || !canEnable)
                }
            }
            .help(!row.canManage ? t("wakeups.read_only") : row.issueClosed ? ti("wakeups.closed_hint") : "")
        }
    }

    private func setSystem(_ enabled: Bool) async {
        pending = true
        defer { pending = false }
        do {
            try await session.api.updateIssueSystemWakeup(issueId: row.issueId, rule: "child_done", enabled: enabled)
            onChanged()
        } catch {
            toaster.error(ti("wakeups.system.save_error"))
        }
    }

    private func disable() async {
        pending = true
        defer { pending = false }
        do {
            try await session.api.disableIssueWakeup(issueId: row.issueId, wakeupId: row.id)
            onChanged()
        } catch {
            toaster.error(AutopilotsWakeupText(session: session).error(error, fallback: ti("wakeups.disable_error")))
        }
    }

    private func enable(at: String? = nil, rearm: Bool? = nil) async throws {
        pending = true
        defer { pending = false }
        try await session.api.enableIssueWakeup(issueId: row.issueId, wakeupId: row.id, revision: row.revision ?? 0, at: at, rearm: rearm)
        onChanged()
    }

    private func enableWithToast(rearm: Bool? = nil) async {
        do {
            try await enable(rearm: rearm)
        } catch {
            toaster.error(AutopilotsWakeupText(session: session).error(error, fallback: ti("wakeups.enable_error")))
        }
    }
}

/// "Set a new time" for a consumed one-time wakeup.
private struct AutopilotsWakeupRescheduleSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let onSubmit: (String) async throws -> Void
    @State private var date = Date().addingTimeInterval(3600)
    @State private var error = ""
    @State private var pending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ti("wakeups.reschedule")).font(Theme.Font.title)
            Text(ti("wakeups.local_time", ["timezone": TimeZone.current.identifier])).font(Theme.Font.caption)
            DatePicker("", selection: $date).labelsHidden().datePickerStyle(.field).disabled(pending)
                .onChange(of: date) { error = "" }
            if !error.isEmpty {
                Text(error).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
            }
            HStack {
                Button(ti("wakeups.instruction_cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(ti("wakeups.reschedule")) { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pending)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func submit() async {
        guard date > Date() else {
            error = ti("wakeups.future_time")
            return
        }
        pending = true
        defer { pending = false }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        do {
            try await onSubmit(f.string(from: date))
            dismiss()
        } catch {
            self.error = AutopilotsWakeupText(session: session).error(error, fallback: ti("wakeups.enable_error"))
        }
    }
}

/// Edits a wakeup's instruction against the snapshot it opened with, so a
/// stale save conflicts instead of overwriting someone else's change.
private struct AutopilotsWakeupInstructionSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let issueID: String
    let wakeupID: String
    let onSaved: () -> Void
    @State private var original: IssueWakeup?
    @State private var loading = true
    @State private var value = ""
    @State private var error = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ti("wakeups.edit_instruction")).font(Theme.Font.title)
            Text(ti("wakeups.instruction_effect")).font(Theme.Font.caption).foregroundStyle(.secondary)
            if loading {
                Text(ti("wakeups.instruction_loading")).font(Theme.Font.body).foregroundStyle(.secondary)
            } else if let original {
                Text(ti("wakeups.instruction_title")).font(.system(size: 11, weight: .medium))
                MarkdownEditor(text: $value, minHeight: 140, maxHeight: 320, isEditable: !saving, onSubmit: { Task { await save(original) } })
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(error.isEmpty ? Theme.border.opacity(1.5) : Theme.destructive))
                    .onChange(of: value) { error = "" }
                if !error.isEmpty {
                    Text(error).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                }
                HStack {
                    Spacer()
                    Button(ti("wakeups.instruction_cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                    Button(saving ? ti("wakeups.instruction_saving") : ti("wakeups.instruction_save")) { Task { await save(original) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving || value.trimmingCharacters(in: .whitespacesAndNewlines) == original.instruction)
                }
            } else {
                Button(ti("wakeups.retry")) { Task { await load() } }
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(saving)
        .task { await load() }
    }

    private func load() async {
        loading = true
        let list = try? await session.api.listIssueWakeups(issueId: issueID)
        if original == nil, let w = list?.first(where: { $0.id == wakeupID }) {
            original = w
            value = w.instruction
        }
        loading = false
    }

    private func save(_ original: IssueWakeup) async {
        guard !saving else { return }
        let instruction = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, instruction.utf8.count <= 12000 else {
            error = ti("wakeups.instruction_invalid")
            return
        }
        saving = true
        defer { saving = false }
        do {
            try await session.api.editIssueWakeupInstruction(issueId: issueID, wakeupId: wakeupID, instruction: instruction,
                                                             expectedInstruction: original.instruction, revision: original.revision ?? 0)
            onSaved()
            dismiss()
        } catch {
            self.error = AutopilotsWakeupText(session: session).error(error, fallback: ti("wakeups.instruction_save_error"))
        }
    }
}

// MARK: - Create

/// "New wakeup" from the workspace list: pick the issue, then fill in the
/// same form as the issue sidebar.
struct AutopilotsWakeupCreateFlow: View {
    @State private var issue: SearchIssueResult?

    var body: some View {
        if let issue {
            AutopilotsWakeupCreateForm(issueID: issue.id,
                                       defaultAgentID: issue.assigneeType == "agent" ? (issue.assigneeId ?? "") : "",
                                       assigneeAgentID: issue.assigneeType == "agent" ? issue.assigneeId : nil)
        } else {
            AutopilotsIssuePicker(title: t("wakeups.create_pick_issue"), description: t("wakeups.create_pick_issue_description"),
                                  excludeIDs: [], isSelectable: { $0.status != "done" && $0.status != "cancelled" }) { issue = $0 }
        }
    }
}

/// Searches issues on the server (upstream IssuePickerModal).
struct AutopilotsIssuePicker: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let title: String
    let description: String
    let excludeIDs: Set<String>
    var isSelectable: (SearchIssueResult) -> Bool = { _ in true }
    let onSelect: (SearchIssueResult) -> Void
    @State private var query = ""
    @State private var results: [SearchIssueResult] = []
    @State private var loading = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.Font.title)
                Text(description).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            TextField(tr("modals", "issue_picker.search_placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .focused($focused)
                .onSubmit { if let first = results.first { pick(first) } }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if loading && results.isEmpty {
                        Text(tr("modals", "issue_picker.searching")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(12)
                    } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(tr("modals", "issue_picker.prompt_to_search")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(12)
                    } else if results.isEmpty {
                        Text(tr("modals", "issue_picker.no_results")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(results) { issue in
                        Button { pick(issue) } label: {
                            HStack(spacing: 8) {
                                session.issues.catalog.icon(for: IssueStatusKey(rawValue: issue.status), size: 13)
                                Text(issue.identifier).foregroundStyle(.secondary).monospacedDigit()
                                Text(issue.title).lineLimit(1)
                            }
                            .font(Theme.Font.body)
                        }
                        .buttonStyle(HoverRowButtonStyle())
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 320)
            Divider()
            HStack {
                Spacer()
                Button(t("wakeups.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            .padding(12)
        }
        .frame(width: 520)
        .onAppear { focused = true }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else {
                results = []
                loading = false
                return
            }
            loading = true
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = (try? await session.api.searchIssues(q: q, limit: 20, includeClosed: true))?.issues ?? []
            guard !Task.isCancelled else { return }
            results = found.filter { !excludeIDs.contains($0.id) && isSelectable($0) }
            loading = false
        }
    }

    private func pick(_ issue: SearchIssueResult) {
        onSelect(issue)
    }
}

/// The wakeup create form (upstream WakeupCreateForm): a condition and its
/// parameters, the agent to wake, the instruction, and the deadline options.
private struct AutopilotsWakeupCreateForm: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let issueID: String
    let assigneeAgentID: String?
    @State private var draft: AutopilotsWakeupDraft
    @State private var error = ""
    @State private var submitting = false
    @State private var otherIssuePickerOpen = false
    @State private var stages: [Int] = []

    init(issueID: String, defaultAgentID: String, assigneeAgentID: String?) {
        self.issueID = issueID
        self.assigneeAgentID = assigneeAgentID
        _draft = State(initialValue: AutopilotsWakeupDraft(agentID: defaultAgentID, timezone: TimeZone.current.identifier))
    }

    private typealias Condition = AutopilotsWakeupDraft.Condition

    var body: some View {
        let agentName = session.agentRecords.item(draft.agentID)?.name ?? session.directory.agent(draft.agentID)?.name
        VStack(alignment: .leading, spacing: 0) {
            Text(ti("wakeups.create.title")).font(Theme.Font.title)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(ti("wakeups.create.when")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    AutopilotsFlowLayout(spacing: 6) {
                        conditionMenu
                        conditionParams
                    }
                }
                GridRow {
                    Text(ti("wakeups.create.wake")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    agentChoice(value: draft.agentID, placeholder: ti("wakeups.create.choose_agent"), allowAny: false) { $0.agentID = $1 }
                }
            }
            .padding(.top, 14)
            if draft.wakesAssigneeOnComments(assigneeAgentID: assigneeAgentID) {
                Text(ti("wakeups.create.assignee_comment_hint", ["name": agentName ?? ""]))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.05)))
                    .padding(.top, 10)
            }
            if draft.condition == .at && draft.atPreset == .custom {
                DatePicker(ti("wakeups.local_time", ["timezone": TimeZone.current.identifier]),
                           selection: Binding(get: { draft.atCustom ?? Date().addingTimeInterval(3600) }, set: { v in update { $0.atCustom = v } }))
                    .datePickerStyle(.field)
                    .font(Theme.Font.caption)
                    .padding(.top, 10)
                    .onAppear { if draft.atCustom == nil { draft.atCustom = Date().addingTimeInterval(3600) } }
            }
            Text(ti("wakeups.instruction_title")).font(.system(size: 11, weight: .medium)).padding(.top, 16).padding(.bottom, 6)
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { draft.instruction }, set: { v in update { $0.instruction = v } }))
                    .font(Theme.Font.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 64)
                if draft.instruction.isEmpty {
                    Text(ti("wakeups.create.instruction_placeholder")).font(Theme.Font.body).foregroundStyle(.tertiary)
                        .padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border.opacity(1.5)))
            if draft.condition == .recurring {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text(ti("wakeups.create.until")).font(Theme.Font.caption).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                        DatePicker("", selection: Binding(get: { draft.until }, set: { v in update { $0.until = v } }), displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.field).fixedSize()
                    }
                }
                .padding(.top, 16)
            }
            if AutopilotsWakeupDraft.isEventCondition(draft.condition) {
                eventOptions(agentName: agentName).padding(.top, 16)
            }
            if !error.isEmpty {
                Text(error).font(Theme.Font.caption).foregroundStyle(Theme.destructive).padding(.top, 12)
            }
            Divider().padding(.top, 16)
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle").font(.system(size: 10))
                    Text(ti("wakeups.create.on_behalf"))
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button(ti("wakeups.create.cancel")) { dismiss() }.buttonStyle(.borderless).disabled(submitting).keyboardShortcut(.cancelAction)
                Button(submitting ? ti("wakeups.create.submitting") : ti("wakeups.create.submit")) { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(submitting)
            }
            .controlSize(.small)
            .padding(.top, 12)
        }
        .padding(16)
        .frame(width: 460)
        .interactiveDismissDisabled(submitting)
        .task {
            await session.agentRecords.loadIfNeeded()
            await session.labels.loadIfNeeded()
            await session.properties.loadIfNeeded()
            await session.squads.loadIfNeeded()
            let children: JSONValue? = try? await session.api.call(.get, "/api/issues/\(issueID.pathEscaped)/children")
            let found = children?["issues"]?.arrayValue?.compactMap { $0["stage"]?.doubleValue.map { Int($0) } } ?? []
            stages = Array(Set(found)).sorted()
        }
        .sheet(isPresented: $otherIssuePickerOpen) {
            AutopilotsIssuePicker(title: ti("wakeups.create.pick_issue_title"), description: ti("wakeups.create.pick_issue_description"),
                                  excludeIDs: [issueID]) { issue in
                update {
                    $0.otherIssueID = issue.id
                    $0.otherIssueIdentifier = issue.identifier
                }
                otherIssuePickerOpen = false
            }
        }
    }

    private func update(_ patch: (inout AutopilotsWakeupDraft) -> Void) {
        patch(&draft)
        error = ""
    }

    // MARK: Condition

    private static let conditionSymbols: [Condition: String] = [
        .at: "clock", .recurring: "arrow.clockwise", .reply: "bubble.left", .field: "smallcircle.filled.circle",
        .runEnd: "cpu", .children: "checklist", .pullRequest: "arrow.triangle.pull", .otherIssue: "link", .custom: "bolt",
    ]
    private static let conditionKeys: [Condition: String] = [
        .at: "cond_at", .recurring: "cond_recurring", .reply: "cond_reply", .field: "cond_field", .runEnd: "cond_run_end",
        .children: "cond_children", .pullRequest: "cond_pr", .otherIssue: "cond_issue", .custom: "cond_custom",
    ]

    private func conditionHint(_ c: Condition) -> String {
        let key = Self.conditionKeys[c]!
        return c == .custom
            ? ti("wakeups.create.\(key)_hint", ["count": AutopilotsWakeupDraft.eventTypes.count])
            : ti("wakeups.create.\(key)_hint")
    }

    private var conditionMenu: some View {
        let groups: [(String, [Condition])] = [
            (ti("wakeups.create.group_time"), [.at, .recurring]),
            (ti("wakeups.create.group_collaboration"), [.reply, .field]),
            (ti("wakeups.create.group_runs"), [.runEnd, .children]),
            (ti("wakeups.create.group_linked"), [.pullRequest, .otherIssue]),
        ]
        return Menu {
            ForEach(groups, id: \.0) { label, keys in
                Section(label) {
                    ForEach(keys, id: \.self) { conditionItem($0) }
                }
            }
            Divider()
            conditionItem(.custom)
        } label: {
            pill(icon: draft.condition.flatMap { Self.conditionSymbols[$0] } ?? "circle.dashed",
                 label: draft.condition.map { ti("wakeups.create.\(Self.conditionKeys[$0]!)") } ?? ti("wakeups.create.choose_condition"),
                 placeholder: draft.condition == nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func conditionItem(_ c: Condition) -> some View {
        Button { update { $0.condition = c } } label: {
            Label {
                Text(ti("wakeups.create.\(Self.conditionKeys[c]!)")) + Text("\n") + Text(conditionHint(c)).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: Self.conditionSymbols[c]!)
            }
        }
    }

    @ViewBuilder private var conditionParams: some View {
        switch draft.condition {
        case .field: fieldParams
        case .children:
            pillMenu(ti("wakeups.create.cond_children"), value: draft.stage.map(String.init) ?? "all",
                     options: [("all", ti("wakeups.create.children_all"))] + stages.map { (String($0), ti("wakeups.create.children_stage", ["stage": $0])) }) { v in
                update { $0.stage = v == "all" ? nil : Int(v) }
            }
        case .pullRequest:
            pillMenu(ti("wakeups.create.cond_pr"), value: draft.prEvent,
                     options: [("checks_finished", ti("wakeups.create.pr_checks")), ("merged", ti("wakeups.create.pr_merged"))]) { v in
                update { $0.prEvent = v }
            }
        case .otherIssue:
            Button { otherIssuePickerOpen = true } label: {
                pill(icon: "link", label: draft.otherIssueID == nil ? ti("wakeups.create.choose_issue") : draft.otherIssueIdentifier,
                     placeholder: draft.otherIssueID == nil, chevron: false)
            }
            .buttonStyle(.plain)
            pillMenu(ti("wakeups.create.cond_issue"), value: draft.otherState, options: [
                ("done", ti("wakeups.create.other_done")), ("ended", ti("wakeups.create.other_ended")),
                ("in_review", ti("wakeups.create.other_in_review")),
            ]) { v in update { $0.otherState = v } }
        case .at:
            pillMenu(ti("wakeups.create.cond_at"), value: draft.atPreset.rawValue, options: [
                ("10m", ti("wakeups.create.at_10m")), ("1h", ti("wakeups.create.at_1h")),
                ("tomorrow", ti("wakeups.create.at_tomorrow")), ("custom", ti("wakeups.create.at_custom")),
            ]) { v in update { $0.atPreset = AutopilotsWakeupDraft.AtPreset(rawValue: v) ?? .oneHour } }
        case .recurring:
            pillMenu(ti("wakeups.create.cond_recurring"), value: draft.recurrence.rawValue, options: [
                ("hourly", ti("wakeups.create.hourly")), ("daily", ti("wakeups.create.daily")), ("weekdays", ti("wakeups.create.weekdays")),
            ]) { v in update { $0.recurrence = AutopilotsWakeupDraft.Recurrence(rawValue: v) ?? .daily } }
        case .reply:
            actorChoice(value: draft.replyActor, anyLabel: ti("wakeups.create.anyone"), includeSquads: false) { a in update { $0.replyActor = a } }
        case .runEnd:
            agentChoice(value: draft.runAgentID, placeholder: ti("wakeups.create.any_agent"), allowAny: true) { $0.runAgentID = $1 }
        case .custom:
            Menu {
                ForEach(AutopilotsWakeupDraft.eventTypes, id: \.self) { event in
                    Toggle(isOn: Binding(get: { draft.events.contains(event) }, set: { on in
                        update { d in
                            d.events = on ? AutopilotsWakeupDraft.eventTypes.filter { $0 == event || d.events.contains($0) } : d.events.filter { $0 != event }
                        }
                    })) {
                        Text(AutopilotsWakeupText(session: session).eventName(event))
                    }
                }
            } label: {
                pill(icon: nil, label: ti("wakeups.create.events_selected", ["count": draft.events.count]), placeholder: draft.events.isEmpty)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private var fieldParams: some View {
        pillMenu(ti("wakeups.create.field_kind"), value: draft.field.rawValue, options: [
            ("status", ti("wakeups.create.field_status")), ("assignee", ti("wakeups.create.field_assignee")),
            ("label", ti("wakeups.create.field_label")), ("property", ti("wakeups.create.field_property")),
        ]) { v in
            update {
                $0.field = AutopilotsWakeupDraft.Field(rawValue: v) ?? .status
                $0.fieldTarget = ""
                $0.fieldValue = ""
                $0.assignee = nil
            }
        }
        switch draft.field {
        case .status:
            let catalog = session.issues.catalog
            pillMenu(ti("wakeups.create.choose_status"), value: draft.fieldTarget,
                     options: catalog.entries.filter { $0.archivedAt == nil }.map { ($0.key.rawValue, catalog.localizedName(for: $0.key)) },
                     placeholder: ti("wakeups.create.choose_status")) { v in update { $0.fieldTarget = v } }
        case .assignee:
            actorChoice(value: draft.assignee, anyLabel: nil, includeSquads: true) { a in update { $0.assignee = a } }
        case .label:
            pillMenu(ti("wakeups.create.choose_label"), value: draft.fieldTarget, options: session.labels.items.map { ($0.id, $0.name) },
                     placeholder: ti("wakeups.create.choose_label")) { v in update { $0.fieldTarget = v } }
        case .property:
            let properties = session.properties.items.filter { !$0.archived }
            pillMenu(ti("wakeups.create.choose_property"), value: draft.fieldTarget, options: properties.map { ($0.id, $0.name) },
                     placeholder: ti("wakeups.create.choose_property")) { v in
                update {
                    $0.fieldTarget = v
                    $0.fieldValue = ""
                }
            }
            if let property = properties.first(where: { $0.id == draft.fieldTarget }) {
                if property.type == "select" || property.type == "multi_select" {
                    pillMenu(property.name, value: draft.fieldValue, options: (property.config?.options ?? []).map { ($0.id, $0.name) },
                             placeholder: ti("wakeups.create.value_placeholder")) { v in update { $0.fieldValue = v } }
                } else if property.type == "checkbox" {
                    pillMenu(property.name, value: draft.fieldValue,
                             options: [("true", ti("wakeups.create.checked")), ("false", ti("wakeups.create.unchecked"))],
                             placeholder: ti("wakeups.create.value_placeholder")) { v in update { $0.fieldValue = v } }
                } else {
                    TextField(ti("wakeups.create.value_placeholder"), text: Binding(get: { draft.fieldValue }, set: { v in update { $0.fieldValue = v } }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 128)
                        .accessibilityLabel(property.name)
                }
            }
        }
    }

    private func eventOptions(agentName: String?) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text(ti("wakeups.create.trigger_count")).frame(width: 72, alignment: .leading)
                SegmentedToggle(selection: Binding(get: { draft.mode }, set: { v in update { $0.mode = v } }), options: [
                    ("once", ti("wakeups.once"), nil), ("continuous", ti("wakeups.continuous"), nil),
                ])
                .controlSize(.small)
            }
            if draft.mode == "continuous" {
                GridRow {
                    Text(ti("wakeups.create.max_fires"))
                    pillMenu(ti("wakeups.create.max_fires"), value: String(draft.maxFires),
                             options: AutopilotsWakeupDraft.maxFiresOptions.map { (String($0), ti("wakeups.create.max_fires_times", ["count": $0])) }) { v in
                        update { $0.maxFires = Int(v) ?? 20 }
                    }
                }
            }
            GridRow {
                Text(ti("wakeups.create.max_wait"))
                pillMenu(ti("wakeups.create.max_wait"), value: String(draft.waitDays),
                         options: AutopilotsWakeupDraft.waitDays.map { (String($0), ti("wakeups.create.wait_days", ["count": $0])) }) { v in
                    update { $0.waitDays = Int(v) ?? 7 }
                }
            }
            GridRow {
                Text(ti("wakeups.create.on_timeout"))
                pillMenu(ti("wakeups.create.on_timeout"), value: draft.onTimeout, options: [
                    ("wake", ti("wakeups.create.timeout_wake", ["agent": agentName ?? ti("wakeups.create.the_agent")])),
                    ("end", ti("wakeups.create.timeout_end")),
                ]) { v in update { $0.onTimeout = v } }
            }
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Pickers

    private func pill(icon: String?, label: String, placeholder: Bool, chevron: Bool = true) -> some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary) }
            Text(label).lineLimit(1).foregroundStyle(placeholder ? .secondary : .primary)
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary) }
        }
        .font(Theme.Font.caption)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(placeholder ? Theme.brand.opacity(0.5) : Theme.border.opacity(1.5)))
        .contentShape(Rectangle())
    }

    private func pillMenu(_ label: String, value: String, options: [(String, String)], placeholder: String? = nil,
                          onChange: @escaping (String) -> Void) -> some View {
        let current = options.first { $0.0 == value }
        return Menu {
            Picker(label, selection: Binding(get: { value }, set: onChange)) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            pill(icon: nil, label: current?.1 ?? placeholder ?? "", placeholder: current == nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(label): \(current?.1 ?? "")")
    }

    private func agentChoice(value: String, placeholder: String, allowAny: Bool, onChange: @escaping (inout AutopilotsWakeupDraft, String) -> Void) -> some View {
        let agents = session.agentRecords.items.filter { $0.archivedAt == nil }
        let selected = agents.first { $0.id == value }
        var options: [PickerOption<String>] = []
        if allowAny {
            options.append(PickerOption(id: "", title: placeholder, icon: AnyView(Image(systemName: "cpu").foregroundStyle(.secondary))))
        }
        for a in agents {
            let bound = a.runtimeBound != false && !a.runtimeId.trimmingCharacters(in: .whitespaces).isEmpty
            options.append(PickerOption(id: a.id, title: a.name, disabled: !allowAny && !bound,
                                        icon: AnyView(AvatarView(name: a.name, url: a.avatarUrl, kind: .agent, size: 16))))
        }
        return PopoverButton(label: {
            HStack(spacing: 5) {
                if let selected {
                    AvatarView(name: selected.name, url: selected.avatarUrl, kind: .agent, size: 14)
                } else {
                    Image(systemName: "cpu").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(selected?.name ?? placeholder).lineLimit(1).foregroundStyle(selected == nil ? .secondary : .primary)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(Theme.Font.caption)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border.opacity(1.5)))
            .contentShape(Rectangle())
        }, content: { close in
            OptionList(options: options, selected: [value]) { id in
                close()
                update { onChange(&$0, id) }
            }
        }, style: nil)
    }

    private func actorChoice(value: AutopilotsWakeupDraft.Actor?, anyLabel: String?, includeSquads: Bool,
                             onChange: @escaping (AutopilotsWakeupDraft.Actor?) -> Void) -> some View {
        var options: [PickerOption<String>] = []
        if let anyLabel { options.append(PickerOption(id: "", title: anyLabel)) }
        let members = ti("wakeups.create.members")
        for m in session.directory.members {
            options.append(PickerOption(id: "member:\(m.userID)", title: m.name, group: members,
                                        icon: AnyView(AvatarView(name: m.name, url: m.avatarURL, size: 16))))
        }
        let agentsGroup = ti("wakeups.create.agents")
        for a in session.agentRecords.items where a.archivedAt == nil {
            options.append(PickerOption(id: "agent:\(a.id)", title: a.name, group: agentsGroup,
                                        icon: AnyView(AvatarView(name: a.name, url: a.avatarUrl, kind: .agent, size: 16))))
        }
        if includeSquads {
            let squadsGroup = ti("wakeups.create.squads")
            for s in session.squads.items where s.archivedAt == nil {
                options.append(PickerOption(id: "squad:\(s.id)", title: s.name, group: squadsGroup))
            }
        }
        let name = value.map { session.actorInfo(type: $0.type, id: $0.id).name }
        return PopoverButton(label: {
            HStack(spacing: 5) {
                if let value, value.type != "squad" { ActorAvatar(type: value.type, id: value.id, size: 14) }
                Text(name ?? anyLabel ?? ti("wakeups.create.choose_assignee")).lineLimit(1)
                    .foregroundStyle(name == nil && anyLabel == nil ? .secondary : .primary)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(Theme.Font.caption)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border.opacity(1.5)))
            .contentShape(Rectangle())
        }, content: { close in
            OptionList(options: options, selected: [value.map { "\($0.type):\($0.id)" } ?? ""]) { id in
                close()
                let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
                onChange(parts.count == 2 ? AutopilotsWakeupDraft.Actor(type: parts[0], id: parts[1]) : nil)
            }
        }, style: nil)
    }

    // MARK: Submit

    private func submit() async {
        guard !submitting else { return }
        let propertyType = draft.field == .property ? session.properties.item(draft.fieldTarget)?.type : nil
        let input: IssueWakeupInput
        switch draft.buildInput(propertyType: propertyType) {
        case .success(let i): input = i
        case .failure(let e):
            error = e == .instructionInvalid || e == .futureTime ? ti("wakeups.\(e.rawValue)") : ti("wakeups.create.\(e.rawValue)")
            return
        }
        submitting = true
        defer { submitting = false }
        do {
            try await session.api.createIssueWakeup(issueId: issueID, input)
            AutopilotsWakeupsSignal.shared.created += 1
            dismiss()
        } catch {
            self.error = (error as? APIError)?.code == "wakeup_capacity_exceeded"
                ? ti("wakeups.create.capacity_error")
                : AutopilotsWakeupText(session: session).error(error, fallback: ti("wakeups.create.error"))
        }
    }
}
