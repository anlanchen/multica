import Foundation

/// Upstream `packages/core/projects/config.ts`.
public enum ProjectsConfig {
    public static let statusOrder = ["planned", "in_progress", "paused", "completed", "cancelled"]
    public static let priorityOrder = ["urgent", "high", "medium", "low", "none"]

    /// Total orders for header sorting (projects-page.tsx).
    static let statusRank: [String: Int] = ["planned": 0, "in_progress": 1, "paused": 2, "completed": 3, "cancelled": 4]
    static let priorityRank: [String: Int] = ["urgent": 4, "high": 3, "medium": 2, "low": 1, "none": 0]
}

/// Upstream `getProjectIssueMetrics` plus the derived progress numbers the
/// list, cards and detail sidebar render.
public struct ProjectsIssueMetrics: Equatable, Sendable {
    public var totalCount: Int
    public var completedCount: Int

    public init(totalCount: Int, completedCount: Int) {
        self.totalCount = totalCount
        self.completedCount = completedCount
    }

    public init(_ project: Project) {
        self.init(totalCount: project.issueCount, completedCount: project.doneCount)
    }

    public var fraction: Double { totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0 }
    /// `Math.round(done / total * 100)`.
    public var percent: Int { totalCount > 0 ? Int((fraction * 100).rounded(.toNearestOrAwayFromZero)) : 0 }
    /// Projects without issues sort below every project with issues.
    public var sortKey: Double { totalCount > 0 ? fraction : -1 }
}

/// A partial project update: applied locally for the optimistic write and
/// sent as-is, so clearing a field sends an explicit `null`.
public struct ProjectsPatch: Equatable, Sendable {
    public var title: String?
    public var description: String??
    public var icon: String?
    public var status: String?
    public var priority: String?
    /// `.some(nil)` clears the lead.
    public var lead: ActorRef??
    public var startDate: String??
    public var dueDate: String??

    public init(title: String? = nil, description: String?? = nil, icon: String? = nil, status: String? = nil,
                priority: String? = nil, lead: ActorRef?? = nil, startDate: String?? = nil, dueDate: String?? = nil) {
        self.title = title
        self.description = description
        self.icon = icon
        self.status = status
        self.priority = priority
        self.lead = lead
        self.startDate = startDate
        self.dueDate = dueDate
    }

    public var body: [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        if let title { o["title"] = .string(title) }
        if let description { o["description"] = JSONValue(description) }
        if let icon { o["icon"] = .string(icon) }
        if let status { o["status"] = .string(status) }
        if let priority { o["priority"] = .string(priority) }
        if let lead {
            o["lead_type"] = JSONValue(lead?.type)
            o["lead_id"] = JSONValue(lead?.id)
        }
        if let startDate { o["start_date"] = JSONValue(startDate) }
        if let dueDate { o["due_date"] = JSONValue(dueDate) }
        return o
    }

    public func applied(to p: Project) -> Project {
        var p = p
        if let title { p.title = title }
        if let description { p.description = description }
        if let icon { p.icon = icon }
        if let status { p.status = status }
        if let priority { p.priority = priority }
        if let lead {
            p.leadType = lead?.type
            p.leadId = lead?.id
        }
        if let startDate { p.startDate = startDate }
        if let dueDate { p.dueDate = dueDate }
        return p
    }
}

// MARK: - View state (upstream useProjectViewStore)

public enum ProjectsViewMode: String, Codable, Sendable, CaseIterable {
    case compact, comfortable
}

public enum ProjectsSortDirection: String, Codable, Sendable {
    case asc, desc

    public var toggled: ProjectsSortDirection { self == .asc ? .desc : .asc }
}

public enum ProjectsSortField: String, Codable, Sendable, CaseIterable {
    case name, priority, status, progress, created

    public var defaultDirection: ProjectsSortDirection {
        switch self {
        case .name, .status: return .asc
        case .priority, .progress, .created: return .desc
        }
    }
}

