import Foundation

/// The structured schedule behind the autopilot schedule editor (upstream
/// `autopilots/components/schedule-editor`): the model, its two-way mapping to
/// the robfig/cron v3 5-field grammar the server parses, the plain-language
/// readback, and the state transitions the controls apply.
public enum AutopilotsSchedule {
    public enum Unit: String, Sendable, Hashable, CaseIterable {
        case hours, minutes

        public var maxInterval: Int { self == .hours ? 23 : 59 }
    }

    public struct Window: Sendable, Hashable {
        public var from: String
        public var to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// "Every N hours/minutes". For hours the window's from-minute is the firing
    /// minute; minute windows are hour-granular. `minute` is carried (unused)
    /// for minute patterns so toggling the unit keeps the user's minute.
    public struct Every: Sendable, Hashable {
        public var interval: Int
        public var unit: Unit
        public var window: Window?
        public var minute: Int

        public init(interval: Int = 1, unit: Unit = .hours, window: Window? = nil, minute: Int = 0) {
            self.interval = interval
            self.unit = unit
            self.window = window
            self.minute = minute
        }
    }

    public enum TimePattern: Sendable, Hashable {
        case at(String)
        case every(Every)

        public var isAt: Bool {
            if case .at = self { return true }
            return false
        }
    }

    public enum DayPattern: Sendable, Hashable {
        case every
        /// 0=Sun … 6=Sat, non-empty, deduped, ascending.
        case weekly([Int])
        /// 1-31.
        case monthly(Int)

        public var kind: String {
            switch self {
            case .every: return "every"
            case .weekly: return "weekly"
            case .monthly: return "monthly"
            }
        }
    }

    public struct Config: Sendable, Hashable {
        public var time: TimePattern
        public var days: DayPattern
        /// IANA zone.
        public var timezone: String
        /// Non-nil when the expression exceeds the structured model: the editor
        /// is advanced-only and this exact string round-trips verbatim.
        public var raw: String?

        public init(time: TimePattern, days: DayPattern, timezone: String, raw: String? = nil) {
            self.time = time
            self.days = days
            self.timezone = timezone
            self.raw = raw
        }
    }

    public static func defaultConfig(timezone: String) -> Config {
        Config(time: .at("09:00"), days: .every, timezone: timezone, raw: nil)
    }

    /// Position is the cron day-of-week number.
    public static let dayKeys = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// The maximal runs of consecutive days in a set: [1,2,3,4,5] → 1–5,
    /// [0,1,2,4] → 0–2 and 4–4.
    public static func consecutiveRuns(_ days: [Int]) -> [(Int, Int)] {
        let sorted = Array(Set(days)).sorted()
        var runs: [(Int, Int)] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1] == sorted[j] + 1 { j += 1 }
            runs.append((sorted[i], sorted[j]))
            i = j + 1
        }
        return runs
    }

    public static func pad2(_ n: Int) -> String {
        n < 10 && n >= 0 ? "0\(n)" : String(n)
    }

    public static func timeParts(_ time: String) -> (hour: Int, minute: Int) {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        func leadingInt(_ s: Substring?) -> Int {
            guard let s else { return 0 }
            let digits = s.prefix { ("0"..."9").contains($0) }
            return Int(digits) ?? 0
        }
        return (leadingInt(parts.first), leadingInt(parts.count > 1 ? parts[1] : nil))
    }
}

// MARK: - Cron mapping

extension AutopilotsSchedule {
    private struct Bounds {
        let min: Int
        let max: Int
        var names: [String: Int]? = nil
    }

