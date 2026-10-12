import Foundation

/// Localized UI strings, read from the upstream app's i18next catalogs
/// (packages/views/locales/<lang>/<namespace>.json) so every label matches the
/// official client word for word, in all five shipped languages.
///
///     L10n.shared.t("layout", "nav.inbox")                     // "Inbox" / "收件箱"
///     L10n.shared.t("agents", "list.agent_count", ["count": 3]) // plural-aware
public final class L10n: @unchecked Sendable {
    public static let shared = L10n()

    public static let supported = ["en", "zh-Hans", "ja", "ko", "fr"]

    public struct Language: Hashable, Sendable, Identifiable {
        public var id: String
        public var nativeName: String
    }

    public static let languages: [Language] = [
        Language(id: "en", nativeName: "English"),
        Language(id: "zh-Hans", nativeName: "简体中文"),
        Language(id: "ja", nativeName: "日本語"),
        Language(id: "ko", nativeName: "한국어"),
        Language(id: "fr", nativeName: "Français"),
    ]

    private let state = Locked<(language: String, cache: [String: [String: JSONValue]])>(("en", [:]))
    private let root: URL?

    public convenience init() {
        self.init(root: L10n.bundledRoot)
    }

    public init(root: URL?) {
        self.root = root
        state.withLock { $0.language = L10n.resolve(Locale.preferredLanguages) }
    }

    public var language: String { state.current.language }

    /// Finds the resource bundle without tripping `Bundle.module`'s
    /// fatalError: a packaged .app carries it in Contents/Resources, a
    /// development build next to the executable.
    static var bundledRoot: URL? {
        let name = "MulticaNative_MulticaCore.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ]
        for case let base? in candidates {
            let url = base.appendingPathComponent(name)
            if let b = Bundle(url: url), let locales = b.url(forResource: "Locales", withExtension: nil) {
                return locales
            }
        }
        return Bundle.module.url(forResource: "Locales", withExtension: nil)
    }

    /// Sets the UI language. `nil` (or an unsupported code) follows the system.
    public func setLanguage(_ code: String?) {
        let resolved = code.flatMap { L10n.normalize($0) } ?? L10n.resolve(Locale.preferredLanguages)
        state.withLock { $0.language = resolved }
    }

    /// Maps "zh", "zh-CN", "zh-Hans-CN" → "zh-Hans", "ja-JP" → "ja", etc.
    public static func normalize(_ code: String) -> String? {
        let lower = code.lowercased()
        if lower.hasPrefix("zh") { return "zh-Hans" }
        for lang in ["en", "ja", "ko", "fr"] where lower == lang || lower.hasPrefix(lang + "-") || lower.hasPrefix(lang + "_") {
            return lang
        }
        return nil
    }

    static func resolve(_ preferred: [String]) -> String {
        for p in preferred {
            if let n = normalize(p) { return n }
        }
        return "en"
    }

    private func catalog(_ lang: String, _ ns: String) -> [String: JSONValue] {
        let key = "\(lang)/\(ns)"
        if let hit = state.current.cache[key] { return hit }
        var loaded: [String: JSONValue] = [:]
        if let root,
           let data = try? Data(contentsOf: root.appendingPathComponent(lang).appendingPathComponent("\(ns).json")),
           case .object(let obj)? = try? JSONCoders.decoder.decode(JSONValue.self, from: data) {
            loaded = obj
        }
        state.withLock { $0.cache[key] = loaded }
        return loaded
    }

    private func lookup(_ lang: String, _ ns: String, _ path: [Substring]) -> String? {
        var node: JSONValue = .object(catalog(lang, ns))
        for part in path {
            guard let next = node[String(part)] else { return nil }
            node = next
        }
        if case .string(let s) = node { return s }
        return nil
    }

    /// i18next plural category for `count` in `lang`.
    static func pluralSuffix(_ lang: String, _ count: Int) -> String {
        switch lang {
        case "zh-Hans", "ja", "ko": return "other"
        case "fr": return (count == 0 || count == 1) ? "one" : "other"
        default: return count == 1 ? "one" : "other"
        }
    }

    /// Looks up `key` (dotted path) in namespace `ns`, falling back to English
    /// and finally to the key itself. `{{name}}` placeholders are filled from
    /// `args`; a numeric `count` selects the `_one` / `_other` form.
    public func t(_ ns: String, _ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
        let lang = language
        var path = key.split(separator: ".")
        var template: String?
        if let count = (args["count"] as? Int) ?? (args["count"] as? Double).map({ Int($0) }), let last = path.last {
            for l in [lang, "en"] {
                for suffix in [L10n.pluralSuffix(l, count), "other"] {
                    path[path.count - 1] = Substring("\(last)_\(suffix)")
                    if let s = lookup(l, ns, path) {
                        template = s
                        break
                    }
                }
                if template != nil { break }
            }
            path[path.count - 1] = last
        }
        if template == nil {
            template = lookup(lang, ns, path) ?? lookup("en", ns, path)
        }
        guard var s = template else { return key }
        for (k, v) in args {
            s = s.replacingOccurrences(of: "{{\(k)}}", with: v.description)
        }
        return s
    }
}

/// Shorthand used by views: `tr("layout", "nav.inbox")`.
public func tr(_ ns: String, _ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
    L10n.shared.t(ns, key, args)
}
