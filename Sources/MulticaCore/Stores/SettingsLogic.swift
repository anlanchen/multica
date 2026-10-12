import Foundation

/// Where a settings URL points (upstream settings-navigation.ts), including
/// legacy links server redirects still produce (`?tab=github`,
/// `?tab=integrations&connected=…`).
public struct SettingsLocation: Equatable, Sendable {
    public var tab: String
    public var section: String?
    public var integration: String?

    public init(tab: String, section: String? = nil, integration: String? = nil) {
        self.tab = tab
        self.section = section
        self.integration = integration
    }

    public static let channelIntegrations = ["lark", "slack", "dingtalk", "wecom", "telegram"]

    public static func isChannelIntegration(_ value: String?) -> Bool {
        value.map(channelIntegrations.contains) ?? false
    }

    public static func resolve(_ query: [String: String]) -> SettingsLocation {
        let tab = query["tab"] ?? "profile"
        let section = query["section"]
        let integration = query["integration"]
        switch tab {
        case "issue", "chat":
            return SettingsLocation(tab: "preferences", section: tab)
        case "labs":
            return SettingsLocation(tab: "workspace")
        case "github":
            return SettingsLocation(tab: "code", section: section)
        case "repositories":
            return SettingsLocation(tab: "code", section: section ?? "repositories")
        case "integrations":
            let composioCallback = query["connected"] != nil || query["error"] == "composio_connect_failed"
            if composioCallback || integration == "composio" { return SettingsLocation(tab: "apps") }
            if integration == "github" { return SettingsLocation(tab: "code") }
            if integration == "vcs" { return SettingsLocation(tab: "code", section: "code-hosting") }
            return SettingsLocation(tab: "channels", integration: isChannelIntegration(integration) ? integration : nil)
        default:
            if isChannelIntegration(tab) { return SettingsLocation(tab: "channels", integration: tab) }
            return SettingsLocation(tab: tab, section: section, integration: integration)
        }
    }

    /// Query for opening `tab`, keeping unrelated parameters (OAuth
    /// callbacks) and clearing page-specific ones (upstream settingsHref).
    public static func query(from current: [String: String], tab: String, section: String? = nil, integration: String? = nil) -> [String: String] {
        var q = current
        q["tab"] = tab
        q["section"] = section
        q["integration"] = integration
        return q
    }
}

/// One searchable setting (upstream settings-search.ts).
public struct SettingsSearchEntry: Hashable, Sendable {
    public var tab: String
    public var anchor: String?
    public var integration: String?
    public var title: String
    public var description: String?

    public init(tab: String, anchor: String? = nil, integration: String? = nil, title: String, description: String? = nil) {
        self.tab = tab
        self.anchor = anchor
        self.integration = integration
        self.title = title
        self.description = description
    }

    public var key: String { "\(tab)#\(anchor ?? "")#\(integration ?? "")" }
}

public struct SettingsSearchResult: Hashable, Sendable, Identifiable {
    public var entry: SettingsSearchEntry
    public var snippet: String?
    public var id: String { entry.key }
}

public enum SettingsSearch {
    static let snippetLead = 6
    static let snippetLength = 16
    static let ellipsis = "..."

    public static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Keeps the match visible in a one-line description preview.
    public static func snippet(_ description: String, needle: String) -> String {
        guard let range = description.range(of: needle, options: .caseInsensitive) else { return description }
        let at = description.distance(from: description.startIndex, to: range.lowerBound)
        if at + needle.count <= snippetLength { return description }
        let start = description.index(description.startIndex, offsetBy: max(0, at - snippetLead))
        return ellipsis + description[start...]
    }

