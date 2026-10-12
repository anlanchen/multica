import AppKit
import MulticaCore
import SwiftUI
import WebKit

/// Native counterpart of upstream `RichContent` (packages/views/rich-content):
/// the one renderer for issue descriptions, comments and chat. Block
/// structure comes from `MarkdownBlocks` (after upstream's preprocessing:
/// bare links, `MUL-123` autolinks, mention shortcodes), inline formatting
/// from Foundation's parser. Issue and project mentions render as chips,
/// links into this deployment route in-app, file cards and images open the
/// attachment preview, and closed mermaid/html fences render as diagrams /
/// previews.
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

/// Where in-app links point (`AppConfig.appURL`), set at launch.
enum MarkdownLinks {
    @MainActor static var appURL: URL?

    /// A link into this deployment (`https://app/<slug>/issues/<id>`).
    @MainActor static func route(_ url: URL) -> (slug: String, route: AppRoute)? {
        guard let app = appURL, let host = url.host, host == app.host, url.scheme?.hasPrefix("http") == true else { return nil }
        return AppRoute.parse(path: url.path)
    }
}

/// Inline Markdown → AttributedString, memoised.
enum InlineMarkdown {
    struct Parsed {
        let text: AttributedString
        /// Carries links that render as entity chips (issue/project
        /// mentions, bare in-app entity URLs).
        let hasChips: Bool
    }

    @MainActor private static var cache: [String: Parsed] = [:]

    @MainActor static func render(_ s: String) -> AttributedString { parsed(s).text }

    @MainActor static func parsed(_ s: String) -> Parsed {
        if let hit = cache[s] { return hit }
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var a = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
        var chips = false
        for run in a.runs {
            guard let url = run.link else { continue }
            switch url.scheme {
            case "mention":
                let type = url.host() ?? ""
                if type == "issue" || type == "project" {
                    chips = true
                } else {
                    a[run.range].foregroundColor = Theme.brand
                    a[run.range].backgroundColor = Theme.brand.opacity(0.08)
                }
            case "slash":
                a[run.range].foregroundColor = Theme.brand
                a[run.range].link = nil
            default:
                if String(a[run.range].characters) == url.absoluteString, MarkdownLinks.route(url) != nil { chips = true }
            }
        }
        let parsed = Parsed(text: a, hasChips: chips)
        if cache.count > 3000 { cache.removeAll() }
        cache[s] = parsed
        return parsed
    }
}

/// One run of inline Markdown, with entity chips resolved live.
struct RichInlineText: View {
    let markdown: String
    @Environment(WorkspaceSession.self) private var session: WorkspaceSession?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let parsed = InlineMarkdown.parsed(markdown)
        if parsed.hasChips, let session {
            MentionChips.text(parsed.text, session: session, dark: scheme == .dark)
        } else {
            Text(parsed.text)
        }
    }
}

/// Resolves issues addressed by identifier or id for mention chips
/// (upstream `useResolveIssueIdentifier`: `GET /api/issues/<identifier>`,
/// a 404 renders the plain text the author typed).
@MainActor
@Observable
final class MentionResolver {
    private static var instances: [String: MentionResolver] = [:]

    static func shared(_ session: WorkspaceSession) -> MentionResolver {
        if let r = instances[session.workspace.id], r.session === session { return r }
        let r = MentionResolver(session: session)
        instances[session.workspace.id] = r
        return r
    }

    @ObservationIgnored private weak var session: WorkspaceSession?
    private(set) var fetched: [String: Issue] = [:]
    @ObservationIgnored private var identifierIDs: [String: String] = [:]
    @ObservationIgnored private var misses: Set<String> = []
    @ObservationIgnored private var inflight: Set<String> = []
    @ObservationIgnored private var projectsRequested = false

    private init(session: WorkspaceSession) {
        self.session = session
    }

    func issue(identifier raw: String) -> Issue? {
        guard let session else { return nil }
        let key = raw.uppercased()
        if let id = identifierIDs[key], let m = session.issues.model(id) { return m.issue }
        if let hit = fetched[key] { return session.issues.model(hit.id)?.issue ?? hit }
        if !misses.contains(key), let m = session.issues.model(identifier: key) {
            identifierIDs[key] = m.id
            return m.issue
        }
        let prefix = session.workspace.issuePrefix.uppercased()
        guard prefix.isEmpty || key.hasPrefix(prefix + "-") else { return nil }
        request(key)
        return nil
    }

