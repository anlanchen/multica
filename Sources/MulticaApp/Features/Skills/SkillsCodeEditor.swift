import AppKit
import MulticaCore
import SwiftUI

/// Plain-text editor for skill files: NSTextView (undo, find, IME) with
/// `SyntaxHighlighter` colors applied off the main actor after typing pauses.
struct SkillsCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: String?
    var isEditable: Bool
    var placeholder: String
    /// Changes when the caret should move into this editor (caret at top).
    var focusToken: Int
    var onFocusHandled: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.font = Coordinator.font
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 24, height: 18)
        tv.string = text
        tv.isEditable = isEditable
        tv.isSelectable = true
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        context.coordinator.placeholder.stringValue = placeholder
        context.coordinator.attachPlaceholder(to: tv)
        context.coordinator.scheduleHighlight(immediate: true)
        context.coordinator.lastFocusToken = focusToken
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        let languageChanged = c.parent.language != language
        c.parent = self
        guard let tv = c.textView else { return }
        tv.isEditable = isEditable
        c.placeholder.stringValue = placeholder
        if tv.string != text {
            tv.string = text
            tv.font = Coordinator.font
            c.scheduleHighlight(immediate: true)
        } else if languageChanged {
            c.scheduleHighlight(immediate: true)
        }
        c.updatePlaceholder()
        if focusToken != c.lastFocusToken {
            c.lastFocusToken = focusToken
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
                self.onFocusHandled()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

        var parent: SkillsCodeEditor
        weak var textView: NSTextView?
        let placeholder = NSTextField(labelWithString: "")
        var lastFocusToken = 0
        private var highlightTask: Task<Void, Never>?

        init(_ parent: SkillsCodeEditor) {
            self.parent = parent
        }

        func attachPlaceholder(to tv: NSTextView) {
            placeholder.font = Self.font
            placeholder.textColor = .placeholderTextColor
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            tv.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: tv.textContainerInset.width + 5),
                placeholder.topAnchor.constraint(equalTo: tv.topAnchor, constant: tv.textContainerInset.height),
            ])
            updatePlaceholder()
        }

        func updatePlaceholder() {
            placeholder.isHidden = !(textView?.string.isEmpty ?? true)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            updatePlaceholder()
            scheduleHighlight(immediate: false)
        }

        func scheduleHighlight(immediate: Bool) {
            highlightTask?.cancel()
            guard let tv = textView else { return }
            let code = tv.string
            let language = parent.language
            highlightTask = Task { [weak self] in
                if !immediate { try? await Task.sleep(for: .milliseconds(150)) }
                guard !Task.isCancelled else { return }
                let tokens: [SyntaxHighlighter.Token] = language == nil ? [] : await Task.detached(priority: .userInitiated) {
                    SyntaxHighlighter.tokens(code, language: language)
                }.value
                guard !Task.isCancelled, let self, let tv = self.textView, tv.string == code else { return }
                self.apply(tokens, to: tv)
            }
        }

        private func apply(_ tokens: [SyntaxHighlighter.Token], to tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let length = storage.length
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: length))
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: length))
            for t in tokens {
                let range = NSRange(location: t.range.lowerBound, length: t.range.count)
                guard range.location + range.length <= length else { continue }
                storage.addAttribute(.foregroundColor, value: Self.color(t.kind), range: range)
                if t.kind == .inserted || t.kind == .deleted {
                    storage.addAttribute(.backgroundColor, value: Self.color(t.kind).withAlphaComponent(0.1), range: range)
                }
            }
            storage.endEditing()
        }

        static func color(_ kind: SyntaxHighlighter.Kind) -> NSColor {
            func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
                NSColor(name: nil) { appearance in
                    let v = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
                }
            }
            switch kind {
            case .keyword: return dynamic(0xA626A4, 0xC678DD)
            case .string: return dynamic(0x50A14F, 0x98C379)
            case .comment: return dynamic(0xA0A1A7, 0x7F848E)
            case .number: return dynamic(0x986801, 0xD19A66)
            case .type: return dynamic(0xC18401, 0xE5C07B)
            case .attribute: return dynamic(0x4078F2, 0x61AFEF)
            case .inserted: return dynamic(0x1C882D, 0x4AA651)
            case .deleted: return dynamic(0xE7000B, 0xFF6467)
            case .meta: return dynamic(0x0072D5, 0x4390EE)
            }
        }
    }
}
