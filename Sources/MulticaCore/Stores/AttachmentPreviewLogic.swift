import Foundation

/// How an attachment is shown (upstream editor/utils/preview.ts).
public enum AttachmentPreviewKind: String, Sendable, Hashable {
    case image, pdf, video, audio, markdown, html, table, structured, text
}

public enum AttachmentPreviewStructuredFormat: String, Sendable, Hashable {
    case json, jsonl, yaml
}

public enum AttachmentPreview {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "ico", "svg"]
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi", "ogv"]
    static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "ogg", "oga", "flac", "aac", "opus"]
    static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "log", "csv", "tsv", "html", "htm", "json", "jsonl", "ndjson", "xml",
        "yml", "yaml", "toml", "ini", "conf", "dockerfile", "makefile", "gitignore", "sh", "bash", "zsh",
        "py", "rb", "go", "rs", "ts", "tsx", "js", "jsx", "mjs", "cjs", "css", "scss", "sass", "less",
        "sql", "java", "kt", "swift", "c", "cc", "cpp", "h", "hpp", "cs", "php", "lua", "vim",
    ]
    static let textContentTypes: Set<String> = [
        "application/json", "application/x-ndjson", "application/javascript", "application/xml",
        "application/x-yaml", "application/yaml", "application/toml", "application/x-sh", "application/x-httpd-php",
    ]
    static let textBasenames: Set<String> = ["dockerfile", "makefile", ".env", ".gitignore"]
    static let languageByExtension: [String: String] = [
        "md": "markdown", "markdown": "markdown", "txt": "plaintext", "log": "plaintext",
        "html": "xml", "htm": "xml", "xml": "xml", "svg": "xml", "css": "css", "scss": "scss", "sass": "scss", "less": "less",
        "json": "json", "jsonl": "json", "ndjson": "json", "yml": "yaml", "yaml": "yaml", "toml": "ini", "ini": "ini", "conf": "ini",
        "dockerfile": "dockerfile", "makefile": "makefile", "gitignore": "plaintext", "sh": "bash", "bash": "bash", "zsh": "bash",
        "py": "python", "rb": "ruby", "go": "go", "rs": "rust", "ts": "typescript", "tsx": "typescript", "js": "javascript",
        "jsx": "javascript", "mjs": "javascript", "cjs": "javascript", "java": "java", "kt": "kotlin", "swift": "swift",
        "c": "c", "cc": "cpp", "cpp": "cpp", "h": "c", "hpp": "cpp", "cs": "csharp", "php": "php", "lua": "lua", "vim": "vim",
        "sql": "sql", "csv": "plaintext", "tsv": "plaintext",
    ]
    static let languageByBasename: [String: String] = ["dockerfile": "dockerfile", "makefile": "makefile", ".env": "plaintext", ".gitignore": "plaintext"]

    static func base(_ filename: String) -> String {
        (filename.lowercased().split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
    }

    public static func ext(_ filename: String) -> String {
        let b = base(filename)
        guard let dot = b.lastIndex(of: "."), dot > b.startIndex else { return "" }
        return String(b[b.index(after: dot)...])
    }

    static func normalizedType(_ contentType: String) -> String {
        let ct = contentType.lowercased().trimmingCharacters(in: .whitespaces)
        return (ct.split(separator: ";").first.map(String.init) ?? ct).trimmingCharacters(in: .whitespaces)
    }

    public static func kind(contentType: String, filename: String) -> AttachmentPreviewKind? {
        let ct = normalizedType(contentType)
        let e = ext(filename)
        if ct == "application/pdf" || e == "pdf" { return .pdf }
        if ct.hasPrefix("video/") || videoExtensions.contains(e) { return .video }
        if ct.hasPrefix("audio/") || audioExtensions.contains(e) { return .audio }
        if ct.hasPrefix("image/") || imageExtensions.contains(e) { return .image }
        if ct == "text/markdown" || e == "md" || e == "markdown" { return .markdown }
        if ct == "text/html" || e == "html" || e == "htm" { return .html }
        if ct == "text/csv" || ct == "text/tab-separated-values" || e == "csv" || e == "tsv" { return .table }
        if structuredFormat(contentType: contentType, filename: filename) != nil { return .structured }
        if ct.hasPrefix("text/") || textContentTypes.contains(ct) || (!e.isEmpty && textExtensions.contains(e)) || textBasenames.contains(base(filename)) {
            return .text
        }
        return nil
    }

    public static func structuredFormat(contentType: String, filename: String) -> AttachmentPreviewStructuredFormat? {
        switch ext(filename) {
        case "json": return .json
        case "jsonl", "ndjson": return .jsonl
        case "yml", "yaml": return .yaml
        default: break
        }
        switch normalizedType(contentType) {
        case "application/json": return .json
        case "application/x-ndjson": return .jsonl
        case "application/yaml", "application/x-yaml", "text/yaml", "text/x-yaml": return .yaml
        default: return nil
        }
    }

    public static func isTSV(contentType: String, filename: String) -> Bool {
        ext(filename) == "tsv" || normalizedType(contentType) == "text/tab-separated-values"
    }

    /// The extension upper-cased (`PNG`), for the metadata line.
    public static func typeLabel(_ filename: String) -> String { ext(filename).uppercased() }

    public static func language(for filename: String) -> String? {
        let e = ext(filename)
        if let l = languageByExtension[e], !e.isEmpty { return l }
        return languageByBasename[base(filename)]
    }

    /// Prose and logs wrap; code keeps its lines and scrolls sideways.
    public static func wrapsByDefault(_ filename: String) -> Bool {
        let l = language(for: filename)
        return l == nil || l == "plaintext"
    }
}

