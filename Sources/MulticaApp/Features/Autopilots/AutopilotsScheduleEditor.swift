import MulticaCore
import SwiftUI

private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
    tr("autopilots", key, args)
}

private typealias Schedule = AutopilotsSchedule

/// Server-side next-run preview for one (expression, timezone) input
/// (upstream cronPreviewOptions: 30 s fresh, a 400 is a stable answer).
@MainActor
@Observable
final class AutopilotsCronPreview {
    enum Verdict: Equatable {
        case accepted(readable: Bool)
        case rejected(APIError)
    }

    /// The input the latest settled answer belongs to.
    private(set) var resultKey: String?
    private(set) var runs: [String]?
    private(set) var succeeded = false
    private(set) var transportFailed = false
    /// Last readable answer per input; a transport failure never replaces it.
    private(set) var verdicts: [String: Verdict] = [:]
    /// The list on screen, kept while the next answer is in flight.
    private(set) var shown: (runs: [String], timezone: String)?

    private struct Cached {
        var runs: [String]?
        var rejection: APIError?
        var at: Date
    }

    private static var cache: [String: Cached] = [:]

    static func key(expr: String, tz: String) -> String { "\(expr) \(tz)" }

    func fetch(expr: String, tz: String, api: APIClient, force: Bool = false) async {
        let key = Self.key(expr: expr, tz: tz)
        if !force, let hit = Self.cache[key], Date().timeIntervalSince(hit.at) < 30 {
            settle(key: key, tz: tz, runs: hit.runs, rejection: hit.rejection, failed: false)
            return
        }
        do {
            let r = try await api.cronPreview(expr: expr, tz: tz)
            guard !Task.isCancelled else { return }
            Self.cache[key] = Cached(runs: r.nextRuns, rejection: nil, at: Date())
            settle(key: key, tz: tz, runs: r.nextRuns, rejection: nil, failed: false)
        } catch let e as APIError where e.status == 400 {
            guard !Task.isCancelled else { return }
            Self.cache[key] = Cached(runs: nil, rejection: e, at: Date())
            settle(key: key, tz: tz, runs: nil, rejection: e, failed: false)
        } catch {
            guard !Task.isCancelled else { return }
            settle(key: key, tz: tz, runs: nil, rejection: nil, failed: true)
        }
    }

    private func settle(key: String, tz: String, runs: [String]?, rejection: APIError?, failed: Bool) {
        resultKey = key
        transportFailed = failed
        if let rejection {
            succeeded = false
            self.runs = nil
            verdicts[key] = .rejected(rejection)
        } else if !failed {
            succeeded = true
            self.runs = runs
            verdicts[key] = .accepted(readable: runs != nil)
            if let runs { shown = (runs, tz) }
        } else {
            succeeded = false
        }
    }
}

/// The schedule editor (upstream schedule-editor.tsx): time, days and
/// timezone controls over one structured schedule, plus the cron text, the
/// plain-language readback and the server's next-run preview.
struct AutopilotsScheduleEditor: View {
    @Environment(WorkspaceSession.self) private var session
    @Binding var value: AutopilotsSchedule.Config
    var disabled = false
    /// Fires when the server accepts or rejects the current expression.
    var onValidityChange: ((Bool) -> Void)? = nil

    @State private var preview = AutopilotsCronPreview()
    @State private var anchors = Anchors()
    @State private var cronDraft: String?
    @State private var cronEditing = false
    @State private var pendingPromotion: String?
    @State private var refetchedFor: String?
    @State private var focusTimeField = false
    @State private var focusDayField = false
    @FocusState private var cronFocused: Bool

    /// What the controls remember across mode switches, outside the model.
    private final class Anchors {
        var time = "09:00"
        var every: Schedule.Every?
        var interval: [Schedule.Unit: Int] = [:]
        var daysOfWeek = [1]
        var dayOfMonth = 1
    }

    private var advanced: Bool { value.raw != nil }
    private var committedCron: String { Schedule.toCron(value) }
    private var committedKey: String { AutopilotsCronPreview.key(expr: committedCron, tz: value.timezone) }

