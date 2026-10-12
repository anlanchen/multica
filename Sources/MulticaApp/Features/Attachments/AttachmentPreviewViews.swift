import AppKit
import AVKit
import MulticaCore
import PDFKit
import SwiftUI
import WebKit

// MARK: Image

/// Zoom state shared by the image canvas and the top-bar controls.
@MainActor
@Observable
final class AttachmentPreviewZoom {
    private(set) var magnification: CGFloat = 1
    @ObservationIgnored weak var scrollView: NSScrollView?
    @ObservationIgnored var fitScale: CGFloat = 1

    var percent: Int { Int((magnification * 100).rounded()) }

    func update(_ value: CGFloat) {
        if abs(value - magnification) > 0.001 { magnification = value }
    }

    func zoom(by factor: CGFloat) {
        guard let sv = scrollView else { return }
        let target = min(sv.maxMagnification, max(sv.minMagnification, sv.magnification * factor))
        sv.animator().setMagnification(target, centeredAt: NSPoint(x: sv.documentVisibleRect.midX, y: sv.documentVisibleRect.midY))
    }

    func fit() {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        sv.animator().magnify(toFit: doc.bounds)
    }

    func actualSize() {
        guard let sv = scrollView else { return }
        sv.animator().setMagnification(1, centeredAt: NSPoint(x: sv.documentVisibleRect.midX, y: sv.documentVisibleRect.midY))
    }

    /// Double-click toggles between fitting and actual size.
    func toggle() {
        guard let sv = scrollView else { return }
        abs(sv.magnification - 1) < 0.01 ? fit() : actualSize()
    }
}

/// Drag to pan, pinch or ⌘-scroll to zoom, double-click for actual size.
struct AttachmentPreviewImageCanvas: NSViewRepresentable {
    let image: NSImage
    let zoom: AttachmentPreviewZoom

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.allowsMagnification = true
        sv.minMagnification = 0.05
        sv.maxMagnification = 16
        sv.contentView = AttachmentPreviewCenteringClipView()
        let iv = AttachmentPreviewImageDocument()
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.frame = NSRect(origin: .zero, size: image.size)
        iv.onDoubleClick = { [weak zoom] in zoom?.toggle() }
        sv.documentView = iv
        zoom.scrollView = sv
        context.coordinator.observe(sv, zoom: zoom)
        DispatchQueue.main.async {
            sv.magnify(toFit: iv.bounds)
            if sv.magnification > 1 { sv.magnification = 1 }
            zoom.update(sv.magnification)
        }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let iv = sv.documentView as? NSImageView, iv.image !== image else { return }
        iv.image = image
        iv.frame = NSRect(origin: .zero, size: image.size)
        sv.magnify(toFit: iv.bounds)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var token: NSObjectProtocol?

        func observe(_ sv: NSScrollView, zoom: AttachmentPreviewZoom) {
            token = NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: sv, queue: .main) { [weak sv, weak zoom] _ in
                MainActor.assumeIsolated {
                    if let sv { zoom?.update(sv.magnification) }
                }
            }
            sv.contentView.postsBoundsChangedNotifications = true
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}

private final class AttachmentPreviewImageDocument: NSImageView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
}

/// Keeps a smaller-than-viewport document centred.
private final class AttachmentPreviewCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

// MARK: PDF

struct AttachmentPreviewPDFView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

// MARK: Media

struct AttachmentPreviewPlayer: View {
    let asset: AVURLAsset
    let isAudio: Bool
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .frame(maxWidth: isAudio ? 560 : .infinity, maxHeight: isAudio ? 80 : .infinity)
            }
        }
        .onAppear { player = AVPlayer(playerItem: AVPlayerItem(asset: asset)) }
        .onDisappear { player?.pause() }
    }
}

// MARK: HTML