// MARK: Delimited tables

public struct AttachmentPreviewTable: Sendable, Hashable {
    public var header: [String]
    public var rows: [[String]]
    public var columnCount: Int
    /// Columns whose every filled cell is a number (right-aligned).
    public var numericColumns: Set<Int>
}

extension AttachmentPreview {
    /// The delimiter a `.csv` really uses: whichever of `,` `;` tab splits
    /// the first record most (comma on ties).
    public static func sniffDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        var best: Character = ","
        var bestCount = 0
        for c in [",", ";", "\t"] as [Character] {
            let n = firstLine.filter { $0 == c }.count
            if n > bestCount {
                best = c
                bestCount = n
            }
        }
        return best
    }

    /// RFC 4180 with leniency: quotes are special only at a field's start,
    /// `""` is a literal quote, blank lines are skipped.
    public static func parseDelimited(_ text: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        func endField() {
            record.append(field)
            field = ""
        }
        func endRecord() {
            endField()
            if record.count > 1 || record.first != "" { records.append(record) }
            record = []
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\"" && field.isEmpty {
                i += 1
                while i < chars.count {
                    if chars[i] == "\"" {
                        if i + 1 < chars.count && chars[i + 1] == "\"" {
                            field.append("\"")
                            i += 2
                            continue
                        }
                        i += 1
                        break
                    }
                    field.append(chars[i])
                    i += 1
                }
                continue
            }
            if c == delimiter {
                endField()
                i += 1
            } else if c == "\r\n" || c == "\n" || c == "\r" {
                endRecord()
                i += 1
            } else {
                field.append(c)
                i += 1
            }
        }
        if !field.isEmpty || !record.isEmpty { endRecord() }
        return records
    }

    public static func table(_ text: String, tsv: Bool) -> AttachmentPreviewTable {
        let records = parseDelimited(text, delimiter: tsv ? "\t" : sniffDelimiter(text))
        let columns = records.reduce(0) { max($0, $1.count) }
        func pad(_ r: [String]) -> [String] { r.count == columns ? r : r + Array(repeating: "", count: columns - r.count) }
        let header = records.first.map(pad) ?? []
        let rows = records.dropFirst().map(pad)
        var numeric = Set<Int>()
        for c in 0..<columns {
            var filled = 0, numbers = 0
            for r in rows.prefix(200) {
                let v = r[c].trimmingCharacters(in: .whitespaces)
                if v.isEmpty { continue }
                filled += 1
                if number(v) != nil { numbers += 1 }
            }
            if filled > 0 && filled == numbers { numeric.insert(c) }
        }
        return AttachmentPreviewTable(header: header, rows: Array(rows), columnCount: columns, numericColumns: numeric)
    }

    static func number(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let d = Double(t), d.isFinite else { return nil }
        return d
    }

    /// Numbers compare as numbers and sort before text; text compares
    /// naturally, case-insensitively.
    public static func compareCells(_ a: String, _ b: String) -> ComparisonResult {
        switch (number(a), number(b)) {
        case let (x?, y?): return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        case (.some, nil): return .orderedAscending
        case (nil, .some): return .orderedDescending
        default: return a.compare(b, options: [.numeric, .caseInsensitive, .diacriticInsensitive])
        }
    }

    /// Row indices sorted by a column; empty cells stay last either way.
    public static func sortedRows(_ table: AttachmentPreviewTable, column: Int, ascending: Bool) -> [Int] {
        let filled = table.rows.indices.filter { !table.rows[$0][column].isEmpty }
        let empty = table.rows.indices.filter { table.rows[$0][column].isEmpty }
        let sorted = filled.sorted { i, j in
            let r = compareCells(table.rows[i][column], table.rows[j][column])
            if r == .orderedSame { return i < j }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
        return sorted + empty
    }
}

