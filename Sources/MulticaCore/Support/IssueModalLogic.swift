import Foundation

/// Payload of the run-confirm dialog (upstream RunConfirmIntent + batch use).
public struct IssueModalRunIntent: Sendable, Hashable {
    public enum Mode: String, Sendable { case assign, promote }

    public var issueIDs: [String]
    public var mode: Mode
    /// promote only: the status key the issue moves to.
    public var status: String?
    public var assigneeType: String
    public var assigneeID: String
    public var assigneeName: String?

    public init(issueIDs: [String], mode: Mode, status: String? = nil, assigneeType: String, assigneeID: String, assigneeName: String? = nil) {
        self.issueIDs = issueIDs
        self.mode = mode
        self.status = status
        self.assigneeType = assigneeType
        self.assigneeID = assigneeID
        self.assigneeName = assigneeName
    }
}

/// Which issue writes hand work to an agent and need confirming
/// (upstream issues/actions/run-confirm-gate.ts).
public enum IssueModalRunGate {
    private static let knownCategories: Set<StatusCategory> = [.unstarted, .started, .done, .closed]

    /// The category a status key belongs to, or nil when nothing can answer
    /// (an unknown custom key stays unresolved so callers fail safe).
    public static func category(statusKey: String, carried: StatusCategory?, catalog: StatusCatalog?) -> StatusCategory? {
        if let carried, knownCategories.contains(carried) { return carried }
        if let builtIn = IssueStatusKey(rawValue: statusKey).builtInCategory { return builtIn }
        return catalog?.entry(for: IssueStatusKey(rawValue: statusKey))?.category
    }

    public static func intent(
        issueID: String, status: String, statusCategory: StatusCategory?, assignee: ActorRef?,
        newAssignee: ActorRef?, newStatus: String?, catalog: StatusCatalog?
    ) -> IssueModalRunIntent? {
        let issueCategory = category(statusKey: status, carried: statusCategory, catalog: catalog)
        let parked = status == "backlog"
        if let a = newAssignee, a.type == "agent" || a.type == "squad", !a.id.isEmpty, !parked {
            return IssueModalRunIntent(issueIDs: [issueID], mode: .assign, assigneeType: a.type, assigneeID: a.id)
        }
        if let target = newStatus, target != status, parked || issueCategory == nil,
           let owner = assignee, owner.type == "agent" || owner.type == "squad", !owner.id.isEmpty {
            let targetCategory = category(statusKey: target, carried: nil, catalog: catalog)
            if target != "backlog", targetCategory == nil || (targetCategory != .done && targetCategory != .closed) {
                return IssueModalRunIntent(issueIDs: [issueID], mode: .promote, status: target, assigneeType: owner.type, assigneeID: owner.id)
            }
        }
        return nil
    }
}

/// Daemon CLI version gate for agent-mode create (upstream runtimes/cli-version.ts).
public enum IssueModalCLIVersion {
    public static let minQuickCreate = "0.2.21"
    public static let minQuickCreateFields = "0.4.3"

    public enum State: Sendable, Equatable { case ok, tooOld, missing }

    public struct Check: Sendable, Equatable {
        public var state: State
        public var current: String
        public var min: String
    }

    /// Reads `\d+.\d+.\d+` starting at `i`; returns the numbers and the end.
    private static func triple(_ c: [Character], at start: Int) -> ([Int], Int)? {
        var i = start
        var parts: [Int] = []
        for n in 0..<3 {
            var digits = ""
            while i < c.count, c[i].isASCII, c[i].isNumber { digits.append(c[i]); i += 1 }
            guard let v = Int(digits) else { return nil }
            parts.append(v)
            if n < 2 {
                guard i < c.count, c[i] == "." else { return nil }
                i += 1
            }
        }
        return (parts, i)
    }

    /// First `v?X.Y.Z` anywhere in the string (upstream SEMVER_RE).
    static func parse(_ raw: String) -> [Int]? {
        let c = Array(raw.trimmingCharacters(in: .whitespaces))
        for i in c.indices where c[i].isASCII && c[i].isNumber {
            if let (v, _) = triple(c, at: i) { return v }
        }
        return nil
    }

