import AppKit
import MulticaCore
import SwiftUI

/// Something that can be @-mentioned in an editor.
struct MentionCandidate: Identifiable, Hashable {
    var type: String   // member | agent | squad | issue | project | all
    var id: String
    var label: String
    var subtitle: String? = nil
    var avatarURL: String? = nil
    /// Issues: their status, for the row glyph.
    var status: IssueStatusKey? = nil
    /// Closed issues / cancelled projects sort into their own group.
    var isClosed = false

    /// Upstream mention renderMarkdown: issues and projects carry no `@`.
    var markdown: String {
        let prefix = type == "issue" || type == "project" ? "" : "@"
        return "[\(prefix)\(AttachmentUpload.escapeLabel(label))](mention://\(type)/\(id))"
    }

    var isUserGroup: Bool { type == "member" || type == "agent" || type == "squad" || type == "all" }
}

/// An entry of the editor's `/` menu: the issue-comment command menu
/// (quick actions + `/note`) or the chat skill picker.
struct EditorSlashCommand: Identifiable, Hashable {
    enum Kind: Hashable { case builtin, quickAction, skill }
    var id: String
    var label: String
    var description: String?
    var kind: Kind
}

/// Which `/` menu an editor offers.
enum EditorSlashMode {
    /// Issue comments: hidden when nothing matches.
    case commands
    /// Chat: explains an empty skill list.
    case skills
}