    /// Title matches first, then description-only matches, each in index
    /// order so results read like the navigation.
    public static func search(_ entries: [SettingsSearchEntry], query: String) -> [SettingsSearchResult] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return [] }
        var titleHits: [SettingsSearchResult] = []
        var descriptionHits: [SettingsSearchResult] = []
        var seen = Set<String>()
        for entry in entries {
            guard !seen.contains(entry.key) else { continue }
            let inTitle = entry.title.lowercased().contains(needle)
            let inDescription = entry.description.map { $0.lowercased().contains(needle) } ?? false
            guard inTitle || inDescription else { continue }
            seen.insert(entry.key)
            let snippet = entry.description.map { inDescription ? self.snippet($0, needle: needle) : $0 }
            let result = SettingsSearchResult(entry: entry, snippet: snippet)
            if inTitle { titleHits.append(result) } else { descriptionHits.append(result) }
        }
        return titleHits + descriptionHits
    }

    /// Page entries (with the description of their anchor-less row folded
    /// in) followed by in-page rows, restricted to visible pages
    /// (upstream use-settings-search-index.ts).
    public static func index(pages: [(value: String, label: String)], rows: [SettingsSearchEntry]) -> [SettingsSearchEntry] {
        let visible = Set(pages.map(\.value))
        var pageDescriptions: [String: String] = [:]
        for row in rows where row.anchor == nil && row.integration == nil {
            if let d = row.description { pageDescriptions[row.tab] = d }
        }
        let pageEntries = pages.map { SettingsSearchEntry(tab: $0.value, title: $0.label, description: pageDescriptions[$0.value]) }
        return (pageEntries + rows.filter { $0.anchor != nil || $0.integration != nil }).filter { visible.contains($0.tab) }
    }
}

/// Which chords a shortcut action may use on this client (upstream
/// shortcuts/definitions.ts, macOS + desktop runtime), plus the chords the
/// native menu bar owns (⌘T new tab, ⇧⌘[ / ⇧⌘] tab switching).
public enum SettingsShortcutPolicy {
    public struct Chord: Hashable, Sendable {
        public var key: String
        public var primary: Bool
        public var control: Bool
        public var alt: Bool
        public var shift: Bool

        public init(key: String, primary: Bool = false, control: Bool = false, alt: Bool = false, shift: Bool = false) {
            self.key = key
            self.primary = primary
            self.control = control
            self.alt = alt
            self.shift = shift
        }

        var hasModifier: Bool { primary || control || alt || shift }
        var hasCommand: Bool { primary || control }
    }

    static let primaryReserved: Set<String> = [
        "W", "R", "Q", "T", ",", "A", "C", "V", "X", "Y", "Z",
        "Equals", "Plus", "Minus", "Underscore", "0",
        "1", "2", "3", "4", "5", "6", "7", "8", "9",
    ]
    static let plainGlobalReserved: Set<String> = [
        "Enter", "Space", "Tab", "Escape", "Backspace", "Delete",
        "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown",
    ]
    static let modifierKeys: Set<String> = ["Alt", "Control", "Meta", "Shift", "CapsLock", "Fn"]

    /// Upstream key names for punctuation the event layer reports literally.
    public static func canonicalKey(_ key: String) -> String {
        switch key {
        case "+": return "Plus"
        case "-": return "Minus"
        case "=": return "Equals"
        case "_": return "Underscore"
        case " ": return "Space"
        default: return key.count == 1 ? key.uppercased() : key
        }
    }

    public static func isReserved(_ chord: Chord) -> Bool {
        let key = canonicalKey(chord.key)
        if key == "F5" { return true }
        if chord.primary && primaryReserved.contains(key) { return true }
        if chord.primary && chord.shift && !chord.control && !chord.alt && (key == "[" || key == "]") { return true }
        if chord.primary && ["P", "L", "N", "D", "U"].contains(key) && (chord.control || chord.alt || chord.shift) { return true }
        if chord.primary && ["Space", "Tab", "M", "H"].contains(key) { return true }
        if chord.control && ["Up", "Down", "Left", "Right"].contains(key) { return true }
        return false
    }

    /// Product safety policy on top of reservations: editor-safe actions
    /// need ⌘/⌃, plain navigation keys stay free, Send takes Enter or ⌘Enter.
    public static func isAllowed(_ chord: Chord, isSend: Bool, allowInEditable: Bool) -> Bool {
        let key = canonicalKey(chord.key)
        guard !key.isEmpty, !modifierKeys.contains(key) else { return false }
        if isReserved(chord) { return false }
        if key == "Tab" { return false }
        if isSend {
            return chord == Chord(key: "Enter") || chord == Chord(key: "Enter", primary: true)
        }
        if allowInEditable { return chord.hasCommand }
        return chord.hasModifier || !plainGlobalReserved.contains(key)
    }
}