public enum ProjectsColumn: String, Codable, Sendable, CaseIterable {
    case priority, progress, lead, issues, created
}

public struct ProjectsFilters: Codable, Equatable, Sendable {
    public var statuses: [String] = []
    public var priorities: [String] = []
    /// Composite `type:id` lead refs.
    public var leads: [String] = []

    public init(statuses: [String] = [], priorities: [String] = [], leads: [String] = []) {
        self.statuses = statuses
        self.priorities = priorities
        self.leads = leads
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statuses = (try? c.decodeIfPresent([String].self, forKey: .statuses)) ?? []
        priorities = (try? c.decodeIfPresent([String].self, forKey: .priorities)) ?? []
        leads = (try? c.decodeIfPresent([String].self, forKey: .leads)) ?? []
    }

    /// One per active dimension, not per value.
    public var activeCount: Int {
        (statuses.isEmpty ? 0 : 1) + (priorities.isEmpty ? 0 : 1) + (leads.isEmpty ? 0 : 1)
    }
}

/// Persisted per workspace, like upstream `multica_projects_view:<slug>`.
public struct ProjectsViewState: Codable, Equatable, Sendable {
    public var viewMode: ProjectsViewMode = .compact
    public var sortField: ProjectsSortField = .created
    public var sortDirection: ProjectsSortDirection = ProjectsSortField.created.defaultDirection
    /// Issues count is opt-in.
    public var hiddenColumns: [ProjectsColumn] = [.issues]
    public var filters = ProjectsFilters()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProjectsViewState()
        viewMode = (try? c.decodeIfPresent(ProjectsViewMode.self, forKey: .viewMode)) ?? d.viewMode
        sortField = (try? c.decodeIfPresent(ProjectsSortField.self, forKey: .sortField)) ?? d.sortField
        sortDirection = (try? c.decodeIfPresent(ProjectsSortDirection.self, forKey: .sortDirection)) ?? d.sortDirection
        hiddenColumns = (try? c.decodeIfPresent([String].self, forKey: .hiddenColumns))
            .map { $0.compactMap(ProjectsColumn.init(rawValue:)) } ?? d.hiddenColumns
        filters = (try? c.decodeIfPresent(ProjectsFilters.self, forKey: .filters)) ?? d.filters
    }

    public func isVisible(_ column: ProjectsColumn) -> Bool { !hiddenColumns.contains(column) }

    /// Header click: flips direction on the active field, otherwise switches
    /// to the field with its default direction.
    public mutating func toggleSort(_ field: ProjectsSortField) {
        if sortField == field {
            sortDirection = sortDirection.toggled
        } else {
            sortField = field
            sortDirection = field.defaultDirection
        }
    }

    /// Display-menu select: switches field, never toggles.
    public mutating func setSortField(_ field: ProjectsSortField) {
        guard sortField != field else { return }
        sortField = field
        sortDirection = field.defaultDirection
    }

    public mutating func toggleColumn(_ column: ProjectsColumn) {
        if let i = hiddenColumns.firstIndex(of: column) {
            hiddenColumns.remove(at: i)
        } else {
            hiddenColumns.append(column)
        }
    }

    public mutating func toggleFilter(_ key: WritableKeyPath<ProjectsFilters, [String]>, _ value: String) {
        if let i = filters[keyPath: key].firstIndex(of: value) {
            filters[keyPath: key].remove(at: i)
        } else {
            filters[keyPath: key].append(value)
        }
    }

    public mutating func clearFilters() { filters = ProjectsFilters() }
}

// MARK: - List filtering and sorting (projects-page.tsx)

public enum ProjectsListQuery {
    /// Composite `type:id` so one filter list holds member and agent leads.
    public static func leadValue(_ p: Project) -> String? {
        guard let t = p.leadType, !t.isEmpty, let id = p.leadId, !id.isEmpty else { return nil }
        return "\(t):\(id)"
    }