/// Markdown source editor used for descriptions, comments, chat and agent
/// instructions. Native NSTextView: undo, spellcheck, IME and selection come
/// from AppKit; it grows with its content between `minHeight` and
/// `maxHeight`. `@` opens mention suggestions, `/` the slash menu.
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
    /// Server-side issue search merged into the mention list.
    var searchIssues: ((String) async -> [MentionCandidate])? = nil
    /// Entries for a query typed after `/`.
    var slashCommands: ((String) -> [EditorSlashCommand])? = nil
    var slashMode: EditorSlashMode = .commands
    /// Resolves a quick action to the text it inserts (server-rendered).
    var renderSlashCommand: ((EditorSlashCommand) async throws -> String)? = nil

    @State private var height: CGFloat = 36
    @State private var trigger: EditorTrigger?
    @State private var selection = 0
    @State private var controller = EditorController()
    @State private var searched: (query: String, items: [MentionCandidate])?
    @State private var searching = false
    @Environment(Toaster.self) private var toaster: Toaster?

    private var picks: [EditorPick] {
        guard let trigger else { return [] }
        if trigger.char == "/" {
            return (slashCommands?(trigger.query) ?? []).prefix(20).map(EditorPick.command)
        }
        var items = mentions?(trigger.query) ?? []
        if let searched, searched.query == trigger.query {
            let known = Set(items.map(\.id))
            items += searched.items.filter { !known.contains($0.id) }
        }
        let users = items.filter(\.isUserGroup)
        let open = items.filter { !$0.isUserGroup && !$0.isClosed }
        let closed = items.filter { !$0.isUserGroup && $0.isClosed }
        return (users + open + closed).prefix(20).map(EditorPick.mention)
    }

    var body: some View {
        let picks = self.picks
        ZStack(alignment: .topLeading) {
            EditorTextView(
                text: $text,
                height: $height,
                trigger: $trigger,
                selection: $selection,
                pickCount: picks.count,
                slashEnabled: slashCommands != nil,
                mentionsEnabled: mentions != nil,
                fontSize: fontSize,
                monospaced: monospaced,
                autofocus: autofocus,
                isEditable: isEditable,
                controller: controller,
                onSubmit: onSubmit,
                onEscape: onEscape,
                onFiles: onFiles,
                onPick: { i in if picks.indices.contains(i) { pick(picks[i]) } }
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
            if let trigger, showsPopup(trigger, picks) {
                EditorSuggestionList(picks: picks, selected: selection, searching: searching && trigger.char == "@",
                                     emptyText: emptyText(trigger)) { pick($0) }
                    .offset(y: CGFloat(min(max(picks.count, 1), 8)) * 28 + 16)
                    .zIndex(10)
            }
        }
        .onChange(of: trigger) { selection = 0 }
        .task(id: trigger?.char == "@" ? trigger?.query : nil) {
            guard let q = trigger?.query, trigger?.char == "@", let searchIssues, !q.isEmpty else { searching = false; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let found = await searchIssues(q)
            guard !Task.isCancelled else { return }
            searched = (q, found)
            searching = false
        }
        .environment(\.markdownEditorController, controller)
    }

    private func showsPopup(_ t: EditorTrigger, _ picks: [EditorPick]) -> Bool {
        if !picks.isEmpty { return true }
        if t.char == "/" { return slashMode == .skills }
        return searching
    }

    private func emptyText(_ t: EditorTrigger) -> String? {
        guard t.char == "/", slashMode == .skills else { return nil }
        return t.query.isEmpty ? tr("editor", "slash_command.no_skills_configured") : tr("editor", "slash_command.no_results")
    }

    private func pick(_ p: EditorPick) {
        guard let trigger else { return }
        switch p {
        case .mention(let c):
            controller.replace(trigger, with: c.markdown + " ")
        case .command(let c):
            switch c.kind {
            case .builtin:
                controller.replace(trigger, with: "/\(c.label) ")
            case .skill:
                controller.replace(trigger, with: "[/\(AttachmentUpload.escapeLabel(c.label))](slash://skill/\(c.id)) ")
            case .quickAction:
                guard let render = renderSlashCommand else { return }
                // The typed "/query" stays until the body arrives; a command
                // edited meanwhile is abandoned rather than overwritten.
                let original = controller.text(in: trigger)
                Task {
                    do {
                        let body = try await render(c)
                        guard !body.isEmpty, controller.text(in: trigger) == original else { return }
                        controller.replace(trigger, with: body)
                    } catch {
                        toaster?.error(error)
                    }
                }
            }
        }
        self.trigger = nil
    }
}

/// The token being completed: `@query` or `/query` starting at `start`.
struct EditorTrigger: Equatable {
    var char: Character
    var query: String
    var start: Int
}

enum EditorPick: Hashable {
    case mention(MentionCandidate)
    case command(EditorSlashCommand)
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
        guard let start = mentionStart else { return }
        replace(EditorTrigger(char: "@", query: "", start: start), with: c.markdown + " ")
        mentionStart = nil
    }

    /// Text from the trigger character to the caret.
    func text(in t: EditorTrigger) -> String? {
        guard let tv = textView else { return nil }
        let caret = tv.selectedRange().location
        let s = tv.string as NSString
        guard t.start <= caret, caret <= s.length else { return nil }
        return s.substring(with: NSRange(location: t.start, length: caret - t.start))
    }

    func replace(_ t: EditorTrigger, with string: String) {
        guard let tv = textView else { return }
        let caret = tv.selectedRange().location
        let length = (tv.string as NSString).length
        guard t.start <= caret, caret <= length else { return }
        tv.insertText(string, replacementRange: NSRange(location: t.start, length: caret - t.start))
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

private struct EditorSuggestionList: View {
    let picks: [EditorPick]
    let selected: Int
    let searching: Bool
    let emptyText: String?
    let pick: (EditorPick) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(picks.enumerated()), id: \.offset) { i, p in
                        if let header = header(at: i) {
                            Text(header).font(Theme.Font.micro).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.top, i == 0 ? 4 : 8).padding(.bottom, 2)
                        }
                        Button { pick(p) } label: { row(p) }
                            .buttonStyle(.plain)
                            .background(i == selected ? Theme.selected : .clear)
                            .id(i)
                    }
                    if searching {
                        Text(tr("editor", "mention.searching")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(8)
                    } else if picks.isEmpty, let emptyText {
                        Text(emptyText).font(Theme.Font.caption).foregroundStyle(.secondary).padding(8)
                    }
                }
            }
            .frame(maxHeight: 8 * 28 + 24)
            .onChange(of: selected) { proxy.scrollTo(selected) }
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
        .shadow(radius: 8, y: 2)
    }

    private func group(_ p: EditorPick) -> String? {
        guard case .mention(let c) = p else { return nil }
        if c.isUserGroup { return tr("editor", "mention.group_users") }
        return c.isClosed ? tr("editor", "mention.group_cancelled") : tr("editor", "mention.group_issues")
    }

    private func header(at i: Int) -> String? {
        guard let g = group(picks[i]) else { return nil }
        let groups = Set(picks.compactMap(group))
        guard groups.count > 1 else { return nil }
        return i == 0 || group(picks[i - 1]) != g ? g : nil
    }

    @ViewBuilder private func row(_ p: EditorPick) -> some View {
        HStack(spacing: 8) {
            switch p {
            case .mention(let c):
                switch c.type {
                case "issue":
                    if let s = c.status { StatusIcon(status: s, size: 14).frame(width: 18) } else { Image(systemName: "number").frame(width: 18) }
                case "project": Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 18)
                case "all": Image(systemName: "at").frame(width: 18)
                default: AvatarView(name: c.label, url: c.avatarURL, kind: AvatarKind(actorType: c.type), size: 18)
                }
                Text(c.type == "all" ? tr("editor", "mention.all_members") : c.label).lineLimit(1)
                if let s = c.subtitle { Text(s).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 4)
                if c.type == "agent" { Badge(text: tr("editor", "mention.agent_badge")) }
                if c.type == "squad" { Badge(text: tr("editor", "mention.squad_badge")) }
            case .command(let c):
                Image(systemName: c.kind == .skill ? "book" : c.kind == .quickAction ? "bolt" : "note.text")
                    .foregroundStyle(.secondary).frame(width: 18)
                Text("/" + c.label).lineLimit(1)
                if let d = c.kind == .builtin ? tr("editor", "slash_command.commands.\(c.id)") : c.description, !d.isEmpty {
                    Text(d).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
        }
        .font(Theme.Font.body)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .contentShape(Rectangle())
    }
}