    var body: some View {
        let _ = rememberAnchors()
        let key = committedKey
        let previewIsCurrent = preview.resultKey == key
        let rejection: APIError? = {
            if case .rejected(let e)? = preview.verdicts[key] { return e }
            return nil
        }()
        VStack(alignment: .leading, spacing: 20) {
            field(t("schedule_editor.time_label"), disabled: disabled || advanced) { timeControls }
            field(t("schedule_editor.days_label"), disabled: disabled || advanced) { dayControls }
            field(t("schedule_editor.timezone_label"), disabled: disabled) {
                AutopilotsTimezonePicker(value: value.timezone, disabled: disabled) { tz in
                    value.timezone = tz
                }
            }
            panel(previewIsCurrent: previewIsCurrent, rejection: rejection)
        }
        .task(id: key) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, !committedCron.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            await preview.fetch(expr: committedCron, tz: value.timezone, api: session.api)
        }
        .onChange(of: preview.resultKey) { promoteIfAccepted() }
        .onChange(of: preview.succeeded) { promoteIfAccepted() }
        .onChange(of: rejection == nil, initial: true) { onValidityChange?(rejection == nil) }
        .onChange(of: key) { onValidityChange?(rejection == nil) }
    }

    private func rememberAnchors() {
        if let a = Schedule.timeAnchor(of: value.time) { anchors.time = a }
        if case .every(let e) = value.time {
            anchors.every = e
            anchors.interval[e.unit] = e.interval
        }
        switch value.days {
        case .weekly(let d): anchors.daysOfWeek = d
        case .monthly(let d): anchors.dayOfMonth = d
        case .every: break
        }
    }

    private func field<Content: View>(_ label: String, disabled: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { content() }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
    }

    // MARK: Time

    @ViewBuilder private var timeControls: some View {
        SegmentedToggle(
            selection: Binding(
                get: { value.time.isAt ? "at" : "every" },
                set: { kind in
                    focusTimeField = true
                    if kind == "at" {
                        setTime(.at(Schedule.defaultAtTime(value.time, anchor: anchors.time)))
                    } else {
                        setTime(.every(Schedule.defaultEveryTime(value.time, anchor: anchors.every)))
                    }
                }
            ),
            options: [("at", t("schedule_editor.time_at"), nil), ("every", t("schedule_editor.time_every"), nil)]
        )
        switch value.time {
        case .at(let time):
            AutopilotsClockField(value: time, autoFocus: focusTimeField,
                                 hourLabel: t("schedule_editor.a11y.fixed_hour"), minuteLabel: t("schedule_editor.a11y.fixed_minute")) {
                setTime(.at($0))
            }
            .onAppear { focusTimeField = false }
        case .every(let e):
            AutopilotsEveryControls(time: e, intervalAnchor: anchors.interval, autoFocus: focusTimeField) { setTime(.every($0)) }
                .onAppear { focusTimeField = false }
        }
    }

    private func setTime(_ time: Schedule.TimePattern) {
        cronDraft = nil
        value.time = time
        value.raw = nil
    }

    // MARK: Days

    @ViewBuilder private var dayControls: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { value.days.kind },
                set: { kind in
                    guard kind != value.days.kind else { return }
                    switch kind {
                    case "every": setDays(.every)
                    case "weekly": setDays(.weekly(anchors.daysOfWeek))
                    default:
                        focusDayField = true
                        setDays(.monthly(anchors.dayOfMonth))
                    }
                }
            )) {
                Text(t("schedule_editor.days_every")).tag("every")
                Text(t("schedule_editor.days_weekly")).tag("weekly")
                Text(t("schedule_editor.days_monthly")).tag("monthly")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(t("schedule_editor.a11y.day_pattern"))
            .frame(maxWidth: .infinity)
            if case .monthly(let dom) = value.days {
                AutopilotsNumberField(value: dom, range: 1...31, width: 64, autoFocus: focusDayField,
                                      accessibilityLabel: t("schedule_editor.a11y.day_of_month")) { setDays(.monthly($0)) }
                    .onAppear { focusDayField = false }
            }
        }
        if case .weekly(let selected) = value.days {
            HStack(spacing: 2) {
                ForEach(0..<7, id: \.self) { i in
                    let key = Schedule.dayKeys[i]
                    let on = selected.contains(i)
                    Button { setDays(.weekly(Schedule.toggleDay(selected, i))) } label: {
                        Text(t("schedule_editor.days_short.\(key)"))
                            .font(.system(size: 10, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : .secondary)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(on ? Color.primary : Color.primary.opacity(0.06)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t("schedule_editor.a11y.days_full.\(key)"))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        if case .monthly(let dom) = value.days, dom >= 29 {
            Text(t("schedule_editor.monthly_short_month_hint", ["day": dom])).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
    }

    private func setDays(_ days: Schedule.DayPattern) {
        cronDraft = nil
        value.days = days
        value.raw = nil
    }

    // MARK: Cron text

    /// Commits the cron box's text; returns whether the editor is advanced-only
    /// afterwards.
    @discardableResult
    private func applyDraft(_ draft: String) -> Bool {
        let next = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        cronDraft = nil
        if next.isEmpty || next == Schedule.cronFields(value) { return advanced }
        // A typed TZ= prefix is committed verbatim and promoted only once the
        // server accepts this exact text.
        if Schedule.extractTimezonePrefix(next) != nil {
            pendingPromotion = next
            value.raw = next
            return true
        }
        pendingPromotion = nil
        let parsed = Schedule.parseCron(next, timezone: value.timezone)
        if parsed.raw == nil {
            value = parsed
        } else {
            value.raw = next
        }
        return parsed.raw != nil
    }

    private func promoteIfAccepted() {
        guard let pending = pendingPromotion, pending == committedCron,
              preview.resultKey == committedKey, preview.succeeded else { return }
        pendingPromotion = nil
        value = Schedule.parseCron(pending, timezone: value.timezone)
    }

    // MARK: Panel

    @ViewBuilder
    private func panel(previewIsCurrent: Bool, rejection: APIError?) -> some View {
        let scheduleRejection = rejection.map(Schedule.classifyRejection)
        let previewUnavailable = previewIsCurrent
            && ((preview.transportFailed && rejection == nil) || (preview.succeeded && preview.runs == nil))
        let previewIsSettled = previewIsCurrent && preview.succeeded && preview.runs != nil
        let serverAccepted = preview.verdicts[committedKey] == .accepted(readable: true)
        let cronText = cronDraft ?? Schedule.cronFields(value)
        let ownPrefix = Schedule.hasTimezonePrefix(cronText)
        let cronOpen = advanced || cronEditing
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let description = Schedule.describe(value) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "clock").font(.system(size: 10))
                        Text(description).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.primary)
                }
                if cronOpen {
                    VStack(alignment: .leading, spacing: 0) {
                        if !ownPrefix {
                            Text("TZ=\(value.timezone)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 8)
                                .padding(.top, 5)
                        }
                        TextField(t("schedule_editor.cron_toggle"), text: Binding(get: { cronText }, set: { cronDraft = $0 }))
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .focused($cronFocused)
                            .disabled(disabled)
                            .onSubmit {
                                if let draft = cronDraft {
                                    cronEditing = true
                                    applyDraft(draft)
                                }
                            }
                            .accessibilityLabel(t("schedule_editor.cron_toggle"))
                    }
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .strokeBorder(scheduleRejection != nil ? Theme.destructive.opacity(0.6) : Color.primary.opacity(0.15)))
                    .onChange(of: cronFocused) { _, focused in
                        guard !focused else { return }
                        let stillAdvanced = cronDraft.map { applyDraft($0) } ?? advanced
                        if !stillAdvanced { cronEditing = false }
                    }
                    .onAppear { if cronEditing { cronFocused = true } }
                } else {
                    Button {
                        cronEditing = true
                        cronFocused = true
                    } label: {
                        HStack(spacing: 5) {
                            Text(cronText).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                            Image(systemName: "pencil").font(.system(size: 9)).opacity(0.6)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .accessibilityLabel(t("schedule_editor.cron_click_to_edit"))
                }
                if let scheduleRejection {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scheduleRejection.code == .invalidTimezone ? t("schedule_editor.timezone_invalid") : t("schedule_editor.cron_invalid"))
                        Text(scheduleRejection.detail).font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundStyle(Theme.destructive)
                    .textSelection(.enabled)
                } else if advanced {
                    Text(serverAccepted ? t("schedule_editor.advanced_hint")
                         : previewUnavailable ? t("schedule_editor.advanced_unverified") : t("schedule_editor.advanced_checking"))
                        .fixedSize(horizontal: false, vertical: true)
                } else if cronOpen {
                    Text(t("schedule_editor.cron_hint"))
                }
            }
            if scheduleRejection == nil {
                Divider().padding(.vertical, 10)
                nextRuns(unavailable: previewUnavailable, settled: previewIsSettled)
            }
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder
    private func nextRuns(unavailable: Bool, settled: Bool) -> some View {
        let shown = preview.shown
        let showsList = !unavailable && !(shown?.runs.isEmpty ?? true)
        VStack(alignment: .leading, spacing: 6) {
            Text(t("schedule_editor.next_runs_label")).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
            if unavailable {
                Text(t("schedule_editor.preview_unavailable"))
            } else if let shown, !shown.runs.isEmpty {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                        ForEach(shown.runs, id: \.self) { iso in
                            GridRow {
                                Text(AutopilotsFormat.instant(iso, timeZone: shown.timezone)).foregroundStyle(.primary).monospacedDigit()
                                Text(Timestamp.parse(iso).map { t("schedule_editor.next_in", ["countdown": Schedule.countdown(to: $0, now: context.date)]) } ?? "")
                                    .monospacedDigit()
                                    .opacity(0.7)
                            }
                        }
                    }
                    .task(id: context.date) { refreshIfStale(now: context.date) }
                }
            } else if settled {
                Text(t("schedule_editor.no_upcoming_runs"))
            }
        }
        .frame(minHeight: 56, alignment: .top)
        .opacity(showsList && !settled ? 0.5 : 1)
    }

    /// Once the first previewed run is in the past the cached list is stale.
    private func refreshIfStale(now: Date) {
        guard preview.resultKey == committedKey, let first = preview.runs?.first, let at = Timestamp.parse(first), at <= now else { return }
        let marker = "\(committedKey) \(first)"
        guard refetchedFor != marker else { return }
        refetchedFor = marker
        let expr = committedCron
        let tz = value.timezone
        Task { await preview.fetch(expr: expr, tz: tz, api: session.api, force: true) }
    }
}

