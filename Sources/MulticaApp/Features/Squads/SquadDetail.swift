import AppKit
import MulticaCore
import SwiftUI

/// Upstream `squad-detail-page.tsx`: inspector on the left, Members /
/// Instructions tabs on the right.
struct SquadDetailPage: View {
    let squadID: String
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    @State private var squad: Squad?
    @State private var members: [SquadMember] = []
    @State private var statuses: [String: SquadMemberStatus] = [:]
    @State private var showAddMember = false
    @State private var confirmArchive = false
    @State private var setLeaderPending = false
    @State private var focusTick = 0

    private var canManage: Bool {
        guard let squad else { return false }
        return SquadsListQuery.canManage(squad, userID: session.currentUser.id, isWorkspaceAdmin: session.projectsIsWorkspaceAdmin)
    }

    /// Agent status flips (task lifecycle reconciles `agent:status`), runtime
    /// changes and squad events all move the members' working/idle pills.
    private var statusKey: String {
        "\(squadID):\(session.revision("squad")):\(session.directory.revision):\(session.directory.runtimes.count):\(focusTick)"
    }

    var body: some View {
        Group {
            if let squad {
                VStack(spacing: 0) {
                    header(squad)
                    GeometryReader { g in
                        HStack(alignment: .top, spacing: 16) {
                            SquadsInspector(squad: squad, memberCount: members.count, canManage: canManage,
                                            onUpdate: { try await update(name: $0.name, description: $0.description, avatarURL: $0.avatarURL) })
                                .frame(width: g.size.width >= 1024 ? 320 : 280)
                            SquadsOverviewPane(
                                squad: squad, members: members, statuses: statuses, canManage: canManage,
                                setLeaderPending: setLeaderPending,
                                onAddMember: { showAddMember = true },
                                onCreateAgent: { nav.push(.newAgent, query: ["squad": squadID]) },
                                onSetLeader: { id in Task { await setLeader(id) } },
                                onRemove: { m in Task { await remove(m) } },
                                onUpdateRole: { m, role in try await updateRole(m, role) },
                                onSaveInstructions: { text in
                                    try await update(instructions: text)
                                    toaster.success(tr("squads", "toasts.instructions_saved"))
                                })
                        }
                        .padding(24)
                    }
                }
                .tabTitle(squad.name)
                .sheet(isPresented: $showAddMember) {
                    SquadsAddMemberDialog(existing: members) { type, id, role in
                        try await add(type: type, id: id, role: role)
                    }
                }
                .squadsArchiveConfirmation(squad: squad, isPresented: $confirmArchive) { nav.push(.squads) }
            } else {
                SquadsDetailSkeleton()
            }
        }
        .task(id: "\(squadID):\(session.revision("squad"))") { await reload() }
        .task(id: statusKey) {
            if focusTick > 0 || session.revision("squad") > 0 { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, let resp = try? await session.api.getSquadMemberStatus(squadId: squadID) else { return }
            statuses = Dictionary(resp.members.map { ($0.memberId, $0) }, uniquingKeysWith: { a, _ in a })
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in focusTick += 1 }
    }

    private func header(_ squad: Squad) -> some View {
        PageHeader {
            HStack(spacing: 6) {
                Button(tr("squads", "page.title")) { nav.push(.squads) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                if squad.avatarUrl?.isEmpty == false {
                    AvatarView(name: squad.name, url: squad.avatarUrl, kind: .squad, size: 16)
                } else {
                    Image(systemName: "person.2").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(squad.name).font(Theme.Font.bodyMedium).lineLimit(1)
            }
            .font(Theme.Font.body)
        } trailing: {
            if canManage {
                Button(role: .destructive) { confirmArchive = true } label: {
                    Label(tr("squads", "inspector.archive_button"), systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.destructive)
            }
        }
    }

    // MARK: Data

    private func reload() async {
        let api = session.api
        let id = squadID
        async let s = api.getSquad(id)
        async let m = api.listSquadMembers(squadId: id)
        if let value = try? await s { squad = value }
        if let value = try? await m { members = value }
    }

    private func afterSquadWrite() async {
        await reload()
        await session.squads.refreshIfLoaded()
    }

    private func update(name: String? = nil, description: String? = nil, instructions: String? = nil,
                        avatarURL: String? = nil, leaderID: String? = nil) async throws {
        do {
            squad = try await session.api.updateSquad(squadID, name: name, description: description, instructions: instructions,
                                                      leaderId: leaderID, avatarUrl: avatarURL)
            await afterSquadWrite()
        } catch {
            toaster.error(error)
            throw error
        }
    }

    private func setLeader(_ agentID: String) async {
        setLeaderPending = true
        defer { setLeaderPending = false }
        do {
            squad = try await session.api.updateSquad(squadID, leaderId: agentID)
            await afterSquadWrite()
            toaster.success(tr("squads", "toasts.leader_updated"))
        } catch {
            toaster.error(message(error, tr("squads", "toasts.leader_update_failed")))
        }
    }

    private func add(type: String, id: String, role: String) async throws {
        do {
            let trimmed = role.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await session.api.addSquadMember(squadId: squadID, memberType: type, memberId: id, role: trimmed.isEmpty ? nil : trimmed)
            members = (try? await session.api.listSquadMembers(squadId: squadID)) ?? members
            toaster.success(tr("squads", "toasts.member_added"))
        } catch {
            toaster.error(message(error, tr("squads", "toasts.member_add_failed")))
            throw error
        }
    }

    private func remove(_ m: SquadMember) async {
        do {
            try await session.api.removeSquadMember(squadId: squadID, memberType: m.memberType, memberId: m.memberId)
            members = (try? await session.api.listSquadMembers(squadId: squadID)) ?? members.filter { $0.id != m.id }
            toaster.success(tr("squads", "toasts.member_removed"))
        } catch {
            toaster.error(message(error, tr("squads", "toasts.member_remove_failed")))
        }
    }

    private func updateRole(_ m: SquadMember, _ role: String) async throws {
        do {
            _ = try await session.api.updateSquadMemberRole(squadId: squadID, memberType: m.memberType, memberId: m.memberId, role: role)
            members = (try? await session.api.listSquadMembers(squadId: squadID)) ?? members
            toaster.success(tr("squads", "toasts.role_updated"))
        } catch {
            toaster.error(message(error, tr("squads", "toasts.role_update_failed")))
            throw error
        }
    }

    private func message(_ error: Error, _ fallback: String) -> String {
        let m = (error as? APIError)?.message ?? error.localizedDescription
        return m.isEmpty ? fallback : m
    }
}

private struct SquadsDetailSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            PageHeader { RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)).frame(width: 192, height: 18) }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    Circle().frame(width: 64, height: 64)
                    RoundedRectangle(cornerRadius: 4).frame(width: 160, height: 18)
                    RoundedRectangle(cornerRadius: 4).frame(height: 12)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).frame(width: 180, height: 10)
                        RoundedRectangle(cornerRadius: 4).frame(width: 150, height: 10)
                        RoundedRectangle(cornerRadius: 4).frame(width: 120, height: 10)
                    }
                    Spacer()
                }
                .padding(20)
                .frame(width: 300)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 4).frame(width: 80, height: 14)
                        RoundedRectangle(cornerRadius: 4).frame(width: 96, height: 14)
                    }
                    RoundedRectangle(cornerRadius: 4).frame(height: 14)
                    RoundedRectangle(cornerRadius: 4).frame(height: 14).padding(.trailing, 80)
                    RoundedRectangle(cornerRadius: 4).frame(height: 14).padding(.trailing, 160)
                    Spacer()
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
            }
            .foregroundStyle(Color.primary.opacity(0.06))
            .padding(24)
        }
    }
}

