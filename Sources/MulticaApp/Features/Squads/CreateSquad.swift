import MulticaCore
import SwiftUI

/// Upstream `modals/create-squad.tsx`.
struct CreateSquadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    @State private var name = ""
    @State private var description = ""
    @State private var avatarURL: String?
    @State private var selection = SquadsCreateSelection()
    @State private var creating = false
    @FocusState private var nameFocused: Bool

    static let descriptionMax = 255

    private var activeAgents: [AgentRecord] {
        session.agentRecords.items.filter { $0.archivedAt == nil && !$0.runtimeId.isEmpty }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selection.leaderID.isEmpty && !creating
    }

    var body: some View {
        let agents = activeAgents
        let me = session.currentUser.id
        VStack(spacing: 0) {
            Text(tr("modals", "create_squad.title"))
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { Divider() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        SquadsAvatarUploadControl(value: avatarURL, name: name, size: 64, onUploaded: { avatarURL = $0 },
                                                  onClear: { avatarURL = nil })
                        VStack(alignment: .leading, spacing: 12) {
                            field(tr("modals", "create_squad.name_label")) {
                                TextField(tr("modals", "create_squad.name_placeholder"), text: $name)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($nameFocused)
                                    .onSubmit { Task { await submit() } }
                            }
                            field(tr("modals", "create_squad.description_label")) {
                                TextField(tr("modals", "create_squad.description_placeholder"), text: Binding(
                                    get: { description },
                                    set: { description = String($0.prefix(Self.descriptionMax)) }))
                                    .textFieldStyle(.roundedBorder)
                                SquadsCharCounter(length: description.count, max: Self.descriptionMax)
                            }
                        }
                    }
                    SquadsLeaderPicker(agents: agents, currentUserID: me, value: selection.leaderID) { selection.setLeader($0) }
                    SquadsAdditionalMembersPicker(agents: agents, currentUserID: me, selection: $selection)
                }
                .padding(20)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(tr("modals", "create_squad.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(creating ? tr("modals", "create_squad.submitting") : tr("modals", "create_squad.submit")) {
                    Task { await submit() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Divider() }
        }
        .frame(width: 672, height: 600)
        .onAppear { nameFocused = true }
        .task { await session.agentRecords.loadIfNeeded() }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.Font.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        creating = true
        let api = session.api
        do {
            let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
            let squad = try await api.createSquad(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  description: desc.isEmpty ? nil : desc,
                                                  leaderId: selection.leaderID, avatarUrl: avatarURL)
            let failures = await withTaskGroup(of: (String, String)?.self) { group -> [(String, String)] in
                for m in selection.members {
                    group.addTask {
                        do {
                            _ = try await api.addSquadMember(squadId: squad.id, memberType: m.type, memberId: m.id)
                            return nil
                        } catch {
                            return (m.name, (error as? APIError)?.message ?? error.localizedDescription)
                        }
                    }
                }
                var out: [(String, String)] = []
                for await r in group { if let r { out.append(r) } }
                return out
            }
            for (who, err) in failures {
                toaster.show(tr("modals", "create_squad.toast_member_add_failed", ["name": who, "error": err]))
            }
            session.squads.upsert(squad)
            Task { await session.squads.refreshIfLoaded() }
            dismiss()
            toaster.success(tr("modals", "create_squad.toast_created"))
            nav.push(.squad(squad.id), title: squad.name)
        } catch {
            let m = (error as? APIError)?.message ?? error.localizedDescription
            toaster.error(m.isEmpty ? tr("modals", "create_squad.toast_failed") : m)
            creating = false
        }
    }
}

/// Upstream `CharCounter`: warns at 90 %, errors past the cap.
struct SquadsCharCounter: View {
    let length: Int
    let max: Int

