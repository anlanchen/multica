import AppKit
import MulticaCore
import SwiftUI

// MARK: Column geometry

/// Minimum distance between the conversation column and the surface edges
/// (upstream CHAT_GUTTER: 20 / 32 / 48 pt as the chat container widens).
private struct ChatUIGutterKey: EnvironmentKey {
    static let defaultValue: CGFloat = 20
}

extension EnvironmentValues {
    var chatUIGutter: CGFloat {
        get { self[ChatUIGutterKey.self] }
        set { self[ChatUIGutterKey.self] = newValue }
    }
}

enum ChatUILayout {
    static let columnMaxWidth: CGFloat = 896

    static func gutter(forWidth width: CGFloat) -> CGFloat {
        width >= 896 ? 48 : (width >= 672 ? 32 : 20)
    }
}

extension View {
    /// The reading column shared by message rows, banners and the composer so
    /// their edges line up (upstream CHAT_GUTTER + CHAT_COLUMN).
    func chatUIColumn() -> some View {
        modifier(ChatUIColumnModifier())
    }
}

private struct ChatUIColumnModifier: ViewModifier {
    @Environment(\.chatUIGutter) private var gutter

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: ChatUILayout.columnMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, gutter)
    }
}

// MARK: Formatting

enum ChatUIFormat {
    /// IM-style list time: today → clock, this year → month/day, else date.
    static func listTime(_ timestamp: String) -> String {
        guard let d = Timestamp.parse(timestamp) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
            return d.formatted(.dateTime.month(.defaultDigits).day())
        }
        return d.formatted(date: .numeric, time: .omitted)
    }

    /// Session history "time ago" (chat.session_history.time.*).
    static func timeAgo(_ timestamp: String) -> String {
        guard let d = Timestamp.parse(timestamp) else { return "" }
        let mins = Int(Date().timeIntervalSince(d) / 60)
        if mins < 1 { return tr("chat", "session_history.time.just_now") }
        if mins < 60 { return tr("chat", "session_history.time.minutes", ["count": mins]) }
        if mins < 1440 { return tr("chat", "session_history.time.hours", ["count": mins / 60]) }
        if mins < 10080 { return tr("chat", "session_history.time.days", ["count": mins / 1440]) }
        return d.formatted(date: .numeric, time: .omitted)
    }

    static func untitled(_ s: ChatSession?) -> String {
        let t = s?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? tr("chat", "window.untitled") : t
    }
}

// MARK: Avatars

/// Agent avatar with the presence dot (upstream ActorAvatar showStatusDot).
struct ChatUIAgentAvatar: View {
    @Environment(WorkspaceSession.self) private var session
    let agentID: String
    var size: CGFloat = 24
    var showDot = true

    var body: some View {
        let store = session.chatUI
        let info = session.actorInfo(type: "agent", id: agentID)
        let name = store.agentsByID[agentID]?.name ?? info.name
        AvatarView(name: name, url: store.agentsByID[agentID]?.avatarUrl ?? info.avatarURL, kind: .agent, size: size)
            .overlay(alignment: .bottomTrailing) {
                if showDot, let color = Self.dotColor(store.availabilityByAgent[agentID]) {
                    Circle()
                        .fill(color)
                        .frame(width: max(6, size * 0.3), height: max(6, size * 0.3))
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 1.5, y: 1.5)
                }
            }
            .help(name)
    }

    static func dotColor(_ availability: String?) -> Color? {
        switch availability {
        case "online": return Theme.success
        case "unstable": return Theme.warning
        case "offline": return Color.secondary.opacity(0.6)
        default: return nil
        }
    }
}

// MARK: Rich text

/// Markdown body whose block parse runs off the main actor; while a newer
/// source parses, the previous rendering stays on screen (no flash while a
/// reply streams).
struct ChatUIRichText: View {
    let source: String
    var font: Font = Theme.Font.body
    @State private var rendered: String?

    @MainActor private static var parsed = Set<Int>()

    var body: some View {
        let ready = rendered ?? (Self.parsed.contains(source.hashValue) ? source : nil)
        Group {
            if let ready {
                MarkdownView(source: ready, font: font, compact: true)
            } else {
                Text(source).font(font).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: source) {
            let s = source
            if !Self.parsed.contains(s.hashValue) {
                await Task.detached(priority: .userInitiated) { _ = MarkdownBlocks.cachedParse(s) }.value
                if Self.parsed.count > 4000 { Self.parsed.removeAll() }
                Self.parsed.insert(s.hashValue)
            }
            rendered = s
        }
    }
}

// MARK: Banners

/// One status line above the composer (no agent / revoked / archived /
/// runtime required / offline / unstable).
struct ChatUIBanner: View {
    enum Tone { case neutral, warning }

