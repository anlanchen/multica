import AppKit
import MulticaCore
import SwiftUI

/// Renders Multica Markdown natively: block structure from
/// `MarkdownBlocks`, inline formatting from Foundation's parser. Mention
/// links (`mention://issue/<id>`, `mention://agent/<id>`, ...) navigate
/// inside the app; web links open in the browser.
struct MarkdownView: View {
    let source: String
    var font: Font = Theme.Font.body
    var compact = false

    var body: some View {
        let blocks = MarkdownBlocks.cachedParse(source)
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, font: font)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .modifier(MentionLinkHandler())
    }
}

/// Inline Markdown → AttributedString, memoised.
enum InlineMarkdown {
    @MainActor private static var cache: [String: AttributedString] = [:]

    @MainActor static func render(_ s: String) -> AttributedString {
        if let hit = cache[s] { return hit }
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var a = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        for run in a.runs {
            guard let url = run.link, url.scheme == "mention" else { continue }
            a[run.range].foregroundColor = Theme.brand
            a[run.range].backgroundColor = Theme.brand.opacity(0.08)
        }
        if cache.count > 3000 { cache.removeAll() }
        cache[s] = a
        return a
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let font: Font

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(InlineMarkdown.render(text))
                .font(.system(size: level == 1 ? 20 : level == 2 ? 17 : 15, weight: .semibold))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            Text(InlineMarkdown.render(text)).font(font).fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(checked ? Theme.brand : .secondary)
                            } else if ordered {
                                Text("\(start + i).").monospacedDigit().foregroundStyle(.secondary)
                            } else {
                                Text("•").foregroundStyle(.secondary)
                            }
                        }
                        .frame(minWidth: 14, alignment: .trailing)
                        Text(InlineMarkdown.render(item.text))
                            .strikethrough(item.checked == true, color: .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
            .font(font)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                MarkdownView(source: text, font: font, compact: true).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                            Text(InlineMarkdown.render(h)).font(Theme.Font.bodyMedium).padding(6)
                        }
                    }
                    .background(Color.primary.opacity(0.04))
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        Divider()
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(InlineMarkdown.render(cell)).font(font).padding(6)
                            }
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
            }
        case .rule:
            Divider().padding(.vertical, 4)
        case .image(let alt, let url):
            RemoteImage(url: ImageLoader.resolve(url)) {
                RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.05))
                    .frame(height: 120)
                    .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            }
            .scaledToFit()
            .frame(maxWidth: 560, maxHeight: 420, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .accessibilityLabel(alt)
        }
    }
}

struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? tr("ui", "plain_text")).font(Theme.Font.micro).foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: code).buttonStyle(.borderless).controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeHighlight.render(code, language: language))
                    .font(Theme.Font.mono)
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.045)))
    }
}

/// Routes `mention://` links to in-app navigation.
private struct MentionLinkHandler: ViewModifier {
    @Environment(Navigator.self) private var nav: Navigator?

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "mention" else { return .systemAction }
            let type = url.host() ?? ""
            let id = url.pathComponents.dropFirst().first ?? ""
            guard let nav, !id.isEmpty else { return .discarded }
            switch type {
            case "issue": nav.push(.issue(id))
            case "agent": nav.push(.agent(id))
            case "member": nav.push(.member(id))
            case "squad": nav.push(.squad(id))
            case "project": nav.push(.project(id))
            default: return .discarded
            }
            return .handled
        })
    }
}

/// Collapsible long text (upstream ExpandableDescription).
struct ExpandableMarkdown: View {
    let source: String
    var collapsedHeight: CGFloat = 160
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownView(source: source)
                .frame(maxHeight: expanded ? nil : collapsedHeight, alignment: .top)
                .clipped()
            if source.count > 600 {
                Button(expanded ? tr("common", "expandable_description.collapse") : tr("common", "expandable_description.expand")) {
                    expanded.toggle()
                }
                .buttonStyle(.link)
                .font(Theme.Font.caption)
            }
        }
    }
}

/// Colors `SyntaxHighlighter` tokens (memoised per code + language).
enum CodeHighlight {
    @MainActor private static var cache: [String: AttributedString] = [:]

    @MainActor static func render(_ code: String, language: String?) -> AttributedString {
        let key = (language ?? "") + "\u{0}" + code
        if let hit = cache[key] { return hit }
        var a = AttributedString(code)
        let tokens = SyntaxHighlighter.tokens(code, language: language)
        if !tokens.isEmpty {
            let utf16 = code.utf16
            for t in tokens {
                guard let lo = utf16.index(utf16.startIndex, offsetBy: t.range.lowerBound, limitedBy: utf16.endIndex),
                      let hi = utf16.index(utf16.startIndex, offsetBy: t.range.upperBound, limitedBy: utf16.endIndex),
                      let r = Range(NSRange(lo..<hi, in: code), in: a) else { continue }
                switch t.kind {
                case .keyword: a[r].foregroundColor = Color(light: 0xA626A4, dark: 0xC678DD)
                case .string: a[r].foregroundColor = Color(light: 0x50A14F, dark: 0x98C379)
                case .comment: a[r].foregroundColor = Color(light: 0xA0A1A7, dark: 0x7F848E)
                case .number: a[r].foregroundColor = Color(light: 0x986801, dark: 0xD19A66)
                case .type: a[r].foregroundColor = Color(light: 0xC18401, dark: 0xE5C07B)
                case .attribute: a[r].foregroundColor = Color(light: 0x4078F2, dark: 0x61AFEF)
                case .inserted:
                    a[r].foregroundColor = Theme.success
                    a[r].backgroundColor = Theme.success.opacity(0.10)
                case .deleted:
                    a[r].foregroundColor = Theme.destructive
                    a[r].backgroundColor = Theme.destructive.opacity(0.10)
                case .meta: a[r].foregroundColor = Theme.info
                }
            }
        }
        if cache.count > 500 { cache.removeAll() }
        cache[key] = a
        return a
    }
}