/// "Every N hours/minutes" + the daily window (upstream EveryTimeControls).
private struct AutopilotsEveryControls: View {
    let time: AutopilotsSchedule.Every
    let intervalAnchor: [AutopilotsSchedule.Unit: Int]
    var autoFocus = false
    let onSet: (AutopilotsSchedule.Every) -> Void
    @State private var ends = Ends()

    /// The end the user asked for, restored when a dragged start comes back;
    /// `dragged` is the end this control produced itself by moving the start.
    private final class Ends {
        var anchor: Int?
        var dragged: Int?
    }

    var body: some View {
        let window = Schedule.displayWindow(time)
        let endHour = Schedule.timeParts(window.to).hour
        let _ = { if endHour != ends.dragged { ends.anchor = endHour } }()
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(t("schedule_editor.every_prefix")).foregroundStyle(.secondary)
                AutopilotsNumberField(value: time.interval, range: 1...time.unit.maxInterval, width: 34, autoFocus: autoFocus,
                                      accessibilityLabel: t("schedule_editor.a11y.interval")) { n in
                    var next = time
                    next.interval = n
                    onSet(next)
                }
                Picker("", selection: Binding(
                    get: { time.unit },
                    set: { unit in
                        guard unit != time.unit else { return }
                        var next = time
                        next.unit = unit
                        next.interval = intervalAnchor[unit] ?? min(time.interval, unit.maxInterval)
                        next.window = time.window.map { Schedule.clampWindow($0, unit: unit, minute: time.minute) }
                        onSet(next)
                    }
                )) {
                    Text(t("schedule_editor.unit_hours")).tag(AutopilotsSchedule.Unit.hours)
                    Text(t("schedule_editor.unit_minutes")).tag(AutopilotsSchedule.Unit.minutes)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel(t("schedule_editor.a11y.interval_unit"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(.secondary)
                AutopilotsClockField(value: window.from, hourOnly: time.unit == .minutes,
                                     hourLabel: t("schedule_editor.a11y.window_start_hour"),
                                     minuteLabel: t("schedule_editor.a11y.window_start_minute")) { v in
                    let minute = time.unit == .hours ? Schedule.timeParts(v).minute : time.minute
                    let start = Schedule.timeParts(v).hour
                    let end = max(ends.anchor ?? Schedule.timeParts(window.to).hour, start)
                    let to = "\(Schedule.pad2(end)):\(Schedule.pad2(Schedule.timeParts(window.to).minute))"
                    ends.dragged = end
                    setWindow(AutopilotsSchedule.Window(from: v, to: to), minute: minute)
                }
                Text("~").foregroundStyle(.secondary)
                AutopilotsClockField(value: window.to, hourOnly: time.unit == .minutes, hourMin: Schedule.timeParts(window.from).hour,
                                     hourLabel: t("schedule_editor.a11y.window_end_hour"),
                                     minuteLabel: t("schedule_editor.a11y.window_end_minute")) { v in
                    let minute = time.unit == .hours ? Schedule.timeParts(v).minute : time.minute
                    ends.anchor = Schedule.timeParts(v).hour
                    ends.dragged = Schedule.timeParts(v).hour
                    setWindow(AutopilotsSchedule.Window(from: window.from, to: v), minute: minute)
                }
            }
            .fixedSize()
        }
    }

    private func setWindow(_ next: AutopilotsSchedule.Window, minute: Int) {
        let clamped = Schedule.clampWindow(next, unit: time.unit, minute: minute)
        var out = time
        out.minute = minute
        out.window = Schedule.isFullDay(clamped) ? nil : clamped
        onSet(out)
    }
}

/// 24-hour HH:MM field (upstream TimeInput); `hourOnly` hides the minutes.
struct AutopilotsClockField: View {
    let value: String
    var hourOnly = false
    var hourMin = 0
    var autoFocus = false
    var hourLabel = ""
    var minuteLabel = ""
    let onChange: (String) -> Void

