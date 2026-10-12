import MulticaCore
import SwiftUI

/// A committable access selection.
struct AgentsUIAccessChange: Hashable {
    var permissionMode: String
    var targets: [AgentInvocationTargetInput]

    var patch: [String: JSONValue] {
        ["permission_mode": .string(permissionMode),
         "invocation_targets": .array(targets.map { t in
             var o: [String: JSONValue] = ["target_type": .string(t.targetType)]
             if let id = t.targetId { o["target_id"] = .string(id) }
             return .object(o)
         })]
    }
}

/// Draft-first access editor (upstream inspector/access-picker): choosing a
/// scope only edits the draft; nothing persists until Save (or the bulk
/// dialog's Apply, with `hideFooter`).
struct AgentsUIAccessPicker: View {
    enum Scope: String { case `private`, workspace, members }

    let permissionMode: String
    let targets: [AgentInvocationTarget]
    let members: [Member]
    let ownerID: String?
    var canEdit = true
    var hasComposioAllowlist = false
    var hideFooter = false
    var onDirtyChange: ((Bool) -> Void)? = nil
    var onReadyChange: ((AgentsUIAccessChange?) -> Void)? = nil
    var onSave: ((AgentsUIAccessChange) async -> Void)? = nil

    @State private var draftScope: Scope = .private
    @State private var draftMembers: [String] = []
    @State private var saving = false
    @State private var hasInteracted = false
    @State private var seeded = false

    private var persistedScope: Scope {
        switch AgentsUI.accessScope(permissionMode: permissionMode, targets: targets) {
        case .ownerOnly: return .private
        case .workspace: return .workspace
        case .specificPeople: return .members
        }
    }

    private var persistedMembers: [String] { targets.filter { $0.targetType == "member" }.compactMap(\.targetId) }
    private var teamIDs: [String] { targets.filter { $0.targetType == "team" }.compactMap(\.targetId) }
    private var persistedKey: String { persistedScope.rawValue + ":" + persistedMembers.joined(separator: ",") }

    private var dirty: Bool {
        draftScope != persistedScope || (draftScope == .members && Set(draftMembers) != Set(persistedMembers))
    }

    private var draftChange: AgentsUIAccessChange? {
        switch draftScope {
        case .private: return AgentsUIAccessChange(permissionMode: "private", targets: [])
        case .workspace: return AgentsUIAccessChange(permissionMode: "public_to", targets: [AgentInvocationTargetInput(targetType: "workspace")])
        case .members:
            guard !draftMembers.isEmpty else { return nil }
            return AgentsUIAccessChange(permissionMode: "public_to",
                                        targets: draftMembers.map { AgentInvocationTargetInput(targetType: "member", targetId: $0) }
                                            + teamIDs.map { AgentInvocationTargetInput(targetType: "team", targetId: $0) })
        }
    }

    var body: some View {
        Group {
            if canEdit { editor } else { readonly }
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            draftScope = persistedScope
            draftMembers = persistedMembers
        }
        .onChange(of: persistedKey) {
            draftScope = persistedScope
            draftMembers = persistedMembers
        }
        .onChange(of: dirty, initial: true) { onDirtyChange?(dirty) }
        .onChange(of: hasInteracted ? draftChange : nil, initial: true) { _, new in onReadyChange?(new) }
        .onDisappear { onDirtyChange?(false) }
    }

    private var readonly: some View {
        let summary: String = {
            switch persistedScope {
            case .private: return tr("agents", "access.trigger_private")
            case .workspace: return tr("agents", "access.trigger_workspace")
            case .members:
                return persistedMembers.isEmpty ? tr("agents", "access.trigger_members_empty")
                    : tr("agents", "access.trigger_members_count", ["count": persistedMembers.count])
            }
        }()
        return HStack(alignment: .top, spacing: 12) {
            iconCircle("lock")
            VStack(alignment: .leading, spacing: 2) {
                Text(summary).font(Theme.Font.bodyMedium)
                Text(tr("agents", "access.owner_only_readonly")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editor: some View {
        let editable = members.filter { $0.userID != ownerID }
        return VStack(alignment: .leading, spacing: 0) {
            choice(.private, icon: "lock", title: tr("agents", "access.private_title"), desc: tr("agents", "access.private_desc"))
            Divider()
            choice(.workspace, icon: "globe", title: tr("agents", "access.workspace_title"), desc: tr("agents", "access.workspace_desc"))
            Divider()
            choice(.members, icon: "person.2", title: tr("agents", "access.members_title"), desc: tr("agents", "access.members_desc"))
            if draftScope == .members {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if editable.isEmpty {
                        Text(tr("agents", "access.members_empty")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(editable) { m in
                                    memberRow(m)
                                    if m.id != editable.last?.id { Divider() }
                                }
                            }
                        }
                        .frame(maxHeight: 256)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
                    }
                    if draftMembers.isEmpty {
                        Text(tr("agents", "access.shared_target_required")).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                    }
                }
                .padding(16)
                .background(Color.primary.opacity(0.02))
            }
            if hasComposioAllowlist && persistedScope == .private && draftScope != .private {
                Divider()
                Text(tr("agents", "access.composio_switch_hint"))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.warning).frame(width: 2) }
                    .padding(16)
            }
            if !hideFooter {
                Divider()
                HStack {
                    Spacer()
                    Button {
                        guard let change = draftChange, let onSave else { return }
                        saving = true
                        Task {
                            await onSave(change)
                            saving = false
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if saving { ProgressView().controlSize(.mini) }
                            Text(tr("common", "save"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(onSave == nil || !dirty || saving || (draftScope == .members && draftMembers.isEmpty))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private func iconCircle(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.primary.opacity(0.06)))
    }

    private func choice(_ scope: Scope, icon: String, title: String, desc: String) -> some View {
        Button {
            hasInteracted = true
            draftScope = scope
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: draftScope == scope ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(draftScope == scope ? Theme.brand : .secondary)
                    .padding(.top, 8)
                iconCircle(icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Font.bodyMedium)
                    Text(desc).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 0)
    }

    private func memberRow(_ m: Member) -> some View {
        let checked = draftMembers.contains(m.userID)
        return Button {
            if checked { draftMembers.removeAll { $0 == m.userID } } else { draftMembers.append(m.userID) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(checked ? Theme.brand : .secondary)
                AvatarView(name: m.name, url: m.avatarURL, size: 20)
                Text(m.name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 0)
    }
}

/// Settings › Access (upstream AgentAccessSettings): only the owner edits.
struct AgentsUIAccessSettings: View {
    @Environment(WorkspaceSession.self) private var session
    let agent: AgentRecord
    var onDirtyChange: (Bool) -> Void
    let onUpdate: ([String: JSONValue]) async throws -> Void

    var body: some View {
        AgentsUISettingsSection(title: tr("agents", "access.section_title")) {
            AgentsUISettingsCard {
                AgentsUIAccessPicker(
                    permissionMode: agent.permissionMode,
                    targets: agent.invocationTargets,
                    members: session.directory.members,
                    ownerID: agent.ownerId,
                    canEdit: agent.ownerId != nil && agent.ownerId == session.currentUser.id,
                    hasComposioAllowlist: !(agent.composioToolkitAllowlist ?? []).isEmpty,
                    onDirtyChange: onDirtyChange,
                    onSave: { change in try? await onUpdate(change.patch) }
                )
            }
        }
    }
}
