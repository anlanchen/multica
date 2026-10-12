import Foundation

/// SKILL.md frontmatter (upstream core/skills/frontmatter.ts). Values are
/// read as strings; only top-level scalar keys matter to the client.
public enum SkillsFrontmatter {
    public struct Parsed: Sendable, Hashable {
        public var frontmatter: [String: String]?
        public var body: String
    }

    /// Matches the server's `^---\r?\n([\s\S]*?\r?\n)---\r?\n?`; the block
    /// keeps its trailing newline.
    public static func parse(_ raw: String) -> Parsed {
        let ns = raw as NSString
        let start: Int
        if ns.hasPrefix("---\n") { start = 4 } else if ns.hasPrefix("---\r\n") { start = 5 } else {
            return Parsed(frontmatter: nil, body: raw)
        }
        let close = ns.range(of: "\n---", options: .literal, range: NSRange(location: start, length: ns.length - start))
        guard close.location != NSNotFound else { return Parsed(frontmatter: nil, body: raw) }
        let block = ns.substring(with: NSRange(location: start, length: close.location + 1 - start))
        var end = close.location + close.length
        if end < ns.length, ns.character(at: end) == 13 { end += 1 }
        if end < ns.length, ns.character(at: end) == 10 { end += 1 }
        let body = ns.substring(from: end)
        guard let values = parseYAML(block), !values.isEmpty else { return Parsed(frontmatter: nil, body: body) }
        return Parsed(frontmatter: values, body: body)
    }

    /// Body without the frontmatter block.
    public static func body(_ raw: String) -> String { parse(raw).body }

    /// Minimal YAML mapping reader: plain, quoted and block (`|`, `>`)
    /// scalars; nested values are kept as their raw text. Returns nil when
    /// the block is not a mapping.
    static func parseYAML(_ block: String) -> [String: String]? {
        let lines = block.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [String: String] = [:]
        var i = 0
        func indent(_ s: String) -> Int { s.prefix(while: { $0 == " " }).count }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || indent(line) > 0 { i += 1; continue }
            guard let colon = keyColon(line) else { return nil }
            var key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            if (key.hasPrefix("\"") && key.hasSuffix("\"")) || (key.hasPrefix("'") && key.hasSuffix("'")), key.count >= 2 {
                key = String(key.dropFirst().dropLast())
            }
            let rest = stripComment(String(line[line.index(after: colon)...])).trimmingCharacters(in: .whitespaces)
            i += 1
            var continuation: [String] = []
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty || indent(lines[i]) > 0 {
                continuation.append(lines[i])
                i += 1
            }
            while let last = continuation.last, last.trimmingCharacters(in: .whitespaces).isEmpty, !(rest.hasPrefix("|") || rest.hasPrefix(">")) {
                continuation.removeLast()
            }
            if let value = scalar(rest, continuation: continuation) { result[key] = value }
        }
        return result
    }

    private static func keyColon(_ line: String) -> String.Index? {
        var quote: Character?
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ":" {
                let next = line.index(after: idx)
                if next == line.endIndex || line[next] == " " || line[next] == "\t" { return idx }
            }
            idx = line.index(after: idx)
        }
        return nil
    }

    private static func stripComment(_ s: String) -> String {
        if s.trimmingCharacters(in: .whitespaces).hasPrefix("\"") || s.trimmingCharacters(in: .whitespaces).hasPrefix("'") { return s }
        if let r = s.range(of: " #") { return String(s[..<r.lowerBound]) }
        return s
    }

    private static func scalar(_ rest: String, continuation: [String]) -> String? {
        if rest.hasPrefix("|") || rest.hasPrefix(">") {
            return blockScalar(header: rest, lines: continuation)
        }
        if rest.isEmpty {
            let nested = continuation.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if nested.isEmpty { return nil }
            return nested.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        }
        if rest.hasPrefix("\"") {
            let joined = ([rest] + continuation.map { $0.trimmingCharacters(in: .whitespaces) }).joined(separator: " ")
            return unquoteDouble(joined)
        }
        if rest.hasPrefix("'") {
            let joined = ([rest] + continuation.map { $0.trimmingCharacters(in: .whitespaces) }).joined(separator: " ")
            guard joined.hasSuffix("'"), joined.count >= 2 else { return joined }
            return String(joined.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        let folded = ([rest] + continuation.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }).joined(separator: " ")
        if folded == "~" || folded == "null" || folded == "Null" || folded == "NULL" { return nil }
        return folded
    }

    private static func unquoteDouble(_ s: String) -> String {
        guard s.count >= 2, s.hasSuffix("\"") else { return s }
        var out = ""
        var escaping = false
        for ch in s.dropFirst().dropLast() {
            if escaping {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func blockScalar(header: String, lines: [String]) -> String {
        let literal = header.hasPrefix("|")
        let chomp: Character? = header.dropFirst().first(where: { $0 == "-" || $0 == "+" })
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let indent = content.map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        var body = lines.map { $0.count >= indent ? String($0.dropFirst(indent)) : "" }
        var trailingBlank = 0
        while let last = body.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            body.removeLast()
            trailingBlank += 1
        }
        var text: String
        if literal {
            text = body.joined(separator: "\n")
        } else {
            text = ""
            for (i, line) in body.enumerated() {
                if i > 0 { text += line.isEmpty || body[i - 1].isEmpty ? "\n" : " " }
                text += line
            }
        }
        if body.isEmpty { return "" }
        switch chomp {
        case "-": return text
        case "+": return text + String(repeating: "\n", count: trailingBlank + 1)
        default: return text + "\n"
        }
    }
}