    private static let dowNames = ["SUN": 0, "MON": 1, "TUE": 2, "WED": 3, "THU": 4, "FRI": 5, "SAT": 6]
    private static let monthNames = ["JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
                                     "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12]
    private static let minuteBounds = Bounds(min: 0, max: 59)
    private static let hourBounds = Bounds(min: 0, max: 23)
    private static let domBounds = Bounds(min: 1, max: 31)
    private static let monthBounds = Bounds(min: 1, max: 12, names: monthNames)
    private static let dowBounds = Bounds(min: 0, max: 6, names: dowNames)

    /// One part of a field as robfig's getRange reads it. `wildcard` records the
    /// text ("*"), not robfig's star bit; `stepped` that a step was written;
    /// `explicitRange` that both ends were written.
    private struct RangePart {
        var lo: Int
        var hi: Int
        var step: Int
        var wildcard: Bool
        var stepped: Bool
        var explicitRange: Bool
    }

    private static let maxSafeInteger = 9_007_199_254_740_991

    private static func isDigits(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { ("0"..."9").contains($0) }
    }

    /// A digit string as a JS safe integer, or nil past 2^53-1.
    private static func safeInt(_ s: Substring) -> Int? {
        let trimmed = s.drop { $0 == "0" }
        if trimmed.isEmpty { return 0 }
        guard trimmed.count <= 16, let n = Int(trimmed), n <= maxSafeInteger else { return nil }
        return n
    }

    private static func fieldValue(_ s: Substring, _ b: Bounds) -> Int? {
        if let named = b.names?[s.uppercased()] { return named }
        guard isDigits(s), let n = safeInt(s), n >= b.min, n <= b.max else { return nil }
        return n
    }

    /// `<range>` or `<range>/<step>`, where `<range>` is `*`, a value, or
    /// `lo-hi`. A bare value carrying a step runs to the field's max; the step
    /// itself is unbounded, as in robfig.
    private static func parseRangePart(_ part: Substring, _ b: Bounds) -> RangePart? {
        let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let rangeStr = pieces.first, !rangeStr.isEmpty else { return nil }
        var step = 1
        let stepped = pieces.count == 2
        if stepped {
            let stepStr = pieces[1]
            guard isDigits(stepStr), let s = safeInt(stepStr), s >= 1 else { return nil }
            step = s
        }
        if rangeStr == "*" {
            return RangePart(lo: b.min, hi: b.max, step: step, wildcard: true, stepped: stepped, explicitRange: false)
        }
        let ends = rangeStr.split(separator: "-", omittingEmptySubsequences: false)
        guard ends.count <= 2, let loStr = ends.first, !loStr.isEmpty, let lo = fieldValue(loStr, b) else { return nil }
        let hi: Int
        if ends.count == 2 {
            guard let h = fieldValue(ends[1], b) else { return nil }
            hi = h
        } else {
            hi = stepped ? b.max : lo
        }
        guard hi >= lo else { return nil }
        return RangePart(lo: lo, hi: hi, step: step, wildcard: false, stepped: stepped, explicitRange: ends.count == 2)
    }

    /// The whole field as one pinned value ("9"), not "9-9" or "*/100".
    private static func plainValue(_ field: String, _ b: Bounds) -> Int? {
        guard let r = parseRangePart(Substring(field), b), !r.wildcard, !r.stepped, !r.explicitRange else { return nil }
        return r.lo
    }

    private static func expandDow(_ field: String) -> [Int]? {
        var days = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            guard let r = parseRangePart(part, dowBounds) else { return nil }
            for d in stride(from: r.lo, through: r.hi, by: r.step) { days.insert(d) }
        }
        guard !days.isEmpty else { return nil }
        return days.sorted()
    }

    /// [1,2,3,4,5] → "1-5", [0,1,2,4] → "0-2,4"; any pair is worth a range.
    private static func dowField(fromDays days: [Int]) -> String {
        consecutiveRuns(days).map { $0.1 > $0.0 ? "\($0.0)-\($0.1)" : "\($0.0)" }.joined(separator: ",")
    }

    private static func parseHourPattern(_ field: String) -> (interval: Int, range: (lo: Int, hi: Int)?)? {
        guard let r = parseRangePart(Substring(field), hourBounds), r.step <= hourBounds.max else { return nil }
        let spansDay = r.wildcard || (r.lo == hourBounds.min && r.hi == hourBounds.max)
        return (r.step, spansDay ? nil : (r.lo, r.hi))
    }

    /// `*` → 1, `*/N` and `0/N` → N; anchored steps ("15/5") stay advanced.
    private static func parseMinuteInterval(_ field: String) -> Int? {
        guard let r = parseRangePart(Substring(field), minuteBounds), !r.explicitRange, r.step <= minuteBounds.max else { return nil }
        guard r.lo == minuteBounds.min, r.stepped || r.wildcard else { return nil }
        return r.step
    }