    func issue(id: String) -> Issue? {
        guard let session else { return nil }
        if let m = session.issues.model(id) { return m.issue }
        if let hit = fetched[id] { return hit }
        request(id)
        return nil
    }

    func project(_ id: String) -> Project? {
        guard let session else { return nil }
        if !projectsRequested {
            projectsRequested = true
            Task { await session.projects.loadIfNeeded() }
        }
        return session.projects.item(id)
    }

    private func request(_ key: String) {
        guard let session, !misses.contains(key), !inflight.contains(key) else { return }
        inflight.insert(key)
        let api = session.api
        Task { [weak self] in
            do {
                let issue = try await api.issue(key)
                self?.fetched[key] = issue
                self?.fetched[issue.id] = issue
            } catch {
                if (error as? APIError)?.status == 404 { self?.misses.insert(key) }
            }
            self?.inflight.remove(key)
        }
    }
}

/// Builds the chip-substituted `Text` for a run of inline Markdown.
@MainActor
enum MentionChips {
    static func text(_ a: AttributedString, session: WorkspaceSession, dark: Bool) -> Text {
        let resolver = MentionResolver.shared(session)
        var out = Text(verbatim: "")
        var plain = AttributedString()
        var linkRun: (url: URL, label: AttributedString)?

        func flushPlain() {
            guard !plain.characters.isEmpty else { return }
            out = out + Text(plain)
            plain = AttributedString()
        }
        func flushLink() {
            guard let run = linkRun else { return }
            linkRun = nil
            if let chip = chip(run.url, label: run.label, resolver: resolver, session: session, dark: dark) {
                flushPlain()
                out = out + chip
            } else {
                plain.append(run.label)
            }
        }

        for run in a.runs {
            let piece = AttributedString(a[run.range])
            if let url = run.link {
                if let current = linkRun, current.url == url {
                    linkRun?.label.append(piece)
                } else {
                    flushLink()
                    linkRun = (url, piece)
                }
            } else {
                flushLink()
                plain.append(piece)
            }
        }
        flushLink()
        flushPlain()
        return out
    }

    private static func chip(_ url: URL, label: AttributedString, resolver: MentionResolver, session: WorkspaceSession, dark: Bool) -> Text? {
        let labelText = String(label.characters)
        if url.scheme == "mention" {
            let type = url.host() ?? ""
            let id = url.pathComponents.dropFirst().first ?? ""
            switch type {
            case "issue":
                if MarkdownPreprocess.isIssueIdentifier(id) {
                    guard let issue = resolver.issue(identifier: id) else { return Text(verbatim: id) }
                    return issueChip(issue, dark: dark)
                }
                guard let issue = resolver.issue(id: id) else { return linkText(labelText, url: url) }
                return issueChip(issue, dark: dark)
            case "project":
                guard let project = resolver.project(id) else { return linkText(labelText.isEmpty ? id : labelText, url: url) }
                return projectChip(project)
            default:
                return nil
            }
        }
        guard labelText == url.absoluteString, let target = MarkdownLinks.route(url), target.slug == session.workspace.slug else { return nil }
        switch target.route {
        case .issue(let id):
            let issue = MarkdownPreprocess.isIssueIdentifier(id) ? resolver.issue(identifier: id) : resolver.issue(id: id)
            return issue.map { issueChip($0, dark: dark) }
        case .project(let id):
            return resolver.project(id).map(projectChip)
        default:
            return nil
        }
    }

    private static func linkText(_ s: String, url: URL) -> Text {
        var a = AttributedString(s)
        a.link = url
        a.foregroundColor = Theme.brand
        return Text(a)
    }

    private static func issueChip(_ issue: Issue, dark: Bool) -> Text {
        let link = URL(string: "mention://issue/\(issue.id)")
        var id = AttributedString(" \(issue.identifier) ")
        id.foregroundColor = .secondary
        id.link = link
        var title = AttributedString(issue.title)
        title.foregroundColor = .primary
        title.link = link
        let glyph = Text(Image(nsImage: StatusGlyphImage.image(issue.status, dark: dark))).baselineOffset(-2)
        return glyph + Text(id) + Text(title)
    }