// MARK: Structured values

/// A parsed JSON / YAML value that keeps object key order.
public indirect enum AttachmentPreviewValue: Sendable, Hashable {
    case object([(String, AttachmentPreviewValue)])
    case array([AttachmentPreviewValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public static func == (a: AttachmentPreviewValue, b: AttachmentPreviewValue) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(x), .array(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    public func hash(into h: inout Hasher) {
        switch self {
        case .object(let e): h.combine(0); for (k, v) in e { h.combine(k); h.combine(v) }
        case .array(let a): h.combine(1); h.combine(a)
        case .string(let s): h.combine(s)
        case .number(let n): h.combine(n)
        case .bool(let b): h.combine(b)
        case .null: h.combine(5)
        }
    }

    public var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }

    public var entries: [(String, AttachmentPreviewValue)] {
        switch self {
        case .object(let e): return e
        case .array(let a): return a.enumerated().map { (String($0.offset), $0.element) }
        default: return []
        }
    }
}

public enum AttachmentPreviewParse: Sendable, Hashable {
    case ok(AttachmentPreviewValue)
    case failed(String)
}

public struct AttachmentPreviewParseError: Error, Sendable {
    public var message: String
}

extension AttachmentPreview {
    public static func parseStructured(_ text: String, format: AttachmentPreviewStructuredFormat) -> AttachmentPreviewParse {
        do {
            switch format {
            case .json:
                var parser = AttachmentPreviewJSONParser(text)
                return .ok(try parser.parseDocument())
            case .jsonl:
                var values: [AttachmentPreviewValue] = []
                for (i, line) in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).enumerated() {
                    if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                    do {
                        var parser = AttachmentPreviewJSONParser(String(line))
                        values.append(try parser.parseDocument())
                    } catch let e as AttachmentPreviewParseError {
                        return .failed("Line \(i + 1): \(e.message)")
                    }
                }
                return .ok(.array(values))
            case .yaml:
                var parser = AttachmentPreviewYAMLParser(text)
                return .ok(try parser.parseStream())
            }
        } catch let e as AttachmentPreviewParseError {
            return .failed(e.message)
        } catch {
            return .failed(String(describing: error))
        }
    }

    static func formatNumber(_ n: Double) -> String {
        if n.rounded() == n && abs(n) < 1e21 { return String(format: "%.0f", n) }
        return String(n)
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 { out += String(format: "\\u%04x", c.value) } else { out.unicodeScalars.append(c) }
            }
        }
        return out + "\""
    }

    /// How a primitive reads in the tree (strings quoted, like JSON).
    public static func primitiveText(_ v: AttachmentPreviewValue) -> String {
        switch v {
        case .string(let s): return quoted(s)
        case .number(let n): return formatNumber(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .object: return "{…}"
        case .array: return "[…]"
        }
    }

    /// Bare keys stay bare; anything else is quoted.
    public static func formatKey(_ key: String) -> String {
        let ok = !key.isEmpty && key.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || "_$-".unicodeScalars.contains($0) }
        return ok ? key : quoted(key)
    }

    /// One-line preview of a collapsed container, within ~80 characters.
    public static func previewOf(_ v: AttachmentPreviewValue) -> String {
        let isArray: Bool
        if case .array = v { isArray = true } else { isArray = false }
        var parts: [String] = []
        var used = 0
        var truncated = false
        for (key, item) in v.entries {
            let shown = primitiveText(item)
            let part = isArray ? shown : "\(formatKey(key)): \(shown)"
            if !parts.isEmpty && used + part.count > 80 {
                truncated = true
                break
            }
            parts.append(part)
            used += part.count + 2
        }
        let body = parts.joined(separator: ", ") + (truncated ? ", …" : "")
        return isArray ? "[\(body)]" : "{ \(body) }"
    }

    static func isArrayValue(_ v: AttachmentPreviewValue) -> Bool {
        if case .array = v { return true }
        return false
    }
}