    var body: some View {
        let parts = AutopilotsSchedule.timeParts(value)
        HStack(spacing: 1) {
            AutopilotsNumberField(value: parts.hour, range: hourMin...23, pad: true, width: 26, autoFocus: autoFocus,
                                  bordered: false, accessibilityLabel: hourLabel) { h in
                onChange("\(AutopilotsSchedule.pad2(h)):\(AutopilotsSchedule.pad2(parts.minute))")
            }
            Text(":").foregroundStyle(.secondary)
            if hourOnly {
                Text(AutopilotsSchedule.pad2(parts.minute)).foregroundStyle(.secondary).monospacedDigit().frame(width: 20)
            } else {
                AutopilotsNumberField(value: parts.minute, range: 0...59, pad: true, width: 26, bordered: false,
                                      accessibilityLabel: minuteLabel) { m in
                    onChange("\(AutopilotsSchedule.pad2(parts.hour)):\(AutopilotsSchedule.pad2(m))")
                }
            }
        }
        .font(Theme.Font.body)
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.primary.opacity(0.15)))
        .fixedSize()
    }
}

/// Integer field whose text and value cannot drift: typing commits in-range
/// numbers, blur clamps (or snaps back when empty), ↑/↓ step and wrap.
struct AutopilotsNumberField: View {
    let value: Int
    let range: ClosedRange<Int>
    var pad = false
    var width: CGFloat = 40
    var autoFocus = false
    var bordered = true
    var accessibilityLabel = ""
    let onCommit: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .frame(width: width, height: bordered ? 24 : nil)
            .background {
                if bordered {
                    RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor))
                    RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.primary.opacity(0.15))
                }
            }
            .focused($focused)
            .accessibilityLabel(accessibilityLabel)
            .onAppear {
                text = display(value)
                if autoFocus { focused = true }
            }
            .onChange(of: value) { _, v in
                if Int(text) != v { text = display(v) }
            }
            .onChange(of: text) { _, s in
                if let n = Int(s), range.contains(n), n != value { onCommit(n) }
            }
            .onChange(of: focused) { _, f in if !f { reconcile() } }
            .onSubmit { reconcile() }
            .onKeyPress(.upArrow) { step(1); return .handled }
            .onKeyPress(.downArrow) { step(-1); return .handled }
    }

    private func display(_ n: Int) -> String { pad ? AutopilotsSchedule.pad2(n) : String(n) }

    private func reconcile() {
        guard let n = Int(text) else {
            text = display(value)
            return
        }
        let clamped = min(range.upperBound, max(range.lowerBound, n))
        text = display(clamped)
        if clamped != value { onCommit(clamped) }
    }

    private func step(_ delta: Int) {
        let typed = Int(text)
        let stepped: Int
        if let typed, !range.contains(typed) {
            stepped = min(range.upperBound, max(range.lowerBound, typed))
        } else {
            stepped = (typed ?? value) + delta
        }
        let wrapped = stepped > range.upperBound ? range.lowerBound : stepped < range.lowerBound ? range.upperBound : stepped
        text = display(wrapped)
        if wrapped != value { onCommit(wrapped) }
    }
}