/// The document runs scripts in a throwaway, non-persistent store with no
/// origin; links open in the browser (upstream sandboxes the iframe the
/// same way).
struct AttachmentPreviewWebView: NSViewRepresentable {
    let html: String
    let reloadToken: Int
    var pageZoom: CGFloat = 1

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.pageZoom = pageZoom
        view.loadHTMLString(html, baseURL: nil)
        context.coordinator.loaded = (html, reloadToken)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.pageZoom != pageZoom { view.pageZoom = pageZoom }
        if context.coordinator.loaded.html != html || context.coordinator.loaded.token != reloadToken {
            context.coordinator.loaded = (html, reloadToken)
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loaded: (html: String, token: Int) = ("", 0)

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(action.request.url?.scheme == "about" || action.navigationType == .other || action.navigationType == .reload ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, url.scheme == "http" || url.scheme == "https" { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}

// MARK: Code

/// Read-only source with line numbers, syntax colours and a wrap toggle.
/// AppKit text layout keeps large files responsive.
struct AttachmentPreviewCodeView: NSViewRepresentable {
    let text: NSAttributedString
    let wrap: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        sv.drawsBackground = false
        sv.autohidesScrollers = true
        let tv = sv.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 12)
        tv.isRichText = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.layoutManager?.allowsNonContiguousLayout = true
        let ruler = AttachmentPreviewLineRuler(textView: tv)
        sv.verticalRulerView = ruler
        sv.hasVerticalRuler = true
        sv.rulersVisible = true
        context.coordinator.ruler = ruler
        context.coordinator.observe(sv)
        apply(sv, tv, ruler)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView, let ruler = context.coordinator.ruler else { return }
        apply(sv, tv, ruler)
    }

    private func apply(_ sv: NSScrollView, _ tv: NSTextView, _ ruler: AttachmentPreviewLineRuler) {
        if tv.textStorage?.isEqual(to: text) == false {
            tv.textStorage?.setAttributedString(text)
            ruler.recount(text.string)
        }
        guard let container = tv.textContainer else { return }
        let wrapping = container.widthTracksTextView
        if wrapping != wrap {
            container.widthTracksTextView = wrap
            tv.isHorizontallyResizable = !wrap
            sv.hasHorizontalScroller = !wrap
            if wrap {
                container.containerSize = NSSize(width: sv.contentSize.width - ruler.ruleThickness, height: .greatestFiniteMagnitude)
                tv.frame.size.width = sv.contentSize.width - ruler.ruleThickness
            } else {
                container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
                tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            }
            ruler.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var ruler: AttachmentPreviewLineRuler?
        private var token: NSObjectProtocol?

        func observe(_ sv: NSScrollView) {
            sv.contentView.postsBoundsChangedNotifications = true
            token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ruler?.needsDisplay = true }
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    /// Colours `SyntaxHighlighter` tokens; safe to run off the main thread.
    nonisolated static func highlighted(_ code: String, language: String?) -> AttachmentHighlightedText {
        AttachmentHighlightedText(value: build(code, language: language))
    }

    private nonisolated static func build(_ code: String, language: String?) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let out = NSMutableAttributedString(string: code, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        guard code.utf16.count < 600_000, language != nil, language != "plaintext" else { return out }
        func dyn(_ light: UInt32, _ dark: UInt32) -> NSColor {
            NSColor(name: nil) { appearance in
                let v = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
            }
        }
        let colors: [SyntaxHighlighter.Kind: NSColor] = [
            .keyword: dyn(0xA626A4, 0xC678DD), .string: dyn(0x50A14F, 0x98C379), .comment: dyn(0xA0A1A7, 0x7F848E),
            .number: dyn(0x986801, 0xD19A66), .type: dyn(0xC18401, 0xE5C07B), .attribute: dyn(0x4078F2, 0x61AFEF),
            .inserted: dyn(0x1C882D, 0x4AA651), .deleted: dyn(0xE7000B, 0xFF6467), .meta: dyn(0x0072D5, 0x4390EE),
        ]
        let length = out.length
        for token in SyntaxHighlighter.tokens(code, language: language) {
            let range = NSRange(location: token.range.lowerBound, length: token.range.count)
            guard range.location >= 0, NSMaxRange(range) <= length, let color = colors[token.kind] else { continue }
            out.addAttribute(.foregroundColor, value: color, range: range)
        }
        return out
    }
}

/// An immutable attributed string handed from a background build to the view.
struct AttachmentHighlightedText: @unchecked Sendable {
    let value: NSAttributedString
}

final class AttachmentPreviewLineRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func recount(_ string: String) {
        var starts = [0]
        let utf16 = Array(string.utf16)
        for (i, c) in utf16.enumerated() where c == 0x0A && i + 1 < utf16.count { starts.append(i + 1) }
        lineStarts = starts
        let digits = String(starts.count).count
        ruleThickness = CGFloat(max(3, digits)) * 8 + 16
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var lo = 0, hi = lineStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= chars.location { lo = mid + 1 } else { hi = mid }
        }
        var line = max(0, lo - 1)
        let end = NSMaxRange(chars)
        let total = (tv.string as NSString).length
        while line < lineStarts.count, lineStarts[line] <= end {
            let start = lineStarts[line]
            guard start <= total else { break }
            let glyph = start < total ? lm.glyphIndexForCharacter(at: start) : max(0, lm.numberOfGlyphs - 1)
            let fragment = lm.numberOfGlyphs == 0 ? .zero : lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = convert(NSPoint(x: 0, y: fragment.minY + tv.textContainerOrigin.y), from: tv).y
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (fragment.height - size.height) / 2), withAttributes: attrs)
            line += 1
        }
    }
}

