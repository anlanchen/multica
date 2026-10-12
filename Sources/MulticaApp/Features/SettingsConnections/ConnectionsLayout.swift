import AppKit
import MulticaCore
import SwiftUI

// Settings page chrome shared by the connection tabs (upstream
// settings-layout.tsx: SettingsTab / Section / Card / Row / ReadOnlyNotice).

enum ConnectionsScope {
    case account, workspace
}

extension WorkspaceSession {
    var connectionsRole: String? { directory.member(userID: currentUser.id)?.role }
    var connectionsIsManager: Bool { connectionsRole == "owner" || connectionsRole == "admin" }
    var connectionsIsMember: Bool { connectionsRole != nil }
}

private struct ConnectionsFlashKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The `?section=` anchor currently being flashed after a deep link.
    var connectionsFlashAnchor: String? {
        get { self[ConnectionsFlashKey.self] }
        set { self[ConnectionsFlashKey.self] = newValue }
    }
}

extension View {
    /// Marks a deep-link target (`?section=<anchor>`) and flashes it when linked.
    @ViewBuilder func connectionsAnchor(_ anchor: String?) -> some View {
        if let anchor { modifier(ConnectionsAnchorModifier(anchor: anchor)) } else { self }
    }
}

private struct ConnectionsAnchorModifier: ViewModifier {
    @Environment(\.connectionsFlashAnchor) private var flash
    let anchor: String

    func body(content: Content) -> some View {
        content
            .background(Theme.selected.opacity(flash == anchor ? 1 : 0))
            .animation(.easeOut(duration: 0.7), value: flash == anchor)
            .id(anchor)
    }
}

/// A self-contained, scrollable settings tab body.
struct ConnectionsSettingsPage<Content: View>: View {
    @Environment(Navigator.self) private var nav
    @State private var flash: String?
    let title: String
    var description: String? = nil
    var scope: ConnectionsScope? = nil
    var wide = false
    var breadcrumb: AnyView? = nil
    var actions: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            scroll
                .task(id: nav.query("section")) {
                    guard let section = nav.query("section"), !section.isEmpty else { return }
                    // Tab content may still be loading; give it a moment to lay out.
                    try? await Task.sleep(for: .milliseconds(250))
                    withAnimation { proxy.scrollTo(section, anchor: .center) }
                    flash = section
                    try? await Task.sleep(for: .milliseconds(1600))
                    flash = nil
                }
        }
        .environment(\.connectionsFlashAnchor, flash)
    }

    private var scroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    if let breadcrumb { breadcrumb }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 10) {
                                Text(title).font(.system(size: 18, weight: .semibold))
                                if let scope { ConnectionsScopeBadge(scope: scope) }
                            }
                            if let description {
                                Text(description)
                                    .font(Theme.Font.body)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(3)
                                    .frame(maxWidth: 640, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        if let actions { actions }
                    }
                }
                content()
            }
            .frame(maxWidth: wide ? 1024 : 896, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
    }
}

struct ConnectionsScopeBadge: View {
    @Environment(WorkspaceSession.self) private var session
    let scope: ConnectionsScope

    var body: some View {
        HStack(spacing: 4) {
            switch scope {
            case .account:
                Image(systemName: "person").font(.system(size: 9))
                Text(tr("settings", "layout.scope.account"))
            case .workspace:
                if let url = session.workspace.avatarURL, !url.isEmpty {
                    WorkspaceAvatar(name: session.workspace.name, url: url, size: 12)
                } else {
                    Image(systemName: "building.2").font(.system(size: 9))
                }
                Text(tr("settings", "layout.scope.workspace", ["name": session.workspace.name]))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

struct ConnectionsSection<Content: View>: View {
    var title: String? = nil
    var description: String? = nil
    var action: AnyView? = nil
    var anchor: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        sectionBody.connectionsAnchor(anchor)
    }

    private var sectionBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || description != nil || action != nil {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
                        if let description {
                            Text(description)
                                .font(Theme.Font.caption)
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if let action { action }
                }
                .padding(.horizontal, 2)
            }
            content()
        }
    }
}

/// Bordered card; callers place `Divider()` between rows.
struct ConnectionsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.02)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ConnectionsRow<Label: View, Control: View>: View {
    @ViewBuilder var label: () -> Label
    var description: String? = nil
    var descriptionView: AnyView? = nil
    var alignTop = false
    var anchor: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        rowBody.connectionsAnchor(anchor)
    }

    private var rowBody: some View {
        HStack(alignment: alignTop ? .top : .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                label().font(Theme.Font.bodyMedium)
                if let descriptionView {
                    descriptionView
                } else if let description {
                    Text(description)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 64)
    }
}

extension ConnectionsRow where Label == Text {
    init(_ title: String, description: String? = nil, descriptionView: AnyView? = nil, alignTop: Bool = false,
         anchor: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.label = { Text(title) }
        self.description = description
        self.descriptionView = descriptionView
        self.alignTop = alignTop
        self.anchor = anchor
        self.control = control
    }
}

