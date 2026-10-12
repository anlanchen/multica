import Foundation

// Dotenv parsing for the agent Environment tab (upstream tabs/env-file.ts):
// paste/bulk-edit read values verbatim, never evaluating them, and bulk text
// is only offered when it round-trips exactly.
extension AgentsUI {
    public struct EnvAssignment: Sendable, Hashable {
        public var key: String
        public var value: String
        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// `line` is 1-based and counts blank and comment lines.
    public enum EnvParseError: Error, Sendable, Hashable {
        case malformed(line: Int)
        case duplicate(line: Int, key: String)
    }

    public enum EnvFormatError: Error, Sendable, Hashable {
        case unrepresentable(key: String)
        case duplicate(key: String)
    }

    private static func isKeyStart(_ c: Character) -> Bool { c == "_" || (c.isASCII && c.isLetter) }
    private static func isKeyChar(_ c: Character) -> Bool { c == "_" || (c.isASCII && (c.isLetter || c.isNumber)) }
    private static func isBlank(_ c: Character) -> Bool { c == " " || c == "\t" }

    /// `^(?:export[\t ]+)?([A-Za-z_][A-Za-z0-9_]*)[\t ]*=(.*)$` on a trimmed line.
    static func matchAssignment(_ line: Substring) -> (key: String, raw: Substring)? {
        func match(_ s: Substring) -> (String, Substring)? {
            guard let first = s.first, isKeyStart(first) else { return nil }
            var i = s.index(after: s.startIndex)
            while i < s.endIndex, isKeyChar(s[i]) { i = s.index(after: i) }
            let key = String(s[s.startIndex..<i])
            while i < s.endIndex, isBlank(s[i]) { i = s.index(after: i) }
            guard i < s.endIndex, s[i] == "=" else { return nil }
            return (key, s[s.index(after: i)...])
        }
        if line.hasPrefix("export") {
            let rest = line.dropFirst(6)
            if let c = rest.first, isBlank(c), let m = match(rest.drop(while: isBlank)) { return m }
        }
        return match(line)
    }

    private static func parseQuoted(_ raw: Substring) -> String? {
        guard let quote = raw.first, quote == "\"" || quote == "'" else { return nil }
        var i = raw.index(after: raw.startIndex)
        while i < raw.endIndex {
            if raw[i] == quote {
                let remainder = raw[raw.index(after: i)...]
                let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
                let blanks = remainder.prefix(while: isBlank)
                if trimmed.isEmpty || (!blanks.isEmpty && remainder.dropFirst(blanks.count).first == "#") {
                    return String(raw[raw.index(after: raw.startIndex)..<i])
                }
            }
            i = raw.index(after: i)
        }
        return nil
    }

    private static func trimEnd(_ s: Substring) -> String {
        var end = s.endIndex
        while end > s.startIndex, s[s.index(before: end)].isWhitespace { end = s.index(before: end) }
        return String(s[s.startIndex..<end])
    }

    private static func parseUnquoted(_ raw: Substring, hadLeadingWhitespace: Bool) -> String {
        var prev: Character?
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == "#" && ((i == raw.startIndex && hadLeadingWhitespace) || (prev?.isWhitespace ?? false)) {
                return trimEnd(raw[raw.startIndex..<i])
            }
            prev = c
            i = raw.index(after: i)
        }
        return trimEnd(raw)
    }

    private static func parseValue(_ raw: Substring) -> String? {
        let hadLeading = raw.first.map(isBlank) ?? false
        let value = raw.drop(while: \.isWhitespace)
        if value.first == "\"" || value.first == "'" { return parseQuoted(value) }
        return parseUnquoted(value, hadLeadingWhitespace: hadLeading)
    }

    private static func lines(_ text: String) -> [Substring] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Parses a dotenv file. No assignments at all is success with an empty
    /// list (bulk editing's "clear everything").
    public static func parseEnvFileResult(_ text: String) -> Result<[EnvAssignment], EnvParseError> {
        var out: [EnvAssignment] = []
        var keys = Set<String>()
        for (index, line) in lines(text).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let lineNumber = index + 1
            guard let m = matchAssignment(Substring(trimmed)), let value = parseValue(m.raw) else {
                return .failure(.malformed(line: lineNumber))
            }
            if keys.contains(m.key) { return .failure(.duplicate(line: lineNumber, key: m.key)) }
            keys.insert(m.key)
            out.append(EnvAssignment(key: m.key, value: value))
        }
        return .success(out)
    }

    /// A pasted env file, or nil when it is not one (or has no assignments).
    public static func parseEnvFile(_ text: String) -> [EnvAssignment]? {
        guard case .success(let list) = parseEnvFileResult(text), !list.isEmpty else { return nil }
        return list
    }

    /// Whether a paste looks like an env file at all (any `KEY=` line).
    public static func isEnvFilePaste(_ text: String) -> Bool {
        lines(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .contains { matchAssignment(Substring($0)) != nil }
    }

    private static func encodeValue(key: String, value: String) -> String? {
        if value.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) { return nil }
        for candidate in [value, "\"\(value)\"", "'\(value)'"] {
            if case .success(let list) = parseEnvFileResult("\(key)=\(candidate)"), list.first?.value == value {
                return candidate
            }
        }
        return nil
    }

    /// Text that parses back to exactly these entries, or the first entry
    /// that cannot be represented.
    public static func formatEnvFile(_ assignments: [EnvAssignment]) -> Result<String, EnvFormatError> {
        var out: [String] = []
        var keys = Set<String>()
        for a in assignments {
            guard let first = a.key.first, isKeyStart(first), a.key.allSatisfy(isKeyChar) else {
                return .failure(.unrepresentable(key: a.key))
            }
            if keys.contains(a.key) { return .failure(.duplicate(key: a.key)) }
            guard let encoded = encodeValue(key: a.key, value: a.value) else { return .failure(.unrepresentable(key: a.key)) }
            keys.insert(a.key)
            out.append("\(a.key)=\(encoded)")
        }
        return .success(out.joined(separator: "\n"))
    }
}
