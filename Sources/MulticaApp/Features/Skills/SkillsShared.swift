import AppKit
import MulticaCore
import SwiftUI

/// The glyph that means "a skill" anywhere one is shown as an entity,
/// derived from the route icon so sidebar, tabs and pages agree.
let skillsIcon = WorkspacePage.skills.icon.systemImage

enum SkillsOriginStyle {
    static func icon(_ type: SkillsOriginType) -> String {
        switch type {
        case .manual: return "pencil"
        case .runtimeLocal: return "internaldrive"
        case .clawhub, .skillsSh, .github: return "arrow.down.to.line"
        }
    }

    /// List "Source" column label.
    static func tableLabel(_ origin: SkillsOrigin, runtime: RuntimeDeviceRecord?) -> String {
        switch origin.type {
        case .manual: return tr("skills", "table.source_manual")
        case .runtimeLocal:
            if let runtime { return tr("skills", "table.source_runtime_named", ["name": SkillsRuntimeLabels.displayLabel(runtime)]) }
            if let provider = origin.provider, !provider.isEmpty { return tr("skills", "table.source_runtime_provider", ["provider": provider]) }
            return tr("skills", "table.source_runtime_unknown")
        case .clawhub: return tr("skills", "table.source_clawhub")
        case .skillsSh: return tr("skills", "table.source_skills_sh")
        case .github: return tr("skills", "table.source_github")
        }
    }

    /// Filter-menu label for an origin type.
    static func filterLabel(_ type: SkillsOriginType) -> String {
        switch type {
        case .manual: return tr("skills", "table.source_manual")
        case .runtimeLocal: return tr("skills", "table.source_runtime_unknown")
        case .clawhub: return tr("skills", "table.source_clawhub")
        case .skillsSh: return tr("skills", "table.source_skills_sh")
        case .github: return tr("skills", "table.source_github")
        }
    }

    /// Detail identity-strip label.
    static func detailLabel(_ origin: SkillsOrigin, runtime: RuntimeDeviceRecord?) -> String {
        switch origin.type {
        case .manual: return tr("skills", "detail.subline.origin_workspace")
        case .runtimeLocal:
            if let runtime { return tr("skills", "detail.subline.origin_runtime_named", ["name": SkillsRuntimeLabels.displayLabel(runtime)]) }
            if let provider = origin.provider, !provider.isEmpty { return tr("skills", "detail.subline.origin_runtime_provider", ["provider": provider]) }
            return tr("skills", "detail.subline.origin_runtime_unknown")
        case .clawhub: return tr("skills", "detail.subline.origin_clawhub")
        case .skillsSh: return tr("skills", "detail.subline.origin_skills_sh")
        case .github: return tr("skills", "detail.subline.origin_github")
        }
    }

    /// The hosted source a refresh re-downloads from.
    static func refreshSourceLabel(_ origin: SkillsOrigin) -> String {
        switch origin.type {
        case .clawhub: return tr("skills", "detail.refresh.source_clawhub")
        case .skillsSh: return tr("skills", "detail.refresh.source_skills_sh")
        default: return tr("skills", "detail.refresh.source_github")
        }
    }
}

extension WorkspaceSession {
    /// The signed-in member's workspace role, from the member catalog.
    var skillsMyRole: String? {
        memberRecords.items.first { $0.userId == currentUser.id }?.role
    }

    var skillsStore: SkillsStore { SkillsStore.shared(for: self) }

    /// Catalogs every skills screen reads.
    func skillsLoadSupportingData() async {
        async let agents: Void = agentRecords.loadIfNeeded()
        async let members: Void = memberRecords.loadIfNeeded()
        async let runtimes: Void = runtimeRecords.loadIfNeeded()
        _ = await (agents, members, runtimes)
    }

    var skillsSupportingDataFailed: Bool {
        agentRecords.error != nil || memberRecords.error != nil || runtimeRecords.error != nil
    }
}

extension View {
    /// Re-runs `action` when `id` or any of the session revisions change.
    /// The revisions are read inside the modifier so an unrelated realtime
    /// event re-evaluates only this modifier, not the page body.
    func skillsRefetch(on keys: [String], id: String, _ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(SkillsRevisionTask(keys: keys, id: id, action: action))
    }
}

private struct SkillsRevisionTask: ViewModifier {
    @Environment(WorkspaceSession.self) private var session
    let keys: [String]
    let id: String
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content.task(id: ([id] + keys.map { String(session.revision($0)) }).joined(separator: "|")) { await action() }
    }
}

extension View {
    /// Middle-click handler; every other click passes through untouched.
    func skillsOnMiddleClick(_ action: @escaping () -> Void) -> some View {
        overlay(SkillsMiddleClickCatcher(action: action))
    }
}

