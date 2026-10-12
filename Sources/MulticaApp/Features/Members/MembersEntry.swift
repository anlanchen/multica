import MulticaCore
import SwiftUI

/// Upstream `members/member-detail-page.tsx`: identity header plus the
/// member's issues. `memberID` is the member's user id.
struct MemberDetailPage: View {
    let memberID: String
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        let member = session.directory.member(userID: memberID)
        let record = session.memberRecords.items.first { $0.userId == memberID }
        Group {
            if let name = member?.name ?? record?.name {
                VStack(spacing: 0) {
                    MembersBreadcrumb(title: name)
                    HStack(spacing: 12) {
                        AvatarView(name: name, url: member?.avatarURL ?? record?.avatarUrl, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                                MembersRoleBadge(role: member?.role ?? record?.role ?? "member")
                            }
                            Text(member?.email ?? record?.email ?? "").font(Theme.Font.body).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .overlay(alignment: .bottom) { Divider() }
                    IssueCollectionView(scope: .actor(type: "member", id: memberID))
                }
                .tabTitle(name)
            } else if !session.isBootstrapped || session.memberRecords.isLoading {
                MembersDetailSkeleton()
            } else {
                VStack(spacing: 0) {
                    MembersBreadcrumb(title: tr("members", "detail.breadcrumb_fallback"))
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                        VStack(spacing: 4) {
                            Text(tr("members", "detail.not_found_title")).font(Theme.Font.bodyMedium)
                            Text(tr("members", "detail.not_found_description")).font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 64)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: memberID) {
            if session.directory.member(userID: memberID) == nil { await session.memberRecords.loadIfNeeded() }
        }
    }
}

private struct MembersBreadcrumb: View {
    @Environment(WorkspaceSession.self) private var session
    let title: String

    var body: some View {
        PageHeader {
            HStack(spacing: 6) {
                WorkspaceAvatar(name: session.workspace.name, url: session.workspace.avatarURL, size: 16)
                Text(session.workspace.name.isEmpty ? tr("members", "detail.workspace_fallback") : session.workspace.name)
                    .foregroundStyle(.secondary)
                chevron
                Text(tr("members", "detail.members_breadcrumb")).foregroundStyle(.secondary)
                chevron
                Text(title).fontWeight(.medium).lineLimit(1)
            }
            .font(Theme.Font.body)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
    }
}

struct MembersRoleBadge: View {
    let role: String

    var body: some View {
        Text(tr("members", "role.\(MembersRole.key(role))"))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.06)))
    }
}

private struct MembersDetailSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            PageHeader { RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)).frame(width: 208, height: 18) }
            HStack(spacing: 12) {
                Circle().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).frame(width: 160, height: 18)
                    RoundedRectangle(cornerRadius: 4).frame(width: 224, height: 14)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            HStack(alignment: .top, spacing: 16) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).frame(width: 80, height: 14)
                        RoundedRectangle(cornerRadius: 8).frame(height: 96)
                        RoundedRectangle(cornerRadius: 8).frame(height: 96)
                    }
                }
            }
            .padding(16)
            Spacer()
        }
        .foregroundStyle(Color.primary.opacity(0.06))
    }
}

/// 30-day run counts per agent, fetched once per workspace (orders a
/// member's agents on the profile card).
@MainActor
@Observable
final class MembersRunCounts {
    static let shared = MembersRunCounts()
    private(set) var counts: [AgentRunCount] = []
    @ObservationIgnored private var loadedFor: String?

    func load(_ session: WorkspaceSession) async {
        guard loadedFor != session.workspace.id else { return }
        loadedFor = session.workspace.id
        counts = (try? await session.api.getWorkspaceAgentRunCounts()) ?? []
    }
}

/// Upstream `MemberProfileCard`: identity plus the member's most-used agents.
struct MembersProfileCard: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let userID: String
    @State private var runs = MembersRunCounts.shared

    var body: some View {
        let member = session.directory.member(userID: userID)
        Group {
            if let member {
                let owned = MembersOwnedAgents.sorted(session.agentRecords.items, ownerID: userID, runCounts: runs.counts)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        AvatarView(name: member.name, url: member.avatarURL, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(member.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                MembersRoleBadge(role: member.role)
                            }
                            Text(member.email).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if !owned.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("members", "card.agents_section", ["count": owned.count])).foregroundStyle(.secondary)
                            ForEach(owned.prefix(2)) { a in
                                MembersOwnedAgentRow(agent: a) { nav.push(.agent(a.id), title: a.name) }
                            }
                            if owned.count > 2 {
                                Text(tr("members", "card.more_agents", ["count": owned.count - 2])).foregroundStyle(.secondary)
                            }
                        }
                        .font(Theme.Font.caption)
                    }
                }
            } else if !session.isBootstrapped {
                HStack(spacing: 12) {
                    Circle().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).frame(width: 112, height: 14)
                        RoundedRectangle(cornerRadius: 3).frame(width: 80, height: 10)
                    }
                }
                .foregroundStyle(Color.primary.opacity(0.06))
            } else {
                Text(tr("members", "card.unavailable")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 288, alignment: .leading)
        .task {
            async let agents: Void = session.agentRecords.loadIfNeeded()
            async let counts: Void = runs.load(session)
            _ = await (agents, counts)
        }
    }
}

private struct MembersOwnedAgentRow: View {
    let agent: AgentRecord
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                ActorAvatar(type: "agent", id: agent.id, size: 18).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name).fontWeight(.medium).lineLimit(1)
                    if !agent.description.isEmpty {
                        Text(agent.description).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(tr("members", "card.detail_link")).foregroundStyle(Theme.brand).opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension View {
    /// Upstream `ActorAvatar enableHoverCard` for human members and squads:
    /// the profile card opens after a short hover and stays while the
    /// pointer is over either the trigger or the card.
    func membersHoverCard(type: String, id: String) -> some View {
        modifier(MembersHoverCard(type: type, id: id))
    }
}

private struct MembersHoverCard: ViewModifier {
    let type: String
    let id: String
    @State private var shown = false
    @State private var overTrigger = false
    @State private var overCard = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        if type == "member" || type == "squad" {
            content
                .onHover { overTrigger = $0; schedule() }
                .popover(isPresented: $shown, arrowEdge: .bottom) {
                    Group {
                        if type == "member" { MembersProfileCard(userID: id) } else { SquadsProfileCard(squadID: id) }
                    }
                    .onHover { overCard = $0; schedule() }
                }
        } else {
            content
        }
    }

    private func schedule() {
        pending?.cancel()
        let want = overTrigger || overCard
        guard want != shown else { return }
        pending = Task {
            try? await Task.sleep(for: .milliseconds(want ? 500 : 250))
            guard !Task.isCancelled else { return }
            shown = overTrigger || overCard
        }
    }
}