/// The invite-with-seat-purchase rules (upstream seat-invite-purchase.ts and
/// billing-format.ts).
public enum SettingsSeatPurchase {
    public enum CapacityFailure: Equatable, Sendable { case full, unavailable, rateLimited }

    public static func capacityFailure(_ code: String?) -> CapacityFailure? {
        switch code {
        case "seat_capacity_full": return .full
        case "seat_capacity_unavailable": return .unavailable
        case "seat_capacity_rate_limited": return .rateLimited
        default: return nil
        }
    }

    public static func canRetryInvitationAfterPurchase(_ code: String?) -> Bool {
        let f = capacityFailure(code)
        return f == .unavailable || f == .rateLimited
    }

    static func isSafeInteger(_ v: Double) -> Bool {
        v.rounded() == v && abs(v) <= 9_007_199_254_740_991
    }

    public static func isSingleSeatPreview(_ p: WorkspaceSeatPurchasePreview?) -> Bool {
        guard let p else { return false }
        return p.additionalSeats == 1 && p.resultingSeats == p.currentSeats + 1
            && isSafeInteger(p.prorationAmount) && p.prorationAmount >= 0
            && isSafeInteger(p.nextInvoiceAmount) && p.nextInvoiceAmount >= 0
    }

    public static func purchaseMatchesPreview(_ r: PurchaseWorkspaceSeatsResponse?, _ p: WorkspaceSeatPurchasePreview) -> Bool {
        guard let r else { return false }
        return r.currentSeats == p.currentSeats && r.additionalSeats == p.additionalSeats
            && r.resultingSeats == p.resultingSeats && r.currency == p.currency
    }

    public static func canRetryWithSameQuote(_ code: String?) -> Bool {
        !["seat_purchase_payment_failed", "seat_purchase_in_progress", "seat_quote_changed", "seat_capacity_changed"].contains(code ?? "")
    }

    public static func seatIsReadyForInvitation(_ summary: WorkspaceSubscriptionSummary?, preview: WorkspaceSeatPurchasePreview,
                                                submittedAt: Date, summaryFetchedAt: Date) -> Bool {
        guard summaryFetchedAt >= submittedAt, let c = summary?.seatCapacity else { return false }
        return c.purchased >= preview.resultingSeats && c.available >= 1
    }

    static let zeroDecimal: Set<String> = ["BIF", "CLP", "DJF", "GNF", "JPY", "KMF", "KRW", "MGA", "PYG", "RWF", "VND", "VUV", "XAF", "XOF", "XPF"]
    static let twoDecimalCompat: Set<String> = ["ISK", "UGX"]
    static let threeDecimal: Set<String> = ["BHD", "JOD", "KWD", "OMR", "TND"]

    /// A Stripe minor-unit amount, without guessing currency precision.
    public static func formatMinorAmount(_ amount: Double, currency: String, locale: Locale = .current) -> String? {
        guard isSafeInteger(amount), amount >= 0 else { return nil }
        let code = currency.trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { return nil }
        let digits = twoDecimalCompat.contains(code) ? 2 : zeroDecimal.contains(code) ? 0 : threeDecimal.contains(code) ? 3 : 2
        let major = amount / pow(10, Double(digits))
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = locale
        f.currencyCode = code
        if major.rounded() == major {
            f.minimumFractionDigits = 0
            f.maximumFractionDigits = 0
        } else {
            f.minimumFractionDigits = digits
            f.maximumFractionDigits = digits
        }
        return f.string(from: NSNumber(value: major))
    }
}

/// Pure helpers behind individual settings pages.
public enum SettingsRules {
    /// Server cap on the profile "About you" text.
    public static let maxProfileDescription = 2000
    /// Server cap on the child-done wakeup instruction, in UTF-8 bytes.
    public static let maxWakeupInstructionBytes = 4000
    public static let maxActiveProperties = 20
    public static let unusedQuickActionDays = 90