// MARK: - Inspector

struct SquadsIdentityEdit {
    var name: String?
    var description: String?
    var avatarURL: String?
}

private struct SquadsInspector: View {
    @Environment(WorkspaceSession.self) private var session
    let squad: Squad
    let memberCount: Int
    let canManage: Bool
    let onUpdate: (SquadsIdentityEdit) async throws -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    if canManage {
                        SquadsAvatarUploadControl(value: squad.avatarUrl, name: squad.name, size: 64) { url in
                            try await onUpdate(SquadsIdentityEdit(avatarURL: url))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            SquadsNameEditor(value: squad.name) { try await onUpdate(SquadsIdentityEdit(name: $0)) }
                            SquadsDescriptionEditor(value: squad.description) { try await onUpdate(SquadsIdentityEdit(description: $0)) }
                        }
                    } else {
                        AvatarView(name: squad.name, url: squad.avatarUrl, kind: .squad, size: 64).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(squad.name).font(.system(size: 15, weight: .semibold))
                            if squad.description.isEmpty {
                                Text(tr("squads", "description_dialog.placeholder_empty")).italic()
                                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                            } else {
                                Text(squad.description).font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(20)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("squads", "inspector.details_section").uppercased())
                        .font(.system(size: 10, weight: .medium)).tracking(0.6).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                        row(tr("squads", "details.leader")) {
                            HStack(spacing: 6) {
                                ActorAvatar(type: "agent", id: squad.leaderId, size: 14)
                                Text(name("agent", squad.leaderId)).lineLimit(1)
                            }
                        }
                        row(tr("squads", "details.members")) { Text("\(memberCount)").monospacedDigit().foregroundStyle(.secondary) }
                        row(tr("squads", "details.created_by")) {
                            HStack(spacing: 6) {
                                ActorAvatar(type: "member", id: squad.creatorId, size: 14)
                                Text(name("member", squad.creatorId)).lineLimit(1)
                            }
                        }
                        row(tr("squads", "details.created")) { RelativeTime(timestamp: squad.createdAt).foregroundStyle(.secondary) }
                        row(tr("squads", "details.updated")) { RelativeTime(timestamp: squad.updatedAt).foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
    }

    private func name(_ type: String, _ id: String) -> String {
        type == "agent" ? session.directory.agent(id)?.name ?? String(id.prefix(8))
                        : session.directory.member(userID: id)?.name ?? String(id.prefix(8))
    }

    private func row<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).padding(.vertical, 4)
            value().padding(.vertical, 4)
        }
        .font(Theme.Font.caption)
    }
}

