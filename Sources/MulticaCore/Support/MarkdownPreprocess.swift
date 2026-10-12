import Foundation

/// Upstream `preprocessMarkdown` (packages/views/editor/utils/preprocess.ts
/// and packages/ui/markdown): the text rewrites every product surface
/// applies before rendering. Code spans, fenced code and math are never
/// rewritten; existing Markdown links are left alone.
public enum MarkdownPreprocess {
    public static func apply(_ markdown: String, autolinkIssueIdentifiers: Bool = true) -> String {
        guard !markdown.isEmpty else { return "" }
        var s = stripChannelMediaMarkers(markdown)
        s = mentionShortcodes(s)
        if autolinkIssueIdentifiers { s = issueIdentifiers(s) }
        return links(s)
    }

    private final class Patterns: @unchecked Sendable {
        let fenced = try! NSRegularExpression(pattern: "```[\\s\\S]*?```")
        let displayMath = try! NSRegularExpression(pattern: "\\$\\$[\\s\\S]*?\\$\\$")
        let inlineMath = try! NSRegularExpression(pattern: "(?<!\\$)\\$(?!\\$)([^$\\n]+)\\$(?!\\$)")
        let inlineCode = try! NSRegularExpression(pattern: "(?<!`)`(?!`)([^`\\n]+)`(?!`)")
        let identifier = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_-])([A-Z][A-Z0-9]*-\\d+)(?![A-Za-z0-9_-])")
        let identifierPretest = try! NSRegularExpression(pattern: "[A-Z][A-Z0-9]*-\\d")
        let shortcode = try! NSRegularExpression(pattern: "\\[@\\s+([^\\]]*)\\]")
        let attribute = try! NSRegularExpression(pattern: "(\\w+)=\"([^\"]*)\"")
        let channelMedia = try! NSRegularExpression(pattern: "<!-- multica:channel-media:[0-9a-fA-F-]{36} -->")
        let url = try! NSRegularExpression(pattern: "(?:https?://|www\\.)[^\\s<>\"'`\\]]+", options: [.caseInsensitive])
        let email = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}(?![A-Za-z0-9])")
    }

    private static let p = Patterns()

    /// Upstream `ISSUE_IDENTIFIER_PATTERN`.
    public static func isIssueIdentifier(_ s: String) -> Bool {
        guard let dash = s.firstIndex(of: "-"), dash != s.startIndex else { return false }
        let prefix = s[..<dash], number = s[s.index(after: dash)...]
        guard let first = prefix.unicodeScalars.first, ("A"..."Z").contains(first), !number.isEmpty else { return false }
        return prefix.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
            && number.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    public static func stripChannelMediaMarkers(_ s: String) -> String {
        guard s.contains("<!-- multica:channel-media:") else { return s }
        let ns = s as NSString
        return p.channelMedia.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    /// `[@ id="…" label="…"]` → `[@label](mention://member/id)`.
    public static func mentionShortcodes(_ s: String) -> String {
        guard s.contains("[@ ") || s.contains("[@\t") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in p.shortcode.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let attrs = ns.substring(with: m.range(at: 1))
            let ans = attrs as NSString
            var dict: [String: String] = [:]
            for a in p.attribute.matches(in: attrs, range: NSRange(location: 0, length: ans.length)) {
                dict[ans.substring(with: a.range(at: 1))] = ans.substring(with: a.range(at: 2))
            }
            guard let id = dict["id"], let label = dict["label"], !id.isEmpty, !label.isEmpty else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += "[@\(label)](mention://member/\(id))"
            last = m.range.location + m.range.length
        }
        guard last > 0 else { return s }
        return out + ns.substring(from: last)
    }

    /// Bare `MUL-123` → `[MUL-123](mention://issue/MUL-123)`.
    public static func issueIdentifiers(_ s: String) -> String {
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard p.identifierPretest.firstMatch(in: s, range: full) != nil else { return s }
        let units = Array(s.utf16)
        let code = codeRanges(s)
        let linkRanges = markdownLinkRanges(units)
        let detected = detectLinks(s)
        var out = ""
        var last = 0
        for m in p.identifier.matches(in: s, range: full) {
            let r = m.range(at: 1)
            let start = r.location, end = r.location + r.length
            if inside(start, code) { continue }
            if linkRanges.contains(where: { overlaps($0, start..<end) }) { continue }
            if detected.contains(where: { overlaps($0.range, start..<end) }) { continue }
            let after: UInt16? = end < units.count ? units[end] : nil
            let afterNext: UInt16? = end + 1 < units.count ? units[end + 1] : nil
            let before: UInt16? = start > 0 ? units[start - 1] : nil
            if after == 0x2E, let n = afterNext, isAlnum(n) { continue }
            if after == 0x2F || before == 0x2F || before == 0x2E { continue }
            let id = ns.substring(with: r)
            out += ns.substring(with: NSRange(location: last, length: start - last))
            out += "[\(id)](mention://issue/\(id))"
            last = end
        }
        guard last > 0 else { return s }
        return out + ns.substring(from: last)
    }

    /// Bare URLs and emails → Markdown links (upstream `preprocessLinks`).
    public static func links(_ s: String) -> String {
        guard s.contains("http") || s.contains("www.") || s.contains("WWW.") || s.contains("@") else { return s }
        let found = detectLinks(s)
        guard !found.isEmpty else { return s }
        let ns = s as NSString
        let units = Array(s.utf16)
        let code = codeRanges(s)
        let linkRanges = markdownLinkRanges(units)
        var out = ""
        var last = 0
        for link in found {
            if inside(link.range.lowerBound, code) { continue }
            if linkRanges.contains(where: { overlaps($0, link.range) }) { continue }
            if alreadyLinked(units, link.range) { continue }
            out += ns.substring(with: NSRange(location: last, length: link.range.lowerBound - last))
            out += "[\(link.text)](\(link.url))"
            last = link.range.upperBound
        }
        guard last > 0 else { return s }
        return out + ns.substring(from: last)
    }

    // MARK: Detection

    struct Link {
        var text: String
        var url: String
        var range: Range<Int>
    }

    static func detectLinks(_ s: String) -> [Link] {
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [Link] = []
        for m in p.url.matches(in: s, range: full) {
            var text = ns.substring(with: m.range)
            if let cjk = text.unicodeScalars.firstIndex(where: isCJKTerminator) {
                text = String(text.unicodeScalars[..<cjk])
            }
            text = trimURL(text)
            guard text.count > 4 else { continue }
            let lower = text.lowercased()
            let url = lower.hasPrefix("www.") ? "https://" + text : text
            out.append(Link(text: text, url: url, range: m.range.location..<(m.range.location + (text as NSString).length)))
        }
        for m in p.email.matches(in: s, range: full) {
            let r = m.range.location..<(m.range.location + m.range.length)
            if out.contains(where: { overlaps($0.range, r) }) { continue }
            let text = ns.substring(with: m.range)
            out.append(Link(text: text, url: "mailto:" + text, range: r))
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Drops trailing punctuation, unbalanced closing parens and Markdown
    /// delimiter runs (`**url**` keeps its closing `**` outside the link).
    private static func trimURL(_ raw: String) -> String {
        var t = Substring(raw)
        while let c = t.last {
            if "*~".contains(c) || ".,:;!?".contains(c) {
                t.removeLast()
            } else if c == ")" {
                let open = t.filter { $0 == "(" }.count, close = t.filter { $0 == ")" }.count
                if close > open { t.removeLast() } else { break }
            } else {
                break
            }
        }
        return String(t)
    }

    private static func isCJKTerminator(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF5E, 0x3001, 0x3002, 0x300C...0x3011: return true
        default: return false
        }
    }

    static func codeRanges(_ s: String) -> [Range<Int>] {
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        var ranges: [Range<Int>] = []
        func add(_ re: NSRegularExpression) {
            for m in re.matches(in: s, range: full) {
                let r = m.range.location..<(m.range.location + m.range.length)
                if !inside(r.lowerBound, ranges) { ranges.append(r) }
            }
        }
        if s.contains("```") { add(p.fenced) }
        if s.contains("$") {
            add(p.displayMath)
            add(p.inlineMath)
        }
        if s.contains("`") { add(p.inlineCode) }
        return ranges
    }

    static func markdownLinkRanges(_ t: [UInt16]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var i = 0
        while i < t.count {
            defer { i += 1 }
            guard t[i] == 0x5B, !escaped(t, i), !inside(i, ranges) else { continue }
            guard let labelEnd = matching(t, from: i, open: 0x5B, close: 0x5D) else { continue }
            let start = i > 0 && t[i - 1] == 0x21 && !escaped(t, i - 1) ? i - 1 : i
            let next: UInt16? = labelEnd + 1 < t.count ? t[labelEnd + 1] : nil
            if next == 0x28, let close = matching(t, from: labelEnd + 1, open: 0x28, close: 0x29) {
                ranges.append(start..<(close + 1))
                i = close
            } else if next == 0x5B, let close = matching(t, from: labelEnd + 1, open: 0x5B, close: 0x5D) {
                ranges.append(start..<(close + 1))
                i = close
            }
        }
        return ranges
    }

    private static func matching(_ t: [UInt16], from: Int, open: UInt16, close: UInt16) -> Int? {
        var depth = 0
        var i = from
        while i < t.count {
            if !escaped(t, i) {
                if t[i] == open { depth += 1 } else if t[i] == close {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i += 1
        }
        return nil
    }

    private static func escaped(_ t: [UInt16], _ i: Int) -> Bool {
        var n = 0
        var j = i - 1
        while j >= 0, t[j] == 0x5C { n += 1; j -= 1 }
        return n % 2 == 1
    }

    private static func alreadyLinked(_ t: [UInt16], _ r: Range<Int>) -> Bool {
        if r.lowerBound >= 2 {
            let a = t[r.lowerBound - 2], b = t[r.lowerBound - 1]
            if a == 0x5D && (b == 0x28 || b == 0x5B) { return true }
        }
        let before: UInt16? = r.lowerBound > 0 ? t[r.lowerBound - 1] : nil
        let after: UInt16? = r.upperBound < t.count ? t[r.upperBound] : nil
        return before == 0x5B && after == 0x5D
    }

    private static func inside(_ pos: Int, _ ranges: [Range<Int>]) -> Bool {
        ranges.contains { $0.contains(pos) }
    }

    private static func overlaps(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }

    private static func isAlnum(_ u: UInt16) -> Bool {
        (0x30...0x39).contains(u) || (0x41...0x5A).contains(u) || (0x61...0x7A).contains(u)
    }
}
