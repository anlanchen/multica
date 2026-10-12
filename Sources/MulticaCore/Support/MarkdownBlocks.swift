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
    /// `!file[name](url)` on its own line (upstream file-card syntax).
    case fileCard(name: String, url: String)
    /// `$$ … $$` display math.
    case math(String)
    /// A closed ```mermaid / ```html fence (upstream upgrades only closed
    /// fences, so a half-streamed diagram stays readable source).
    case richFence(kind: String, code: String, title: String?)
}

public struct MarkdownListItem: Hashable, Sendable {
    public var text: String
    /// nil for plain items, true/false for `- [x]` / `- [ ]`.
    public var checked: Bool?
    public var indent: Int
}

public enum MarkdownBlocks {
    private static let cache = Locked<[Int: [MarkdownBlock]]>([:])

    /// Host of the deployment's file CDN (`AppConfig.cdn_domain`); lines of
    /// the legacy form `[name](https://cdn/…)` pointing there render as file
    /// cards.
    public static var cdnDomain: String {
        get { cdn.current }
        set { cdn.withLock { $0 = newValue } }
    }
    private static let cdn = Locked("")

    /// Memoised preprocess + parse (documents are re-rendered far more often
    /// than edited).
    public static func cachedParse(_ source: String) -> [MarkdownBlock] {
        let key = source.hashValue
        if let hit = cache.current[key] { return hit }
        let blocks = parse(MarkdownPreprocess.apply(source))
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
                let info = fenceInfo(String(trimmed.dropFirst(3)))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                let closed = i < lines.count
                let body = code.joined(separator: "\n")
                if closed, let lang = info.language?.lowercased(), lang == "mermaid" || lang == "html" {
                    blocks.append(.richFence(kind: lang, code: body, title: info.title))
                } else {
                    blocks.append(.code(language: info.language, code: body))
                }
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            if let card = fileCard(trimmed) {
                flushParagraph()
                blocks.append(card)
                i += 1
                continue
            }

            // Display math.
            if trimmed.hasPrefix("$$") {
                if trimmed.count > 4, trimmed.hasSuffix("$$") {
                    flushParagraph()
                    blocks.append(.math(String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)))
                    i += 1
                    continue
                }
                if trimmed == "$$", let end = lines[(i + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "$$" }) {
                    flushParagraph()
                    blocks.append(.math(lines[(i + 1)..<end].joined(separator: "\n")))
                    i = end + 1
                    continue
                }
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

    /// Fence info string: language is the first token, `title="…"` optional.
    static func fenceInfo(_ raw: String) -> (language: String?, title: String?) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        let lang = t.prefix { !$0.isWhitespace && $0 != "{" }
        var title: String?
        if let r = t.range(of: "title=\"") {
            let rest = t[r.upperBound...]
            if let close = rest.firstIndex(of: "\"") { title = String(rest[..<close]) }
        }
        return (lang.isEmpty ? nil : String(lang), title)
    }

    /// `!file[name](url)`, or the legacy `[name](https://<cdn>/…)` line for a
    /// non-image file on the configured CDN.
    static func fileCard(_ line: String) -> MarkdownBlock? {
        if line.hasPrefix("!file["), line.hasSuffix(")"), let close = labelEnd(line, from: line.index(line.startIndex, offsetBy: 5)) {
            let after = line.index(after: close)
            guard after < line.endIndex, line[after] == "(" else { return nil }
            let url = String(line[line.index(after: after)..<line.index(before: line.endIndex)])
            guard isFileCardURL(url) else { return nil }
            let rawName = String(line[line.index(line.startIndex, offsetBy: 6)..<close])
            return .fileCard(name: unescapeLabel(rawName), url: url)
        }
        let cdn = cdnDomain
        if !cdn.isEmpty, line.hasPrefix("["), line.hasSuffix(")"), !line.contains("\n"),
           let mid = line.range(of: "]("), !line[..<mid.lowerBound].dropFirst().contains("]") {
            let url = String(line[mid.upperBound..<line.index(before: line.endIndex)])
            guard url.hasPrefix("http"), let host = URL(string: url)?.host,
                  host == cdn || host.hasSuffix(".amazonaws.com") else { return nil }
            let ext = (URL(string: url)?.pathExtension ?? "").lowercased()
            guard !["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "tif", "tiff"].contains(ext) else { return nil }
            return .fileCard(name: String(line[line.index(after: line.startIndex)..<mid.lowerBound]), url: url)
        }
        return nil
    }

    /// Upstream `FILE_CARD_URL_PATTERN` / `isAllowedFileCardHref`.
    public static func isFileCardURL(_ url: String) -> Bool {
        if url.hasPrefix("/uploads/") || url.hasPrefix("http://") || url.hasPrefix("https://") { return !url.contains(")") }
        return attachmentID(fromDownloadURL: url) != nil
    }

    /// The attachment id of a stable `/api/attachments/<uuid>/download` URL
    /// (relative or absolute).
    public static func attachmentID(fromDownloadURL url: String) -> String? {
        guard let r = url.range(of: "/api/attachments/") else { return nil }
        let rest = url[r.upperBound...]
        guard let slash = rest.firstIndex(of: "/"), rest[slash...].hasPrefix("/download") else { return nil }
        let id = String(rest[..<slash])
        guard id.count == 36, UUID(uuidString: id) != nil else { return nil }
        let tail = rest[slash...].dropFirst("/download".count)
        return tail.isEmpty || tail.first == "?" ? id : nil
    }

    private static func labelEnd(_ s: String, from open: String.Index) -> String.Index? {
        var i = s.index(after: open)
        var escaped = false
        while i < s.endIndex {
            let c = s[i]
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "]" { return i }
            i = s.index(after: i)
        }
        return nil
    }

    private static func unescapeLabel(_ s: String) -> String {
        var out = ""
        var escaped = false
        for c in s {
            if escaped {
                if !"[]\\()".contains(c) { out.append("\\") }
                out.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        if escaped { out.append("\\") }
        return out
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