    /// Letters and digits only, uppercase, at most 10 characters.
    public static func normalizeIssuePrefix(_ raw: String) -> String {
        String(raw.uppercased().unicodeScalars.filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }.prefix(10).map(Character.init))
    }

    /// The first `{{...}}` template token in a quick action prompt.
    public static func quickActionTemplateToken(_ prompt: String) -> String? {
        guard let open = prompt.range(of: "{{") else { return nil }
        var i = open.upperBound
        while i < prompt.endIndex {
            if prompt[i] == "}" {
                let next = prompt.index(after: i)
                if next < prompt.endIndex, prompt[next] == "}" { return String(prompt[open.lowerBound...next]) }
                return quickActionTemplateToken(String(prompt[next...]))
            }
            i = prompt.index(after: i)
        }
        return nil
    }

    /// Usage-first ordering: active before archived, most used first, then name.
    public static func sortQuickActions(_ actions: [QuickAction]) -> [QuickAction] {
        actions.sorted { a, b in
            if a.status != b.status { return a.status == "active" }
            if a.useCount != b.useCount { return a.useCount > b.useCount }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    /// Unused long enough to flag: 90 days since last use, or since creation
    /// when never used.
    public static func isStaleQuickAction(_ action: QuickAction, now: Date = Date()) -> Bool {
        func days(_ iso: String?) -> Int? {
            guard let iso, let d = Timestamp.parse(iso) else { return nil }
            return Int(floor(now.timeIntervalSince(d) / 86_400))
        }
        if let last = days(action.lastUsedAt) { return last >= unusedQuickActionDays }
        if let age = days(action.createdAt) { return age >= unusedQuickActionDays }
        return false
    }

    /// "UTC+8", "UTC-3:30", "UTC+0" — a zone's offset at `date`.
    public static func utcOffset(_ zone: TimeZone, at date: Date = Date()) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let h = abs(seconds) / 3600
        let m = (abs(seconds) % 3600) / 60
        return m == 0 ? "UTC\(sign)\(h)" : "UTC\(sign)\(h):\(String(format: "%02d", m))"
    }

    /// The configured status PR merges move issues to ("none" when off).
    public static func prMergeStatus(settings: [String: JSONValue]) -> String {
        guard let value = settings["pr_merge_status"], !value.isNull else {
            let legacy = settings["pr_auto_complete_enabled"]
            return legacy == nil || legacy?.isNull == true || legacy?.boolValue == true ? "done" : "none"
        }
        guard let s = value.stringValue else { return "none" }
        let trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? "none" : trimmed
    }

    public static let statusCategories: [StatusCategory] = [.unstarted, .started, .done, .closed]
    static let builtInOrder: [IssueStatusKey] = [.backlog, .todo, .inProgress, .inReview, .blocked, .done, .cancelled]

    /// Accepts legacy category spellings and built-in keys.
    public static func normalizeCategory(_ raw: String) -> StatusCategory? {
        switch raw {
        case "completed": return .done
        case "canceled": return .closed
        case "unstarted", "started", "done", "closed": return StatusCategory(rawValue: raw)
        default: return IssueStatusKey(rawValue: raw).builtInCategory
        }
    }

    /// Catalog order: category, position, built-ins first, built-in order, key.
    public static func compareStatuses(_ a: IssueStatusEntry, _ b: IssueStatusEntry) -> Bool {
        func rank(_ e: IssueStatusEntry) -> Int {
            normalizeCategory(e.category.rawValue).flatMap { statusCategories.firstIndex(of: $0) } ?? statusCategories.count
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        if a.position != b.position { return a.position < b.position }
        if a.isSystem != b.isSystem { return a.isSystem }
        if a.isSystem && b.isSystem {
            let ra = builtInOrder.firstIndex(of: a.key) ?? builtInOrder.count
            let rb = builtInOrder.firstIndex(of: b.key) ?? builtInOrder.count
            if ra != rb { return ra < rb }
        }
        return a.key.rawValue < b.key.rawValue
    }

    /// Members matching a search on name or email.
    public static func filterMembers(_ members: [MemberWithUserRecord], query: String) -> [MemberWithUserRecord] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return members }
        return members.filter { $0.name.lowercased().contains(needle) || $0.email.lowercased().contains(needle) }
    }
}
