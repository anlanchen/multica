import AppKit
import MulticaCore
import SwiftUI

/// IM-style conversation list (upstream ChatThreadList). The default view
/// lists active chats (hover: pin + archive, or stop while running); the
/// "Archived" view is the only place a chat can be deleted.
struct ChatUIThreadList: View {
    @Environment(WorkspaceSession.self) private var session
    let onSelect: (ChatSession) -> Void
    let onArchive: (ChatSession) -> Void
    @State private var archivedView = false

    var body: some View {
        let store = session.chatUI
        let history = store.historySessions
        let archived = store.archivedSessions
        let showArchived = archivedView && !archived.isEmpty
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if showArchived {
                    Button { archivedView = false } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            Text(tr("chat", "list.archived_title")).lineLimit(1)
                            Spacer()
                            Text("\(archived.count)").monospacedDigit()
                        }
                        .font(Theme.Font.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                    rows(archived, archivedView: true)
                } else {
                    if history.isEmpty {
                        Text(tr("chat", "window.no_previous"))
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                    } else {
                        rows(history, archivedView: false)
                    }
                    if !archived.isEmpty {
                        Button { archivedView = true } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "archivebox").frame(width: 32)
                                Text(tr("chat", "list.archived_title")).fontWeight(.medium).lineLimit(1)
                                Spacer()
                                Text("\(archived.count)").monospacedDigit()
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .onAppear { store.retainAggregate() }
        .onDisappear { store.releaseAggregate() }
    }

    private func rows(_ list: [ChatSession], archivedView: Bool) -> some View {
        let store = session.chatUI
        return ForEach(list) { s in
            ChatUIThreadRow(
                chat: s,
                agent: store.agentsByID[s.agentId],
                isCurrent: s.id == store.activeSessionID,
                pendingTaskID: store.pendingBySession[s.id]?.taskId,
                agentOffline: store.availabilityByAgent[s.agentId] == "offline",
                archivedView: archivedView,
                onSelect: onSelect,
                onArchive: onArchive
            )
            .equatable()
        }
    }
}

struct ChatUIThreadRow: View, Equatable {
    @Environment(WorkspaceSession.self) private var session
    let chat: ChatSession
    let agent: AgentRecord?
    let isCurrent: Bool
    let pendingTaskID: String?
    let agentOffline: Bool
    let archivedView: Bool
    let onSelect: (ChatSession) -> Void
    let onArchive: (ChatSession) -> Void
    @State private var hovering = false
    @State private var confirming: Confirm?
    @State private var working = false

    enum Confirm { case delete, stop }

    static func == (a: ChatUIThreadRow, b: ChatUIThreadRow) -> Bool {
        a.chat == b.chat && a.agent == b.agent && a.isCurrent == b.isCurrent && a.pendingTaskID == b.pendingTaskID
            && a.agentOffline == b.agentOffline && a.archivedView == b.archivedView
    }