/// Upstream `SquadNameEditor`: pencil-on-hover trigger, popover editor.
private struct SquadsNameEditor: View {
    @Environment(Toaster.self) private var toaster
    let value: String
    let onSave: (String) async throws -> Void
    @State private var open = false
    @State private var draft = ""
    @State private var saving = false
    @State private var error: String?
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 6) {
                Text(value).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.leading)
                Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(hovering ? Color.secondary : Color.clear)
            }
            .padding(.horizontal, 4)
            .hoverHighlight(cornerRadius: Theme.Radius.small)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("squads", "name_editor.title")).font(.system(size: 11, weight: .medium))
                TextField(tr("squads", "name_editor.placeholder"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onChange(of: draft) { error = nil }
                    .onSubmit { Task { await commit() } }
                if let error { Text(error).font(Theme.Font.caption).foregroundStyle(Theme.destructive) }
                HStack {
                    Spacer()
                    Button(tr("squads", "name_editor.cancel")) { open = false }
                        .keyboardShortcut(.cancelAction)
                        .disabled(saving)
                    Button {
                        Task { await commit() }
                    } label: {
                        if saving { ProgressView().controlSize(.small) } else { Text(tr("squads", "name_editor.save")) }
                    }
                    .disabled(saving || draft == value)
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(width: 288)
            .onAppear {
                draft = value
                error = nil
                focused = true
            }
        }
    }

    private func commit() async {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = tr("squads", "name_editor.required")
            return
        }
        guard draft != value else { open = false; return }
        saving = true
        defer { saving = false }
        do {
            try await onSave(draft.trimmingCharacters(in: .whitespacesAndNewlines))
            open = false
            toaster.success(tr("squads", "name_editor.saved"))
        } catch {}
    }
}

