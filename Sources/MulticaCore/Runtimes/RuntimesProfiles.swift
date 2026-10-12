import Foundation

/// A row of the custom-runtime management dialog: built-in targets are
/// read-only references, custom profiles are editable.
public enum RuntimesCatalogEntry: Sendable, Hashable, Identifiable {
    case builtin(family: String)
    case custom(RuntimeProfile)

    public var id: String {
        switch self {
        case .builtin(let f): return "builtin:\(f)"
        case .custom(let p): return p.id
        }
    }

    public var protocolFamily: String {
        switch self {
        case .builtin(let f): return f
        case .custom(let p): return RuntimesProfileCatalog.runtimeType(of: p)
        }
    }

    public var isBuiltin: Bool {
        if case .builtin = self { return true }
        return false
    }
}

public enum RuntimesCommandLineError: String, Sendable, Hashable, Error {
    case empty
    case unclosedQuote = "unclosed_quote"
    case trailingEscape = "trailing_escape"
    case shellSyntax = "shell_syntax"
    case shellExpansion = "shell_expansion"
}

public struct RuntimesParsedCommand: Sendable, Hashable {
    public var commandName: String
    public var fixedArgs: [String]
}

public enum RuntimesProfileField: String, Sendable, Hashable {
    case displayName, commandLine
}

/// Custom runtime profile helpers (upstream `runtime-profile-catalog.ts`).
public enum RuntimesProfileCatalog {
    /// Base protocol families a custom runtime can wrap (server allow-list).
    public static let protocolFamilies = [
        "claude", "codebuddy", "codex", "copilot", "opencode", "codearts", "deveco", "openclaw", "hermes", "pi",
        "cursor", "kimi", "reasonix", "dsh", "dim", "kiro", "antigravity", "qoder", "qoderclicn", "traecli",
        "grok", "qwen", "qwenpaw", "mcode", "zeroclaw",
    ]

    public static let runtimeTypes = protocolFamilies + ["omp"]

    static let labels = ["omp": "Oh-My-Pi"]

    /// What the user reads for a runtime target (rendered capitalized).
    public static func label(_ runtimeType: String) -> String {
        labels[runtimeType] ?? runtimeType
    }

    /// The target a profile was created against (older profiles only carry
    /// a protocol family).
    public static func runtimeType(of profile: RuntimeProfile) -> String {
        if let t = profile.runtimeType, !t.isEmpty { return t }
        return profile.protocolFamily
    }

    /// Custom profiles (enabled first, newest first, then by name) and the
    /// built-in reference families.
    public static func build(_ profiles: [RuntimeProfile]) -> (customs: [RuntimesCatalogEntry], builtins: [RuntimesCatalogEntry]) {
        let customs = profiles.sorted { a, b in
            if a.enabled != b.enabled { return a.enabled }
            let at = Timestamp.parse(a.updatedAt)?.timeIntervalSince1970 ?? 0
            let bt = Timestamp.parse(b.updatedAt)?.timeIntervalSince1970 ?? 0
            if at != bt { return at > bt }
            return a.displayName.compare(b.displayName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedAscending
        }
        return (customs.map(RuntimesCatalogEntry.custom), runtimeTypes.map { .builtin(family: $0) })
    }

    static let shellControl: Set<Character> = ["|", ">", "<", ";", "&"]

    /// Splits a pasted command into executable + fixed args with POSIX-like
    /// quoting, refusing shell syntax the daemon would not interpret.
    public static func parse(_ input: String) -> Result<RuntimesParsedCommand, RuntimesCommandLineError> {
        let line = Array(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !line.isEmpty else { return .failure(.empty) }
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        var started = false
        var i = 0
        while i < line.count {
            let ch = line[i]
            let next: Character? = i + 1 < line.count ? line[i + 1] : nil
            if quote == nil {
                if ch.isWhitespace {
                    if started { tokens.append(token); token = ""; started = false }
                } else if ch == "`" {
                    return .failure(.shellSyntax)
                } else if ch == "$" {
                    return .failure(.shellExpansion)
                } else if shellControl.contains(ch) {
                    return .failure(.shellSyntax)
                } else if ch == "\\" {
                    guard let next else { return .failure(.trailingEscape) }
                    token.append(next)
                    started = true
                    i += 1
                } else if ch == "'" || ch == "\"" {
                    quote = ch
                    started = true
                } else {
                    token.append(ch)
                    started = true
                }
            } else if ch == quote {
                quote = nil
                started = true
            } else if quote == "\"" && ch == "\\" {
                guard let next else { return .failure(.trailingEscape) }
                token.append(next)
                started = true
                i += 1
            } else if quote != "'" && (ch == "`" || ch == "$") {
                return .failure(ch == "$" ? .shellExpansion : .shellSyntax)
            } else {
                token.append(ch)
                started = true
            }
            i += 1
        }
        if quote != nil { return .failure(.unclosedQuote) }
        if started { tokens.append(token) }
        guard let first = tokens.first, !first.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(.empty) }
        return .success(RuntimesParsedCommand(commandName: first, fixedArgs: Array(tokens.dropFirst())))
    }

    public static func format(commandName: String, fixedArgs: [String]) -> String {
        ([commandName] + fixedArgs).filter { !$0.isEmpty }.map(quote).joined(separator: " ")
    }

    static func quote(_ arg: String) -> String {
        if arg.isEmpty { return "\"\"" }
        let needs = arg.contains { $0.isWhitespace || "\"'\\|<>;&`$".contains($0) }
        guard needs else { return arg }
        var escaped = ""
        for ch in arg {
            if "\"\\$`".contains(ch) { escaped.append("\\") }
            escaped.append(ch)
        }
        return "\"\(escaped)\""
    }

    public static func validate(displayName: String, commandLine: String) -> [RuntimesProfileField] {
        var errors: [RuntimesProfileField] = []
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append(.displayName) }
        if commandLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append(.commandLine) }
        return errors
    }
}