    /// `git describe` output past a tag, e.g. `v0.2.15-235-gdaf0e935`.
    static func isDevDescribe(_ s: String) -> Bool {
        let c = Array(s)
        var i = c.first == "v" ? 1 : 0
        guard let (_, end) = triple(c, at: i) else { return false }
        i = end
        guard i < c.count, c[i] == "-" else { return false }
        i += 1
        let digitsStart = i
        while i < c.count, c[i].isASCII, c[i].isNumber { i += 1 }
        guard i > digitsStart, i + 1 < c.count, c[i] == "-", c[i + 1] == "g" else { return false }
        i += 2
        return i < c.count && c[i].isHexDigit
    }

    public static func check(_ detected: String?, minimum: String) -> Check {
        let current = (detected ?? "").trimmingCharacters(in: .whitespaces)
        if isDevDescribe(current) {
            return Check(state: .ok, current: current, min: minimum)
        }
        guard !current.isEmpty, let v = parse(current), v.count == 3, let m = parse(minimum) else {
            return Check(state: .missing, current: current, min: minimum)
        }
        return Check(state: v.lexicographicallyPrecedes(m) ? .tooOld : .ok, current: current, min: minimum)
    }

    public static func runtimeCLIVersion(_ metadata: [String: JSONValue]?) -> String {
        if case .string(let s)? = metadata?["cli_version"] { return s }
        return ""
    }
}

/// The one recovery state every issue/quota-limit surface shows (upstream
/// billing/recovery.ts). Cloud's action set is authoritative.
public enum IssueModalBillingRecovery: String, Sendable {
    case billingDisabled, checkout, portal, billing, contactAdmin, checking, billingUnavailable

    public static func resolve(actions: JSONValue?, billingEnabled: Bool, loading: Bool, portalFailed: Bool) -> IssueModalBillingRecovery {
        if !billingEnabled { return .billingDisabled }
        if portalFailed { return .billingUnavailable }
        let present = actions.map { !$0.isNull } ?? false
        func flag(_ k: String) -> Bool { actions?[k]?.boolValue == true }
        if flag("checkout") { return .checkout }
        if flag("portal") { return .portal }
        if flag("purchaseSeats") { return .billing }
        if present { return .contactAdmin }
        if loading { return .checking }
        return .billingUnavailable
    }
}

/// Sub-issue stage options (upstream stage-picker.tsx).
public enum IssueModalStage {
    public static func maxSibling(_ stages: [Int?]) -> Int {
        stages.reduce(0) { m, s in s.map { max(m, $0) } ?? m }
    }

    public static func options(stage: Int?, maxStage: Int) -> [Int] {
        let top = max(stage ?? 0, maxStage, 2) + 1
        return Array(1...top)
    }
}

public enum IssueModalAttachments {
    public static func downloadPath(_ id: String) -> String { "/api/attachments/\(id)/download" }

    private static func references(_ content: String, _ url: String?) -> Bool {
        guard let url, !url.isEmpty else { return false }
        if content.contains(url) { return true }
        let stable = String(url.split(whereSeparator: { $0 == "?" || $0 == "#" }).first ?? "")
        return !stable.isEmpty && content.contains(stable)
    }

    /// Upstream contentReferencesAttachment: the stable download path or any
    /// of the attachment's URLs appears in the Markdown.
    public static func contentReferences(_ content: String, id: String, url: String?, downloadURL: String?, markdownURL: String?) -> Bool {
        guard !content.isEmpty else { return false }
        if content.contains(downloadPath(id)) { return true }
        return references(content, url) || references(content, downloadURL) || references(content, markdownURL)
    }

    /// Appends a block to a Markdown body with one blank line between.
    public static func appendMarkdown(_ existing: String, _ markdown: String) -> String {
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return markdown }
        var base = existing
        while let last = base.last, last.isWhitespace { base.removeLast() }
        return base + "\n\n" + markdown
    }
}