private struct SkillsMiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged: return super.hitTest(point)
            default: return nil
            }
        }

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action?() } else { super.otherMouseUp(with: event) }
        }
    }
}

enum SkillsLinks {
    static func docsURL() -> URL {
        let lang = L10n.shared.language
        let prefix: String
        if lang.hasPrefix("zh") { prefix = "/zh" } else if lang.hasPrefix("ja") { prefix = "/ja" } else if lang.hasPrefix("ko") { prefix = "/ko" } else if lang.hasPrefix("fr") { prefix = "/fr" } else { prefix = "" }
        return URL(string: "https://multica.ai/docs\(prefix)/skills")!
    }

    static func open(_ raw: String) {
        if let url = URL(string: raw) { NSWorkspace.shared.open(url) }
    }
}

/// Square checkbox drawn like upstream's (tri-state for select-all).
struct SkillsCheckbox: View {
    let checked: Bool
    var indeterminate = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3.5)
                .fill(checked || indeterminate ? Theme.brand : Color.clear)
            RoundedRectangle(cornerRadius: 3.5)
                .strokeBorder(checked || indeterminate ? Theme.brand : Color.secondary.opacity(0.5), lineWidth: 1)
            if checked {
                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white)
            } else if indeterminate {
                Rectangle().fill(.white).frame(width: 7, height: 1.5)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// Inline error box used by dialogs (destructive tint + icon).
struct SkillsErrorBox: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").padding(.top, 1)
            Text(message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.destructive)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.destructive.opacity(0.1)))
    }
}

/// Tinted notice box (warning / destructive / muted).
struct SkillsNotice: View {
    enum Tone { case warning, destructive, muted }
    let text: String
    var tone: Tone = .warning
    var icon: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let icon {
                Image(systemName: icon).foregroundStyle(tone == .warning ? Theme.warning : tone == .destructive ? Theme.destructive : .secondary)
                    .padding(.top, 1)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(tone == .destructive ? Theme.destructive : .secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(background))
    }

    private var background: Color {
        switch tone {
        case .warning: return Theme.warning.opacity(0.1)
        case .destructive: return Theme.destructive.opacity(0.1)
        case .muted: return Color.primary.opacity(0.05)
        }
    }
}

/// Full-width strip under a page header (supporting-data / conflict).
struct SkillsBanner<Content: View>: View {
    var tint: Color = Theme.warning
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(tint).padding(.top, 1)
            content()
            Spacer(minLength: 0)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Dialog chrome: title + optional description, body, trailing buttons.
struct SkillsDialog<Content: View, Footer: View>: View {
    let title: String
    var description: String? = nil
    var width: CGFloat = 420
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.Font.title)
                if let description {
                    Text(description).font(Theme.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
            HStack(spacing: 8) {
                Spacer()
                footer()
            }
        }
        .padding(20)
        .frame(width: width)
    }
}

/// Primary button label with an optional spinner while busy.
struct SkillsBusyLabel: View {
    let title: String
    var icon: String? = nil
    var busy = false

    var body: some View {
        HStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.mini)
            } else if let icon {
                Image(systemName: icon)
            }
            Text(title)
        }
    }
}

/// Avatar for an agent record.
struct SkillsAgentAvatar: View {
    let agent: AgentRecord
    var size: CGFloat = 20

    var body: some View {
        AvatarView(name: agent.name, url: agent.avatarUrl, kind: .agent, size: size)
    }
}

/// A skill-scoped label chip: filled with the label color, contrasting text.
struct SkillsLabelChip: View {
    let name: String
    let color: String

    var body: some View {
        Text(name)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(Self.textColor(color))
            .background(Capsule().fill(Color(hex: color)))
            .help(name)
    }

    /// Upstream `contrastTextColor` (BT.601 luminance).
    static func textColor(_ hex: String) -> Color {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return Color(red: 0x11 / 255, green: 0x18 / 255, blue: 0x27 / 255) }
        let r = Double((v >> 16) & 0xFF) / 255, g = Double((v >> 8) & 0xFF) / 255, b = Double(v & 0xFF) / 255
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.55 ? Color(red: 0x11 / 255, green: 0x18 / 255, blue: 0x27 / 255) : Color(red: 0xF9 / 255, green: 0xFA / 255, blue: 0xFB / 255)
    }
}

/// Text with search-term highlights.
struct SkillsHighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for segment in SkillsTextHighlight.segments(text, query: query) {
            var part = AttributedString(segment.text)
            if segment.highlighted { part.backgroundColor = Color.yellow.opacity(0.45) }
            out += part
        }
        return out
    }
}