    private static func parseTimeFields(_ minuteField: String, _ hourField: String) -> TimePattern? {
        if let plainMinute = plainValue(minuteField, minuteBounds) {
            if let plainHour = plainValue(hourField, hourBounds) {
                return .at("\(pad2(plainHour)):\(pad2(plainMinute))")
            }
            guard let hour = parseHourPattern(hourField) else { return nil }
            let window = hour.range.map {
                Window(from: "\(pad2($0.lo)):\(pad2(plainMinute))", to: "\(pad2($0.hi)):\(pad2(plainMinute))")
            }
            return .every(Every(interval: hour.interval, unit: .hours, window: window, minute: plainMinute))
        }
        guard let interval = parseMinuteInterval(minuteField), let hour = parseHourPattern(hourField) else { return nil }
        let window: Window?
        if let range = hour.range {
            let selectsOneHour = hour.interval > range.hi - range.lo
            if !selectsOneHour && hour.interval != 1 { return nil }
            window = Window(from: "\(pad2(range.lo)):00", to: "\(pad2(selectsOneHour ? range.lo : range.hi)):59")
        } else {
            if hour.interval != 1 { return nil }
            window = nil
        }
        return .every(Every(interval: interval, unit: .minutes, window: window, minute: 0))
    }

    /// Drops empty list elements, rewrites wildcard low ends, and reads numbers
    /// the way strconv.Atoi does ("009", "+9").
    private static func normalizeField(_ field: String) -> String {
        field.split(separator: ",", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map { normalizeNumbers(normalizeRange($0)) }
            .joined(separator: ",")
    }

    /// robfig tests a range's low end for "*"/"?" and takes the full span,
    /// never reading what followed the "-"; the step survives.
    private static func normalizeRange(_ part: Substring) -> String {
        let slash = part.firstIndex(of: "/")
        let range = slash.map { part[..<$0] } ?? part
        let step = slash.map { String(part[$0...]) } ?? ""
        let low = range.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return low == "*" || low == "?" ? "*\(step)" : String(part)
    }

    /// Replaces every `\+?\d+` run with its safe-integer value.
    private static func normalizeNumbers(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let startsNumber = ("0"..."9").contains(c) || (c == "+" && i + 1 < chars.count && ("0"..."9").contains(chars[i + 1]))
            guard startsNumber else {
                out.append(c)
                i += 1
                continue
            }
            var j = c == "+" ? i + 1 : i
            while j < chars.count && ("0"..."9").contains(chars[j]) { j += 1 }
            let digits = Substring(String(chars[(c == "+" ? i + 1 : i)..<j]))
            if let n = safeInt(digits) {
                out += String(n)
            } else {
                out += String(chars[i..<j])
            }
            i = j
        }
        return out
    }

    /// A step wider than its range selects only the range's first value. The
    /// hour (`rangeSlot`) keeps every range its parser can still read exactly.
    private static func collapseDegenerateRange(_ field: String, _ b: Bounds, rangeSlot: Bool) -> String {
        field.split(separator: ",", omittingEmptySubsequences: false).map { part -> String in
            guard let r = parseRangePart(part, b) else { return String(part) }
            if rangeSlot && !r.stepped { return String(part) }
            if rangeSlot && r.explicitRange && r.step <= b.max { return String(part) }
            return r.step > r.hi - r.lo ? String(r.lo) : String(part)
        }.joined(separator: ",")
    }

