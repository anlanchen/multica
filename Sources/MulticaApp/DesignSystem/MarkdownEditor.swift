import AppKit
import MulticaCore
import SwiftUI

/// Something that can be @-mentioned in an editor.
struct MentionCandidate: Identifiable, Hashable {
    var type: String   // member | agent | squad | issue | all
    var id: String
    var label: String
    var subtitle: String? = nil
    var avatarURL: String? = nil

    var markdown: String {
        type == "issue" || type == "project" ? "[\(label)](mention://\(type)/\(id))" : "[@\(label)](mention://\(type)/\(id))"
    }
}

/// Markdown source editor used for descriptions, comments, chat and agent
/// instructions. Native NSTextView: undo, spellcheck, IME and selection come
/// from AppKit; it grows with its content between `minHeight` and
/// `maxHeight`.
struct MarkdownEditor: View {
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 36
    var maxHeight: CGFloat = 320
    var fontSize: CGFloat = 13
    var monospaced = false
    var autofocus = false
    var isEditable = true
    /// ⌘↩ (upstream `send` shortcut).
    var onSubmit: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil
    /// Files pasted or dropped into the editor (upload, then insert links).
    var onFiles: (([URL]) -> Void)? = nil
    /// Mention candidates for a query typed after `@`.
    var mentions: ((String) -> [MentionCandidate])? = nil

    @State private var height: CGFloat = 36
    @State private var mentionQuery: String?
    @State private var mentionIndex = 0
    @State private var controller = EditorController()

    var body: some View {
        let candidates = mentionQuery.flatMap { q in mentions?(q) } ?? []
        ZStack(alignment: .topLeading) {
            EditorTextView(
                text: $text,
                height: $height,
                mentionQuery: $mentionQuery,
                mentionIndex: $mentionIndex,
                candidateCount: candidates.count,
                fontSize: fontSize,
                monospaced: monospaced,
                autofocus: autofocus,
                isEditable: isEditable,
                controller: controller,
                onSubmit: onSubmit,
                onEscape: onEscape,
                onFiles: onFiles,
                onPickMention: { i in
                    if candidates.indices.contains(i) { controller.insertMention(candidates[i]) }
                }
            )
            .frame(height: min(max(height, minHeight), maxHeight))
            if text.isEmpty && !placeholder.isEmpty {
                Text(placeholder)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !candidates.isEmpty {
                MentionList(candidates: candidates, selected: mentionIndex) { c in
                    controller.insertMention(c)
                }
                .offset(y: min(CGFloat(candidates.count), 6) * 28 + 12)
                .zIndex(10)
            }
        }
        .onChange(of: mentionQuery) { mentionIndex = 0 }
        .environment(\.markdownEditorController, controller)
    }
}

/// Lets toolbars insert text at the caret (attachments, emoji, templates).
@MainActor
final class EditorController {
    weak var textView: NSTextView?
    var mentionStart: Int?