private final class GrowingTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFiles: (([URL]) -> Void)?
    /// Set by a paste; a `/` the user did not type never opens the menu
    /// (upstream MUL-5429: pasted paths like `/usr/local/bin`).
    var lastEditWasPaste = false

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onSubmit?()
            return
        }
        lastEditWasPaste = false
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
        lastEditWasPaste = true
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
    @Binding var trigger: EditorTrigger?
    @Binding var selection: Int
    let pickCount: Int
    let slashEnabled: Bool
    let mentionsEnabled: Bool
    let fontSize: CGFloat
    let monospaced: Bool
    let autofocus: Bool
    let isEditable: Bool
    let controller: EditorController
    let onSubmit: (() -> Void)?
    let onEscape: (() -> Void)?
    let onFiles: (([URL]) -> Void)?
    let onPick: (Int) -> Void

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
            updateTrigger()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateTrigger()
        }

        func recalcHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2 + 4
            if abs(parent.height - h) > 0.5 {
                DispatchQueue.main.async { self.parent.height = h }
            }
        }

        private func updateTrigger() {
            guard let tv = textView as? GrowingTextView, parent.mentionsEnabled || parent.slashEnabled else { return }
            let s = tv.string as NSString
            let caret = tv.selectedRange().location
            var found: EditorTrigger?
            var i = caret - 1
            while i >= 0, caret - i <= 64 {
                let ch = s.character(at: i)
                if ch == 32 || ch == 10 || ch == 9 { break }
                if ch == 64 || ch == 47 { // "@" "/"
                    let query = s.substring(with: NSRange(location: i + 1, length: caret - i - 1))
                    let before: String = i == 0 ? "" : s.substring(with: s.rangeOfComposedCharacterSequence(at: i - 1))
                    if ch == 64, parent.mentionsEnabled, EditorTextView.isMentionBoundary(after: before) {
                        found = EditorTrigger(char: "@", query: query, start: i)
                    } else if ch == 47, parent.slashEnabled, !tv.lastEditWasPaste,
                              before.isEmpty || before.allSatisfy(\.isWhitespace) {
                        found = EditorTrigger(char: "/", query: query, start: i)
                    }
                    break
                }
                i -= 1
            }
            parent.controller.mentionStart = found?.char == "@" ? found?.start : nil
            if parent.trigger != found {
                parent.trigger = found
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard parent.trigger != nil else { return false }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.trigger = nil
                return true
            }
            guard parent.pickCount > 0 else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                parent.selection = min(parent.selection + 1, parent.pickCount - 1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.selection = max(parent.selection - 1, 0)
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                parent.onPick(parent.selection)
                return true
            default:
                return false
            }
        }
    }

    /// Upstream `isMentionBoundaryAfter`: an `@` starts a mention unless it
    /// continues a word; spaceless scripts (CJK, Thai, …) are an exception.
    static func isMentionBoundary(after previous: String) -> Bool {
        guard let scalar = previous.unicodeScalars.last else { return true }
        let v = scalar.value
        let spaceless = (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x3040...0x30FF).contains(v)
            || (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) || (0x0E00...0x0EFF).contains(v)
            || (0x1780...0x17FF).contains(v) || (0x1000...0x109F).contains(v) || (0x0F00...0x0FFF).contains(v)
            || (0x20000...0x2FA1F).contains(v) || v == 0xFF70 || v == 0xFF9E || v == 0xFF9F
        if spaceless { return true }
        let props = scalar.properties
        let word = props.isAlphabetic || props.numericType != nil || scalar == "_"
            || props.generalCategory == .nonspacingMark || props.generalCategory == .spacingMark || props.generalCategory == .enclosingMark
        return !word
    }
}