/// The tree as visible rows: containers open per `expanded`, children paged
/// 100 at a time (upstream structured-tree.tsx).
public struct AttachmentPreviewTreeRow: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case primitive(String)
        case empty(isArray: Bool)
        case container(isArray: Bool, count: Int, open: Bool, preview: String)
        case showMore(remaining: Int)
    }

    public var id: String { path + (kind.isShowMore ? "#more" : "") }
    public var path: String
    public var depth: Int
    public var key: String
    public var keyIsIndex: Bool
    public var kind: Kind
}

extension AttachmentPreviewTreeRow.Kind {
    var isShowMore: Bool {
        if case .showMore = self { return true }
        return false
    }
}

public enum AttachmentPreviewTree {
    public static let pageSize = 100
    public static let autoOpenLimit = 50

    /// Paths open by default: top-level objects with few enough keys.
    public static func defaultExpanded(_ root: AttachmentPreviewValue) -> Set<String> {
        guard case .object = root else { return [] }
        var out = Set<String>()
        for (key, item) in root.entries where item.isContainer && item.entries.count <= autoOpenLimit && !item.entries.isEmpty {
            out.insert("/" + key)
        }
        return out
    }

    public static func rows(_ root: AttachmentPreviewValue, expanded: Set<String>, shown: [String: Int]) -> [AttachmentPreviewTreeRow] {
        var out: [AttachmentPreviewTreeRow] = []
        guard root.isContainer else {
            out.append(AttachmentPreviewTreeRow(path: "", depth: 0, key: "", keyIsIndex: false, kind: .primitive(AttachmentPreview.primitiveText(root))))
            return out
        }
        appendChildren(of: root, path: "", depth: 1, expanded: expanded, shown: shown, into: &out)
        return out
    }

    static func appendChildren(of value: AttachmentPreviewValue, path: String, depth: Int, expanded: Set<String>, shown: [String: Int], into out: inout [AttachmentPreviewTreeRow]) {
        let isArray = AttachmentPreview.isArrayValue(value)
        let entries = value.entries
        let limit = shown[path] ?? pageSize
        for (key, item) in entries.prefix(limit) {
            let childPath = path + "/" + key
            if item.isContainer {
                let childIsArray = AttachmentPreview.isArrayValue(item)
                let count = item.entries.count
                if count == 0 {
                    out.append(.init(path: childPath, depth: depth, key: key, keyIsIndex: isArray, kind: .empty(isArray: childIsArray)))
                    continue
                }
                let open = expanded.contains(childPath)
                out.append(.init(path: childPath, depth: depth, key: key, keyIsIndex: isArray,
                                 kind: .container(isArray: childIsArray, count: count, open: open, preview: open ? "" : AttachmentPreview.previewOf(item))))
                if open { appendChildren(of: item, path: childPath, depth: depth + 1, expanded: expanded, shown: shown, into: &out) }
            } else {
                out.append(.init(path: childPath, depth: depth, key: key, keyIsIndex: isArray, kind: .primitive(AttachmentPreview.primitiveText(item))))
            }
        }
        if entries.count > limit {
            out.append(.init(path: path, depth: depth, key: "", keyIsIndex: false, kind: .showMore(remaining: entries.count - limit)))
        }
    }
}

