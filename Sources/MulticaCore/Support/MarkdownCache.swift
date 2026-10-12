import Foundation

/// Parses comment and description Markdown off the main thread and memoises
/// the result by content.
///
/// Upstream mounted a ProseMirror/TipTap editor per comment and parsed long
/// Markdown on the renderer thread (`parseMarkdownChunked` appears in its hang
/// reports, MUL-5345), and auto-detected the language of every unlabelled code
/// fence by running every grammar over it. Here Markdown becomes an
/// `AttributedString` once, in the background, and the view renders it as
/// text; unlabelled code stays plain.
public final class MarkdownCache: @unchecked Sendable {
    public static let shared = MarkdownCache()

    private let cache = Locked<[Int: AttributedString]>([:])
    private let order = Locked<[Int]>([])
    private let capacity: Int

    public init(capacity: Int = 2000) {
        self.capacity = capacity
    }

    public func cached(_ markdown: String) -> AttributedString? {
        cache.current[markdown.hashValue]
    }

    /// Returns the rendered text, parsing on a background executor on a miss.
    public func render(_ markdown: String) async -> AttributedString {
        let key = markdown.hashValue
        if let hit = cache.current[key] { return hit }
        let parsed = await Task.detached(priority: .userInitiated) { MarkdownCache.parse(markdown) }.value
        store(key, parsed)
        return parsed
    }

    public static func parse(_ markdown: String) -> AttributedString {
        #if canImport(Darwin)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        #else
        // swift-corelibs-foundation has no Markdown parser; non-Darwin builds
        // (tests, tooling) render the source text.
        return AttributedString(markdown)
        #endif
    }

    private func store(_ key: Int, _ value: AttributedString) {
        cache.withLock { $0[key] = value }
        let evict: Int? = order.withLock { o in
            o.append(key)
            return o.count > capacity ? o.removeFirst() : nil
        }
        if let evict { cache.withLock { $0[evict] = nil } }
    }
}