/// Upstream pinyin-match: Han names match a query by full pinyin, initials,
/// or a mix of syllable prefixes (`zhangs` → 张三).
enum EditorPinyin {
    @MainActor private static var cache: [String: [String]] = [:]

    @MainActor static func matches(_ name: String, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        guard name.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return false }
        let syllables = syllables(of: name)
        let q = query.lowercased()
        if syllables.joined().hasPrefix(q) { return true }
        if String(syllables.compactMap(\.first)).hasPrefix(q) { return true }
        return hybrid(syllables, 0, Array(q), 0)
    }

    @MainActor private static func syllables(of name: String) -> [String] {
        if let hit = cache[name] { return hit }
        let latin = name.applyingTransform(.mandarinToLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? name
        let parts = latin.lowercased().replacingOccurrences(of: "ü", with: "v").split(whereSeparator: \.isWhitespace).map(String.init)
        if cache.count > 2000 { cache.removeAll() }
        cache[name] = parts
        return parts
    }

    private static func hybrid(_ arr: [String], _ ai: Int, _ q: [Character], _ qi: Int) -> Bool {
        if qi >= q.count { return true }
        if ai >= arr.count { return false }
        let syllable = Array(arr[ai])
        var len = syllable.count
        while len >= 1 {
            if qi + len <= q.count, Array(q[qi..<(qi + len)]) == Array(syllable[0..<len]), hybrid(arr, ai + 1, q, qi + len) { return true }
            len -= 1
        }
        return false
    }
}

