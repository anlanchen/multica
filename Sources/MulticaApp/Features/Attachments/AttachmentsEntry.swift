import AppKit
import AVKit
import MulticaCore
import PDFKit
import SwiftUI

/// Any attachment on a tab of its own: the viewer's top bar and stage
/// (upstream attachments/attachment-preview-page.tsx). The record loads once
/// per page view; `?name=` titles the tab until it lands.
struct AttachmentPreviewPage: View {
    let attachmentID: String
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @State private var attachment: Attachment?
    @State private var failed = false

    var body: some View {
        Group {
            if let attachment {
                AttachmentPreviewStandalone(attachment: attachment)
            } else {
                HStack(spacing: 8) {
                    if failed {
                        Text(tr("editor", "attachment.preview_failed"))
                    } else {
                        ProgressView().controlSize(.small)
                        Text(tr("editor", "attachment.preview_loading"))
                    }
                }
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.colorScheme, .dark)
            }
        }
        .background(Color.black.opacity(0.95))
        .tabTitle(attachment?.filename ?? nav.query("name"))
        .task(id: attachmentID) {
            failed = false
            do {
                let a = try await session.api.getAttachment(attachmentID)
                attachment = a.id.isEmpty ? nil : a
                failed = a.id.isEmpty
            } catch {
                failed = true
            }
        }
    }
}

private enum AttachmentHTMLViewport: String, CaseIterable {
    case fill, desktop, tablet, phone

    var width: CGFloat? {
        switch self {
        case .fill: return nil
        case .desktop: return 1440
        case .tablet: return 768
        case .phone: return 390
        }
    }

    var icon: String {
        switch self {
        case .fill: return "arrow.up.left.and.arrow.down.right"
        case .desktop: return "desktopcomputer"
        case .tablet: return "ipad"
        case .phone: return "iphone"
        }
    }
}

private enum AttachmentTextLoad {
    case loading
    case loaded(String)
    case tooLarge, unsupported, failed
}