    func insert(_ string: String) {
        guard let tv = textView else { return }
        tv.insertText(string, replacementRange: tv.selectedRange())
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    func insertMention(_ c: MentionCandidate) {
        guard let tv = textView, let start = mentionStart else { return }
        let caret = tv.selectedRange().location
        let range = NSRange(location: start, length: max(0, caret - start))
        tv.insertText(c.markdown + " ", replacementRange: range)
        mentionStart = nil
    }
}

private struct EditorControllerKey: EnvironmentKey {
    static let defaultValue: EditorController? = nil
}

extension EnvironmentValues {
    var markdownEditorController: EditorController? {
        get { self[EditorControllerKey.self] }
        set { self[EditorControllerKey.self] = newValue }
    }
}

private struct MentionList: View {
    let candidates: [MentionCandidate]
    let selected: Int
    let pick: (MentionCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(candidates.prefix(6).enumerated()), id: \.element.id) { i, c in
                Button { pick(c) } label: {
                    HStack(spacing: 8) {
                        if c.type == "issue" {
                            Image(systemName: "number").frame(width: 18)
                        } else if c.type == "all" {
                            Image(systemName: "at").frame(width: 18)
                        } else {
                            AvatarView(name: c.label, url: c.avatarURL, kind: AvatarKind(actorType: c.type), size: 18)
                        }
                        Text(c.label).lineLimit(1)
                        if let s = c.subtitle { Text(s).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                    }
                    .font(Theme.Font.body)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(i == selected ? Theme.selected : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
        .shadow(radius: 8, y: 2)
    }
}

private final class GrowingTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFiles: (([URL]) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }

    private func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func pastedImageFile(_ pb: NSPasteboard) -> URL? {
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pasted-\(UUID().uuidString.prefix(8)).png")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let onFiles {
            let files = fileURLs(pb)
            if !files.isEmpty { onFiles(files); return }
            if pb.string(forType: .string) == nil, let image = pastedImageFile(pb) { onFiles([image]); return }
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let onFiles {
            let files = fileURLs(sender.draggingPasteboard)
            if !files.isEmpty { onFiles(files); return true }
        }
        return super.performDragOperation(sender)
    }
}

private struct EditorTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var mentionQuery: String?
    @Binding var mentionIndex: Int
    let candidateCount: Int
    let fontSize: CGFloat
    let monospaced: Bool
    let autofocus: Bool
    let isEditable: Bool
    let controller: EditorController
    let onSubmit: (() -> Void)?
    let onEscape: (() -> Void)?
    let onFiles: (([URL]) -> Void)?
    let onPickMention: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = GrowingTextView()
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.lineFragmentPadding = 5
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.font = monospaced ? .monospacedSystemFont(ofSize: fontSize, weight: .regular) : .systemFont(ofSize: fontSize)
        tv.string = text
        tv.delegate = context.coordinator
        tv.registerForDraggedTypes([.fileURL])
        scroll.documentView = tv
        controller.textView = tv
        context.coordinator.textView = tv
        if autofocus {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? GrowingTextView else { return }
        tv.onSubmit = onSubmit
        tv.onEscape = onEscape
        tv.onFiles = onFiles
        tv.isEditable = isEditable
        if tv.string != text {
            tv.string = text
            context.coordinator.recalcHeight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorTextView
        weak var textView: NSTextView?

        init(_ parent: EditorTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            recalcHeight()
            updateMention()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateMention()
        }

        func recalcHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2 + 4
            if abs(parent.height - h) > 0.5 {
                DispatchQueue.main.async { self.parent.height = h }
            }
        }

        private func updateMention() {
            guard parent.onPickMentionEnabled, let tv = textView else { return }
            let s = tv.string as NSString
            let caret = tv.selectedRange().location
            var i = caret - 1
            var query: String?
            while i >= 0 {
                let ch = s.character(at: i)
                if ch == 64 { // "@"
                    let before = i == 0 ? 32 : s.character(at: i - 1)
                    if before == 32 || before == 10 || before == 40 || i == 0 {
                        query = s.substring(with: NSRange(location: i + 1, length: caret - i - 1))
                        parent.controller.mentionStart = i
                    }
                    break
                }
                if ch == 32 || ch == 10 || caret - i > 32 { break }
                i -= 1
            }
            if parent.mentionQuery != query {
                parent.mentionQuery = query
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard parent.mentionQuery != nil, parent.candidateCount > 0 else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                parent.mentionIndex = min(parent.mentionIndex + 1, min(parent.candidateCount, 6) - 1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.mentionIndex = max(parent.mentionIndex - 1, 0)
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                parent.onPickMention(parent.mentionIndex)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.mentionQuery = nil
                return true
            default:
                return false
            }
        }
    }

    var onPickMentionEnabled: Bool { true }
}

extension WorkspaceSession {
    /// Members, agents and squads matching `query` (upstream mention list:
    /// "all" first, then people and agents).
    func mentionCandidates(_ query: String, includeIssues: Bool = false) -> [MentionCandidate] {
        let q = query.lowercased()
        func match(_ s: String) -> Bool { q.isEmpty || s.lowercased().contains(q) }
        var out: [MentionCandidate] = []
        if match("all") { out.append(MentionCandidate(type: "all", id: "all", label: "all", subtitle: nil)) }
        for m in directory.members where match(m.name) || match(m.email) {
            out.append(MentionCandidate(type: "member", id: m.userID, label: m.name, subtitle: m.email, avatarURL: m.avatarURL))
        }
        for a in directory.agents where a.archivedAt == nil && match(a.name) {
            out.append(MentionCandidate(type: "agent", id: a.id, label: a.name, avatarURL: a.avatarURL))
        }
        for s in squads.items where s.archivedAt == nil && match(s.name) {
            out.append(MentionCandidate(type: "squad", id: s.id, label: s.name, avatarURL: s.avatarUrl))
        }
        if includeIssues {
            for model in issues.allModels.prefix(400) where match(model.issue.identifier) || match(model.issue.title) {
                out.append(MentionCandidate(type: "issue", id: model.issue.id, label: model.issue.identifier, subtitle: model.issue.title))
                if out.count > 30 { break }
            }
        }
        return out
    }
}