    let icon: String
    let text: String
    var tone: Tone = .neutral
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .font(Theme.Font.caption)
        .foregroundStyle(tone == .warning ? Color(light: 0x78350F, dark: 0xFDE68A) : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .fill(tone == .warning ? Color(light: 0xFFFBEB, dark: 0x451A03).opacity(0.9) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .strokeBorder(tone == .warning ? Color.orange.opacity(0.3) : Theme.border)
        )
        .chatUIColumn()
        .padding(.bottom, 6)
    }
}

/// The mutually exclusive banner slot. The tab ranks a revoked invoke
/// permission above "no agent"; the floating window the other way round.
struct ChatUIBannerSlot: View {
    @Environment(Navigator.self) private var nav
    let context: ChatUIContext
    let surface: ChatUISurface

    var body: some View {
        let name = context.activeAgent?.name.trimmingCharacters(in: .whitespaces) ?? ""
        let fallback = tr("chat", "offline_banner.fallback_name")
        let display = name.isEmpty ? fallback : name
        if surface == .page && context.isAgentAccessRevoked {
            ChatUIBanner(icon: "lock", text: tr("chat", "agent_access_revoked_banner", ["name": display]))
        } else if context.noAgent {
            ChatUIBanner(icon: "cpu", text: tr("chat", "no_agent_banner"))
        } else if context.isAgentAccessRevoked {
            ChatUIBanner(icon: "lock", text: tr("chat", "agent_access_revoked_banner", ["name": display]))
        } else if context.isAgentArchived {
            ChatUIBanner(icon: "archivebox", text: tr("chat", "archived_agent_banner", ["name": display]))
        } else if !context.isAgentRuntimeBound, let agent = context.activeAgent {
            let runtimeName = name.isEmpty ? tr("chat", "runtime_required_banner.fallback_name") : name
            ChatUIBanner(icon: "server.rack", text: tr("chat", "runtime_required_banner.message", ["name": runtimeName]), tone: .warning,
                         actionTitle: tr("chat", "runtime_required_banner.action")) {
                nav.push(.agent(agent.id), query: ["view": "general"])
            }
        } else if context.availability == "unstable" {
            ChatUIBanner(icon: "exclamationmark.circle", text: tr("chat", "offline_banner.unstable", ["name": display]), tone: .warning)
        } else if context.availability == "offline" {
            ChatUIBanner(icon: "wifi.slash", text: tr("chat", "offline_banner.offline", ["name": display]))
        }
    }
}

// MARK: Agent picker

/// Searchable agent list grouped My agents / Others; agents without a
/// runtime are shown but cannot start a chat (upstream AgentPicker).
struct ChatUIAgentPicker<Label: View>: View {
    @Environment(WorkspaceSession.self) private var session
    let agents: [AgentRecord]
    var currentID: String? = nil
    var arrowEdge: Edge = .bottom
    let onSelect: (AgentRecord) -> Void
    @ViewBuilder let label: () -> Label
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: arrowEdge) {
                OptionList(
                    options: options,
                    selected: currentID.map { [$0] } ?? [],
                    searchPlaceholder: tr("chat", "window.agent_filter_placeholder")
                ) { id in
                    open = false
                    if let agent = agents.first(where: { $0.id == id }) { onSelect(agent) }
                }
            }
    }

    private var options: [PickerOption<String>] {
        let userID = session.currentUser.id
        let mine = agents.filter { $0.ownerId == userID }
        let others = agents.filter { $0.ownerId != userID }
        func option(_ a: AgentRecord, _ group: String) -> PickerOption<String> {
            let bound = ChatUIAgents.isRuntimeBound(a)
            return PickerOption(
                id: a.id, title: a.name,
                subtitle: bound ? nil : tr("chat", "window.agent_needs_runtime"),
                group: group, disabled: !bound,
                help: bound ? nil : tr("chat", "window.agent_needs_runtime_hint"),
                icon: AnyView(ChatUIAgentAvatar(agentID: a.id, size: 18))
            )
        }
        return mine.map { option($0, tr("chat", "window.my_agents")) } + others.map { option($0, tr("chat", "window.others")) }
    }
}

/// "New chat" ⊕: picks the agent the chat will run on. A single available
/// agent starts immediately; none still starts (the surface shows its
/// no-agent state).
struct ChatUINewChatButton: View {
    @Environment(Toaster.self) private var toaster
    let agents: [AgentRecord]
    var arrowEdge: Edge = .bottom
    let onStart: (AgentRecord?) -> Void