extension WorkspaceSession {
    /// Upstream mention suggestion items: "all", members, agents the user may
    /// assign, squads, then loaded issues and projects.
    func mentionCandidates(_ query: String, includeIssues: Bool = false) -> [MentionCandidate] {
        let q = query.lowercased()
        func match(_ s: String) -> Bool { q.isEmpty || s.lowercased().contains(q) || EditorPinyin.matches(s, q) }
        var out: [MentionCandidate] = []
        if q.isEmpty || "all members".contains(q) || "all".contains(q) {
            out.append(MentionCandidate(type: "all", id: "all", label: "All members"))
        }
        for m in directory.members where match(m.name) {
            out.append(MentionCandidate(type: "member", id: m.userID, label: m.name, avatarURL: m.avatarURL))
        }
        let ctx = PermissionContext(userID: currentUser.id, role: directory.member(userID: currentUser.id)?.role)
        let records = agentRecords.isLoaded ? Dictionary(agentRecords.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
        for a in directory.agents where a.archivedAt == nil && match(a.name) {
            if let r = records[a.id], !Permissions.canAssignAgentToIssue(r, ctx).allowed { continue }
            out.append(MentionCandidate(type: "agent", id: a.id, label: a.name, avatarURL: a.avatarURL))
        }
        for s in squads.items where s.archivedAt == nil && match(s.name) {
            out.append(MentionCandidate(type: "squad", id: s.id, label: s.name, avatarURL: s.avatarUrl))
        }
        if includeIssues {
            var issueCount = 0
            for model in issues.allModels {
                let i = model.issue
                guard match(i.identifier) || match(i.title) else { continue }
                let closed = i.status == .cancelled || i.status == .done
                out.append(MentionCandidate(type: "issue", id: i.id, label: i.identifier, subtitle: i.title, status: i.status, isClosed: closed))
                issueCount += 1
                if issueCount >= 12 { break }
            }
            for p in projects.items.prefix(200) where match(p.title) {
                out.append(MentionCandidate(type: "project", id: p.id, label: p.title, subtitle: (p.description ?? "").isEmpty ? nil : p.description,
                                            isClosed: p.status == "cancelled"))
            }
        }
        return out
    }

    /// Server-side issue search for mentions (upstream "Search results").
    func searchMentionIssues(_ query: String) async -> [MentionCandidate] {
        guard let result = try? await api.searchIssues(q: query, limit: 10, includeClosed: true) else { return [] }
        return result.issues.map {
            let status = IssueStatusKey(rawValue: $0.status)
            return MentionCandidate(type: "issue", id: $0.id, label: $0.identifier, subtitle: $0.title, status: status,
                                    isClosed: status == .cancelled || status == .done)
        }
    }

    /// The issue-comment `/` menu: active quick actions first, then `/note`
    /// (prefix match on the label, like upstream).
    func commentSlashCommands(_ query: String) -> [EditorSlashCommand] {
        if !quickActions.isLoaded { Task { await quickActions.loadIfNeeded() } }
        let q = query.lowercased()
        let actions = quickActions.items.filter { $0.status == "active" }.map {
            EditorSlashCommand(id: $0.id, label: $0.name, description: $0.description.isEmpty ? nil : $0.description, kind: .quickAction)
        }
        let builtins = [EditorSlashCommand(id: "note", label: "note", description: nil, kind: .builtin)]
        return (actions + builtins).filter { $0.label.lowercased().hasPrefix(q) }
    }

    /// The chat `/` skill picker for the active agent, ranked like upstream:
    /// exact name, prefix, substring, then description.
    func skillSlashCommands(_ query: String, agentID: String?) -> [EditorSlashCommand] {
        if !agentRecords.isLoaded { Task { await agentRecords.loadIfNeeded() } }
        let ctx = PermissionContext(userID: currentUser.id, role: directory.member(userID: currentUser.id)?.role)
        let available = agentRecords.items.filter { $0.archivedAt == nil && Permissions.canAssignAgentToIssue($0, ctx).allowed }
        guard let agent = available.first(where: { $0.id == agentID }) ?? available.first else { return [] }
        let q = query.lowercased()
        func rank(_ name: String, _ description: String) -> Int? {
            let n = name.lowercased()
            if q.isEmpty || n == q { return 0 }
            if n.hasPrefix(q) { return 1 }
            if n.contains(q) { return 2 }
            if description.lowercased().contains(q) { return 3 }
            return nil
        }
        return agent.skills.enumerated()
            .compactMap { i, s in rank(s.name, s.description).map { (r: $0, i: i, s: s) } }
            .sorted { ($0.r, $0.i) < ($1.r, $1.i) }
            .prefix(20)
            .map { EditorSlashCommand(id: $0.s.id, label: $0.s.name, description: $0.s.description, kind: .skill) }
    }

    /// Server-rendered body for a quick action picked in a comment composer.
    func renderSlashCommand(_ command: EditorSlashCommand, issueID: String) async throws -> String {
        try await api.renderQuickAction(issueId: issueID, quickActionId: command.id)
    }
}