    /// A list carrying a step-1 wildcard part is "*" — only when every part parses.
    private static func collapseWildcardList(_ field: String, _ b: Bounds) -> String {
        let parts = field.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return field }
        let ranges = parts.map { parseRangePart($0, b) }
        guard !ranges.contains(where: { $0 == nil }) else { return field }
        return ranges.contains { $0!.wildcard && $0!.step == 1 } ? "*" : field
    }

    /// The two prefixes robfig's Parse reads a timezone from.
    public static func hasTimezonePrefix(_ s: String) -> Bool {
        s.hasPrefix("TZ=") || s.hasPrefix("CRON_TZ=")
    }

    /// robfig's `TZ=` / `CRON_TZ=` prefix, read case-sensitively up to the first
    /// literal space. Nil when there is no prefix, when robfig would panic (no
    /// space) or read a second prefix as a field, and for a zone the picker
    /// cannot offer.
    public static func extractTimezonePrefix(_ expr: String) -> (timezone: String, rest: String)? {
        guard hasTimezonePrefix(expr), let space = expr.firstIndex(of: " "), let eq = expr.firstIndex(of: "=") else { return nil }
        let name = String(expr[expr.index(after: eq)..<space])
        let rest = String(expr[space...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty, !hasTimezonePrefix(rest) else { return nil }
        guard let timezone = canonicalZone(name.isEmpty ? "UTC" : name) else { return nil }
        return (timezone, rest)
    }

    /// The zone as the picker's list spells it, or nil when this platform does
    /// not know it.
    public static func canonicalZone(_ tz: String) -> String? {
        if tz.caseInsensitiveCompare("UTC") == .orderedSame { return "UTC" }
        guard !tz.isEmpty, !tz.contains(where: { $0.isWhitespace }) else { return nil }
        let known = knownZones
        if known.contains(tz) { return tz }
        return known.first { $0.caseInsensitiveCompare(tz) == .orderedSame }
    }

    private static let knownZones = TimeZone.knownTimeZoneIdentifiers

    public static func parseCron(_ expr: String, timezone: String) -> Config {
        let prefix = extractTimezonePrefix(expr)
        let tz = prefix?.timezone ?? timezone
        let body = prefix?.rest ?? expr
        var advanced = defaultConfig(timezone: tz)
        advanced.raw = body
        let parts = body.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count == 5 else { return advanced }
        let normalized = parts.map(normalizeField)
        let minuteField = collapseDegenerateRange(collapseWildcardList(normalized[0], minuteBounds), minuteBounds, rangeSlot: false)
        let hourField = collapseDegenerateRange(collapseWildcardList(normalized[1], hourBounds), hourBounds, rangeSlot: true)
        let domField = collapseDegenerateRange(collapseWildcardList(normalized[2], domBounds), domBounds, rangeSlot: false)
        let monthField = collapseWildcardList(normalized[3], monthBounds)
        let dowField = collapseWildcardList(normalized[4], dowBounds)

        guard monthField == "*" else { return advanced }
        let days: DayPattern
        if domField == "*" {
            if dowField == "*" {
                days = .every
            } else {
                guard let set = expandDow(dowField) else { return advanced }
                days = .weekly(set)
            }
        } else {
            guard dowField == "*", let dom = plainValue(domField, domBounds) else { return advanced }
            days = .monthly(dom)
        }
        guard let time = parseTimeFields(minuteField, hourField) else { return advanced }
        return Config(time: time, days: days, timezone: tz, raw: nil)
    }

    /// The wire expression: the timezone rides in the cron string as a `TZ=`
    /// prefix, except on a raw that already carries one, on whitespace-padded
    /// or empty text, and on a zone that cannot be embedded.
    public static func toCron(_ config: Config) -> String {
        let fields = cronFields(config)
        if hasTimezonePrefix(fields) { return fields }
        if fields.isEmpty || fields != fields.trimmingCharacters(in: .whitespacesAndNewlines) { return fields }
        if config.timezone.isEmpty || config.timezone.contains(" ") { return fields }
        return "TZ=\(config.timezone) \(fields)"
    }

    /// The five fields alone; advanced expressions round-trip verbatim.
    public static func cronFields(_ config: Config) -> String {
        if let raw = config.raw { return raw }
        var dom = "*"
        var dow = "*"
        switch config.days {
        case .monthly(let d): dom = String(d)
        case .weekly(let set): dow = set.isEmpty ? "1" : dowField(fromDays: set)
        case .every: break
        }
        let minuteField: String
        let hourField: String
        switch config.time {
        case .at(let t):
            let at = timeParts(t)
            minuteField = String(at.minute)
            hourField = String(at.hour)
        case .every(let e) where e.unit == .hours:
            if let w = e.window {
                let from = timeParts(w.from)
                let to = timeParts(w.to)
                minuteField = String(from.minute)
                hourField = e.interval == 1 ? "\(from.hour)-\(to.hour)" : "\(from.hour)-\(to.hour)/\(e.interval)"
            } else {
                minuteField = String(e.minute)
                hourField = e.interval == 1 ? "*" : "*/\(e.interval)"
            }
        case .every(let e):
            minuteField = e.interval == 1 ? "*" : "*/\(e.interval)"
            if let w = e.window {
                let from = timeParts(w.from)
                let to = timeParts(w.to)
                hourField = from.hour == to.hour ? String(from.hour) : "\(from.hour)-\(to.hour)"
            } else {
                hourField = "*"
            }
        }
        return "\(minuteField) \(hourField) \(dom) * \(dow)"
    }
}

// MARK: - Describe

extension AutopilotsSchedule {
    /// Plain-language readback ("At 09:00 · Mon–Fri"); nil in advanced mode.
    public static func describe(_ config: Config, l10n: L10n = .shared) -> String? {
        guard config.raw == nil else { return nil }
        func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
            l10n.t("autopilots", "schedule_editor.describe.\(key)", args)
        }
        var clauses: [String] = []
        switch config.time {
        case .at(let time):
            clauses.append(t("time_at", ["time": time]))
        case .every(let e) where e.unit == .hours:
            if let w = e.window {
                clauses.append(e.interval == 1 ? t("time_every_hour_window") : t("time_every_hours_window", ["interval": e.interval]))
                clauses.append(t("window", ["from": w.from, "to": w.to]))
            } else {
                let minute = pad2(e.minute)
                clauses.append(e.interval == 1 ? t("time_every_hour", ["minute": minute]) : t("time_every_hours", ["interval": e.interval, "minute": minute]))
            }
        case .every(let e):
            clauses.append(e.interval == 1 ? t("time_every_minute") : t("time_every_minutes", ["interval": e.interval]))
            if let w = e.window { clauses.append(t("window", ["from": w.from, "to": w.to])) }
        }
        switch config.days {
        case .every:
            clauses.append(t("days_every"))
        case .weekly(let set):
            let name = { (d: Int) in t("days_long.\(dayKeys[d])") }
            var parts: [String] = []
            for (lo, hi) in consecutiveRuns(set) where (0...6).contains(lo) && (0...6).contains(hi) {
                if hi - lo >= 2 {
                    parts.append(t("days_range", ["from": name(lo), "to": name(hi)]))
                } else {
                    for d in lo...hi { parts.append(name(d)) }
                }
            }
            clauses.append(parts.joined(separator: t("days_join")))
        case .monthly(let day):
            clauses.append(t("days_monthly", ["day": day]))
        }
        return clauses.joined(separator: " · ")
    }

    /// "1d 2h 3m" / "2h 3m" / "3m" / "<1m" until `target`.
    public static func countdown(to target: Date, now: Date, l10n: L10n = .shared) -> String {
        let diff = target.timeIntervalSince(now)
        func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
            l10n.t("autopilots", "schedule_editor.countdown.\(key)", args)
        }
        if diff < 60 { return t("less_than_minute") }
        let minutes = Int(diff / 60)
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return t("days_hours", ["days": days, "hours": hours % 24, "minutes": minutes % 60]) }
        if hours > 0 { return t("hours_minutes", ["hours": hours, "minutes": minutes % 60]) }
        return t("minutes", ["minutes": minutes])
    }
}