    public struct LeadOption: Equatable, Sendable, Identifiable {
        public var type: String
        public var id: String
        public var count: Int
        public var value: String { "\(type):\(id)" }
    }

    /// Lead options in first-seen order, counted over the full set so toggling
    /// one dimension never makes the others vanish.
    public static func leadOptions(_ projects: [Project]) -> [LeadOption] {
        var out: [LeadOption] = []
        var index: [String: Int] = [:]
        for p in projects {
            guard let v = leadValue(p), let t = p.leadType, let id = p.leadId else { continue }
            if let i = index[v] {
                out[i].count += 1
            } else {
                index[v] = out.count
                out.append(LeadOption(type: t, id: id, count: 1))
            }
        }
        return out
    }

    public static func matches(_ p: Project, search: String, filters: ProjectsFilters,
                               pinyin: (String, String) -> Bool = ProjectsPinyin.matches) -> Bool {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty && !p.title.lowercased().contains(q) && !pinyin(p.title, q) { return false }
        if !filters.statuses.isEmpty && !filters.statuses.contains(p.status) { return false }
        if !filters.priorities.isEmpty && !filters.priorities.contains(p.priority) { return false }
        if !filters.leads.isEmpty {
            guard let v = leadValue(p), filters.leads.contains(v) else { return false }
        }
        return true
    }

    public static func visible(_ projects: [Project], search: String, filters: ProjectsFilters,
                               sortField: ProjectsSortField, direction: ProjectsSortDirection,
                               pinyin: (String, String) -> Bool = ProjectsPinyin.matches) -> [Project] {
        let filtered = projects.filter { matches($0, search: search, filters: filters, pinyin: pinyin) }
        return sorted(filtered, by: sortField, direction: direction)
    }

    public static func sorted(_ projects: [Project], by field: ProjectsSortField, direction: ProjectsSortDirection) -> [Project] {
        let dir = direction == .asc ? 1 : -1
        func titleOrder(_ a: Project, _ b: Project) -> Int { order(a.title.localizedCompare(b.title)) }
        func compare(_ a: Project, _ b: Project) -> Int {
            switch field {
            case .name:
                return titleOrder(a, b) * dir
            case .priority:
                let d = (ProjectsConfig.priorityRank[a.priority] ?? 0) - (ProjectsConfig.priorityRank[b.priority] ?? 0)
                return d != 0 ? d.signum() * dir : titleOrder(a, b)
            case .status:
                let d = (ProjectsConfig.statusRank[a.status] ?? 0) - (ProjectsConfig.statusRank[b.status] ?? 0)
                return d != 0 ? d.signum() * dir : titleOrder(a, b)
            case .progress:
                let d = ProjectsIssueMetrics(a).sortKey - ProjectsIssueMetrics(b).sortKey
                return d != 0 ? (d > 0 ? 1 : -1) * dir : titleOrder(a, b)
            case .created:
                let ta = Timestamp.parse(a.createdAt)?.timeIntervalSince1970 ?? 0
                let tb = Timestamp.parse(b.createdAt)?.timeIntervalSince1970 ?? 0
                return ta == tb ? 0 : (ta > tb ? 1 : -1) * dir
            }
        }
        return projects.sorted { compare($0, $1) < 0 }
    }

    static func order(_ r: ComparisonResult) -> Int {
        switch r {
        case .orderedAscending: return -1
        case .orderedSame: return 0
        case .orderedDescending: return 1
        }
    }
}

/// Upstream `useFormatRelativeDate`: Today / 1d ago / {{n}}d ago / {{n}}mo ago.
public enum ProjectsRelativeDate: Equatable, Sendable {
    case today
    case oneDay
    case days(Int)
    case months(Int)

    public static func of(_ timestamp: String, now: Date = Date()) -> ProjectsRelativeDate {
        guard let date = Timestamp.parse(timestamp) else { return .today }
        let days = Int((now.timeIntervalSince(date) / 86_400).rounded(.down))
        if days < 1 { return .today }
        if days == 1 { return .oneDay }
        if days < 30 { return .days(days) }
        return .months(days / 30)
    }
}

