import AppKit
import MulticaCore
import SwiftUI

/// The floating chat card (upstream ChatWindow): resizable from its left,
/// top and top-left edges, expandable to 90% of the window, minimised to the
/// launcher.
struct ChatUIFloatingWindow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(ShellState.self) private var shell
    let container: CGSize
    @State private var live: CGSize?
    @State private var dragStart: CGSize?

    var body: some View {
        let store = session.chatUI
        let maxW = max(ChatUIStore.minWidth, floor(container.width * 0.9))
        let maxH = max(ChatUIStore.minHeight, floor(container.height * 0.9))
        let w = store.isExpanded ? maxW : min(max(store.chatWidth, ChatUIStore.minWidth), maxW)
        let h = store.isExpanded ? maxH : min(max(store.chatHeight, ChatUIStore.minHeight), maxH)
        let atMax = w >= maxW && h >= maxH
        VStack(spacing: 0) {
            header(expandedOrMax: store.isExpanded || atMax)
            Divider()
            ChatUIConversationBody(surface: .floating, leftAdornment: AnyView(ChatUIAgentDropdown()), focusOnAppear: true)
        }
        .frame(width: live?.width ?? w, height: live?.height ?? h)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .overlay(alignment: .topLeading) { handles(w: w, h: h, maxW: maxW, maxH: maxH) }
        .animation(dragStart == nil ? .snappy(duration: 0.3) : nil, value: w)
        .animation(dragStart == nil ? .snappy(duration: 0.3) : nil, value: h)
    }

    private func header(expandedOrMax: Bool) -> some View {
        let store = session.chatUI
        return HStack(spacing: 8) {
            HStack(spacing: 4) {
                Button { store.newChat() } label: { ChatUIIconLabel(systemName: "plus") }
                    .buttonStyle(.plain)
                    .help(tr("chat", "window.new_chat_tooltip"))
                    .accessibilityLabel(tr("chat", "window.new_chat_tooltip"))
                ChatUISessionDropdown()
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                Button {
                    if expandedOrMax {
                        store.setFloatingSize(width: ChatUIStore.minWidth, height: ChatUIStore.minHeight)
                    } else {
                        store.setExpanded(true)
                    }
                } label: {
                    ChatUIIconLabel(systemName: expandedOrMax ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .help(tr("chat", expandedOrMax ? "window.restore_tooltip" : "window.expand_tooltip"))
                Button { shell.chatOpen = false } label: { ChatUIIconLabel(systemName: "minus") }
                    .buttonStyle(.plain)
                    .help(tr("chat", "window.minimize_tooltip"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private enum Edge { case left, top, corner }

    private func handles(w: CGFloat, h: CGFloat, maxW: CGFloat, maxH: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            handle(.left, w: w, h: h, maxW: maxW, maxH: maxH)
                .frame(width: 5)
                .frame(maxHeight: .infinity)
                .padding(.top, 16)
            handle(.top, w: w, h: h, maxW: maxW, maxH: maxH)
                .frame(height: 5)
                .frame(maxWidth: .infinity)
                .padding(.leading, 16)
            handle(.corner, w: w, h: h, maxW: maxW, maxH: maxH)
                .frame(width: 16, height: 16)
        }
    }

    private func handle(_ edge: Edge, w: CGFloat, h: CGFloat, maxW: CGFloat, maxH: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { Self.cursor(edge).push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { g in
                        let start = dragStart ?? CGSize(width: w, height: h)
                        if dragStart == nil { dragStart = start }
                        let nw = edge == .top ? start.width : start.width - g.translation.width
                        let nh = edge == .left ? start.height : start.height - g.translation.height
                        live = CGSize(width: min(max(nw, ChatUIStore.minWidth), maxW), height: min(max(nh, ChatUIStore.minHeight), maxH))
                    }
                    .onEnded { _ in
                        if let live { session.chatUI.setFloatingSize(width: live.width, height: live.height) }
                        live = nil
                        dragStart = nil
                    }
            )
    }

    private static func cursor(_ edge: Edge) -> NSCursor {
        switch edge {
        case .left: return .resizeLeftRight
        case .top: return .resizeUpDown
        case .corner:
            if #available(macOS 15.0, *) { return .frameResize(position: .topLeft, directions: .all) }
            return .crosshair
        }
    }
}

/// The composer's agent picker in the floating window: switching agent
/// starts a fresh chat; the current agent is checked.
struct ChatUIAgentDropdown: View {
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        let store = session.chatUI
        if let agent = store.context.activeAgent {
            ChatUIAgentPicker(agents: store.context.availableAgents, currentID: agent.id, arrowEdge: .top, onSelect: { store.selectAgent($0.id) }) {
                HStack(spacing: 6) {
                    ChatUIAgentAvatar(agentID: agent.id, size: 20)
                    Text(agent.name).font(Theme.Font.caption.weight(.medium)).lineLimit(1).frame(maxWidth: 112, alignment: .leading)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .hoverHighlight()
            }
        } else {
            Text(tr("chat", "window.no_agents")).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
    }
}

/// Chat history popover in the floating header: the current chat's title and
/// live state in the trigger, other chats' activity beside it.
struct ChatUISessionDropdown: View {
    @Environment(WorkspaceSession.self) private var session
    @State private var open = false
    @State private var renamingID: String?
    @State private var confirmingStopID: String?
    @State private var stoppingTaskID: String?
    @State private var completedFlash: Set<String> = []
    @State private var previousInFlight: Set<String> = []

    var body: some View {
        let store = session.chatUI
        let active = store.activeSessionID
        let current = active.flatMap { id in session.chatSessions.item(id) }
        let inFlight = Set(store.pendingBySession.keys)
        let all = session.chatSessions.items
        let otherRunning = all.filter { $0.id != active && inFlight.contains($0.id) }.count
        let otherUnread = all.filter { $0.id != active && $0.hasUnread }.count
        HStack(spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    if let current { ChatUIAgentAvatar(agentID: current.agentId, size: 20) }
                    Text(ChatUIFormat.untitled(current)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let active, inFlight.contains(active) {
                        ProgressView().controlSize(.mini).accessibilityLabel(tr("chat", "session_history.row_subtitle.working"))
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: 384, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(open ? Theme.selected : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            .popover(isPresented: $open, arrowEdge: .bottom) { history(store) }
            if otherRunning > 0 {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    if otherRunning > 1 { Text("\(otherRunning)") }
                }
                .font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                .help(tr("chat", "window.another_running"))
            } else if otherUnread > 0 {
                HStack(spacing: 4) {
                    Circle().fill(Theme.brand).frame(width: 6, height: 6)
                    if otherUnread > 1 { Text("\(otherUnread)") }
                }
                .font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                .help(tr("chat", "window.another_unread"))
            }
        }
        .onAppear { previousInFlight = inFlight }
        .onChange(of: inFlight) { _, now in flashCompleted(now) }
        .onChange(of: inFlight.contains(confirmingStopID ?? "")) { _, running in if !running { confirmingStopID = nil } }
    }

    /// A chat that just finished with an unread reply flashes "Completed".
    private func flashCompleted(_ now: Set<String>) {
        let unread = Set(session.chatSessions.items.filter(\.hasUnread).map(\.id))
        for id in previousInFlight where !now.contains(id) && unread.contains(id) {
            completedFlash.insert(id)
            Task {
                try? await Task.sleep(for: .milliseconds(1600))
                completedFlash.remove(id)
            }
        }
        previousInFlight = now
    }

    private func history(_ store: ChatUIStore) -> some View {
        let sessions = store.historySessions
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if sessions.isEmpty {
                    Text(tr("chat", "window.no_previous")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(8)
                } else {
                    Text(tr("chat", "window.history_group")).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                    ForEach(sessions) { s in
                        historyRow(s, store: store)
                    }
                }
            }
            .padding(4)
        }
        .frame(minWidth: 256, idealWidth: 320, maxWidth: 384, maxHeight: 384)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func historyRow(_ s: ChatSession, store: ChatUIStore) -> some View {
        let isCurrent = s.id == store.activeSessionID
        let pending = store.pendingBySession[s.id]
        let running = pending != nil
        let flashing = completedFlash.contains(s.id) && !isCurrent
        let unread = s.hasUnread && !isCurrent
        let confirming = confirmingStopID == s.id && running
        let trailing = running ? tr("chat", "session_history.row_subtitle.working")
            : flashing ? tr("chat", "session_history.row_subtitle.completed")
            : unread ? tr("chat", "session_history.row_subtitle.new_reply")
            : ChatUIFormat.timeAgo(s.updatedAt)
        return ChatUIHistoryRow(isCurrent: isCurrent, confirming: confirming) {
            HStack(spacing: 8) {
                ChatUIAgentAvatar(agentID: s.agentId, size: 22)
                if renamingID == s.id {
                    ChatUIRenameField(initial: s.title) { value in
                        renamingID = nil
                        store.rename(s.id, to: value)
                    } onCancel: { renamingID = nil }
                } else if confirming {
                    Text(tr("chat", "session_history.stop_dialog.title")).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.destructive).lineLimit(1)
                } else {
                    Text(ChatUIFormat.untitled(s)).font(.system(size: 13, weight: (unread || flashing) && !running ? .medium : .regular)).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
        } status: {
            HStack(spacing: 6) {
                if running { ProgressView().controlSize(.mini) }
                if flashing && !running { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.success) }
                if unread && !running && !flashing { Circle().fill(Theme.brand).frame(width: 6, height: 6).help(tr("chat", "window.unread")) }
                Text(trailing).fontWeight(unread || flashing || running ? .medium : .regular).foregroundStyle(unread || flashing || running ? .primary : .secondary).lineLimit(1)
            }
            .font(Theme.Font.caption)
        } actions: {
            if confirming, let pending {
                HStack(spacing: 4) {
                    Button(tr("chat", "session_history.stop_dialog.cancel")) { confirmingStopID = nil }
                        .buttonStyle(.borderless).font(Theme.Font.micro.weight(.medium))
                    Button(stoppingTaskID == pending.taskId ? tr("chat", "session_history.stop_dialog.confirming") : tr("chat", "session_history.stop_dialog.confirm")) {
                        stoppingTaskID = pending.taskId
                        previousInFlight.remove(s.id)
                        Task {
                            await store.stopFromList(sessionID: s.id, taskID: pending.taskId)
                            stoppingTaskID = nil
                            confirmingStopID = nil
                        }
                    }
                    .buttonStyle(.borderless).font(Theme.Font.micro.weight(.medium)).foregroundStyle(Theme.destructive)
                }
                .disabled(stoppingTaskID == pending.taskId)
            } else if renamingID != s.id {
                HStack(spacing: 2) {
                    if running {
                        Button { confirmingStopID = s.id } label: {
                            Label(tr("chat", "session_history.stop_action"), systemImage: "stop.fill").font(Theme.Font.micro.weight(.medium))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.destructive)
                        .help(tr("chat", "session_history.row_stop_aria"))
                    } else {
                        Button { renamingID = s.id } label: { Image(systemName: "pencil").font(.system(size: 11)).frame(width: 24, height: 24) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(tr("chat", "session_history.row_rename_aria"))
                        Button { archive(s, store: store) } label: { Image(systemName: "archivebox").font(.system(size: 11)).frame(width: 24, height: 24) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(tr("chat", "list.archive"))
                    }
                }
            }
        } onSelect: {
            guard renamingID != s.id, !confirming else { return }
            store.selectSession(s)
            open = false
        }
        .contextMenu {
            if running {
                Button(role: .destructive) { confirmingStopID = s.id } label: { Label(tr("chat", "session_history.row_stop_aria"), systemImage: "stop.fill") }
            } else {
                Button { renamingID = s.id } label: { Label(tr("chat", "session_history.row_rename_aria"), systemImage: "pencil") }
                Button { archive(s, store: store) } label: { Label(tr("chat", "list.archive"), systemImage: "archivebox") }
            }
        }
    }

    /// Archiving the chat in view advances to the next one; the floating
    /// window never hard-deletes (that lives in the tab's Archived view).
    private func archive(_ s: ChatSession, store: ChatUIStore) {
        store.advanceSelectionAfterArchive(s.id)
        store.setArchived(s.id, true)
    }
}

/// History row chrome: status at rest, actions on hover.
private struct ChatUIHistoryRow<Main: View, Status: View, Actions: View>: View {
    let isCurrent: Bool
    let confirming: Bool
    @ViewBuilder let main: () -> Main
    @ViewBuilder let status: () -> Status
    @ViewBuilder let actions: () -> Actions
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            main()
            if hovering || confirming { actions() } else { status() }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 40)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .fill(confirming ? Theme.destructive.opacity(0.05) : (isCurrent ? Theme.selected : (hovering ? Theme.hover : .clear)))
        )
        .overlay(alignment: .leading) {
            if isCurrent { Capsule().fill(Theme.brand).frame(width: 2).padding(.vertical, 6) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

/// Inline title editor: Enter commits, Escape cancels, losing focus commits.
struct ChatUIRenameField: View {
    let initial: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var value = ""
    @State private var done = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $value)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))
            .focused($focused)
            .onSubmit { finish(commit: true) }
            .onExitCommand { finish(commit: false) }
            .onChange(of: focused) { _, f in if !f { finish(commit: true) } }
            .onChange(of: value) { _, v in if v.count > 200 { value = String(v.prefix(200)) } }
            .onAppear {
                value = initial
                DispatchQueue.main.async { focused = true }
            }
            .accessibilityLabel(tr("chat", "session_history.row_rename_aria"))
    }

    private func finish(commit: Bool) {
        guard !done else { return }
        done = true
        if commit { onSubmit(value) } else { onCancel() }
    }
}

/// The minimised launcher (upstream ChatFab): opens the floating window and
/// pulses while one of the member's chat tasks runs.
struct ChatUIFab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(ShellState.self) private var shell
    @Environment(ShortcutStore.self) private var shortcuts
    @State private var impulse = false
    @MainActor private static var restored = false

    var body: some View {
        let store = session.chatUI
        ZStack(alignment: .bottomTrailing) {
            Color.clear.frame(width: 0, height: 0)
            if nav.route != .chat && store.floatingEnabled { launcher(store) }
        }
        .onAppear { mounted(store) }
    }

    /// The launcher is mounted whenever the window is closed: restore a
    /// persisted "open" choice once per launch, otherwise record "closed".
    private func mounted(_ store: ChatUIStore) {
        if !Self.restored {
            Self.restored = true
            if store.openPreference && store.floatingEnabled {
                if nav.route != .chat { shell.chatOpen = true }
                return
            }
        }
        store.setOpenPreference(false)
    }

    private func launcher(_ store: ChatUIStore) -> some View {
        Group {
            let running = store.hasPendingAny
            let unread = ChatUISessions.unreadSessionCount(session.chatSessions.items)
            let tooltip = running ? tr("chat", "fab.running") : (unread > 0 ? tr("chat", "fab.unread", ["count": unread]) : tr("chat", "fab.default"))
            let chord = shortcuts.chord(for: .toggleChat)?.display.joined()
            Button { shell.chatOpen = true } label: {
                Image(systemName: "bubble.left")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(Circle().strokeBorder(Theme.border))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                    .scaleEffect(running && impulse ? 1.06 : 1)
                    .animation(running ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: impulse)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(chord.map { "\(tooltip)  \($0)" } ?? tooltip)
            .accessibilityLabel(tooltip)
            .onAppear {
                impulse = true
                store.retainHasPending()
                Task { await session.chatSessions.loadIfNeeded() }
            }
            .onDisappear { store.releaseHasPending() }
        }
    }
}