/// `actor` / `multi_actor` custom property values (upstream types/property.ts).
public enum IssueModalActorRefs {
    public static let maxValues = 20
    public static let knownKinds: Set<String> = ["member"]

    /// Raw reference strings in stored order, including unknown kinds.
    public static func rawValues(_ value: JSONValue?) -> [String] {
        switch value {
        case .string(let s)?: return s.isEmpty ? [] : [s]
        case .array(let a)?: return a.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        default: return []
        }
    }

    public static func parse(_ raw: String) -> ActorRef? {
        guard let sep = raw.firstIndex(of: ":"), sep != raw.startIndex else { return nil }
        let kind = String(raw[..<sep])
        let id = String(raw[raw.index(after: sep)...])
        guard !id.isEmpty, knownKinds.contains(kind) else { return nil }
        return ActorRef(type: kind, id: id)
    }

    public static func refs(_ value: JSONValue?) -> [ActorRef] {
        rawValues(value).compactMap(parse)
    }

    public static func hasUnknown(_ value: JSONValue?) -> Bool {
        rawValues(value).count != refs(value).count
    }

    public static func format(kind: String, id: String) -> String { "\(kind):\(id)" }

    /// Toggles one key in a multi_actor list, keeping insertion order and
    /// unknown entries; nil clears the property.
    public static func toggle(_ current: [String], key: String) -> [String]? {
        if current.contains(key) {
            let next = current.filter { $0 != key }
            return next.isEmpty ? nil : next
        }
        if current.count >= maxValues { return current }
        return current + [key]
    }
}

/// Who may hand work to an agent (upstream permissions/rules.ts
/// canAssignAgentToIssue + agents/runtime-binding.ts).
public enum IssueModalAgentAccess {
    public static func isRuntimeBound(_ a: AgentRecord) -> Bool {
        a.runtimeBound != false && !a.runtimeId.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// nil when allowed, otherwise the upstream denial message.
    public static func denial(_ a: AgentRecord, userID: String?, role: String?) -> String? {
        guard let userID else { return "Sign in to assign agents." }
        if let owner = a.ownerId, owner == userID { return nil }
        if a.permissionMode == "private" { return "Personal agent — only the owner can assign work." }
        let validRole = ["owner", "admin", "member"].contains(role ?? "")
        if a.invocationTargets.contains(where: { $0.targetType == "workspace" }) {
            return validRole ? nil : "Join this workspace to assign agents."
        }
        if a.invocationTargets.contains(where: { $0.targetType == "member" && $0.targetId == userID }) { return nil }
        return "Restricted agent — you don't have access to assign work to it."
    }
}

/// Color for a label created inline from a picker: stable per name
/// (upstream pickInlineColor, a 31-multiplier hash over UTF-16 units).
public enum IssueModalLabelColor {
    public static let palette = ["#ef4444", "#f97316", "#eab308", "#22c55e", "#14b8a6",
                                 "#3b82f6", "#6366f1", "#a855f7", "#ec4899", "#64748b"]

    public static func pick(_ name: String) -> String {
        var hash: UInt32 = 0
        for unit in name.utf16 { hash = hash &* 31 &+ UInt32(unit) }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

public enum IssueModalDuplicates {
    /// A duplicate is a cancelled issue that remembers its original.
    public static func isDuplicate(status: String, duplicateOfID: String?) -> Bool {
        status == "cancelled" && !(duplicateOfID ?? "").isEmpty
    }
}

/// Splits a sentence whose interpolated values are fenced with `\u{0}` into
/// plain and emphasised runs (upstream run-confirm boldFenced).
public enum IssueModalFence {
    public static let mark = "\u{0}"

    public static func fenced(_ value: String) -> String { mark + value + mark }

    public static func runs(_ text: String) -> [(text: String, bold: Bool)] {
        let parts = text.components(separatedBy: mark)
        guard parts.count >= 3 else { return [(text, false)] }
        return parts.enumerated().compactMap { i, p in p.isEmpty ? nil : (p, i % 2 == 1) }
    }
}