// MARK: - Git refs and GitHub URLs (core/github/repo-ref.ts, views/common/github-url.ts)

public enum ProjectsGitRef {
    public static let maxLength = 255

    public enum Invalid: Equatable, Sendable {
        case tooLong, invalidCharacters, invalidFormat
    }

    /// Shape-only check mirroring the user-facing subset of
    /// `git check-ref-format`. Empty means "use the default branch" and is valid.
    public static func validate(_ ref: String) -> Invalid? {
        let value = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if value.utf16.count > maxLength { return .tooLong }
        let reserved: Set<Unicode.Scalar> = ["~", "^", ":", "?", "*", "[", "\\"]
        for s in value.unicodeScalars where s.value <= 0x20 || s.value == 0x7f || reserved.contains(s) {
            return .invalidCharacters
        }
        if value.contains("..") || value.contains("@{") || value == "@"
            || value.hasPrefix("/") || value.hasSuffix("/") || value.contains("//")
            || value.hasPrefix(".") || value.hasSuffix(".") || value.hasSuffix(".lock")
            || value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.hasPrefix(".") || $0.hasSuffix(".lock") }) {
            return .invalidFormat
        }
        return nil
    }

    /// A full-length object id (SHA-1 or SHA-256) — the one shape that can
    /// only be a commit.
    public static func looksLikeCommitSha(_ value: String) -> Bool {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count == 40 || t.count == 64 else { return false }
        return t.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) }
    }

    /// Upstream `githubRefHasError`: what the branch field refuses to submit.
    public static func hasError(_ value: String) -> Bool {
        validate(value) != nil || looksLikeCommitSha(value)
    }

    /// Splits a pasted `.../tree/<branch>` browse URL into clone URL + ref.
    public static func splitGithubURL(_ input: String) -> (url: String, ref: String?) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = value as NSString
        guard let m = ProjectsRegexes.shared.browse.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)),
              m.range(at: 1).location != NSNotFound, m.range(at: 2).location != NSNotFound else {
            return (value, nil)
        }
        let clone = ns.substring(with: m.range(at: 1))
        var ref = ns.substring(with: m.range(at: 2))
        while ref.hasSuffix("/") { ref.removeLast() }
        guard !ref.isEmpty, validate(ref) == nil else { return (value, nil) }
        return (clone, ref)
    }

    /// `owner/repo` for GitHub URLs (https, ssh, scp shorthand); anything else
    /// is returned unchanged.
    public static func githubShortLabel(_ url: String) -> String {
        let ns = url as NSString
        if let m = ProjectsRegexes.shared.scp.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)) {
            return midTruncate("\(ns.substring(with: m.range(at: 1)))/\(ns.substring(with: m.range(at: 2)))")
        }
        guard let u = URL(string: url), let host = u.host?.lowercased(), host == "github.com" || host == "www.github.com" else {
            return url
        }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return url }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        return midTruncate("\(parts[0])/\(repo)")
    }

    /// Keeps both ends visible: repos sharing a long prefix differ at the tail.
    public static func midTruncate(_ s: String, maxLen: Int = 40) -> String {
        guard s.count > maxLen else { return s }
        let tail = (maxLen - 1) / 2
        let head = maxLen - 1 - tail
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
    }
}

private final class ProjectsRegexes: @unchecked Sendable {
    static let shared = ProjectsRegexes()
    let browse = try! NSRegularExpression(
        pattern: #"^(https?://(?:www\.)?github\.com/[^/\s]+/[^/\s]+?)(?:\.git)?/tree/(.+)$"#,
        options: [.caseInsensitive])
    let scp = try! NSRegularExpression(pattern: #"^(?:[^@/]+@)?github\.com:([^/]+)/([^/]+?)(?:\.git)?$"#)
}

// MARK: - Project resources

public enum ProjectsExecutionMode: String, Sendable, CaseIterable {
    case inPlace = "in_place"
    case worktree
}

/// Why the worktree option is unavailable (local-directory-mode-dialog.tsx).
public enum ProjectsWorktreeBlocker: Equatable, Sendable {
    case notGit
    case serverOutdated