    private static func projectChip(_ project: Project) -> Text {
        let link = URL(string: "mention://project/\(project.id)")
        var title = AttributedString(" " + project.title)
        title.foregroundColor = .primary
        title.link = link
        let icon: Text = (project.icon?.isEmpty == false)
            ? Text(verbatim: project.icon ?? "")
            : Text(Image(systemName: "folder")).foregroundColor(.secondary)
        return icon + Text(title)
    }
}

/// The Canvas-drawn status glyph rasterized once per status and scheme so it
/// can sit inside `Text`.
@MainActor
enum StatusGlyphImage {
    private static var cache: [String: NSImage] = [:]

    static func image(_ status: IssueStatusKey, dark: Bool) -> NSImage {
        let key = "\(status.rawValue)|\(dark)"
        if let hit = cache[key] { return hit }
        let renderer = ImageRenderer(content: StatusIcon(status: status, size: 12).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 12, height: 12))
        cache[key] = image
        return image
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let font: Font

    var body: some View {
        switch block {
        case .heading(let level, let text):
            RichInlineText(markdown: text)
                .font(.system(size: level == 1 ? 20 : level == 2 ? 17 : 15, weight: .semibold))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            RichInlineText(markdown: text).font(font).fixedSize(horizontal: false, vertical: true)
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
                        RichInlineText(markdown: item.text)
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
                            RichInlineText(markdown: h).font(Theme.Font.bodyMedium).padding(6)
                        }
                    }
                    .background(Color.primary.opacity(0.04))
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        Divider()
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                RichInlineText(markdown: cell).font(font).padding(6)
                            }
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
            }
        case .rule:
            Divider().padding(.vertical, 4)
        case .image(let alt, let url):
            MarkdownImageBlock(alt: alt, url: url)
        case .fileCard(let name, let url):
            MarkdownFileCard(name: name, url: url)
        case .math(let tex):
            MarkdownMathBlock(tex: tex)
        case .richFence(let kind, let code, let title):
            MarkdownDynamicBlock(kind: kind, code: code, title: title)
        }
    }
}

// MARK: Attachments

/// Fetches attachment bytes (with credentials for this deployment's URLs)
/// and saves them to Downloads.
enum MarkdownAttachmentDownload {
    @MainActor static func save(url raw: String, name: String, toaster: Toaster?) {
        Task {
            do {
                let data = try await ImageLoader.shared.data(raw)
                let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
                let target = uniqueURL(dir.appendingPathComponent(name.isEmpty ? "download" : name))
                try await Task.detached { try data.write(to: target) }.value
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } catch {
                toaster?.error(tr("editor", "attachment.download_failed"))
            }
        }
    }

    private static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 1
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}

/// Upstream `<Attachment>` file card: icon, name, preview + download.
struct MarkdownFileCard: View {
    let name: String
    let url: String
    @Environment(Toaster.self) private var toaster: Toaster?
    @State private var previewing = false

    private var attachmentID: String? { MarkdownBlocks.attachmentID(fromDownloadURL: url) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: RouteIconName.forAttachment(name).systemImage)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            Text(name).font(Theme.Font.bodyMedium).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if attachmentID != nil {
                Button { previewing = true } label: { Image(systemName: "eye") }
                    .buttonStyle(.borderless)
                    .help(tr("editor", "attachment.preview"))
            }
            Button { MarkdownAttachmentDownload.save(url: url, name: name, toaster: toaster) } label: { Image(systemName: "arrow.down.to.line") }
                .buttonStyle(.borderless)
                .help(tr("editor", "image.download"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
        .contentShape(Rectangle())
        .onTapGesture {
            if attachmentID != nil { previewing = true } else { MarkdownAttachmentDownload.save(url: url, name: name, toaster: toaster) }
        }
        .sheet(isPresented: $previewing) {
            if let id = attachmentID {
                MarkdownPreviewSheet { AttachmentPreviewPage(attachmentID: id) }
            }
        }
    }
}

/// Hosts a preview in a sheet with a close button (upstream preview modal).
struct MarkdownPreviewSheet<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(tr("editor", "attachment.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            content()
        }
        .frame(minWidth: 760, idealWidth: 960, minHeight: 540, idealHeight: 720)
    }
}