/// Top bar + stage for one attachment.
private struct AttachmentPreviewStandalone: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let attachment: Attachment

    @State private var wrapChoice: Bool?
    @State private var viewport: AttachmentHTMLViewport = .fill
    @State private var showSource = false
    @State private var treeView = true
    @State private var reloadToken = 0
    @State private var text: AttachmentTextLoad = .loading
    @State private var highlighted: NSAttributedString?
    @State private var parse: AttachmentPreviewParse?
    @State private var table: AttachmentPreviewTable?
    @State private var image: NSImage?
    @State private var pdf: PDFDocument?
    @State private var asset: AVURLAsset?
    @State private var mediaFailed = false
    @State private var zoom = AttachmentPreviewZoom()

    private var kind: AttachmentPreviewKind? { AttachmentPreview.kind(contentType: attachment.contentType, filename: attachment.filename) }
    private var wrap: Bool { wrapChoice ?? AttachmentPreview.wrapsByDefault(attachment.filename) }
    private var textBacked: Bool {
        switch kind {
        case .markdown, .html, .table, .structured, .text: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .environment(\.colorScheme, .dark)
            stage
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: attachment.id) { await load() }
        .onChange(of: showSource) { Task { await highlight() } }
    }

    // MARK: Loading

    private func load() async {
        let api = session.api
        switch kind {
        case .image:
            if let data = try? await api.getAttachmentBlob(attachment.id), let img = NSImage(data: data) { image = img } else { mediaFailed = true }
        case .pdf:
            if let data = try? await api.getAttachmentBlob(attachment.id), let doc = PDFDocument(data: data) { pdf = doc } else { mediaFailed = true }
        case .video, .audio:
            guard let url = mediaURL else { mediaFailed = true; return }
            var options: [String: Any] = [:]
            if let base = ImageLoader.baseURL, url.host == base.host, let token = await api.currentToken() {
                options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": "Bearer \(token)", "X-Workspace-Slug": session.workspace.slug]
            }
            asset = AVURLAsset(url: url, options: options)
        case .markdown, .html, .table, .structured, .text:
            do {
                let body = try await api.getAttachmentTextContent(attachment.id).text
                await prepare(body)
                text = .loaded(body)
            } catch let e as APIError where e.status == 413 {
                text = .tooLarge
            } catch let e as APIError where e.status == 415 {
                text = .unsupported
            } catch {
                text = .failed
            }
        case nil:
            break
        }
    }

    /// Parses / highlights off the main actor before the body is shown.
    private func prepare(_ body: String) async {
        let filename = attachment.filename, contentType = attachment.contentType
        switch kind {
        case .markdown:
            await Task.detached(priority: .userInitiated) { _ = MarkdownBlocks.cachedParse(body) }.value
        case .table:
            let tsv = AttachmentPreview.isTSV(contentType: contentType, filename: filename)
            table = await Task.detached(priority: .userInitiated) { AttachmentPreview.table(body, tsv: tsv) }.value
        case .structured:
            let format = AttachmentPreview.structuredFormat(contentType: contentType, filename: filename) ?? .json
            parse = await Task.detached(priority: .userInitiated) { AttachmentPreview.parseStructured(body, format: format) }.value
            await highlight(body)
        case .text:
            await highlight(body)
        default:
            break
        }
    }

    private func highlight(_ override: String? = nil) async {
        let body: String
        if let override { body = override } else if case .loaded(let t) = text { body = t } else { return }
        let language = kind == .html ? "xml" : AttachmentPreview.language(for: attachment.filename)
        let result = await Task.detached(priority: .userInitiated) { AttachmentPreviewCodeView.highlighted(body, language: language) }.value
        highlighted = result.value
    }

    private var mediaURL: URL? {
        let raw = [attachment.downloadUrl, attachment.markdownUrl, attachment.url].first { !$0.isEmpty } ?? ""
        return ImageLoader.resolve(raw)
    }

    // MARK: Header

    private var meta: String {
        var parts = [AttachmentPreview.typeLabel(attachment.filename)]
        if kind == .image, let image, let rep = image.representations.first, rep.pixelsWide > 0 {
            parts.append("\(rep.pixelsWide) × \(rep.pixelsHigh)")
        }
        if attachment.sizeBytes > 0 { parts.append(Formatters.bytes(Int64(attachment.sizeBytes))) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var kindIcon: String {
        switch kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .video: return "film"
        case .audio: return "waveform"
        case .markdown: return "doc.text"
        case .html: return "globe"
        case .table: return "tablecells"
        case .structured: return "curlybraces"
        case .text: return "doc.plaintext"
        case nil: return "doc"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: kindIcon)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename).font(Theme.Font.bodyMedium).lineLimit(1).truncationMode(.middle)
                if !meta.isEmpty {
                    Text(meta).font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            controls
            AttachmentChromeButton(label: tr("editor", "image.download"), icon: "arrow.down.to.line", action: download)
            AttachmentChromeButton(label: trd("editor", "attachment.open_externally", "Open with Default App"), icon: "arrow.up.forward.app", action: openExternally)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 56)
        .foregroundStyle(.primary)
    }

    @ViewBuilder private var controls: some View {
        switch kind {
        case .image where image != nil:
            AttachmentChromeButton(label: tr("editor", "canvas.zoom_out"), icon: "minus.magnifyingglass") { zoom.zoom(by: 1 / 1.5) }
            Text("\(zoom.percent)%").font(Theme.Font.caption).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 40)
            AttachmentChromeButton(label: tr("editor", "canvas.zoom_in"), icon: "plus.magnifyingglass") { zoom.zoom(by: 1.5) }
            AttachmentChromeButton(label: tr("editor", "canvas.zoom_fit"), icon: "arrow.down.right.and.arrow.up.left") { zoom.fit() }
            AttachmentChromeButton(label: tr("editor", "canvas.zoom_actual"), icon: "1.magnifyingglass") { zoom.actualSize() }
            AttachmentChromeDivider()
            AttachmentChromeButton(label: tr("editor", "image.copy_image"), icon: "doc.on.doc", action: copyImage)
        case .html:
            AttachmentChromeButton(label: tr("editor", "attachment.reload"), icon: "arrow.clockwise", disabled: showSource) { reloadToken += 1 }
            HStack(spacing: 2) {
                ForEach(AttachmentHTMLViewport.allCases, id: \.self) { v in
                    AttachmentChromeButton(label: tr("editor", "attachment.viewport_\(v.rawValue)"), icon: v.icon, pressed: viewport == v, disabled: showSource) { viewport = v }
                }
            }
            .accessibilityLabel(tr("editor", "attachment.viewport"))
            AttachmentChromeButton(label: tr("editor", "attachment.view_source"), icon: "chevron.left.forwardslash.chevron.right", pressed: showSource) { showSource.toggle() }
            wrapButton(enabled: showSource)
            AttachmentChromeDivider()
        case .structured:
            let treeAvailable = parse.map { if case .ok = $0 { return true } else { return false } } ?? true
            HStack(spacing: 2) {
                AttachmentChromeButton(label: tr("editor", "attachment.view_tree"), icon: "list.bullet.indent", pressed: treeView && treeAvailable, disabled: !treeAvailable) { treeView = true }
                AttachmentChromeButton(label: tr("editor", "attachment.view_raw"), icon: "chevron.left.forwardslash.chevron.right", pressed: !treeView || !treeAvailable, disabled: !treeAvailable) { treeView = false }
            }
            .accessibilityLabel(tr("editor", "attachment.view_mode"))
            wrapButton(enabled: !treeView || !treeAvailable)
            AttachmentChromeDivider()
        case .text:
            wrapButton(enabled: true)
            AttachmentChromeDivider()
        default:
            EmptyView()
        }
    }

    private func wrapButton(enabled: Bool) -> some View {
        AttachmentChromeButton(label: tr("editor", "attachment.wrap_lines"), icon: "text.word.spacing", pressed: enabled && wrap, disabled: !enabled) {
            wrapChoice = !wrap
        }
    }

    // MARK: Stage

    @ViewBuilder private var stage: some View {
        switch kind {
        case .image:
            if let image {
                AttachmentPreviewImageCanvas(image: image, zoom: zoom).padding(.vertical, 16)
            } else if mediaFailed {
                fallback(tr("editor", "attachment.preview_failed"))
            } else {
                loading
            }
        case .pdf:
            if let pdf {
                AttachmentPreviewPDFView(document: pdf)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 16)
            } else if mediaFailed {
                fallback(tr("editor", "attachment.preview_failed"))
            } else {
                loading
            }
        case .video, .audio:
            if let asset {
                AttachmentPreviewPlayer(asset: asset, isAudio: kind == .audio)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(kind == .audio ? 32 : 0)
                    .padding(.bottom, 16)
            } else if mediaFailed {
                fallback(tr("editor", "attachment.preview_failed"))
            } else {
                loading
            }
        case .markdown, .html, .table, .structured, .text:
            textStage
        case nil:
            fallback(tr("editor", "attachment.preview_unsupported"))
        }
    }

    @ViewBuilder private var textStage: some View {
        switch text {
        case .loading: loading
        case .tooLarge: fallback(tr("editor", "attachment.preview_too_large"))
        case .unsupported: fallback(tr("editor", "attachment.preview_unsupported"))
        case .failed: fallback(tr("editor", "attachment.preview_failed"))
        case .loaded(let body):
            switch kind {
            case .markdown:
                ScrollView {
                    MarkdownView(source: body)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 32)
                        .frame(maxWidth: 768, alignment: .leading)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                        .frame(maxWidth: .infinity)
                }
            case .html:
                if showSource { codeSheet } else { htmlStage(body) }
            case .table:
                if let table { tableStage(table) } else { loading }
            case .structured:
                structuredStage
            default:
                codeSheet
            }
        }
    }

    private var codeSheet: some View {
        Group {
            if let highlighted {
                AttachmentPreviewCodeView(text: highlighted, wrap: wrap)
            } else {
                loading
            }
        }
        .frame(maxWidth: 1024)
        .background(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .frame(maxWidth: .infinity)
    }

    private func htmlStage(_ html: String) -> some View {
        GeometryReader { geo in
            let device = viewport.width
            let scale = device.map { min(1, geo.size.width / $0) } ?? 1
            VStack(spacing: 6) {
                AttachmentPreviewWebView(html: html, reloadToken: reloadToken, pageZoom: scale)
                    .frame(width: device.map { $0 * scale } ?? geo.size.width)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: device == nil ? 8 : 12))
                if device != nil {
                    Text(tr("editor", "attachment.viewport_scale", ["percent": Int((scale * 100).rounded())]))
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .environment(\.colorScheme, .dark)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.bottom, 16)
    }

    private func tableStage(_ table: AttachmentPreviewTable) -> some View {
        VStack(spacing: 0) {
            if table.rows.isEmpty && table.header.isEmpty {
                Text(tr("editor", "attachment.table_empty")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AttachmentPreviewTableView(table: table)
            }
            HStack(spacing: 6) {
                Text(tr("editor", "attachment.table_rows", ["count": table.rows.count]))
                Text("·")
                Text(tr("editor", "attachment.table_columns", ["count": table.columnCount]))
                Spacer()
            }
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(alignment: .top) { Divider() }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 16)
    }

    @ViewBuilder private var structuredStage: some View {
        switch parse {
        case .ok(let value) where treeView:
            AttachmentPreviewTreeView(value: value)
                .padding(.vertical, 12)
                .frame(maxWidth: 1024)
                .background(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .frame(maxWidth: .infinity)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                (Text(tr("editor", "attachment.structured_parse_failed")) + Text(" ") + Text(message).font(.system(size: 11, design: .monospaced)))
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .environment(\.colorScheme, .dark)
                    .frame(maxWidth: 1024, alignment: .leading)
                codeSheet
            }
            .frame(maxWidth: .infinity)
        default:
            codeSheet
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(tr("editor", "attachment.preview_loading"))
        }
        .font(Theme.Font.body)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    private func fallback(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(message).font(Theme.Font.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action: download) { Label(tr("editor", "image.download"), systemImage: "arrow.down.to.line") }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Actions

    private func download() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.canCreateDirectories = true
        let api = session.api
        let id = attachment.id
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let data = try await api.getAttachmentBlob(id)
                    try data.write(to: url, options: .atomic)
                } catch {
                    toaster.error(tr("editor", "attachment.download_failed"))
                }
            }
        }
    }

    private func openExternally() {
        let api = session.api
        let id = attachment.id
        let name = attachment.filename.isEmpty ? id : attachment.filename
        Task {
            do {
                let data = try await api.getAttachmentBlob(id)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("multica-attachments/\(id)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent(name)
                try data.write(to: file, options: .atomic)
                NSWorkspace.shared.open(file)
            } catch {
                toaster.error(tr("editor", "attachment.download_failed"))
            }
        }
    }

    private func copyImage() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([image]) {
            toaster.success(tr("editor", "image.image_copied"))
        } else {
            toaster.error(tr("editor", "image.copy_image_failed"))
        }
    }
}

/// Top-bar icon button (upstream ChromeButton).
private struct AttachmentChromeButton: View {
    let label: String
    let icon: String
    var pressed = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(pressed ? Color.white.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pressed ? .primary : .secondary)
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct AttachmentChromeDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 16).padding(.horizontal, 6)
    }
}