    var body: some View {
        let over = length > max
        let near = !over && length >= Int(Double(max) * 0.9)
        Text("\(length) / \(max)" + (over ? tr("agents", "char_counter.over_limit", ["count": length - max]) : ""))
            .font(Theme.Font.caption)
            .monospacedDigit()
            .foregroundStyle(over ? Theme.destructive : (near ? Theme.warning : .secondary))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Single-select leader: "My Agents" first, then "Workspace Agents".
private struct SquadsLeaderPicker: View {
    let agents: [AgentRecord]
    let currentUserID: String
    let value: String
    let onChange: (String) -> Void
    @State private var open = false

    var body: some View {
        let selected = agents.first { $0.id == value }
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("modals", "create_squad.leader_label")).font(Theme.Font.caption).foregroundStyle(.secondary)
            Text(tr("modals", "create_squad.leader_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if agents.isEmpty {
                Text(tr("modals", "create_squad.no_agents"))
                    .font(Theme.Font.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                Button { open.toggle() } label: {
                    HStack(spacing: 12) {
                        if let selected {
                            AvatarView(name: selected.name, url: selected.avatarUrl, kind: .agent, size: 20)
                        } else {
                            Image(systemName: "person.badge.plus").foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(selected?.name ?? tr("modals", "create_squad.leader_placeholder")).font(Theme.Font.bodyMedium).lineLimit(1)
                            if let d = selected?.description, !d.isEmpty {
                                Text(d).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .modifier(SquadsFieldChrome())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    SquadsActorPicker(searchPlaceholder: tr("modals", "create_squad.picker_search_placeholder"),
                                      sections: sections, isSelected: { $0.id == value }) { pick in
                        onChange(pick.id)
                        open = false
                    }
                    .frame(width: 600)
                }
            }
        }
    }

    private var sections: [SquadsActorPicker.Section] {
        let mine = agents.filter { $0.ownerId == currentUserID }.map { SquadsCreateSelection.Pick(type: "agent", id: $0.id, name: $0.name) }
        let others = agents.filter { $0.ownerId != currentUserID }.map { SquadsCreateSelection.Pick(type: "agent", id: $0.id, name: $0.name) }
        return [
            .init(title: tr("modals", "create_squad.group_my_agents"), items: mine),
            .init(title: tr("modals", "create_squad.group_workspace_agents"), items: others),
        ]
    }
}

/// Multi-select agents and members; the popover stays open while toggling.
private struct SquadsAdditionalMembersPicker: View {
    @Environment(WorkspaceSession.self) private var session
    let agents: [AgentRecord]
    let currentUserID: String
    @Binding var selection: SquadsCreateSelection
    @State private var open = false

    private static let chipLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            (Text(tr("modals", "create_squad.members_label")) + Text(" ") + Text(tr("modals", "create_squad.members_optional")))
                .font(Theme.Font.caption).foregroundStyle(.secondary)
            Text(tr("modals", "create_squad.members_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if selection.members.isEmpty {
                    Image(systemName: "person.badge.plus").foregroundStyle(.secondary)
                    Text(tr("modals", "create_squad.members_placeholder")).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    ProjectsFlowLayout(spacing: 6) {
                        ForEach(selection.members.prefix(Self.chipLimit), id: \.self) { m in chip(m) }
                        if selection.members.count > Self.chipLimit {
                            Text(tr("modals", "create_squad.members_more_count", ["count": selection.members.count - Self.chipLimit]))
                                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.06)))
                        }
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(Theme.Font.body)
            .modifier(SquadsFieldChrome())
            .onTapGesture { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                SquadsActorPicker(searchPlaceholder: tr("modals", "create_squad.picker_search_placeholder"),
                                  sections: sections, isSelected: { selection.contains(type: $0.type, id: $0.id) }) { pick in
                    selection.toggle(pick)
                }
                .frame(width: 600)
            }
        }
    }

    private func chip(_ m: SquadsCreateSelection.Pick) -> some View {
        HStack(spacing: 4) {
            ActorAvatar(type: m.type, id: m.id, size: 14)
            Text(m.name).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
            Button { selection.remove(m) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tr("modals", "create_squad.members_remove_aria", ["name": m.name]))
        }
        .font(Theme.Font.caption)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(.background))
        .overlay(Capsule().strokeBorder(Theme.border))
    }

    private var sections: [SquadsActorPicker.Section] {
        let leader = selection.leaderID
        let mine = agents.filter { $0.ownerId == currentUserID && $0.id != leader }
            .map { SquadsCreateSelection.Pick(type: "agent", id: $0.id, name: $0.name) }
        let others = agents.filter { $0.id != leader && $0.ownerId != currentUserID }
            .map { SquadsCreateSelection.Pick(type: "agent", id: $0.id, name: $0.name) }
        let members = session.directory.members.map { SquadsCreateSelection.Pick(type: "member", id: $0.userID, name: $0.name) }
        return [
            .init(title: tr("modals", "create_squad.group_my_agents"), items: mine),
            .init(title: tr("modals", "create_squad.group_workspace_agents"), items: others),
            .init(title: tr("modals", "create_squad.group_members"), items: members),
        ]
    }
}

struct SquadsFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.02)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
    }
}