    var body: some View {
        let unread = isCurrent ? 0 : (chat.unreadCount ?? 0)
        let confirmingNow = confirming == .delete || (confirming == .stop && pendingTaskID != nil)
        HStack(spacing: 12) {
            if let agent {
                ChatUIAgentAvatar(agentID: agent.id, size: 32, showDot: false)
            } else {
                Color.clear.frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if chat.pinned == true {
                        Image(systemName: "pin.fill").font(.system(size: 9)).rotationEffect(.degrees(45)).foregroundStyle(.secondary)
                            .accessibilityLabel(tr("chat", "list.pinned"))
                    }
                    Text(ChatUIFormat.untitled(chat))
                        .font(.system(size: 13, weight: unread > 0 ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ChatUIFormat.listTime(chat.lastMessage?.createdAt ?? chat.updatedAt))
                        .font(Theme.Font.micro).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if confirmingNow, let confirming {
                        confirmRow(confirming)
                    } else {
                        HStack(spacing: 6) {
                            if let name = agent?.name.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                                Text(name).fontWeight(.medium).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                                Text("·").foregroundStyle(.tertiary)
                            }
                            preview(unread: unread)
                        }
                        .font(Theme.Font.caption)
                        Spacer(minLength: 0)
                        if unread > 0 {
                            Text(unread > 99 ? "99+" : "\(unread)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(Color(light: 0xD9534F, dark: 0xE06A66)))
                                .accessibilityLabel(tr("chat", "session_history.row_subtitle.new_reply"))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .fill(confirmingNow ? Theme.destructive.opacity(0.05) : (isCurrent ? Theme.selected : (hovering ? Theme.hover : .clear)))
        )
        .overlay(alignment: .trailing) {
            if hovering && !confirmingNow {
                HStack(spacing: 2) {
                    ForEach(actions, id: \.key) { a in
                        Button(action: a.run) {
                            Image(systemName: a.icon).font(.system(size: 11)).frame(width: 26, height: 26).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(a.danger ? Theme.destructive : .secondary)
                        .help(a.label)
                        .accessibilityLabel(a.label)
                    }
                }
                .padding(.leading, 36)
                .padding(.trailing, 4)
                .frame(maxHeight: .infinity)
                .background(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Color(nsColor: .windowBackgroundColor), location: 0.45)], startPoint: .leading, endPoint: .trailing))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !confirmingNow { onSelect(chat) } }
        .onHover { hovering = $0 }
        .contextMenu {
            ForEach(actions, id: \.key) { a in
                Button(role: a.danger ? .destructive : nil, action: a.run) { Label(a.label, systemImage: a.icon) }
            }
        }
        .onChange(of: pendingTaskID) { _, id in if id == nil && confirming == .stop { confirming = nil } }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    @ViewBuilder
    private func preview(unread: Int) -> some View {
        let last = chat.lastMessage
        if pendingTaskID != nil && agentOffline {
            Label(tr("chat", "list.waiting"), systemImage: "clock").foregroundStyle(.secondary).lineLimit(1)
        } else if pendingTaskID != nil {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(tr("chat", "list.typing")).lineLimit(1)
            }
            .foregroundStyle(Color.green)
        } else if let last, let f = last.failureReason, !f.isEmpty {
            Text(tr("chat", "list.failed")).foregroundStyle(Theme.destructive).lineLimit(1)
        } else if last?.messageKind == "no_response" {
            Text(tr("chat", "list.no_response_preview")).italic().foregroundStyle(.secondary).lineLimit(1)
        } else if let last {
            Text((last.role == "user" ? tr("chat", "list.you_prefix") : "") + ChatUIText.preview(last.content))
                .foregroundStyle(unread > 0 ? .primary : .secondary)
                .lineLimit(1)
        } else {
            Text(tr("chat", "list.no_messages")).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private struct Action {
        var key: String
        var icon: String
        var label: String
        var danger = false
        var run: () -> Void
    }

    private var actions: [Action] {
        let store = session.chatUI
        if archivedView {
            return [
                Action(key: "unarchive", icon: "arrow.uturn.backward.square", label: tr("chat", "list.unarchive")) { store.setArchived(chat.id, false) },
                Action(key: "delete", icon: "trash", label: tr("chat", "session_history.row_delete_aria"), danger: true) { confirming = .delete },
            ]
        }
        let pin = Action(key: "pin", icon: chat.pinned == true ? "pin.slash" : "pin", label: tr("chat", chat.pinned == true ? "list.unpin" : "list.pin")) {
            store.setPinned(chat.id, !(chat.pinned == true))
        }
        if pendingTaskID != nil {
            return [pin, Action(key: "stop", icon: "stop.fill", label: tr("chat", "session_history.row_stop_aria"), danger: true) { confirming = .stop }]
        }
        return [pin, Action(key: "archive", icon: "archivebox", label: tr("chat", "list.archive")) { onArchive(chat) }]
    }

    private func confirmRow(_ kind: Confirm) -> some View {
        let store = session.chatUI
        let isDelete = kind == .delete
        return HStack(spacing: 8) {
            Text(tr("chat", isDelete ? "session_history.delete_dialog.title" : "session_history.stop_dialog.title"))
                .font(Theme.Font.caption.weight(.medium)).foregroundStyle(Theme.destructive).lineLimit(1)
            Spacer(minLength: 4)
            Button(tr("chat", isDelete ? "session_history.delete_dialog.cancel" : "session_history.stop_dialog.cancel")) { confirming = nil }
                .buttonStyle(.borderless).font(Theme.Font.micro.weight(.medium)).disabled(working)
            Button(working
                   ? tr("chat", isDelete ? "session_history.delete_dialog.confirming" : "session_history.stop_dialog.confirming")
                   : tr("chat", isDelete ? "session_history.delete_dialog.confirm" : "session_history.stop_dialog.confirm")) {
                working = true
                Task {
                    if isDelete {
                        _ = await store.delete(chat.id)
                    } else if let task = pendingTaskID {
                        await store.stopFromList(sessionID: chat.id, taskID: task)
                    }
                    working = false
                    confirming = nil
                }
            }
            .buttonStyle(.borderless)
            .font(Theme.Font.micro.weight(.medium))
            .foregroundStyle(Theme.destructive)
            .disabled(working)
        }
    }
}

/// Header of the open conversation on the chat tab: agent, editable title,
/// agent subtitle, and the ⋯ menu (rename, profile, archive / unarchive +
/// delete).
struct ChatUISessionHeader: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let chat: ChatSession
    let agent: AgentRecord?
    let onArchive: (ChatSession) -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmDelete = false
    @FocusState private var focused: Bool

    var body: some View {
        let store = session.chatUI
        let title = ChatUIFormat.untitled(chat)
        let archived = chat.status == "archived"
        HStack(spacing: 12) {
            if let agent {
                ChatUIAgentAvatar(agentID: agent.id, size: 30)
            } else {
                Color.clear.frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                if editing {
                    TextField("", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, weight: .semibold))
                        .focused($focused)
                        .onSubmit { commit() }
                        .onExitCommand { editing = false }
                        .onChange(of: focused) { _, f in if !f && editing { commit() } }
                        .onChange(of: draft) { _, v in if v.count > 200 { draft = String(v.prefix(200)) } }
                        .accessibilityLabel(tr("chat", "header.rename"))
                } else {
                    Button(action: startRename) {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(tr("chat", "header.rename"))
                }
                if let agent {
                    Text(agent.description.isEmpty ? agent.name : "\(agent.name) · \(agent.description)")
                        .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Menu {
                Button(action: startRename) { Label(tr("chat", "header.rename"), systemImage: "pencil") }
                if let agent {
                    Button { nav.push(.agent(agent.id)) } label: { Label(tr("chat", "header.view_profile"), systemImage: "person.crop.circle") }
                }
                Divider()
                if archived {
                    Button { store.setArchived(chat.id, false) } label: { Label(tr("chat", "header.unarchive"), systemImage: "arrow.uturn.backward.square") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label(tr("chat", "header.delete"), systemImage: "trash") }
                } else {
                    Button { onArchive(chat) } label: { Label(tr("chat", "header.archive"), systemImage: "archivebox") }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .overlay(alignment: .bottom) { Divider() }
        .alert(tr("chat", "session_history.delete_dialog.title"), isPresented: $confirmDelete) {
            Button(tr("chat", "session_history.delete_dialog.cancel"), role: .cancel) {}
            Button(tr("chat", "session_history.delete_dialog.confirm"), role: .destructive) {
                Task { _ = await store.delete(chat.id) }
            }
        } message: {
            Text(title)
        }
        .onChange(of: chat.id) { editing = false }
    }

    private func startRename() {
        draft = chat.title
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        session.chatUI.rename(chat.id, to: draft)
    }
}