/// Upstream `SquadDescriptionEditor`: inline text, edited in a dialog.
private struct SquadsDescriptionEditor: View {
    let value: String
    let onSave: (String) async throws -> Void
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open = true } label: {
            HStack(alignment: .top, spacing: 6) {
                if value.isEmpty {
                    Text(tr("squads", "description_dialog.placeholder_empty")).italic()
                } else {
                    Text(value).multilineTextAlignment(.leading)
                }
                Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(hovering ? Color.secondary : Color.clear).padding(.top, 2)
            }
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .hoverHighlight(cornerRadius: Theme.Radius.small)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .sheet(isPresented: $open) {
            SquadsDescriptionDialog(initial: value, onSave: onSave) { open = false }
        }
    }
}

private struct SquadsDescriptionDialog: View {
    let initial: String
    let onSave: (String) async throws -> Void
    let onClose: () -> Void
    @State private var draft = ""
    @State private var saving = false

    var body: some View {
        let dirty = draft != initial
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("squads", "description_dialog.title")).font(Theme.Font.title)
            MarkdownEditor(text: $draft, placeholder: tr("squads", "description_dialog.responsibility_placeholder"),
                           minHeight: 120, maxHeight: 240, autofocus: true,
                           onSubmit: { Task { await commit() } }, onEscape: onClose)
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
            HStack {
                Spacer()
                Button(tr("squads", "description_dialog.cancel"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button {
                    Task { await commit() }
                } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text(tr("squads", "description_dialog.save")) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || !dirty)
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { draft = initial }
    }

    private func commit() async {
        guard !saving else { return }
        guard draft != initial else { onClose(); return }
        saving = true
        defer { saving = false }
        do {
            try await onSave(draft)
            onClose()
        } catch {}
    }
}

// MARK: - Overview tabs

private enum SquadsDetailTab: String, CaseIterable {
    case members, instructions

    var icon: String { self == .members ? "person.2" : "doc.text" }
}

private struct SquadsOverviewPane: View {
    let squad: Squad
    let members: [SquadMember]
    let statuses: [String: SquadMemberStatus]
    let canManage: Bool
    let setLeaderPending: Bool
    let onAddMember: () -> Void
    let onCreateAgent: () -> Void
    let onSetLeader: (String) -> Void
    let onRemove: (SquadMember) -> Void
    let onUpdateRole: (SquadMember, String) async throws -> Void
    let onSaveInstructions: (String) async throws -> Void
    @State private var tab: SquadsDetailTab = .members
    @State private var dirty = false
    @State private var pendingTab: SquadsDetailTab?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SquadsDetailTab.allCases, id: \.self) { t in
                    Button { request(t) } label: {
                        Label(tr("squads", "detail_tabs.\(t.rawValue)"), systemImage: t.icon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tab == t ? .primary : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(tab == t ? Color.primary : .clear).frame(height: 2)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .overlay(alignment: .bottom) { Divider() }
            Group {
                switch tab {
                case .members:
                    ScrollView {
                        SquadsMembersTab(squad: squad, members: members, statuses: statuses, canManage: canManage,
                                         setLeaderPending: setLeaderPending, onAddMember: onAddMember, onCreateAgent: onCreateAgent,
                                         onSetLeader: onSetLeader, onRemove: onRemove, onUpdateRole: onUpdateRole)
                            .padding(24)
                    }
                case .instructions:
                    SquadsInstructionsTab(squad: squad, canManage: canManage, onSave: onSaveInstructions, dirty: $dirty)
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
        .alert(tr("squads", "discard_changes_dialog.title"), isPresented: Binding(get: { pendingTab != nil }, set: { if !$0 { pendingTab = nil } })) {
            Button(tr("squads", "discard_changes_dialog.keep_editing"), role: .cancel) { pendingTab = nil }
            Button(tr("squads", "discard_changes_dialog.discard_button"), role: .destructive) {
                if let pendingTab { tab = pendingTab }
                dirty = false
                pendingTab = nil
            }
        } message: {
            Text(tr("squads", "discard_changes_dialog.description"))
        }
    }

    private func request(_ next: SquadsDetailTab) {
        guard next != tab else { return }
        if dirty { pendingTab = next } else { tab = next }
    }
}

private struct SquadsMembersTab: View {
    let squad: Squad
    let members: [SquadMember]
    let statuses: [String: SquadMemberStatus]
    let canManage: Bool
    let setLeaderPending: Bool
    let onAddMember: () -> Void
    let onCreateAgent: () -> Void
    let onSetLeader: (String) -> Void
    let onRemove: (SquadMember) -> Void
    let onUpdateRole: (SquadMember, String) async throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("squads", "members_tab.section_title")).font(Theme.Font.bodyMedium)
                    Text(tr("squads", "members_tab.section_count", ["count": members.count]))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if canManage {
                    Button(action: onCreateAgent) { Label(tr("squads", "members_tab.create_agent_button"), systemImage: "plus") }
                    Button(action: onAddMember) { Label(tr("squads", "members_tab.add_member_button"), systemImage: "plus") }
                }
            }
            .controlSize(.small)
            LazyVStack(spacing: 8) {
                ForEach(members) { m in
                    SquadsMemberCard(member: m, status: statuses[m.memberId], isLeader: m.memberType == "agent" && squad.leaderId == m.memberId,
                                     canManage: canManage, setLeaderPending: setLeaderPending,
                                     onSetLeader: { onSetLeader(m.memberId) }, onRemove: { onRemove(m) },
                                     onUpdateRole: { try await onUpdateRole(m, $0) })
                }
            }
        }
    }
}

