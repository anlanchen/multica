import Foundation

/// Masks credentials in agent output before it is displayed.
///
/// Redaction is applied to the rows being rendered, never to a whole
/// transcript per update: upstream redacted every message of every live run
/// on each 100 ms flush (~25 ms per flush at 3000 messages, MUL-7227). It is
/// also applied to a whole body *before* clipping, because a pattern only
/// matches while both of its ends are present.
public final class Redactor: @unchecked Sendable {
    public static let shared = Redactor()

    private struct Rule {
        var regex: NSRegularExpression
        /// Number of leading capture groups to keep verbatim (e.g. `api_key=`).
        var keepGroup: Int?
        /// Cheap substrings (ASCII, lowercase) of which at least one must be
        /// present for the rule to possibly match. Checked on a lowercased
        /// byte view, so the regex engine only runs on plausible bodies.
        var needles: [[UInt8]]
    }

    private let rules: [Rule]
    public static let mask = "[REDACTED]"

    public init() {
        func rule(_ pattern: String, keep: Int? = nil, needles: [String]) -> Rule {
            Rule(regex: try! NSRegularExpression(pattern: pattern, options: []), keepGroup: keep,
                 needles: needles.map { Array($0.lowercased().utf8) })
        }
        rules = [
            rule(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, needles: ["private key"]),
            rule(#"\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{20,}"#, needles: ["sk-"]),
            rule(#"\bgh[pousr]_[A-Za-z0-9]{30,}"#, needles: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"]),
            rule(#"\bgithub_pat_[A-Za-z0-9_]{22,}"#, needles: ["github_pat_"]),
            rule(#"\bglpat-[A-Za-z0-9_\-]{20,}"#, needles: ["glpat-"]),
            rule(#"\bAKIA[0-9A-Z]{16}\b"#, needles: ["akia"]),
            rule(#"\bAIza[0-9A-Za-z_\-]{35}"#, needles: ["aiza"]),
            rule(#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, needles: ["xox"]),
            rule(#"\bnpm_[A-Za-z0-9]{36}\b"#, needles: ["npm_"]),
            rule(#"\bmul_[A-Za-z0-9]{20,}"#, needles: ["mul_"]),
            rule(#"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#, needles: ["eyj"]),
            rule(#"(?i)(bearer\s+)[A-Za-z0-9._~+/=\-]{16,}"#, keep: 1, needles: ["bearer"]),
            rule(#"(?i)((?:api[_-]?key|secret|password|passwd|access[_-]?token|auth[_-]?token)["']?\s*[:=]\s*["']?)[^\s"',;]{8,}"#,
                 keep: 1, needles: ["key", "secret", "passw", "token"]),
            rule(#"(https?://[^/\s:@]+:)[^/\s:@]+(@)"#, keep: 1, needles: ["://"]),
        ]
    }

    /// Lowercased ASCII bytes of `text`, for needle checks.
    private static func folded(_ text: String) -> [UInt8] {
        var out = Array(text.utf8)
        for i in out.indices where out[i] >= 65 && out[i] <= 90 { out[i] += 32 }
        return out
    }

    private static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard let first = needle.first, hay.count >= needle.count else { return false }
        let last = hay.count - needle.count
        var i = 0
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < needle.count && hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    public func redact(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var text = input
        let folded = Redactor.folded(input)
        for r in rules {
            guard r.needles.contains(where: { Redactor.contains(folded, $0) }) else { continue }
            let ns = text as NSString
            let matches = r.regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var out = ""
            out.reserveCapacity(text.utf16.count)
            var cursor = 0
            for m in matches {
                out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                if let keep = r.keepGroup, m.numberOfRanges > keep, m.range(at: keep).location != NSNotFound {
                    out += ns.substring(with: m.range(at: keep))
                    out += Redactor.mask
                    // Preserve a trailing group (the `@` of URL credentials).
                    if m.numberOfRanges > keep + 1, m.range(at: keep + 1).location != NSNotFound {
                        out += ns.substring(with: m.range(at: keep + 1))
                    }
                } else {
                    out += Redactor.mask
                }
                cursor = m.range.location + m.range.length
            }
            out += ns.substring(from: cursor)
            text = out
        }
        return text
    }

    /// Redact first, then clip — never the other way around.
    public func displayText(_ input: String, limit: Int) -> (text: String, clipped: Bool) {
        let redacted = redact(input)
        guard redacted.count > limit else { return (redacted, false) }
        return (String(redacted.prefix(limit)), true)
    }

    /// Redacts the human-readable fields of a task message. Applied once per
    /// message when it enters the client (off the main thread), so rendering
    /// never runs the patterns.
    public func redacted(_ m: TaskMessage) -> TaskMessage {
        var out = m
        if let c = m.content { out.content = redact(c) }
        if let o = m.output { out.output = redact(o) }
        if let i = m.input { out.input = redact(i) }
        return out
    }

    public func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s): return .string(redact(s))
        case .array(let a): return .array(a.map(redact))
        case .object(let o): return .object(o.mapValues(redact))
        default: return value
        }
    }

    /// Redacts a REST backfill on a background executor.
    public func redactedInBackground(_ messages: [TaskMessage]) async -> [TaskMessage] {
        await Task.detached(priority: .userInitiated) { [self] in messages.map(self.redacted) }.value
    }
}