    /// `isGitRepo == nil` means "could not check" and stays permissive.
    public static func reason(isGitRepo: Bool?, serverValidates: Bool) -> ProjectsWorktreeBlocker? {
        if isGitRepo == false { return .notGit }
        if !serverValidates { return .serverOutdated }
        return nil
    }
}

public struct ProjectsGithubRef: Equatable, Sendable {
    public var url: String
    public var ref: String?
}

public struct ProjectsLocalRef: Equatable, Sendable {
    public var localPath: String
    public var daemonID: String
    public var label: String?
    public var executionModeRaw: String?

    /// Absent or unknown modes read as in-place, matching the server.
    public var executionMode: ProjectsExecutionMode { executionModeRaw == "worktree" ? .worktree : .inPlace }
}

extension ProjectResource {
    public var projectsGithubRef: ProjectsGithubRef? {
        guard resourceType == "github_repo" else { return nil }
        return ProjectsGithubRef(url: resourceRef["url"]?.stringValue ?? "", ref: resourceRef["ref"]?.stringValue)
    }

    public var projectsLocalRef: ProjectsLocalRef? {
        guard resourceType == "local_directory" else { return nil }
        return ProjectsLocalRef(
            localPath: resourceRef["local_path"]?.stringValue ?? "",
            daemonID: resourceRef["daemon_id"]?.stringValue ?? "",
            label: resourceRef["label"]?.stringValue,
            executionModeRaw: resourceRef["execution_mode"]?.stringValue)
    }

    /// Upstream `localDirectoryLabel`: the label column outranks the legacy
    /// copy inside the ref; the path is the last resort.
    public var projectsLocalDirectoryLabel: String {
        let ref = projectsLocalRef
        let path = ref?.localPath ?? ""
        let candidates = [label ?? "", ref?.label ?? "", path]
        let first = candidates.first { !$0.isEmpty } ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? path.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }
}

public enum ProjectsResourceRefs {
    /// An absent ref is how "use the default branch" looks on the wire.
    public static func github(url: String, ref: String?) -> JSONValue {
        var o: [String: JSONValue] = ["url": .string(url)]
        if let ref, !ref.isEmpty { o["ref"] = .string(ref) }
        return .object(o)
    }

    public static func localDirectory(localPath: String, daemonID: String, label: String?, mode: ProjectsExecutionMode) -> JSONValue {
        var o: [String: JSONValue] = [
            "local_path": .string(localPath),
            "daemon_id": .string(daemonID),
            "execution_mode": .string(mode.rawValue),
        ]
        if let label, !label.isEmpty { o["label"] = .string(label) }
        return .object(o)
    }

    /// The server replaces the whole ref, so edits keep every other field;
    /// `nil` drops the key.
    public static func setting(_ ref: JSONValue, _ key: String, _ value: String?) -> JSONValue {
        var o: [String: JSONValue] = [:]
        if case .object(let existing) = ref { o = existing }
        if let value { o[key] = .string(value) } else { o[key] = nil }
        return .object(o)
    }

    /// Upstream `runtimeAdvertisesLocalWorktree`: judged by the daemon's most
    /// recently seen runtime row, positive signal only.
    public static func runtimeAdvertisesLocalWorktree(_ runtimes: [RuntimeDeviceRecord], daemonID: String?) -> Bool {
        guard let daemonID, !daemonID.isEmpty else { return false }
        var newest: RuntimeDeviceRecord?
        for rt in runtimes where rt.daemonId == daemonID {
            guard let current = newest else { newest = rt; continue }
            if (rt.lastSeenAt ?? "") > (current.lastSeenAt ?? "") { newest = rt }
        }
        guard case .array(let caps)? = newest?.metadata["capabilities"] else { return false }
        return caps.contains(.string("local-worktree-v1"))
    }