// MARK: Table

/// A delimited file as a sortable table: click a header for ascending,
/// again for descending, a third time for file order. The `#` column keeps
/// each row's position in the source (upstream table-preview.tsx).
struct AttachmentPreviewTableView: NSViewRepresentable {
    let table: AttachmentPreviewTable

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        let tv = NSTableView()
        tv.usesAlternatingRowBackgroundColors = true
        tv.columnAutoresizingStyle = .noColumnAutoresizing
        tv.allowsColumnReordering = false
        tv.allowsColumnResizing = true
        tv.gridStyleMask = [.solidVerticalGridLineMask]
        tv.rowHeight = 22
        tv.style = .plain
        tv.dataSource = context.coordinator
        tv.delegate = context.coordinator
        context.coordinator.configure(tv, table: table)
        sv.documentView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTableView, context.coordinator.table != table else { return }
        context.coordinator.configure(tv, table: table)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var table: AttachmentPreviewTable?
        private var order: [Int] = []
        private var sortColumn: Int?
        private var ascending = true

        @MainActor func configure(_ tv: NSTableView, table: AttachmentPreviewTable) {
            self.table = table
            order = Array(table.rows.indices)
            sortColumn = nil
            for c in tv.tableColumns { tv.removeTableColumn(c) }
            let font = NSFont.systemFont(ofSize: 12)
            let number = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("#"))
            number.title = "#"
            number.width = max(44, CGFloat(String(table.rows.count).count) * 8 + 20)
            number.headerCell.alignment = .right
            tv.addTableColumn(number)
            for (i, title) in table.header.enumerated() {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
                col.title = title
                col.minWidth = 48
                var widest = (title as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12)]).width + 28
                for row in table.rows.prefix(200) {
                    widest = max(widest, (row[i] as NSString).size(withAttributes: [.font: font]).width + 16)
                }
                col.width = min(360, max(64, widest))
                if table.numericColumns.contains(i) { col.headerCell.alignment = .right }
                tv.addTableColumn(col)
            }
            tv.reloadData()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { order.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let table, let id = tableColumn?.identifier.rawValue, row < order.count else { return nil }
            let source = order[row]
            let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell"), owner: nil) as? NSTextField) ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = NSUserInterfaceItemIdentifier("cell")
                f.lineBreakMode = .byTruncatingTail
                f.font = .systemFont(ofSize: 12)
                return f
            }()
            if id == "#" {
                cell.stringValue = "\(source + 1)"
                cell.alignment = .right
                cell.textColor = .secondaryLabelColor
                cell.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                cell.toolTip = nil
            } else if let c = Int(id.dropFirst()), c < table.columnCount {
                let value = table.rows[source][c]
                cell.stringValue = value
                cell.toolTip = value.isEmpty ? nil : value
                cell.textColor = .labelColor
                let numeric = table.numericColumns.contains(c)
                cell.alignment = numeric ? .right : .left
                cell.font = numeric ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let table, tableColumn.identifier.rawValue != "#", let c = Int(tableColumn.identifier.rawValue.dropFirst()) else { return }
            for col in tableView.tableColumns { tableView.setIndicatorImage(nil, in: col) }
            if sortColumn == c {
                if ascending {
                    ascending = false
                } else {
                    sortColumn = nil
                    order = Array(table.rows.indices)
                    tableView.reloadData()
                    return
                }
            } else {
                sortColumn = c
                ascending = true
            }
            order = AttachmentPreview.sortedRows(table, column: c, ascending: ascending)
            tableView.setIndicatorImage(NSImage(named: ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"), in: tableColumn)
            tableView.reloadData()
        }
    }
}