private struct SquadsMemberCard: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let member: SquadMember
    let status: SquadMemberStatus?
    let isLeader: Bool
    let canManage: Bool
    let setLeaderPending: Bool
    let onSetLeader: () -> Void
    let onRemove: () -> Void
    let onUpdateRole: (String) async throws -> Void
    @State private var hovering = false

    var body: some View {
        let isAgent = member.memberType == "agent"
        let archived = isAgent && session.directory.agent(member.memberId)?.archivedAt != nil
        let statusValue = status?.status
        let issues = status?.activeIssues ?? []
        HStack(alignment: .top, spacing: 12) {
            ActorAvatar(type: member.memberType, id: member.memberId, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(name).font(Theme.Font.bodyMedium).lineLimit(1)
                    Text(tr("squads", "member_type.\(member.memberType == "agent" ? "agent" : "member")"))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                    if isLeader { SquadsLeaderChip() }
                    if isAgent, let statusValue, let label = statusLabel(statusValue) {
                        HStack(spacing: 4) {
                            Circle().fill(statusColor(statusValue)).frame(width: 6, height: 6)
                            Text(label)
                        }
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                }
                if canManage {
                    SquadsRoleEditor(value: member.role, onSave: onUpdateRole)
                } else if !member.role.isEmpty {
                    Text(member.role).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                if let primary = issues.first {
                    HStack(spacing: 4) {
                        Button { nav.push(.issue(primary.issueId), title: primary.title) } label: {
                            HStack(spacing: 4) {
                                Text(primary.identifier.uppercased()).font(.system(size: 10, design: .monospaced))
                                Text(primary.title).lineLimit(1)
                                if primary.issueStatus == "blocked" {
                                    Text(tr("squads", "members_tab.issue_status_blocked").uppercased())
                                        .font(.system(size: 10)).tracking(0.5).foregroundStyle(Theme.warning)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        if issues.count > 1 {
                            Text("· " + tr("squads", "members_tab.active_issue_more", ["count": issues.count - 1]))
                        }
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
                if isAgent, let statusValue, statusValue != "working", let last = status?.lastActiveAt {
                    Text(tr("squads", "members_tab.last_active_label", ["time": Formatters.relative(last)]))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if isAgent {
                    actionButton("arrow.up.right", tr("squads", "members_tab.view_agent_tooltip")) {
                        nav.push(.agent(member.memberId), title: name)
                    }
                }
                if canManage && isAgent && !isLeader && !archived {
                    actionButton("crown", tr("squads", "members_tab.make_leader_tooltip"), action: onSetLeader)
                        .disabled(setLeaderPending)
                }
                if canManage && !isLeader {
                    actionButton("trash", tr("squads", "members_tab.remove_member_tooltip"), action: onRemove)
                }
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.001)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
        .onHover { hovering = $0 }
    }

    private var name: String {
        member.memberType == "agent" ? session.directory.agent(member.memberId)?.name ?? String(member.memberId.prefix(8))
                                     : session.directory.member(userID: member.memberId)?.name ?? String(member.memberId.prefix(8))
    }

    private func statusLabel(_ s: String) -> String? {
        ["working", "idle", "offline", "unstable", "archived"].contains(s) ? tr("squads", "members_tab.status_\(s)") : nil
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "working": return Theme.success
        case "unstable": return Theme.warning
        default: return Color.secondary.opacity(0.4)
        }
    }

    private func actionButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .hoverHighlight()
        .help(help)
    }
}

/// Upstream `RoleEditor`: click to edit inline; Return/blur commits, Escape cancels.
private struct SquadsRoleEditor: View {
    let value: String
    let onSave: (String) async throws -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField(tr("squads", "role_editor.placeholder"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(Theme.Font.caption)
                .frame(maxWidth: 260)
                .focused($focused)
                .disabled(saving)
                .onSubmit { Task { await commit() } }
                .onExitCommand { draft = value; editing = false }
                .onChange(of: focused) { if !focused && editing { Task { await commit() } } }
                .onAppear { focused = true }
        } else {
            Button {
                draft = value
                editing = true
            } label: {
                Group {
                    if value.isEmpty {
                        Text(tr("squads", "role_editor.empty")).italic().opacity(0.6)
                    } else {
                        Text(value)
                    }
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func commit() async {
        guard !saving else { return }
        let next = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != value.trimmingCharacters(in: .whitespacesAndNewlines) else { editing = false; return }
        saving = true
        defer { saving = false }
        do {
            try await onSave(next)
            editing = false
        } catch {}
    }
}

private struct SquadsInstructionsTab: View {
    let squad: Squad
    let canManage: Bool
    let onSave: (String) async throws -> Void
    @Binding var dirty: Bool
    @State private var value = ""
    @State private var saving = false

    var body: some View {
        let isDirty = value != squad.instructions
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("squads", "instructions_tab.description")).font(Theme.Font.caption).foregroundStyle(.secondary)
            ScrollView {
                MarkdownEditor(text: $value, placeholder: canManage ? tr("squads", "instructions_tab.placeholder") : "",
                               minHeight: 240, maxHeight: 100_000, isEditable: canManage)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .frame(maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
            if canManage {
                HStack(spacing: 12) {
                    Spacer()
                    if isDirty {
                        Text(tr("squads", "instructions_tab.unsaved_changes")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        Task {
                            saving = true
                            defer { saving = false }
                            try? await onSave(value)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if saving { ProgressView().controlSize(.mini) } else { Image(systemName: "square.and.arrow.down") }
                            Text(tr("squads", "instructions_tab.save_button"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!isDirty || saving)
                }
            }
        }
        .onAppear { value = squad.instructions }
        .onChange(of: squad.id) { value = squad.instructions }
        .onChange(of: squad.instructions) { value = squad.instructions }
        .onChange(of: isDirty) { dirty = canManage && isDirty }
        .onDisappear { dirty = false }
    }
}

// MARK: - Add member

/// Upstream `AddMemberDialog`: pick a member or agent, optionally a role.
private struct SquadsAddMemberDialog: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceSession.self) private var session
    let existing: [SquadMember]
    let onSubmit: (_ type: String, _ id: String, _ role: String) async throws -> Void
    @State private var target: SquadsCreateSelection.Pick?
    @State private var role = ""
    @State private var pickerOpen = false
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("squads", "add_member_dialog.title")).font(Theme.Font.title)
                Text(tr("squads", "add_member_dialog.description")).font(Theme.Font.body).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("squads", "add_member_dialog.label_member")).font(Theme.Font.caption).foregroundStyle(.secondary)
                Button { pickerOpen.toggle() } label: {
                    HStack(spacing: 12) {
                        if let target {
                            ActorAvatar(type: target.type, id: target.id, size: 20)
                        } else {
                            Image(systemName: "person.badge.plus").foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(target?.name ?? tr("squads", "add_member_dialog.select_target")).font(Theme.Font.bodyMedium).lineLimit(1)
                            if let target {
                                Text(tr("squads", "member_type.\(target.type)")).font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(pickerOpen ? 180 : 0))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.02)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                    SquadsActorPicker(
                        searchPlaceholder: tr("squads", "add_member_dialog.search_placeholder"),
                        sections: sections,
                        isSelected: { target?.type == $0.type && target?.id == $0.id }
                    ) { pick in
                        target = pick
                        pickerOpen = false
                    }
                    .frame(width: 380)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                (Text(tr("squads", "add_member_dialog.label_role")) + Text(" ") + Text(tr("squads", "add_member_dialog.label_optional")))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                TextField(tr("squads", "add_member_dialog.role_placeholder"), text: $role)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await submit() } }
            }
            HStack {
                Spacer()
                Button(tr("squads", "add_member_dialog.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await submit() }
                } label: {
                    if submitting { ProgressView().controlSize(.small) } else { Text(tr("squads", "add_member_dialog.add")) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target == nil || submitting)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var sections: [SquadsActorPicker.Section] {
        let members = session.directory.members
            .filter { m in !existing.contains { $0.memberType == "member" && $0.memberId == m.userID } }
            .map { SquadsCreateSelection.Pick(type: "member", id: $0.userID, name: $0.name) }
        let agents = session.directory.agents
            .filter { a in a.archivedAt == nil && !existing.contains { $0.memberType == "agent" && $0.memberId == a.id } }
            .map { SquadsCreateSelection.Pick(type: "agent", id: $0.id, name: $0.name) }
        return [
            .init(title: tr("squads", "add_member_dialog.members_section"), items: members),
            .init(title: tr("squads", "add_member_dialog.agents_section"), items: agents),
        ]
    }

    private func submit() async {
        guard let target, !submitting else { return }
        submitting = true
        do {
            try await onSubmit(target.type, target.id, role)
            dismiss()
        } catch {
            submitting = false
        }
    }
}

/// Searchable, sectioned member/agent list (upstream PickerSection/PickerItem).
struct SquadsActorPicker: View {
    struct Section {
        var title: String
        var items: [SquadsCreateSelection.Pick]
    }

    let searchPlaceholder: String
    let sections: [Section]
    let isSelected: (SquadsCreateSelection.Pick) -> Bool
    let onPick: (SquadsCreateSelection.Pick) -> Void
    @State private var filter = ""
    @FocusState private var focused: Bool

    var body: some View {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = sections.map { s in
            Section(title: s.title, items: s.items.filter { q.isEmpty || $0.name.lowercased().contains(q) || ProjectsPinyin.matches($0.name, q) })
        }
        VStack(alignment: .leading, spacing: 0) {
            TextField(searchPlaceholder, text: $filter)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .focused($focused)
                .padding(.horizontal, 10)
                .frame(height: 32)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered.indices, id: \.self) { i in
                        let s = filtered[i]
                        if !s.items.isEmpty {
                            Text(s.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                            ForEach(s.items, id: \.self) { item in
                                Button { onPick(item) } label: {
                                    HStack(spacing: 8) {
                                        ActorAvatar(type: item.type, id: item.id, size: 18)
                                        Text(item.name).lineLimit(1)
                                        Spacer(minLength: 4)
                                        if isSelected(item) {
                                            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                                        }
                                    }
                                    .font(Theme.Font.body)
                                }
                                .buttonStyle(HoverRowButtonStyle(selected: isSelected(item)))
                            }
                        }
                    }
                    if filtered.allSatisfy({ $0.items.isEmpty }) {
                        Text(tr("issues", "pickers.no_results"))
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 288)
        }
        .onAppear { focused = true }
    }
}
