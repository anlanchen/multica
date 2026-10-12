import Foundation

/// Block structure of a Markdown document (GFM subset used by Multica:
/// headings, paragraphs, bullet/ordered/task lists, fenced code, quotes,
/// tables, rules, images). Inline formatting inside each block is left as
/// Markdown source for the platform's inline parser.
public enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case code(language: String?, code: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
    case image(alt: String, url: String)
}

public struct MarkdownListItem: Hashable, Sendable {
    public var text: String
    /// nil for plain items, true/false for `- [x]` / `- [ ]`.
    public var checked: Bool?
    public var indent: Int
}

public enum MarkdownBlocks {
    private static let cache = Locked<[Int: [MarkdownBlock]]>([:])

    /// Memoised parse (documents are re-rendered far more often than edited).
    public static func cachedParse(_ source: String) -> [MarkdownBlock] {
        let key = source.hashValue
        if let hit = cache.current[key] { return hit }
        let blocks = parse(source)
        cache.withLock { c in
            if c.count > 1500 { c.removeAll(keepingCapacity: true) }
            c[key] = blocks
        }
        return blocks
    }

    public static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if let img = standaloneImage(text) { blocks.append(img) } else { blocks.append(.paragraph(text)) }
            }
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: lang.isEmpty ? nil : lang, code: code.joined(separator: "\n")))
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Heading.
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6, trimmed.dropFirst(level).first == " " {
                    flushParagraph()
                    blocks.append(.heading(level: level, text: trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)))
                    i += 1
                    continue
                }
            }

            // Thematic break.
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // Quote.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var rest = t.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            // Table: header row, delimiter row.
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|") else { break }
                    var r = cells(t)
                    if r.count < header.count { r += Array(repeating: "", count: header.count - r.count) }
                    rows.append(Array(r.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // Lists.
            if let first = listMarker(line) {
                flushParagraph()
                var items: [MarkdownListItem] = []
                let ordered = first.ordered
                while i < lines.count {
                    if let m = listMarker(lines[i]), m.ordered == ordered || m.indent > 0 {
                        var text = m.text
                        var checked: Bool?
                        if text.hasPrefix("[ ] ") { checked = false; text.removeFirst(4) }
                        else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { checked = true; text.removeFirst(4) }
                        items.append(MarkdownListItem(text: text, checked: checked, indent: m.indent))
                        i += 1
                    } else if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                              lines[i].hasPrefix("  "), !items.isEmpty {
                        // Lazy continuation of the previous item.
                        items[items.count - 1].text += "\n" + lines[i].trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(ordered: ordered, start: first.number, items: items))
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func isRule(_ t: String) -> Bool {
        let chars = t.filter { $0 != " " }
        guard chars.count >= 3, let c = chars.first, "-*_".contains(c) else { return false }
        return chars.allSatisfy { $0 == c }
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var t = row
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private struct Marker {
        var ordered: Bool
        var number: Int
        var indent: Int
        var text: String
    }

    private static func listMarker(_ line: String) -> Marker? {
        let spaces = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let t = line.drop(while: { $0 == " " || $0 == "\t" })
        if let c = t.first, "-*+".contains(c), t.dropFirst().first == " " {
            return Marker(ordered: false, number: 1, indent: spaces / 2, text: String(t.dropFirst(2)))
        }
        let digits = t.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count < 10 {
            let rest = t.dropFirst(digits.count)
            if let d = rest.first, d == "." || d == ")", rest.dropFirst().first == " " {
                return Marker(ordered: true, number: Int(digits) ?? 1, indent: spaces / 2, text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    private static func standaloneImage(_ text: String) -> MarkdownBlock? {
        guard text.hasPrefix("!["), text.hasSuffix(")"), !text.contains("\n"),
              let close = text.range(of: "]("), text.filter({ $0 == "(" }).count == 1 else { return nil }
        let alt = String(text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound])
        let url = String(text[close.upperBound..<text.index(before: text.endIndex)])
        return .image(alt: alt, url: url.split(separator: " ").first.map(String.init) ?? url)
    }

    /// Mention links in Multica Markdown: `[@Name](mention://member/<id>)`.
    public struct Mention: Hashable, Sendable {
        public var type: String
        public var id: String
        public var label: String
    }

    public static func mentions(in source: String) -> [Mention] {
        var out: [Mention] = []
        var rest = Substring(source)
        while let open = rest.range(of: "](mention://") {
            guard let labelStart = rest[..<open.lowerBound].lastIndex(of: "[") else { rest = rest[open.upperBound...]; continue }
            let label = String(rest[rest.index(after: labelStart)..<open.lowerBound])
            let after = rest[open.upperBound...]
            guard let close = after.firstIndex(of: ")") else { break }
            let parts = after[..<close].split(separator: "/", maxSplits: 1)
            if parts.count == 2 {
                out.append(Mention(type: String(parts[0]), id: String(parts[1]), label: label.hasPrefix("@") ? String(label.dropFirst()) : label))
            }
            rest = after[after.index(after: close)...]
        }
        return out
    }
}
