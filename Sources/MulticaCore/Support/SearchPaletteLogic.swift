import Foundation

/// Query highlighting (upstream search/highlight-text.tsx): the whole query
/// and, for multi-word queries, each word, matched case-insensitively.
public enum SearchPaletteHighlight {
    public struct Segment: Equatable, Sendable {
        public var text: String
        public var highlight: Bool
        public init(_ text: String, _ highlight: Bool) {
            self.text = text
            self.highlight = highlight
        }
    }

    public static func segments(_ text: String, query: String) -> [Segment] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !text.isEmpty else { return [Segment(text, false)] }
        var patterns = [q]
        let terms = q.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if terms.count > 1 {
            for t in terms where !patterns.contains(t) { patterns.append(t) }
        }
        var out: [Segment] = []
        var plainStart = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            var matched: Range<String.Index>?
            for p in patterns {
                if let r = text.range(of: p, options: [.caseInsensitive, .anchored], range: i..<text.endIndex) {
                    matched = r
                    break
                }
            }
            if let r = matched, !r.isEmpty {
                if plainStart < r.lowerBound { out.append(Segment(String(text[plainStart..<r.lowerBound]), false)) }
                out.append(Segment(String(text[r]), true))
                i = r.upperBound
                plainStart = i
            } else {
                i = text.index(after: i)
            }
        }
        if plainStart < text.endIndex { out.append(Segment(String(text[plainStart...]), false)) }
        return out.isEmpty ? [Segment(text, false)] : out
    }
}

/// Cross-type cancelled demotion for aggregated results (upstream
/// search/cancelled-rank.ts, MUL-5824).
public enum SearchPaletteRank {
    /// The issue number a query targets: `MUL-123`, `V2-12` or a bare `123`.
    public static func queryNumber(_ query: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dash = q.lastIndex(of: "-") {
            let prefix = q[..<dash]
            let digits = q[q.index(after: dash)...]
            if let first = prefix.first, first.isASCII, first.isLetter,
               prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
               !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
               let n = Int(digits), n > 0 {
                return n
            }
        }
        if !q.isEmpty, q.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(q), n > 0 { return n }
        return nil
    }

    static func isExactTitle(_ title: String?, _ query: String) -> Bool {
        guard let title else { return false }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == q.lowercased()
    }

    public static func isIssueDirectHit(title: String?, number: Int?, identifier: String?, query: String) -> Bool {
        if let target = queryNumber(query) {
            let n = number ?? identifier.flatMap(queryNumber)
            if n == target { return true }
        }
        if let identifier,
           identifier.trimmingCharacters(in: .whitespaces).lowercased() == query.trimmingCharacters(in: .whitespaces).lowercased() {
            return true
        }
        return isExactTitle(title, query)
    }

    public static func isProjectDirectHit(title: String?, query: String) -> Bool {
        isExactTitle(title, query)
    }

    /// Stable partition: relative order inside each side is preserved.
    public static func partition<T>(_ items: [T], demote: (T) -> Bool) -> (live: [T], cancelled: [T]) {
        var live: [T] = []
        var cancelled: [T] = []
        for item in items {
            if demote(item) { cancelled.append(item) } else { live.append(item) }
        }
        return (live, cancelled)
    }
}

/// Row matching for the palette's pages, commands and members.
public enum SearchPaletteMatch {
    /// Visible labels match anywhere; invisible keywords only by prefix.
    public static func row(label: String, keywords: [String], query: String) -> Bool {
        label.lowercased().contains(query) || keywords.contains { $0.hasPrefix(query) }
    }

    public static func member(name: String, email: String, role: String, query: String) -> Bool {
        name.lowercased().contains(query) || email.lowercased().contains(query)
            || (query.count >= 3 && role.hasPrefix(query))
    }

    /// "mem", "peo", "use", "tea" list every member.
    public static func wantsAllMembers(_ query: String) -> Bool {
        query.count >= 3 && ["members", "people", "users", "team"].contains { $0.hasPrefix(query) }
    }

    /// Pinyin matching on per-character syllables: full prefix, initials, or
    /// a left-to-right mix of syllable prefixes (upstream pinyin-match.ts).
    public static func pinyin(syllables: [String], query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        if syllables.joined().hasPrefix(q) { return true }
        if syllables.map({ String($0.prefix(1)) }).joined().hasPrefix(q) { return true }
        let qc = Array(q)
        let arr = syllables.map { Array($0) }
        func match(_ ai: Int, _ qi: Int) -> Bool {
            if qi >= qc.count { return true }
            if ai >= arr.count { return false }
            let s = arr[ai]
            var len = s.count
            while len >= 1 {
                if qi + len <= qc.count, Array(qc[qi..<(qi + len)]) == Array(s[0..<len]), match(ai + 1, qi + len) { return true }
                len -= 1
            }
            return false
        }
        return match(0, 0)
    }
}

/// Invisible synonyms per sidebar page (upstream PAGE_KEYWORDS).
public enum SearchPalettePages {
    /// Upstream WORKSPACE_PAGES registry order.
    public static let order: [WorkspacePage] = [.inbox, .chat, .myIssues, .issues, .projects, .autopilots,
                                                .agents, .squads, .usage, .runtimes, .skills, .settings]

    public static func keywords(_ page: WorkspacePage) -> [String] {
        switch page {
        case .inbox: return ["inbox", "notifications", "收件箱", "通知"]
        case .chat: return ["chat", "messages", "conversation", "聊天", "消息", "对话"]
        case .myIssues: return ["my", "issues", "assigned", "mine", "我的", "任务"]
        case .issues: return ["issues", "tasks", "bugs", "任务"]
        case .projects: return ["projects", "kanban", "项目"]
        case .autopilots: return ["autopilot", "autopilots", "automation", "schedule", "cron", "webhook", "自动化", "定时"]
        case .agents: return ["agents", "bots", "ai", "智能体"]
        case .squads: return ["squads", "teams", "小队", "团队"]
        case .usage: return ["usage", "analytics", "stats", "metrics", "统计", "分析", "用量"]
        case .runtimes: return ["runtimes", "environments", "machines", "运行时"]
        case .skills: return ["skills", "library", "技能"]
        case .settings: return ["settings", "config", "preferences", "设置", "配置"]
        }
    }

    /// Recently visited issue ids, newest first, from a workspace's browsing
    /// history (the native counterpart of upstream recent-issues-store).
    public static func recentIssueIDs(_ history: [TabLocation], limit: Int = 20) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for loc in history {
            guard case .issue(let id) = loc.route, seen.insert(id).inserted else { continue }
            out.append(id)
            if out.count == limit { break }
        }
        return out
    }
}