// MARK: Tree

/// A JSON / YAML value as a collapsible tree, rendered as one flat list of
/// visible rows (upstream structured-tree.tsx).
struct AttachmentPreviewTreeView: View {
    let value: AttachmentPreviewValue
    @State private var expanded: Set<String> = []
    @State private var shown: [String: Int] = [:]
    @State private var rows: [AttachmentPreviewTreeRow] = []

    var body: some View {
        List(rows) { row in
            AttachmentPreviewTreeRowView(row: row) {
                switch row.kind {
                case .container:
                    if expanded.contains(row.path) { expanded.remove(row.path) } else { expanded.insert(row.path) }
                case .showMore:
                    shown[row.path, default: AttachmentPreviewTree.pageSize] += AttachmentPreviewTree.pageSize
                default:
                    break
                }
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 22)
        .onAppear {
            expanded = AttachmentPreviewTree.defaultExpanded(value)
            rebuild()
        }
        .onChange(of: expanded) { rebuild() }
        .onChange(of: shown) { rebuild() }
    }

    private func rebuild() {
        rows = AttachmentPreviewTree.rows(value, expanded: expanded, shown: shown)
    }
}

private struct AttachmentPreviewTreeRowView: View {
    let row: AttachmentPreviewTreeRow
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ForEach(1..<max(1, row.depth), id: \.self) { _ in
                Rectangle().fill(Theme.border).frame(width: 1).padding(.leading, 7).padding(.trailing, 12)
            }
            switch row.kind {
            case .primitive(let text):
                Color.clear.frame(width: 16, height: 1)
                if !row.path.isEmpty { key }
                Text(text).foregroundStyle(primitiveColor(text)).textSelection(.enabled)
            case .empty(let isArray):
                Color.clear.frame(width: 16, height: 1)
                key
                Text(isArray ? "[]" : "{}").foregroundStyle(.secondary)
            case .container(let isArray, let count, let open, let preview):
                Button(action: action) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        key
                        Text(open ? tr("editor", isArray ? "attachment.tree_items" : "attachment.tree_keys", ["count": count]) : preview)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            case .showMore(let remaining):
                Button(tr("editor", "attachment.tree_show_more", ["count": remaining]), action: action)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(minHeight: 22)
    }

    private var key: some View {
        HStack(spacing: 0) {
            Text(row.keyIsIndex ? row.key : AttachmentPreview.formatKey(row.key))
                .foregroundStyle(row.keyIsIndex ? Color.secondary : Color(light: 0x4078F2, dark: 0x61AFEF))
            Text(":").foregroundStyle(.secondary)
        }
    }

    private func primitiveColor(_ text: String) -> Color {
        if text.hasPrefix("\"") { return Color(light: 0x50A14F, dark: 0x98C379) }
        if text == "true" || text == "false" || text == "null" { return Color(light: 0x0184BC, dark: 0x56B6C2) }
        return Color(light: 0x986801, dark: 0xD19A66)
    }
}