/// Inline image with lightbox (upstream image node + preview modal).
struct MarkdownImageBlock: View {
    let alt: String
    let url: String
    @State private var viewing = false

    var body: some View {
        RemoteImage(url: ImageLoader.resolve(url)) {
            RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.05))
                .frame(height: 120)
                .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
        }
        .scaledToFit()
        .frame(maxWidth: 560, maxHeight: 420, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .accessibilityLabel(alt)
        .contentShape(Rectangle())
        .onTapGesture { viewing = true }
        .help(tr("editor", "image.view"))
        .sheet(isPresented: $viewing) { MarkdownImageLightbox(alt: alt, url: url) }
    }
}

struct MarkdownImageLightbox: View {
    let alt: String
    let url: String
    @Environment(\.dismiss) private var dismiss
    @Environment(Toaster.self) private var toaster: Toaster?
    @State private var zoom: CGFloat = 1
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(alt.isEmpty ? tr("editor", "image.view") : alt).font(Theme.Font.bodyMedium).lineLimit(1)
                Spacer()
                Button { copyImage() } label: { Image(systemName: "doc.on.doc") }
                    .help(tr("editor", "image.copy_image")).disabled(image == nil)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ImageLoader.resolve(url)?.absoluteString ?? url, forType: .string)
                    toaster?.success(tr("editor", "image.link_copied"))
                } label: { Image(systemName: "link") }
                    .help(tr("editor", "image.copy_link"))
                Button { MarkdownAttachmentDownload.save(url: url, name: alt.isEmpty ? (URL(string: url)?.lastPathComponent ?? "image") : alt, toaster: toaster) } label: { Image(systemName: "arrow.down.to.line") }
                    .help(tr("editor", "image.download"))
                Button(tr("editor", "attachment.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: image.size.width * zoom, height: image.size.height * zoom)
                    } else {
                        ProgressView().padding(40)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .gesture(MagnificationGesture().onChanged { zoom = max(0.1, min(8, $0)) })
            .onTapGesture(count: 2) { zoom = zoom == 1 ? 2 : 1 }
            .accessibilityLabel(tr("editor", "image.canvas_label"))
        }
        .frame(minWidth: 640, idealWidth: 960, minHeight: 480, idealHeight: 720)
        .task {
            guard let u = ImageLoader.resolve(url) else { return }
            image = await ImageLoader.shared.load(u)
        }
    }

    private func copyImage() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([image]) {
            toaster?.success(tr("editor", "image.image_copied"))
        } else {
            toaster?.error(tr("editor", "image.copy_image_failed"))
        }
    }
}

// MARK: Math, mermaid, html

struct MarkdownMathBlock: View {
    let tex: String
    @State private var error: String?

    var body: some View {
        if error != nil {
            Text(verbatim: "$$\(tex)$$").font(Theme.Font.mono).foregroundStyle(.secondary).textSelection(.enabled)
        } else {
            RichRenderedImage(kind: .math, source: tex, onError: { error = $0 })
                .frame(maxWidth: .infinity)
        }
    }
}

/// Upstream DynamicBlock: titled frame with Preview/Source toggle,
/// fullscreen and copy-source actions; errors show the source.
struct MarkdownDynamicBlock: View {
    let kind: String
    let code: String
    let title: String?
    @State private var showSource = false
    @State private var error: String?
    @State private var fullscreen = false
    @State private var htmlHeight: CGFloat = 160