// MARK: - Transitions

extension AutopilotsSchedule {
    /// A window spans the day when its hours run 0–23; minutes have no say.
    public static func isFullDay(_ window: Window) -> Bool {
        timeParts(window.from).hour == 0 && timeParts(window.to).hour == 23
    }

    /// The bounds the window fields show; all day renders as the day's bounds.
    public static func displayWindow(_ time: Every) -> Window {
        if let w = time.window { return w }
        return time.unit == .hours
            ? Window(from: "00:\(pad2(time.minute))", to: "23:\(pad2(time.minute))")
            : Window(from: "00:00", to: "23:59")
    }

    /// The last hour:minute the user expressed: hour from the window, minute
    /// from `minute`; nil for an all-day interval.
    public static func timeAnchor(of time: TimePattern) -> String? {
        switch time {
        case .at(let t): return t
        case .every(let e):
            guard let w = e.window else { return nil }
            return "\(pad2(timeParts(w.from).hour)):\(pad2(e.minute))"
        }
    }

    public static func defaultAtTime(_ prev: TimePattern, anchor: String) -> String {
        if let a = timeAnchor(of: prev) { return a }
        var minute = 0
        if case .every(let e) = prev { minute = e.minute }
        return "\(pad2(timeParts(anchor).hour)):\(pad2(minute))"
    }

