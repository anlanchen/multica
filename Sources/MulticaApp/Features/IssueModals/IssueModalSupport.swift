import AppKit
import MulticaCore
import SwiftUI

/// Extra opener context the `CreateIssueDraft` value cannot carry
/// (upstream modal `data`: comment anchor, agent seeds, parent identifier).
struct IssueModalCreateContext {
    var anchorCommentID: String?
    var parentIssueID: String?
    var parentIssueIdentifier: String?
    var stage: Int?
    var agentID: String?
    var squadID: String?
    var prompt: String?
}

@MainActor
enum IssueModalPending {
    static var createContext: IssueModalCreateContext?
    static var runIntents: [String: IssueModalRunIntent] = [:]
    /// What the dialog last mirrored into `AppEnvironment.issueDraft`, so a
    /// reopen seeded with that mirror is not mistaken for an opener's seed.
    static var lastMirror: CreateIssueDraft?

    static func takeCreateContext() -> IssueModalCreateContext? {
        defer { createContext = nil }
        return createContext
    }

    static let modeKey = "multica.createIssue.mode"

    static func setLastMode(_ mode: CreateIssueMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
    }
}

extension ModalCenter {
    /// Run confirmation with its full payload (assignee or promotion target,
    /// batch ids). `.runConfirm(issueID:)` alone falls back to the issue's
    /// current agent owner.
    func issueModalConfirmRun(_ intent: IssueModalRunIntent) {
        guard let first = intent.issueIDs.first else { return }
        IssueModalPending.runIntents[first] = intent
        present(.runConfirm(issueID: first))
    }

    /// Create dialog seeded with context the draft value has no room for:
    /// a sub-issue from a comment (captured source context), or an agent seed.
    func issueModalCreate(_ draft: CreateIssueDraft, context: IssueModalCreateContext, mode: CreateIssueMode? = nil) {
        IssueModalPending.createContext = context
        switch mode {
        case .agent?: present(.quickCreateIssue(draft))
        case .manual?: present(.createIssue(draft))
        case nil: createIssue(draft)
        }
    }
}

enum IssueModalErrors {
    static func code(_ error: Error) -> String? { (error as? APIError)?.code }
    static func body(_ error: Error) -> JSONValue? { (error as? APIError)?.body }
    static func status(_ error: Error) -> Int? { (error as? APIError)?.status }

    /// Upstream `err instanceof Error && err.message ? err.message : fallback`.
    static func message(_ error: Error, fallback: String) -> String {
        if let e = error as? APIError { return e.message.isEmpty ? fallback : e.message }
        let m = error.localizedDescription
        return m.isEmpty ? fallback : m
    }
}

extension WorkspaceSession {
    /// Issue write with the full upstream request shape: optimistic local
    /// patch, server answer adopted, rollback on failure.
    func issueModalUpdate(_ issueID: String, _ record: UpdateIssueRequestRecord, optimistic: (inout Issue) -> Void = { _ in }) async throws {
        let previous = issues.patch(issueID) { current in
            var next = current
            optimistic(&next)
            return next
        }
        issues.resectionIfNeeded()
        do {
            let updated = try await api.updateIssue(issueID, record: record)
            issues.upsert(updated)
        } catch {
            if let previous { issues.restore(previous) }
            throw error
        }
    }

    func issueModalCreate(_ record: CreateIssueRequestRecord) async throws -> Issue {
        let issue = try await api.createIssue(record: record)
        issues.upsert(issue, isNew: true)
        return issue
    }

    /// The signed-in member's workspace role.
    var issueModalRole: String? {
        directory.member(userID: currentUser.id)?.role
            ?? memberRecords.items.first { $0.userId == currentUser.id }?.role
    }
}

/// A child list whose rows keep `stage` (the hand-tuned `Issue` drops it).
private struct IssueModalChildEnvelope: Decodable, Sendable {
    var issues: [IssueRecord]
    enum CodingKeys: String, CodingKey { case issues }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issues = c.lossyArray(IssueRecord.self, .issues)
    }
}

extension APIClient {
    nonisolated func issueModalChildRecords(_ parentID: String) async throws -> [IssueRecord] {
        try await call(.get, "/api/issues/\(parentID.pathEscaped)/children", as: IssueModalChildEnvelope.self).issues
    }
}

/// The `send` shortcut (⌘↩ by default) as a SwiftUI key equivalent. Chords
/// without a modifier are left to the editors so plain keys keep typing.
struct IssueModalSendShortcut: ViewModifier {
    @Environment(ShortcutStore.self) private var shortcuts

    func body(content: Content) -> some View {
        if let chord = shortcuts.chord(for: .send), let key = Self.key(chord.key), chord.primary || chord.control || chord.alt {
            content.keyboardShortcut(key, modifiers: Self.modifiers(chord))
        } else {
            content
        }
    }

    static func key(_ k: String) -> KeyEquivalent? {
        switch k {
        case "Enter": return .return
        case "Space": return .space
        case "Tab": return .tab
        case "Up": return .upArrow
        case "Down": return .downArrow
        case "Left": return .leftArrow
        case "Right": return .rightArrow
        default: return k.count == 1 ? KeyEquivalent(Character(k.lowercased())) : nil
        }
    }

    static func modifiers(_ c: ShortcutChord) -> EventModifiers {
        var m: EventModifiers = []
        if c.primary { m.insert(.command) }
        if c.control { m.insert(.control) }
        if c.alt { m.insert(.option) }
        if c.shift { m.insert(.shift) }
        return m
    }
}

/// Keycaps for the `send` chord, drawn inside a primary button.
struct IssueModalSendKeyCaps: View {
    @Environment(ShortcutStore.self) private var shortcuts

    var body: some View {
        if let chord = shortcuts.chord(for: .send) {
            HStack(spacing: 2) {
                ForEach(Array(chord.display.enumerated()), id: \.offset) { _, k in
                    Text(k)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 3)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.18)))
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Filled accent button used for dialog primary actions.
struct IssueModalPrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.brand
    var dimmed = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.bodyMedium)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(tint.opacity(configuration.isPressed ? 0.85 : 1)))
            .opacity(isEnabled && !dimmed ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}

/// Bordered secondary dialog button.
struct IssueModalOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.bodyMedium)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(configuration.isPressed ? Theme.selected : Color.primary.opacity(0.02)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.primary.opacity(0.15)))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}

/// Small square header icon button (expand / close).
struct IssueModalIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .hoverHighlight(cornerRadius: Theme.Radius.small)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Wraps children onto new lines like a CSS `flex-wrap` row.
struct IssueModalFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// Pinyin syllables for Chinese names, cached (upstream matchesPinyin
/// through pinyin-pro; here the system Mandarin→Latin transform).
@MainActor
enum IssueModalPinyin {
    private static var cache: [String: [String]] = [:]

    static func matches(_ name: String, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        guard name.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return false }
        return SearchPaletteMatch.pinyin(syllables: syllables(name), query: query)
    }

    static func syllables(_ name: String) -> [String] {
        if let hit = cache[name] { return hit }
        var out: [String] = []
        for ch in name {
            let s = String(ch)
            if let latin = s.applyingTransform(.mandarinToLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) {
                out.append(latin.lowercased().replacingOccurrences(of: "ü", with: "v").filter { !$0.isWhitespace })
            } else {
                out.append(s.lowercased())
            }
        }
        if cache.count > 2000 { cache.removeAll() }
        cache[name] = out
        return out
    }

    /// Name filter shared by every picker: substring or pinyin.
    static func filter(_ name: String, _ query: String) -> Bool {
        query.isEmpty || name.lowercased().contains(query) || matches(name, query)
    }
}