    private var isMermaid: Bool { kind == "mermaid" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isMermaid ? "point.3.connected.trianglepath.dotted" : "macwindow")
                    .foregroundStyle(.secondary)
                Text(title ?? (isMermaid ? "Mermaid" : "HTML")).font(Theme.Font.caption.weight(.medium)).lineLimit(1)
                Spacer()
                Picker(tr("editor", "dynamic_block.view"), selection: $showSource) {
                    Text(tr("editor", "dynamic_block.preview")).tag(false)
                    Text(tr("editor", "dynamic_block.source")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                Button { fullscreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help(tr("editor", "code_block.fullscreen"))
                CopyButton(text: code).help(tr("editor", "dynamic_block.copy_source"))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            Group {
                if showSource {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(CodeHighlight.render(code, language: isMermaid ? nil : "html"))
                            .font(Theme.Font.mono).textSelection(.enabled).padding(10)
                    }
                } else if let error {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isMermaid ? tr("editor", "dynamic_block.error_mermaid") : tr("editor", "dynamic_block.error_html"))
                            .font(Theme.Font.bodyMedium)
                        Text(error).font(Theme.Font.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button(tr("editor", "dynamic_block.view_source")) { showSource = true }
                            Button(tr("editor", "dynamic_block.copy_error")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(error, forType: .string)
                            }
                        }
                        .buttonStyle(.link)
                        .font(Theme.Font.caption)
                    }
                    .padding(10)
                } else if isMermaid {
                    RichRenderedImage(kind: .mermaid, source: code, onError: { error = $0 })
                        .padding(10)
                        .frame(maxWidth: .infinity)
                } else {
                    MarkdownHTMLPreview(html: code, height: $htmlHeight, onError: { error = $0 })
                        .frame(height: htmlHeight)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .sheet(isPresented: $fullscreen) {
            MarkdownPreviewSheet {
                ScrollView([.horizontal, .vertical]) {
                    if isMermaid {
                        RichRenderedImage(kind: .mermaid, source: code, width: 1300).padding(20)
                    } else {
                        MarkdownHTMLPreview(html: code, height: .constant(700), onError: { _ in }).frame(minWidth: 900, minHeight: 700)
                    }
                }
            }
        }
    }
}

/// A sandboxed preview of a ```html fence: scripts run, but nothing may
/// load from or navigate to the network (upstream sandboxed srcdoc iframe).
struct MarkdownHTMLPreview: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "multica")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.document(html), baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "multica")
    }

    static func document(_ html: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:">
        <meta name="color-scheme" content="light dark">
        <style>body{margin:12px;font:14px -apple-system,sans-serif;}</style>
        <script>
        window.addEventListener('error', e => webkit.messageHandlers.multica.postMessage({error: String(e.message)}));
        const report = () => webkit.messageHandlers.multica.postMessage({height: document.documentElement.scrollHeight});
        window.addEventListener('load', () => { report(); new ResizeObserver(report).observe(document.documentElement); });
        </script></head><body>\(html)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MarkdownHTMLPreview
        init(_ parent: MarkdownHTMLPreview) { self.parent = parent }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let h = body["height"] as? NSNumber {
                let height = min(max(CGFloat(truncating: h), 60), 900)
                if abs(height - parent.height) > 1 { parent.height = height }
            } else if let e = body["error"] as? String {
                parent.onError(e)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            decisionHandler(url == nil || url?.scheme == "about" || url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}

// MARK: Links

/// Routes `mention://` links and links into this deployment to in-app
/// navigation (⌘-click opens a new tab); everything else opens in the
/// browser.
private struct MentionLinkHandler: ViewModifier {
    @Environment(Navigator.self) private var nav: Navigator?
    @Environment(WorkspaceSession.self) private var session: WorkspaceSession?

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            guard let nav else { return url.scheme == "mention" ? .discarded : .systemAction }
            let newTab = NSEvent.modifierFlags.contains(.command)
            @MainActor func go(_ route: AppRoute) {
                if newTab { nav.openInNewTab(route) } else { nav.push(route) }
            }
            if url.scheme == "mention" {
                let type = url.host() ?? ""
                let id = url.pathComponents.dropFirst().first ?? ""
                guard !id.isEmpty else { return .discarded }
                switch type {
                case "issue":
                    if MarkdownPreprocess.isIssueIdentifier(id), let session,
                       let issue = MentionResolver.shared(session).issue(identifier: id) {
                        go(.issue(issue.id))
                    } else {
                        go(.issue(id))
                    }
                case "agent": go(.agent(id))
                case "member": go(.member(id))
                case "squad": go(.squad(id))
                case "project": go(.project(id))
                default: return .discarded
                }
                return .handled
            }
            if let target = MarkdownLinks.route(url), target.slug == session?.workspace.slug {
                go(target.route)
                return .handled
            }
            return .systemAction
        })
    }
}

// MARK: Code

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