    /// Switching to an interval restores the remembered step, unit and window,
    /// rebased on the fixed time being left when that still leaves a window.
    public static func defaultEveryTime(_ prev: TimePattern, anchor: Every?) -> Every {
        guard case .at(let at) = prev else {
            if case .every(let e) = prev { return e }
            return Every()
        }
        let (hour, minute) = timeParts(at)
        var time = anchor ?? Every(interval: 1, unit: .hours, window: nil, minute: minute)
        time.minute = minute
        guard let window = time.window else { return time }
        let rebased = hour < timeParts(window.to).hour
            ? Window(from: "\(pad2(hour)):\(pad2(minute))", to: window.to)
            : window
        let clamped = clampWindow(rebased, unit: time.unit, minute: minute)
        time.window = isFullDay(clamped) ? nil : clamped
        return time
    }

    /// Canonical bounds: `minute` is the firing minute, minute windows are
    /// hour-granular, and `to` is never earlier than `from`.
    public static func clampWindow(_ window: Window, unit: Unit, minute: Int) -> Window {
        let from = timeParts(window.from)
        let to = timeParts(window.to)
        let edgeMinute = unit == .hours ? minute : 0
        let endMinute = unit == .hours ? minute : 59
        let endHour = max(to.hour, from.hour)
        return Window(from: "\(pad2(from.hour)):\(pad2(edgeMinute))", to: "\(pad2(endHour)):\(pad2(endMinute))")
    }

    /// Toggles a weekday; the last remaining day cannot be removed.
    public static func toggleDay(_ days: [Int], _ day: Int) -> [Int] {
        if days.contains(day) {
            if days.count == 1 { return days }
            return days.filter { $0 != day }
        }
        return (days + [day]).sorted()
    }
}

// MARK: - Timezones

extension AutopilotsSchedule {
    /// Curated fallback list (upstream COMMON_TIMEZONES).
    public static let commonTimezones = [
        "UTC", "America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York",
        "America/Sao_Paulo", "Europe/London", "Europe/Berlin", "Europe/Paris", "Europe/Moscow",
        "Africa/Cairo", "Asia/Dubai", "Asia/Kolkata", "Asia/Bangkok", "Asia/Shanghai",
        "Asia/Singapore", "Asia/Tokyo", "Australia/Sydney", "Pacific/Auckland",
    ]

    public static func localTimezone() -> String {
        let id = TimeZone.current.identifier
        return id.isEmpty ? "UTC" : id
    }

    /// [current, local, common…, every known zone], deduped in order.
    public static func timezoneOptions(current: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tz in [current, localTimezone()] + commonTimezones + knownZones where !tz.isEmpty && seen.insert(tz).inserted {
            out.append(tz)
        }
        return out
    }

    /// "Shanghai" for "Asia/Shanghai".
    public static func cityLabel(_ tz: String) -> String {
        if tz == "UTC" { return "UTC" }
        return (tz.split(separator: "/").last.map(String.init) ?? tz).replacingOccurrences(of: "_", with: " ")
    }

    /// "GMT+8" style offset for the zone right now.
    public static func offsetLabel(_ tz: String, at date: Date = Date()) -> String {
        guard let zone = TimeZone(identifier: tz) else { return "" }
        let seconds = zone.secondsFromGMT(for: date)
        if seconds == 0 { return "GMT" }
        let sign = seconds < 0 ? "-" : "+"
        let h = abs(seconds) / 3600
        let m = (abs(seconds) % 3600) / 60
        return m == 0 ? "GMT\(sign)\(h)" : "GMT\(sign)\(h):\(pad2(m))"
    }
}

// MARK: - Server validation

extension AutopilotsSchedule {
    /// The server's rejection of a schedule: which input is at fault, and the
    /// parser's own words.
    public struct Rejection: Sendable, Hashable {
        public enum Code: String, Sendable { case invalidCron = "invalid_cron", invalidTimezone = "invalid_timezone" }
        public var code: Code
        public var detail: String

        public init(code: Code, detail: String) {
            self.code = code
            self.detail = detail
        }
    }

    /// Anything but an explicit invalid_timezone tag is the cron's fault.
    public static func classifyRejection(_ error: APIError) -> Rejection {
        Rejection(code: error.code == "invalid_timezone" ? .invalidTimezone : .invalidCron, detail: error.message)
    }

    /// Asks the server whether it accepts the schedule. Only a 400 is a
    /// rejection; transport failures must not block a save.
    public static func findRejection(api: APIClient, config: Config) async -> Rejection? {
        do {
            _ = try await api.cronPreview(expr: toCron(config), tz: config.timezone)
            return nil
        } catch let error as APIError where error.status == 400 {
            return classifyRejection(error)
        } catch {
            return nil
        }
    }
}
