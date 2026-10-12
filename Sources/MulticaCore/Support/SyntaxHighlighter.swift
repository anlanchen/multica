import Foundation

/// A small lexer for code fences with a language label (upstream highlights
/// labelled fences with highlight.js and leaves unlabelled ones plain).
/// Produces token ranges; the UI maps kinds to colors.
public enum SyntaxHighlighter {
    public enum Kind: Sendable, Hashable {
        case keyword, string, comment, number, type, attribute, inserted, deleted, meta
    }

    public struct Token: Sendable, Hashable {
        public var range: Range<Int>   // UTF-16 offsets
        public var kind: Kind
    }

    struct Grammar {
        var keywords: Set<String>
        var lineComments: [String]
        var blockComment: (String, String)?
        var stringQuotes: Set<Character>
        var typesCapitalized = true
        var hashComment: Bool { lineComments.contains("#") }
    }

    private static let cStyle = ["//"]

    static func grammar(_ language: String) -> Grammar? {
        switch language.lowercased() {
        case "swift":
            return Grammar(keywords: ["let", "var", "func", "if", "else", "guard", "return", "for", "in", "while", "switch", "case", "default", "struct", "class", "enum", "protocol", "extension", "import", "public", "private", "fileprivate", "internal", "static", "self", "Self", "true", "false", "nil", "try", "await", "async", "throws", "throw", "do", "catch", "init", "deinit", "where", "some", "any", "actor", "inout", "defer", "break", "continue", "is", "as", "final", "override", "mutating", "lazy", "weak", "unowned", "typealias", "associatedtype", "subscript", "operator", "repeat"], lineComments: cStyle, blockComment: ("/*", "*/"), stringQuotes: ["\""])
        case "js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs":
            return Grammar(keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "this", "class", "extends", "super", "import", "export", "from", "as", "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "true", "false", "null", "undefined", "void", "yield", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "static", "declare", "namespace", "keyof", "satisfies"], lineComments: cStyle, blockComment: ("/*", "*/"), stringQuotes: ["\"", "'", "`"])
        case "py", "python":
            return Grammar(keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "None", "True", "False", "self", "async", "await", "global", "nonlocal", "del", "assert"], lineComments: ["#"], blockComment: nil, stringQuotes: ["\"", "'"])
        case "go", "golang":
            return Grammar(keywords: ["package", "import", "func", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "go", "defer", "chan", "select", "struct", "interface", "map", "type", "var", "const", "nil", "true", "false", "fallthrough", "goto"], lineComments: cStyle, blockComment: ("/*", "*/"), stringQuotes: ["\"", "`", "'"])
        case "rs", "rust":
            return Grammar(keywords: ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "crate", "self", "Self", "super", "return", "if", "else", "match", "for", "in", "while", "loop", "break", "continue", "as", "ref", "move", "where", "async", "await", "dyn", "true", "false", "const", "static", "unsafe", "type"], lineComments: cStyle, blockComment: ("/*", "*/"), stringQuotes: ["\""])
        case "java", "kotlin", "kt", "c", "h", "cpp", "cc", "c++", "hpp", "cs", "csharp", "scala", "dart":
            return Grammar(keywords: ["class", "interface", "enum", "struct", "public", "private", "protected", "static", "final", "void", "int", "long", "float", "double", "char", "bool", "boolean", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "this", "super", "import", "package", "namespace", "using", "try", "catch", "finally", "throw", "throws", "true", "false", "null", "nullptr", "const", "auto", "val", "var", "fun", "override", "virtual", "template", "typename", "include", "define", "sizeof", "extends", "implements", "when", "object", "data"], lineComments: cStyle, blockComment: ("/*", "*/"), stringQuotes: ["\"", "'"])
        case "rb", "ruby":
            return Grammar(keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do", "return", "yield", "begin", "rescue", "ensure", "raise", "nil", "true", "false", "self", "require", "attr_accessor", "and", "or", "not", "then", "case", "when"], lineComments: ["#"], blockComment: nil, stringQuotes: ["\"", "'"])
        case "php":
            return Grammar(keywords: ["function", "return", "if", "else", "elseif", "foreach", "for", "while", "class", "public", "private", "protected", "static", "new", "echo", "namespace", "use", "true", "false", "null", "array", "as", "try", "catch", "throw"], lineComments: ["//", "#"], blockComment: ("/*", "*/"), stringQuotes: ["\"", "'"])
        case "sh", "bash", "zsh", "shell", "console", "shellscript":
            return Grammar(keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "export", "local", "echo", "cd", "set", "unset", "source", "exit", "sudo"], lineComments: ["#"], blockComment: nil, stringQuotes: ["\"", "'"], typesCapitalized: false)
        case "sql":
            return Grammar(keywords: Set(["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "alter", "drop", "index", "join", "left", "right", "inner", "outer", "on", "and", "or", "not", "null", "is", "as", "order", "by", "group", "having", "limit", "offset", "primary", "key", "references", "default", "returning", "with", "distinct", "union", "case", "when", "then", "else", "end", "in", "exists", "like"].flatMap { [$0, $0.uppercased()] }), lineComments: ["--"], blockComment: ("/*", "*/"), stringQuotes: ["'", "\""], typesCapitalized: false)
        case "json", "jsonc":
            return Grammar(keywords: ["true", "false", "null"], lineComments: [], blockComment: nil, stringQuotes: ["\""], typesCapitalized: false)
        case "yaml", "yml", "toml", "ini":
            return Grammar(keywords: ["true", "false", "null", "yes", "no", "on", "off"], lineComments: ["#"], blockComment: nil, stringQuotes: ["\"", "'"], typesCapitalized: false)
        case "css", "scss", "less":
            return Grammar(keywords: ["important", "media", "import", "from", "to"], lineComments: [], blockComment: ("/*", "*/"), stringQuotes: ["\"", "'"], typesCapitalized: false)
        case "html", "xml", "svg", "vue":
            return Grammar(keywords: [], lineComments: [], blockComment: ("<!--", "-->"), stringQuotes: ["\"", "'"], typesCapitalized: false)
        default:
            return nil
        }
    }

    /// Tokens for `code`; empty for unknown languages (rendered plain).
    public static func tokens(_ code: String, language: String?) -> [Token] {
        guard let language else { return [] }
        let lang = language.lowercased()
        if lang == "diff" || lang == "patch" { return diffTokens(code) }
        guard let g = grammar(lang) else { return [] }
        let chars = Array(code.utf16)
        var out: [Token] = []
        var i = 0
        let n = chars.count

        func starts(_ s: String, at p: Int) -> Bool {
            let u = Array(s.utf16)
            guard p + u.count <= n else { return false }
            for k in 0..<u.count where chars[p + k] != u[k] { return false }
            return true
        }
        func isIdent(_ c: UInt16) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36
        }

        while i < n {
            let c = chars[i]
            // Line comments.
            if let lc = g.lineComments.first(where: { starts($0, at: i) }) {
                // "#" only starts a comment at line start or after whitespace (not in `#include`-free grammars it's fine).
                _ = lc
                var j = i
                while j < n && chars[j] != 10 { j += 1 }
                out.append(Token(range: i..<j, kind: .comment))
                i = j
                continue
            }
            if let (open, close) = g.blockComment, starts(open, at: i) {
                var j = i + open.utf16.count
                while j < n && !starts(close, at: j) { j += 1 }
                j = min(n, j + close.utf16.count)
                out.append(Token(range: i..<j, kind: .comment))
                i = j
                continue
            }
            if let ch = Unicode.Scalar(c).map(Character.init), g.stringQuotes.contains(ch) {
                var j = i + 1
                while j < n && chars[j] != c {
                    if chars[j] == 92 { j += 1 } // backslash escape
                    if chars[j < n ? j : n - 1] == 10 && ch != "`" { break }
                    j += 1
                }
                j = min(n, j + 1)
                out.append(Token(range: i..<j, kind: .string))
                i = j
                continue
            }
            if c >= 48 && c <= 57 && (i == 0 || !isIdent(chars[i - 1])) {
                var j = i
                while j < n && (isIdent(chars[j]) || chars[j] == 46) { j += 1 }
                out.append(Token(range: i..<j, kind: .number))
                i = j
                continue
            }
            if c == 64 && i + 1 < n && isIdent(chars[i + 1]) { // @attribute / decorator
                var j = i + 1
                while j < n && isIdent(chars[j]) { j += 1 }
                out.append(Token(range: i..<j, kind: .attribute))
                i = j
                continue
            }
            if isIdent(c) {
                var j = i
                while j < n && isIdent(chars[j]) { j += 1 }
                let word = String(utf16CodeUnits: Array(chars[i..<j]), count: j - i)
                if g.keywords.contains(word) {
                    out.append(Token(range: i..<j, kind: .keyword))
                } else if g.typesCapitalized, let f = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(f) {
                    out.append(Token(range: i..<j, kind: .type))
                }
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    static func diffTokens(_ code: String) -> [Token] {
        var out: [Token] = []
        var offset = 0
        for line in code.components(separatedBy: "\n") {
            let len = line.utf16.count
            if line.hasPrefix("+") && !line.hasPrefix("+++") { out.append(Token(range: offset..<(offset + len), kind: .inserted)) }
            else if line.hasPrefix("-") && !line.hasPrefix("---") { out.append(Token(range: offset..<(offset + len), kind: .deleted)) }
            else if line.hasPrefix("@@") || line.hasPrefix("diff ") || line.hasPrefix("+++") || line.hasPrefix("---") { out.append(Token(range: offset..<(offset + len), kind: .meta)) }
            offset += len + 1
        }
        return out
    }
}