/// Plain card body with a title and caption (not-configured, empty states).
struct ConnectionsMessageCard: View {
    let title: String
    var message: String? = nil
    var messageView: AnyView? = nil
    var tone: Color = .primary

    var body: some View {
        ConnectionsCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.Font.bodyMedium).foregroundStyle(tone)
                if let messageView {
                    messageView
                } else if let message {
                    Text(message).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }
}

/// Inline code chip (`MULTICA_SLACK_SECRET_KEY`).
func connectionsCode(_ s: String) -> Text {
    Text(s).font(.system(size: 10, design: .monospaced))
}

struct ConnectionsAlert<Content: View>: View {
    enum Tone { case info, destructive, success, pending }
    var tone: Tone = .info
    var icon: String? = nil
    let title: String
    var message: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if tone == .pending {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Image(systemName: icon ?? defaultIcon).font(.system(size: 14))
                }
            }
            .foregroundStyle(tone == .destructive ? Theme.destructive : .primary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.Font.bodyMedium).foregroundStyle(tone == .destructive ? Theme.destructive : .primary)
                if let message {
                    Text(message)
                        .font(Theme.Font.body)
                        .foregroundStyle(tone == .destructive ? Theme.destructive.opacity(0.9) : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tone == .destructive ? Theme.destructive.opacity(0.05) : Color.primary.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tone == .destructive ? Theme.destructive.opacity(0.3) : Theme.border))
    }

    private var defaultIcon: String {
        switch tone {
        case .success: return "checkmark.circle"
        default: return "exclamationmark.circle"
        }
    }
}

extension ConnectionsAlert where Content == EmptyView {
    init(tone: Tone = .info, icon: String? = nil, title: String, message: String? = nil) {
        self.tone = tone
        self.icon = icon
        self.title = title
        self.message = message
        self.content = { EmptyView() }
    }
}

/// "View only" note naming who can make the change.
struct ConnectionsReadOnlyNotice: View {
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        let managers = session.directory.members
            .filter { $0.role == "owner" || $0.role == "admin" }
            .map(\.name)
            .filter { !$0.isEmpty }
            .prefix(3)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eye").foregroundStyle(.secondary).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("settings", "layout.read_only.title")).font(Theme.Font.bodyMedium)
                Text(managers.isEmpty
                     ? tr("settings", "layout.read_only.description")
                     : tr("settings", "layout.read_only.contact", ["names": managers.joined(separator: tr("settings", "layout.read_only.separator"))]))
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

/// Square logo tile used by code hosts and channels.
struct ConnectionsHostMark<Content: View>: View {
    var size: CGFloat = 36
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size > 36 ? 12 : 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: size > 36 ? 12 : 8).strokeBorder(Theme.border))
    }
}

struct ConnectionsHostStatus: View {
    let connected: Bool
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            if connected { Circle().fill(Theme.success).frame(width: 6, height: 6) }
            Text(label)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(connected ? Theme.success : .secondary)
    }
}

/// A destructive or confirming dialog that stays open (buttons disabled)
/// until the server answers, like upstream's AlertDialog flows.
struct ConnectionsConfirm: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var cancel: String
    var confirm: String
    var pending: String? = nil
    var destructive = false
    var action: @MainActor () async -> Bool
}

private struct ConnectionsConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    let confirm: ConnectionsConfirm
    @State private var pending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(confirm.title).font(.system(size: 15, weight: .semibold))
            Text(confirm.message)
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(confirm.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(pending)
                Button {
                    pending = true
                    Task {
                        let done = await confirm.action()
                        pending = false
                        if done { dismiss() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if pending { ProgressView().controlSize(.small) }
                        Text(pending ? (confirm.pending ?? confirm.confirm) : confirm.confirm)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .tint(confirm.destructive ? .red : nil)
                .disabled(pending)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(pending)
    }
}

extension View {
    func connectionsConfirm(_ item: Binding<ConnectionsConfirm?>) -> some View {
        sheet(item: item) { ConnectionsConfirmSheet(confirm: $0) }
    }

    /// Runs `action` when the app becomes active again (returning from an
    /// OAuth / checkout flow in the browser), like react-query's refetch on focus.
    func connectionsOnAppActive(_ action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in action() }
    }
}

/// Plain field label + control stack used in dialogs.
struct ConnectionsField<Content: View>: View {
    let label: String
    var hint: String? = nil
    var error: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.Font.bodyMedium)
            content()
            if let error {
                Text(error).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
            } else if let hint {
                Text(hint).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Avatar + name of the agent a channel bot is bound to; opens the agent.
struct ConnectionsAgentIdentity: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let agentID: String
    var available = true
    var size: CGFloat = 32

    var body: some View {
        let info = session.actorInfo(type: "agent", id: agentID)
        Button {
            guard available else { return }
            nav.push(.agent(agentID))
        } label: {
            AvatarView(name: info.name, url: available ? info.avatarURL : nil, kind: .agent, size: size)
        }
        .buttonStyle(.plain)
        .help(info.name)
    }
}