    var body: some View {
        let label = tr("chat", "window.new_chat_tooltip")
        if agents.count <= 1 {
            Button {
                let only = agents.first
                if let only, !ChatUIAgents.isRuntimeBound(only) {
                    toaster.error(tr("chat", "input.runtime_required_toast"))
                    return
                }
                onStart(only)
            } label: { ChatUIIconLabel(systemName: "plus") }
                .buttonStyle(.plain)
                .help(label)
                .accessibilityLabel(label)
        } else {
            ChatUIAgentPicker(agents: agents, arrowEdge: arrowEdge, onSelect: { onStart($0) }) {
                ChatUIIconLabel(systemName: "plus")
            }
            .help(label)
            .accessibilityLabel(label)
        }
    }
}

/// Small round ghost icon button face.
struct ChatUIIconLabel: View {
    let systemName: String
    var size: CGFloat = 26
    @State private var hovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hovering ? .primary : .secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(hovering ? Theme.hover : .clear))
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

// MARK: Empty state

/// The compose placeholder before the first message: agent identity and
/// conversation starters (configured, or the generic fallback set).
struct ChatUIEmptyState: View {
    @Environment(Navigator.self) private var nav
    let agent: AgentRecord?
    let hasSessions: Bool
    let canCustomize: Bool
    let onPick: (String) -> Void

    static var fallbackStarters: [AgentConversationStarter] {
        ["capabilities", "first_task", "recommend"].map {
            AgentConversationStarter(label: tr("chat", "conversation_starters.\($0).label"), prompt: tr("chat", "conversation_starters.\($0).prompt"))
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let agent {
                    ChatUIAgentAvatar(agentID: agent.id, size: 48, showDot: false)
                }
                VStack(spacing: 4) {
                    Text(agent.map { tr("chat", "empty_state.chat_with_named", ["name": $0.name]) } ?? tr("chat", "empty_state.first_time_title"))
                        .font(.system(size: 16, weight: .semibold))
                        .multilineTextAlignment(.center)
                    if let d = agent?.description.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                        Text(d).font(Theme.Font.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if !hasSessions {
                        Text(tr("chat", "empty_state.first_time_actions")).font(Theme.Font.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 384)
                if let agent {
                    VStack(spacing: 8) {
                        ForEach(Array(ChatUIAgents.starters(agent.conversationStarters, fallback: Self.fallbackStarters).enumerated()), id: \.offset) { _, s in
                            ChatUIStarterButton(label: s.label) { onPick(s.prompt) }
                        }
                        if canCustomize {
                            Button {
                                nav.push(.agent(agent.id), query: ["view": "instructions", "focus": "conversation_starters"])
                            } label: {
                                Label(tr("chat", "conversation_starters.customize"), systemImage: "slider.horizontal.3")
                                    .font(Theme.Font.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: 384)
                    .accessibilityLabel(tr("chat", "conversation_starters.aria_label"))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChatUIStarterButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(hovering ? Theme.hover : Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(hovering ? Theme.brand.opacity(0.4) : Theme.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: Attachments

/// Attachments the markdown does not already show inline: images at size,
/// other files as cards in a grid (upstream AttachmentList).
struct ChatUIAttachmentList: View {
    @Environment(Navigator.self) private var nav
    let attachments: [Attachment]?
    let content: String

    var body: some View {
        let standalone = ChatUIText.standaloneAttachments(attachments, content: content)
        if !standalone.isEmpty {
            let images = standalone.filter { $0.contentType.hasPrefix("image/") }
            let files = standalone.filter { !$0.contentType.hasPrefix("image/") }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(images) { a in
                    Button { nav.openInNewTab(.attachmentPreview(a.id)) } label: {
                        RemoteImage(url: ImageLoader.resolve(a.markdownUrl.isEmpty ? a.url : a.markdownUrl)) {
                            RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.05))
                                .frame(width: 220, height: 140)
                                .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                        }
                        .scaledToFit()
                        .frame(maxWidth: 360, maxHeight: 320, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
                    }
                    .buttonStyle(.plain)
                    .help(a.filename)
                }
                if !files.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(files) { a in
                            Button { nav.openInNewTab(.attachmentPreview(a.id)) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(a.filename).font(Theme.Font.body).lineLimit(1)
                                        if a.sizeBytes > 0 {
                                            Text(Formatters.bytes(Int64(a.sizeBytes))).font(Theme.Font.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.03)))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

// MARK: Skeleton

/// Placeholder while an uncached session loads (assistant → user →
/// assistant shape so nothing jumps when messages land).
struct ChatUIMessageSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                bar(0.75)
                bar(0.5)
            }
            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.07)).frame(width: 192, height: 32)
            }
            VStack(alignment: .leading, spacing: 8) {
                bar(0.66)
                bar(0.83)
                bar(0.33)
            }
        }
        .chatUIColumn()
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .redacted(reason: .placeholder)
    }

    private func bar(_ fraction: CGFloat) -> some View {
        GeometryReader { g in
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: g.size.width * fraction, height: 14)
        }
        .frame(height: 14)
    }
}