// MARK: Parsers

/// Order-preserving JSON parser (Foundation's loses object key order).
struct AttachmentPreviewJSONParser {
    private let s: [UInt8]
    private var i = 0
    private var depth = 0

    init(_ text: String) { s = Array(text.utf8) }

    mutating func parseDocument() throws -> AttachmentPreviewValue {
        skipWS()
        let v = try value()
        skipWS()
        if i < s.count { throw err("Unexpected token after JSON value") }
        return v
    }

    private func err(_ m: String) -> AttachmentPreviewParseError {
        AttachmentPreviewParseError(message: "\(m) at position \(i)")
    }

    private mutating func skipWS() {
        while i < s.count, s[i] == 0x20 || s[i] == 0x0A || s[i] == 0x0D || s[i] == 0x09 { i += 1 }
    }

    private mutating func value() throws -> AttachmentPreviewValue {
        guard i < s.count else { throw err("Unexpected end of JSON input") }
        depth += 1
        defer { depth -= 1 }
        if depth > 512 { throw err("Nesting too deep") }
        switch s[i] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return .number(try number())
        }
    }

    private mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= s.count, Array(s[i..<i + w.count]) == w else { throw err("Unexpected token") }
        i += w.count
    }

    private mutating func object() throws -> AttachmentPreviewValue {
        i += 1
        var out: [(String, AttachmentPreviewValue)] = []
        skipWS()
        if i < s.count, s[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
        while true {
            skipWS()
            guard i < s.count, s[i] == UInt8(ascii: "\"") else { throw err("Expected property name") }
            let k = try string()
            skipWS()
            guard i < s.count, s[i] == UInt8(ascii: ":") else { throw err("Expected ':' after property name") }
            i += 1
            skipWS()
            let v = try value()
            if let existing = out.firstIndex(where: { $0.0 == k }) { out[existing].1 = v } else { out.append((k, v)) }
            skipWS()
            guard i < s.count else { throw err("Unexpected end of JSON input") }
            if s[i] == UInt8(ascii: ",") { i += 1; continue }
            if s[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
            throw err("Expected ',' or '}'")
        }
    }

    private mutating func array() throws -> AttachmentPreviewValue {
        i += 1
        var out: [AttachmentPreviewValue] = []
        skipWS()
        if i < s.count, s[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
        while true {
            skipWS()
            out.append(try value())
            skipWS()
            guard i < s.count else { throw err("Unexpected end of JSON input") }
            if s[i] == UInt8(ascii: ",") { i += 1; continue }
            if s[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
            throw err("Expected ',' or ']'")
        }
    }

    private mutating func string() throws -> String {
        i += 1
        var bytes: [UInt8] = []
        while i < s.count {
            let c = s[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                return String(decoding: bytes, as: UTF8.self)
            }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < s.count else { break }
                let e = s[i]
                i += 1
                switch e {
                case UInt8(ascii: "n"): bytes.append(0x0A)
                case UInt8(ascii: "t"): bytes.append(0x09)
                case UInt8(ascii: "r"): bytes.append(0x0D)
                case UInt8(ascii: "b"): bytes.append(0x08)
                case UInt8(ascii: "f"): bytes.append(0x0C)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), i + 1 < s.count, s[i] == UInt8(ascii: "\\"), s[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    bytes.append(contentsOf: Array(String(Unicode.Scalar(code).map(Character.init) ?? "\u{FFFD}").utf8))
                default: bytes.append(e)
                }
                continue
            }
            if c < 0x20 { throw err("Bad control character in string literal") }
            bytes.append(c)
            i += 1
        }
        throw err("Unterminated string in JSON")
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= s.count, let v = UInt32(String(decoding: s[i..<i + 4], as: UTF8.self), radix: 16) else { throw err("Bad Unicode escape") }
        i += 4
        return v
    }

    private mutating func number() throws -> Double {
        let start = i
        while i < s.count, "+-0123456789.eE".utf8.contains(s[i]) { i += 1 }
        guard i > start, let d = Double(String(decoding: s[start..<i], as: UTF8.self)) else { throw err("Unexpected token") }
        return d
    }
}

/// A block-YAML subset: mappings, sequences, plain/quoted scalars, flow
/// collections, block scalars, comments and `---` documents. Anything else
/// fails with a message so the viewer falls back to the source.
struct AttachmentPreviewYAMLParser {
    private struct Line {
        var indent: Int
        var text: String
        var number: Int
    }

    private var lines: [Line] = []
    private var documents: [[Line]] = []
    private var pos = 0

    init(_ text: String) {
        var current: [Line] = []
        var raw = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if raw.first?.hasPrefix("\u{FEFF}") == true { raw[0].removeFirst() }
        for (n, line) in raw.enumerated() {
            if line.hasPrefix("---") && (line.count == 3 || line.dropFirst(3).first == " ") {
                if !current.isEmpty { documents.append(current) }
                current = []
                let rest = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty && !rest.hasPrefix("#") { current.append(Line(indent: 0, text: rest, number: n + 1)) }
                continue
            }
            if line.hasPrefix("...") { continue }
            current.append(Line(indent: line.prefix { $0 == " " }.count, text: line, number: n + 1))
        }
        documents.append(current)
    }

    mutating func parseStream() throws -> AttachmentPreviewValue {
        var values: [AttachmentPreviewValue] = []
        for doc in documents {
            lines = doc
            pos = 0
            skipBlank()
            if pos >= lines.count { continue }
            let v = try block(indent: lines[pos].indent)
            skipBlank()
            if pos < lines.count { throw fail("Unexpected content", lines[pos]) }
            values.append(v)
        }
        if values.isEmpty { return .null }
        return values.count == 1 ? values[0] : .array(values)
    }

    private func fail(_ m: String, _ line: Line) -> AttachmentPreviewParseError {
        AttachmentPreviewParseError(message: "\(m) at line \(line.number)")
    }

    private static func content(_ line: Line) -> String {
        stripComment(String(line.text.dropFirst(line.indent)))
    }

    private static func stripComment(_ s: String) -> String {
        var inSingle = false, inDouble = false
        var prev: Character = " "
        for (idx, c) in zip(s.indices, s) {
            if c == "'" && !inDouble { inSingle.toggle() }
            if c == "\"" && !inSingle && prev != "\\" { inDouble.toggle() }
            if c == "#" && !inSingle && !inDouble && (prev == " " || idx == s.startIndex) {
                return String(s[..<idx]).trimmingCharacters(in: .whitespaces)
            }
            prev = c
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private mutating func skipBlank() {
        while pos < lines.count, Self.content(lines[pos]).isEmpty { pos += 1 }
    }

    private mutating func block(indent: Int) throws -> AttachmentPreviewValue {
        skipBlank()
        guard pos < lines.count else { return .null }
        let first = Self.content(lines[pos])
        if first == "-" || first.hasPrefix("- ") { return try sequence(indent: indent) }
        if Self.splitKey(first) != nil { return try mapping(indent: indent) }
        let line = lines[pos]
        pos += 1
        return try Self.scalarOrFlow(first, line: line)
    }

    private mutating func sequence(indent: Int) throws -> AttachmentPreviewValue {
        var items: [AttachmentPreviewValue] = []
        while true {
            skipBlank()
            guard pos < lines.count, lines[pos].indent == indent else { break }
            let line = lines[pos]
            let c = Self.content(line)
            guard c == "-" || c.hasPrefix("- ") else { break }
            let rest = c == "-" ? "" : String(c.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                pos += 1
                skipBlank()
                if pos < lines.count, lines[pos].indent > indent { items.append(try block(indent: lines[pos].indent)) } else { items.append(.null) }
            } else if Self.splitKey(rest) != nil && !rest.hasPrefix("{") && !rest.hasPrefix("[") && !rest.hasPrefix("\"") && !rest.hasPrefix("'") {
                let inner = indent + 2 + (c.dropFirst(2).prefix { $0 == " " }.count)
                lines[pos] = Line(indent: inner, text: String(repeating: " ", count: inner) + rest, number: line.number)
                items.append(try mapping(indent: inner))
            } else if rest == "|" || rest == ">" || rest.hasPrefix("|") || rest.hasPrefix(">") {
                pos += 1
                items.append(.string(blockScalar(rest, parentIndent: indent)))
            } else {
                pos += 1
                items.append(try Self.scalarOrFlow(rest, line: line))
            }
        }
        return .array(items)
    }

    private mutating func mapping(indent: Int) throws -> AttachmentPreviewValue {
        var entries: [(String, AttachmentPreviewValue)] = []
        while true {
            skipBlank()
            guard pos < lines.count else { break }
            let line = lines[pos]
            if line.indent < indent { break }
            if line.indent > indent { throw fail("Bad indentation of a mapping entry", line) }
            let c = Self.content(line)
            guard let (key, rest) = Self.splitKey(c) else { break }
            pos += 1
            let value: AttachmentPreviewValue
            if rest.isEmpty {
                skipBlank()
                if pos < lines.count, lines[pos].indent > indent {
                    value = try block(indent: lines[pos].indent)
                } else if pos < lines.count, lines[pos].indent == indent, Self.content(lines[pos]).hasPrefix("- ") || Self.content(lines[pos]) == "-" {
                    value = try sequence(indent: indent)
                } else {
                    value = .null
                }
            } else if rest.hasPrefix("|") || rest.hasPrefix(">") {
                value = .string(blockScalar(rest, parentIndent: indent))
            } else {
                value = try Self.scalarOrFlow(rest, line: line)
            }
            if let i = entries.firstIndex(where: { $0.0 == key }) { entries[i].1 = value } else { entries.append((key, value)) }
        }
        return .object(entries)
    }

    private mutating func blockScalar(_ header: String, parentIndent: Int) -> String {
        let folded = header.hasPrefix(">")
        let keep = header.contains("+")
        let strip = header.contains("-")
        var collected: [String] = []
        var blockIndent: Int?
        while pos < lines.count {
            let line = lines[pos]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                collected.append("")
                pos += 1
                continue
            }
            if line.indent <= parentIndent { break }
            let bi = blockIndent ?? line.indent
            blockIndent = bi
            if line.indent < bi { break }
            collected.append(String(line.text.dropFirst(bi)))
            pos += 1
        }
        var trailing = 0
        while collected.last == "" {
            collected.removeLast()
            trailing += 1
        }
        var text: String
        if folded {
            text = ""
            for (i, l) in collected.enumerated() {
                if i > 0 { text += (l.isEmpty || collected[i - 1].isEmpty) ? "\n" : " " }
                text += l
            }
        } else {
            text = collected.joined(separator: "\n")
        }
        if strip { return text }
        return text + (keep ? String(repeating: "\n", count: trailing + 1) : "\n")
    }

    /// `key: value` → (key, value). Quoted keys allowed; the colon must be
    /// followed by a space or end the line.
    static func splitKey(_ s: String) -> (String, String)? {
        var inSingle = false, inDouble = false, depth = 0
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            if c == "'" && !inDouble { inSingle.toggle() }
            else if c == "\"" && !inSingle { inDouble.toggle() }
            else if !inSingle && !inDouble {
                if c == "{" || c == "[" { depth += 1 }
                if c == "}" || c == "]" { depth -= 1 }
                if c == ":" && depth == 0 {
                    let next = s.index(after: idx)
                    if next == s.endIndex || s[next] == " " {
                        var key = String(s[..<idx]).trimmingCharacters(in: .whitespaces)
                        if key.isEmpty || key.hasPrefix("- ") { return nil }
                        if (key.hasPrefix("\"") && key.hasSuffix("\"")) || (key.hasPrefix("'") && key.hasSuffix("'")), key.count >= 2 {
                            key = String(key.dropFirst().dropLast())
                        }
                        return (key, String(s[next...]).trimmingCharacters(in: .whitespaces))
                    }
                }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    private static func scalarOrFlow(_ s: String, line: Line) throws -> AttachmentPreviewValue {
        if s.hasPrefix("[") || s.hasPrefix("{") {
            var p = FlowParser(chars: Array(s))
            guard let v = p.value(), p.atEnd() else {
                throw AttachmentPreviewParseError(message: "Malformed flow collection at line \(line.number)")
            }
            return v
        }
        if s.hasPrefix("&") || s.hasPrefix("*") || s.hasPrefix("!") {
            throw AttachmentPreviewParseError(message: "Anchors, aliases and tags are not supported at line \(line.number)")
        }
        return scalar(s)
    }

    static func scalar(_ raw: String) -> AttachmentPreviewValue {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            let inner = String(s.dropFirst().dropLast())
            var parser = AttachmentPreviewJSONParser("\"" + inner + "\"")
            if let v = try? parser.parseDocument() { return v }
            return .string(inner)
        }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return .string(String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
        }
        switch s {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default: break
        }
        if s.range(of: #"^[-+]?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?$"#, options: .regularExpression) != nil, let d = Double(s) {
            return .number(d)
        }
        if s.hasPrefix("0x"), let v = Int(s.dropFirst(2), radix: 16) { return .number(Double(v)) }
        return .string(s)
    }

    private struct FlowParser {
        var chars: [Character]
        var i = 0

        mutating func ws() { while i < chars.count, chars[i] == " " { i += 1 } }
        mutating func atEnd() -> Bool { ws(); return i >= chars.count }

        mutating func value() -> AttachmentPreviewValue? {
            ws()
            guard i < chars.count else { return nil }
            if chars[i] == "[" {
                i += 1
                var items: [AttachmentPreviewValue] = []
                ws()
                if i < chars.count, chars[i] == "]" { i += 1; return .array(items) }
                while true {
                    guard let v = value() else { return nil }
                    items.append(v)
                    ws()
                    guard i < chars.count else { return nil }
                    if chars[i] == "," { i += 1; continue }
                    if chars[i] == "]" { i += 1; return .array(items) }
                    return nil
                }
            }
            if chars[i] == "{" {
                i += 1
                var entries: [(String, AttachmentPreviewValue)] = []
                ws()
                if i < chars.count, chars[i] == "}" { i += 1; return .object(entries) }
                while true {
                    ws()
                    let key = token(stops: [":", ",", "}"])
                    ws()
                    var v: AttachmentPreviewValue = .null
                    if i < chars.count, chars[i] == ":" {
                        i += 1
                        guard let parsed = value() else { return nil }
                        v = parsed
                    }
                    if case .string(let k) = AttachmentPreviewYAMLParser.scalar(key) { entries.append((k, v)) } else { entries.append((key, v)) }
                    ws()
                    guard i < chars.count else { return nil }
                    if chars[i] == "," { i += 1; continue }
                    if chars[i] == "}" { i += 1; return .object(entries) }
                    return nil
                }
            }
            let t = token(stops: [",", "]", "}"])
            return AttachmentPreviewYAMLParser.scalar(t)
        }

        mutating func token(stops: Set<Character>) -> String {
            var out = ""
            if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                let q = chars[i]
                out.append(q)
                i += 1
                while i < chars.count {
                    out.append(chars[i])
                    if chars[i] == q { i += 1; break }
                    i += 1
                }
                return out
            }
            while i < chars.count, !stops.contains(chars[i]) {
                out.append(chars[i])
                i += 1
            }
            return out.trimmingCharacters(in: .whitespaces)
        }
    }
}