    /// Create-project preselection: worktree only for a git repo on a machine
    /// that advertised it; never submit a mode the picker would block.
    public static func effectiveMode(chosen: ProjectsExecutionMode?, isGitRepo: Bool?, advertises: Bool,
                                     blocker: ProjectsWorktreeBlocker?) -> ProjectsExecutionMode {
        if blocker != nil { return .inPlace }
        if let chosen { return chosen }
        return isGitRepo == true && advertises ? .worktree : .inPlace
    }
}

/// The desktop shell's `local-directory:validate` (apps/desktop/src/main/local-directory.ts).
public enum ProjectsLocalDirectory {
    public enum Failure: Equatable, Sendable {
        case notAbsolute, notFound, notADirectory, notReadable, notWritable
        case error(String)
    }

    public enum Validation: Equatable, Sendable {
        case ok(isGitRepo: Bool)
        case failed(Failure)
    }

    public static func validate(_ path: String, fileManager: FileManager = .default) -> Validation {
        guard !path.isEmpty, path.hasPrefix("/") else { return .failed(.notAbsolute) }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else { return .failed(.notFound) }
        guard isDir.boolValue else { return .failed(.notADirectory) }
        guard fileManager.isReadableFile(atPath: path) else { return .failed(.notReadable) }
        guard fileManager.isWritableFile(atPath: path) else { return .failed(.notWritable) }
        return .ok(isGitRepo: isInsideGitWorkTree(path, fileManager: fileManager))
    }

    /// Walks up looking for `.git` (a directory, or a file in linked worktrees).
    public static func isInsideGitWorkTree(_ path: String, fileManager: FileManager = .default) -> Bool {
        var current = URL(fileURLWithPath: path).standardizedFileURL
        while true {
            if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) { return true }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return false }
            current = parent
        }
    }
}

// MARK: - Pinyin search (views/editor/extensions/pinyin-match.ts)

public enum ProjectsPinyin {
    /// Full-pinyin prefix, initials prefix, or a left-to-right mix of both.
    /// Only names containing CJK ideographs are considered.
    public static func matches(_ name: String, _ query: String) -> Bool {
        if query.isEmpty { return true }
        guard name.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }),
              let syllables = syllables(of: name) else { return false }
        return matches(syllables: syllables, query: query.lowercased())
    }

    public static func matches(syllables: [String], query: String) -> Bool {
        if syllables.joined().hasPrefix(query) { return true }
        if syllables.map({ $0.first.map(String.init) ?? "" }).joined().hasPrefix(query) { return true }
        return hybrid(Array(syllables.map { Array($0) }), 0, Array(query), 0)
    }

    private static func hybrid(_ arr: [[Character]], _ ai: Int, _ q: [Character], _ qi: Int) -> Bool {
        if qi >= q.count { return true }
        if ai >= arr.count { return false }
        let syllable = arr[ai]
        var len = syllable.count
        while len >= 1 {
            if qi + len <= q.count && Array(q[qi..<(qi + len)]) == Array(syllable[0..<len]),
               hybrid(arr, ai + 1, q, qi + len) {
                return true
            }
            len -= 1
        }
        return false
    }

    /// Toneless pinyin per character (ü → v), lowercased.
    public static func syllables(of name: String) -> [String]? {
        #if canImport(Darwin)
        guard let latin = name.applyingTransform(.mandarinToLatin, reverse: false) else { return nil }
        let v = latin.map { "üǖǘǚǜÜǕǗǙǛ".contains($0) ? "v" : String($0) }.joined()
        let plain = v.applyingTransform(.stripDiacritics, reverse: false) ?? v
        return plain.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        #else
        return nil
        #endif
    }
}
