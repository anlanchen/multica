import MulticaCore
import SwiftUI

private enum SettingsMembersView: String { case members, invitations, links }

private struct SettingsSeatPurchaseFlow {
    enum Phase { case review, purchasing, waiting, inviting, error }
    var workspaceID: String
    var email: String
    var role: String
    var preview: WorkspaceSeatPurchasePreview
    var idempotencyKey: String
    var phase: Phase = .review
    var submittedAt: Date?
    var error: String?
    var retryable = false
}

private struct SettingsConfirm: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var run: () async -> Void
}

/// Settings › Members (upstream members-tab.tsx): members with roles,
/// pending invitations and share links, invite (with the seat-purchase
/// hand-off when billing is on), and the destructive confirmations.
struct SettingsMembersTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    @State private var invitations: [Invitation] = []
    @State private var shareLinks: [MulticaCore.ShareLink] = []
    @State private var seats: WorkspaceSeatCapacity?
    @State private var memberQuery = ""
    @State private var visibleMembers: [MemberWithUserRecord] = []
    @State private var inviteOpen = false
    @State private var shareLinkOpen = false
    @State private var memberAction: String?
    @State private var invitationAction: String?
    @State private var shareLinkAction: String?
    @State private var confirm: SettingsConfirm?
    @State private var purchase: SettingsSeatPurchaseFlow?

    private var billingEnabled: Bool { env.settingsFeatureEnabled("billing_workspace_subscriptions") }

    var body: some View {
        let ws = env.settingsWorkspace(session)
        let members = session.memberRecords.items
        let me = members.first { $0.userId == session.currentUser.id }
        let canManage = me?.role == "owner" || me?.role == "admin"
        let isOwner = me?.role == "owner"
        let ownerCount = members.filter { $0.role == "owner" }.count
        let requested = SettingsMembersView(rawValue: SettingsLocation.resolve(nav.location.query).section ?? "") ?? .members
        let view: SettingsMembersView = requested == .links && !canManage ? .members : requested
        SettingsTabView(title: tr("settings", "page.tabs.members"), scope: .workspace, actions: {
            if canManage {
                Button { inviteOpen = true } label: { Label(tr("settings", "members.invite_title"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
        }) {
            if me != nil && !canManage { SettingsReadOnlyNotice() }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    SettingsViewTabs(items: viewItems(canManage: canManage, memberCount: members.count),
                                     selection: Binding(get: { view }, set: { setView($0) }))
                    Spacer(minLength: 8)
                    if billingEnabled, let seats {
                        HStack(spacing: 4) {
                            Text(tr("settings", "members.seats_used", ["used": Int(seats.used + seats.reserved), "purchased": Int(seats.purchased)]))
                            Text("·")
                            Button(tr("settings", "members.manage_seats")) {
                                nav.push(.settings, query: SettingsLocation.query(from: nav.location.query, tab: "billing"))
                            }
                            .buttonStyle(.link)
                        }
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                    }
                    switch view {
                    case .members:
                        SearchField(text: $memberQuery, prompt: tr("settings", "members.search_placeholder")).frame(width: 224)
                    case .links:
                        Button { shareLinkOpen = true } label: { Label(tr("settings", "members.share_links_create_title"), systemImage: "plus") }
                            .controlSize(.small)
                    case .invitations:
                        EmptyView()
                    }
                }
                switch view {
                case .members:
                    if visibleMembers.isEmpty {
                        SettingsEmptyList(text: memberQuery.trimmingCharacters(in: .whitespaces).isEmpty
                                          ? tr("settings", "members.no_members") : tr("settings", "members.no_results"))
                    } else {
                        SettingsCardView {
                            ForEach(visibleMembers) { m in
                                SettingsMemberRow(member: m, canManage: canManage, canManageOwners: isOwner, ownerCount: ownerCount,
                                                  isSelf: m.userId == session.currentUser.id, busy: memberAction == m.id,
                                                  onRoleChange: { changeRole(m, to: $0) }, onRemove: { askRemove(m, workspace: ws.name) })
                            }
                        }
                    }
                case .invitations:
                    if invitations.isEmpty {
                        SettingsEmptyList(text: tr("settings", "members.no_invitations"))
                    } else {
                        SettingsCardView {
                            ForEach(invitations) { inv in
                                SettingsInvitationRow(invitation: inv, canManage: canManage, busy: invitationAction == inv.id) { askRevoke(inv) }
                            }
                        }
                    }
                case .links:
                    if shareLinks.isEmpty {
                        SettingsEmptyList(text: tr("settings", "members.no_share_links"))
                    } else {
                        SettingsCardView {
                            ForEach(shareLinks) { link in
                                SettingsShareLinkRow(link: link, joinURL: joinURL(link), busy: shareLinkAction == link.id,
                                                     onCopy: { copy(link) }, onRevoke: { revoke(link) })
                            }
                        }
                    }
                }
            }
        }
        .task { await session.memberRecords.loadIfNeeded() }
        .task(id: session.revision("invitation")) { await loadInvitations() }
        .task(id: canManage) {
            guard canManage else { return }
            await loadShareLinks()
            await loadSeats()
        }
        .onChange(of: members, initial: true) { filterMembers() }
        .onChange(of: memberQuery) { filterMembers() }
        .task(id: purchase?.phase == .waiting) { await waitForSeat() }
        .sheet(isPresented: $inviteOpen) {
            SettingsInviteSheet(onCancel: { inviteOpen = false }, onInvite: invite)
        }
        .sheet(isPresented: $shareLinkOpen) {
            SettingsShareLinkSheet(onCancel: { shareLinkOpen = false }, onCreate: createShareLink)
        }
        .sheet(isPresented: Binding(get: { purchase != nil }, set: { if !$0, purchase?.phase == .review || purchase?.phase == .error { purchase = nil } })) {
            if let purchase {
                SettingsSeatPurchaseSheet(flow: purchase, onCancel: { self.purchase = nil }, onConfirm: purchaseSeatAndInvite)
                    .interactiveDismissDisabled(purchase.phase != .review && purchase.phase != .error)
            }
        }
        .alert(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { c in
            Button(tr("settings", "members.confirm_cancel"), role: .cancel) {}
            Button(tr("settings", "members.confirm_action"), role: .destructive) { Task { await c.run() } }
        } message: { c in
            Text(c.message)
        }
    }

    private func viewItems(canManage: Bool, memberCount: Int) -> [(value: SettingsMembersView, label: String, count: Int?)] {
        var items: [(value: SettingsMembersView, label: String, count: Int?)] = [
            (.members, tr("settings", "members.members_label"), memberCount),
            (.invitations, tr("settings", "members.pending_label"), invitations.count),
        ]
        if canManage { items.append((.links, tr("settings", "members.share_links_label"), shareLinks.count)) }
        return items
    }

    private func setView(_ v: SettingsMembersView) {
        nav.replace(.settings, query: SettingsLocation.query(from: nav.location.query, tab: "members", section: v == .members ? nil : v.rawValue))
    }

    private func filterMembers() {
        visibleMembers = SettingsRules.filterMembers(session.memberRecords.items, query: memberQuery)
    }

    private func joinURL(_ link: MulticaCore.ShareLink) -> String {
        var base = env.app.config.appURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return "\(base)/join?code=\(link.code)"
    }

    // MARK: Loading

    private func loadInvitations() async {
        if let list = try? await session.api.listWorkspaceInvitations(workspaceId: session.workspace.id) { invitations = list }
    }

    private func loadShareLinks() async {
        if let list = try? await session.api.listShareLinks(workspaceId: session.workspace.id) { shareLinks = list }
    }

    private func loadSeats() async {
        guard billingEnabled else { return }
        seats = (try? await session.api.getWorkspaceSubscriptionSummary())?.seatCapacity
    }

    // MARK: Members

    private func changeRole(_ m: MemberWithUserRecord, to role: String) {
        memberAction = m.id
        Task {
            defer { memberAction = nil }
            do {
                _ = try await session.api.updateMember(workspaceId: session.workspace.id, memberId: m.id, UpdateMemberRequest(role: role))
                await session.memberRecords.load()
                toaster.success(tr("settings", "members.toast_role_updated"))
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("settings", "members.toast_role_failed"), kind: .error)
            }
        }
    }

    private func askRemove(_ m: MemberWithUserRecord, workspace: String) {
        confirm = SettingsConfirm(title: tr("settings", "members.remove_member_title", ["name": m.name]),
                                  message: tr("settings", "members.remove_member_description", ["name": m.name, "workspace": workspace])) {
            memberAction = m.id
            defer { memberAction = nil }
            do {
                try await session.api.deleteMember(workspaceId: session.workspace.id, memberId: m.id)
                await session.memberRecords.load()
                toaster.success(tr("settings", "members.toast_member_removed"))
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("settings", "members.toast_member_remove_failed"), kind: .error)
            }
        }
    }

    // MARK: Invitations

    private func askRevoke(_ inv: Invitation) {
        confirm = SettingsConfirm(title: tr("settings", "members.revoke_invitation_title"),
                                  message: tr("settings", "members.revoke_invitation_description", ["email": inv.inviteeEmail])) {
            invitationAction = inv.id
            defer { invitationAction = nil }
            do {
                try await session.api.revokeInvitation(workspaceId: session.workspace.id, invitationId: inv.id)
                await loadInvitations()
                toaster.success(tr("settings", "members.toast_invitation_revoked"))
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("settings", "members.toast_invitation_revoke_failed"), kind: .error)
            }
        }
    }

    private func sendInvitation(email: String, role: String) async throws {
        try await session.api.settingsInviteMember(workspaceId: session.workspace.id, email: email, role: role)
        await loadInvitations()
        toaster.success(tr("settings", "members.toast_invitation_sent"))
    }

    /// Returns true when the dialog should close.
    private func invite(email: String, role: String) async -> Bool {
        do {
            try await sendInvitation(email: email, role: role)
            return true
        } catch let e as SettingsAPIError {
            if e.code == "seat_capacity_overcommitted" {
                let title = tr("billing", "workspace.seats.members_over_capacity_title")
                if let c = (try? await session.api.getWorkspaceSubscriptionSummary())?.seatCapacity {
                    seats = c
                    toaster.show("\(title). " + tr("billing", "workspace.seats.occupancy_over_capacity_description", [
                        "occupied": Int(c.used + c.reserved), "purchased": Int(c.purchased), "members": Int(c.used), "reserved": Int(c.reserved),
                    ]), kind: .error)
                } else {
                    toaster.error(title)
                }
                return false
            }
            switch SettingsSeatPurchase.capacityFailure(e.code) {
            case .full:
                do {
                    let preview = try await session.api.settingsPreviewSeatPurchase(additionalSeats: 1)
                    guard let preview, SettingsSeatPurchase.isSingleSeatPreview(preview) else {
                        toaster.error(tr("billing", "workspace.seat_purchase.preview_unreadable"))
                        return false
                    }
                    let key = "invite-seat-\(session.workspace.id)-\(UUID().uuidString.lowercased())"
                    purchase = SettingsSeatPurchaseFlow(workspaceID: session.workspace.id, email: email, role: role, preview: preview,
                                                        idempotencyKey: String(key.prefix(200)))
                    return true
                } catch {
                    toaster.error((error as? SettingsAPIError)?.code == "seat_purchase_in_progress"
                                  ? tr("billing", "workspace.seat_purchase.in_progress") : tr("billing", "workspace.seat_purchase.preview_failed"))
                    return false
                }
            case .unavailable:
                toaster.error(tr("settings", "members.toast_seat_capacity_unavailable"))
            case .rateLimited:
                toaster.error(tr("settings", "members.toast_seat_capacity_rate_limited"))
            case nil:
                toaster.error(e.message)
            }
            return false
        } catch {
            toaster.show((error as? APIError)?.message ?? tr("settings", "members.toast_invitation_failed"), kind: .error)
            return false
        }
    }

    private func purchaseSeatAndInvite() {
        guard var flow = purchase, flow.phase == .review || (flow.phase == .error && flow.retryable) else { return }
        guard flow.workspaceID == session.workspace.id else {
            purchase = nil
            return
        }
        flow.phase = .purchasing
        flow.error = nil
        flow.retryable = false
        purchase = flow
        Task {
            do {
                let response = try await session.api.settingsPurchaseSeats(flow.preview, idempotencyKey: flow.idempotencyKey)
                guard SettingsSeatPurchase.purchaseMatchesPreview(response, flow.preview) else {
                    flow.phase = .error
                    flow.error = tr("billing", "workspace.seat_purchase.purchase_unreadable")
                    flow.retryable = true
                    purchase = flow
                    return
                }
                flow.phase = .waiting
                flow.submittedAt = Date()
                purchase = flow
            } catch {
                let code = (error as? SettingsAPIError)?.code
                flow.phase = .error
                switch code {
                case "seat_purchase_payment_failed": flow.error = tr("billing", "workspace.seat_purchase.payment_failed")
                case "seat_purchase_in_progress": flow.error = tr("billing", "workspace.seat_purchase.in_progress")
                case "seat_quote_changed", "seat_capacity_changed": flow.error = tr("billing", "workspace.seat_purchase.quote_changed")
                default: flow.error = tr("billing", "workspace.seat_purchase.purchase_failed")
                }
                flow.retryable = SettingsSeatPurchase.canRetryWithSameQuote(code)
                purchase = flow
            }
        }
    }

    /// Polls the subscription every 2 s until Stripe confirms the seat, then
    /// sends the invitation; gives up after two minutes.
    private func waitForSeat() async {
        guard var flow = purchase, flow.phase == .waiting, let submittedAt = flow.submittedAt else { return }
        while !Task.isCancelled {
            if Date().timeIntervalSince(submittedAt) >= 120 {
                flow.phase = .error
                flow.error = tr("settings", "members.seat_purchase_timeout")
                flow.retryable = false
                purchase = flow
                return
            }
            let summary = try? await session.api.getWorkspaceSubscriptionSummary()
            let fetchedAt = Date()
            if let capacity = summary?.seatCapacity { seats = capacity }
            if SettingsSeatPurchase.seatIsReadyForInvitation(summary, preview: flow.preview, submittedAt: submittedAt, summaryFetchedAt: fetchedAt) {
                flow.phase = .inviting
                purchase = flow
                do {
                    try await sendInvitation(email: flow.email, role: flow.role)
                    purchase = nil
                } catch {
                    let code = (error as? SettingsAPIError)?.code
                    switch SettingsSeatPurchase.capacityFailure(code) {
                    case .full: flow.error = tr("settings", "members.seat_purchase_capacity_taken")
                    case .unavailable: flow.error = tr("settings", "members.toast_seat_capacity_unavailable")
                    case .rateLimited: flow.error = tr("settings", "members.toast_seat_capacity_rate_limited")
                    case nil: flow.error = (error as? SettingsAPIError)?.message ?? tr("settings", "members.toast_invitation_failed")
                    }
                    flow.phase = .error
                    flow.retryable = SettingsSeatPurchase.canRetryInvitationAfterPurchase(code)
                    purchase = flow
                }
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: Share links

    private func createShareLink(role: String, expiresIn: Int?) async -> Bool {
        do {
            _ = try await session.api.createShareLink(workspaceId: session.workspace.id, role: role, expiresIn: expiresIn)
            await loadShareLinks()
            toaster.success(tr("settings", "members.toast_share_link_created"))
            return true
        } catch {
            toaster.show((error as? APIError)?.message ?? tr("settings", "members.toast_share_link_failed"), kind: .error)
            return false
        }
    }

    private func revoke(_ link: MulticaCore.ShareLink) {
        shareLinkAction = link.id
        Task {
            defer { shareLinkAction = nil }
            do {
                try await session.api.revokeShareLink(workspaceId: session.workspace.id, linkId: link.id)
                await loadShareLinks()
                toaster.success(tr("settings", "members.toast_share_link_revoked"))
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("settings", "members.toast_share_link_revoke_failed"), kind: .error)
            }
        }
    }

    private func copy(_ link: MulticaCore.ShareLink) {
        SettingsClipboard.copy(joinURL(link))
        toaster.success(tr("settings", "members.toast_share_link_copied"))
    }
}

enum SettingsRoles {
    static func icon(_ role: String) -> String {
        switch role {
        case "owner": return "crown"
        case "admin": return "shield"
        default: return "person"
        }
    }

    static func label(_ role: String) -> String {
        ["owner", "admin", "member"].contains(role) ? tr("settings", "members.roles.\(role).label") : role
    }

    static func description(_ role: String) -> String {
        tr("settings", "members.roles.\(role).description")
    }
}

private struct SettingsMemberRow: View {
    let member: MemberWithUserRecord
    let canManage: Bool
    let canManageOwners: Bool
    let ownerCount: Int
    let isSelf: Bool
    let busy: Bool
    let onRoleChange: (String) -> Void
    let onRemove: () -> Void

    var body: some View {
        let editable = canManage && !isSelf && (member.role != "owner" || canManageOwners)
        let lastOwner = member.role == "owner" && ownerCount <= 1
        HStack(spacing: 12) {
            AvatarView(name: member.name, url: member.avatarUrl, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(member.name).font(Theme.Font.bodyMedium).lineLimit(1)
                    if isSelf { Badge(text: tr("settings", "members.you")) }
                }
                Text(member.email).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(tr("settings", "members.joined", ["date": SettingsDates.short(member.createdAt)]))
                .font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 128, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: SettingsRoles.icon(member.role)).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(SettingsRoles.label(member.role)).font(Theme.Font.body)
            }
            .frame(width: 96, alignment: .leading)
            Group {
                if editable {
                    Menu {
                        Menu {
                            ForEach(["owner", "admin", "member"], id: \.self) { role in
                                if role != "owner" || canManageOwners {
                                    let blocked = lastOwner && role != "owner"
                                    Button {
                                        onRoleChange(role)
                                    } label: {
                                        Label(SettingsRoles.label(role) + (member.role == role ? "  ✓" : ""), systemImage: SettingsRoles.icon(role))
                                        Text(blocked ? tr("settings", "members.cannot_demote_last_owner") : SettingsRoles.description(role))
                                    }
                                    .disabled(blocked)
                                    .help(blocked ? tr("settings", "members.cannot_demote_last_owner_title") : "")
                                }
                            }
                        } label: {
                            Label(tr("settings", "members.change_role"), systemImage: "shield")
                        }
                        Divider()
                        Button(role: .destructive, action: onRemove) {
                            Label(tr("settings", "members.remove_action"), systemImage: "person.badge.minus")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .disabled(busy)
                    .accessibilityLabel(tr("settings", "members.member_actions", ["name": member.name]))
                }
            }
            .frame(width: 28)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct SettingsInvitationRow: View {
    let invitation: Invitation
    let canManage: Bool
    let busy: Bool
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope").foregroundStyle(.secondary)
                .frame(width: 32, height: 32).background(Circle().fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 1) {
                Text(invitation.inviteeEmail).font(Theme.Font.bodyMedium).lineLimit(1)
                Text(tr("settings", "members.invitation_meta", ["sent": SettingsDates.short(invitation.createdAt), "expires": SettingsDates.short(invitation.expiresAt)]))
                    .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SettingsRoles.label(invitation.role)).font(Theme.Font.body).frame(width: 96, alignment: .leading)
            Group {
                if canManage {
                    Button(action: onRevoke) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                        .accessibilityLabel(tr("settings", "members.revoke_invitation_aria", ["email": invitation.inviteeEmail]))
                }
            }
            .frame(width: 28)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct SettingsShareLinkRow: View {
    let link: MulticaCore.ShareLink
    let joinURL: String
    let busy: Bool
    let onCopy: () -> Void
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link").foregroundStyle(.secondary)
                .frame(width: 32, height: 32).background(Circle().fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(tr("settings", "members.share_link_uses", ["used": link.useCount, "max": link.maxUses.map(String.init) ?? "∞"]))
                    if let expires = link.expiresAt {
                        Text("· " + tr("settings", "members.share_link_expires", ["date": SettingsDates.short(expires)]))
                    }
                }
                .font(Theme.Font.bodyMedium)
                Text(joinURL).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(joinURL)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SettingsRoles.label(link.role)).font(Theme.Font.body).frame(width: 96, alignment: .leading)
            Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help(tr("settings", "members.share_link_copy_tooltip"))
            Button(action: onRevoke) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(busy)
                .help(tr("settings", "members.share_link_revoke_tooltip"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct SettingsRolePicker: View {
    @Binding var role: String
    var showDescriptions = true

    var body: some View {
        Picker("", selection: $role) {
            ForEach(["member", "admin"], id: \.self) { r in
                if showDescriptions {
                    Text("\(SettingsRoles.label(r)) — \(SettingsRoles.description(r))").tag(r)
                } else {
                    Text(SettingsRoles.label(r)).tag(r)
                }
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}

private struct SettingsInviteSheet: View {
    let onCancel: () -> Void
    let onInvite: (String, String) async -> Bool
    @State private var email = ""
    @State private var role = "member"
    @State private var loading = false
    @FocusState private var focused: Bool

    var body: some View {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        SettingsDialog(title: tr("settings", "members.invite_title")) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "members.email_label"))
                    TextField(tr("settings", "members.invite_email_placeholder"), text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit(submit)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "members.role_label"))
                    SettingsRolePicker(role: $role)
                }
            }
        } footer: {
            Button(tr("settings", "members.confirm_cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(loading)
            Button(loading ? tr("settings", "members.inviting") : tr("settings", "members.invite_button"), action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(loading || trimmed.isEmpty)
        }
        .interactiveDismissDisabled(loading)
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !loading else { return }
        loading = true
        Task {
            let close = await onInvite(trimmed, role)
            loading = false
            if close { onCancel() }
        }
    }
}

private struct SettingsShareLinkSheet: View {
    let onCancel: () -> Void
    let onCreate: (String, Int?) async -> Bool
    @State private var role = "member"
    @State private var expiry = "168"
    @State private var loading = false

    private static let expiries: [(value: String, key: String)] = [("24", "expiry_24h"), ("168", "expiry_7d"), ("720", "expiry_30d"), ("0", "expiry_never")]

    var body: some View {
        SettingsDialog(title: tr("settings", "members.share_links_create_title"), description: tr("settings", "members.share_links_description")) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "members.role_label"))
                    SettingsRolePicker(role: $role, showDescriptions: false)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "members.expiry_label"))
                    Picker("", selection: $expiry) {
                        ForEach(Self.expiries, id: \.value) { Text(tr("settings", "members.\($0.key)")).tag($0.value) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }
        } footer: {
            Button(tr("settings", "members.confirm_cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(loading)
            Button(loading ? tr("settings", "members.share_links_creating") : tr("settings", "members.share_links_create_button")) {
                loading = true
                Task {
                    let hours = Int(expiry) ?? 0
                    let close = await onCreate(role, hours > 0 ? hours : nil)
                    loading = false
                    if close { onCancel() }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(loading)
        }
        .interactiveDismissDisabled(loading)
    }
}

/// "Add a seat to send this invitation?" — the Stripe estimate, then the
/// purchase, the wait for confirmation, and the invitation.
private struct SettingsSeatPurchaseSheet: View {
    let flow: SettingsSeatPurchaseFlow
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        let message: String = switch flow.phase {
        case .review: tr("settings", "members.seat_purchase_description", ["email": flow.email])
        case .error: flow.error ?? ""
        default: tr("settings", "members.seat_purchase_waiting")
        }
        SettingsDialog(title: tr("settings", "members.seat_purchase_title"), description: message) {
            if flow.phase == .review {
                VStack(spacing: 0) {
                    line(tr("billing", "workspace.seat_purchase.seats_after"),
                         tr("billing", "workspace.seats.seat_count", ["count": Int(flow.preview.resultingSeats)]))
                    Divider()
                    line(tr("billing", "workspace.seat_purchase.charge_today"),
                         SettingsSeatPurchase.formatMinorAmount(flow.preview.prorationAmount, currency: flow.preview.currency) ?? "—")
                    Divider()
                    line(tr("billing", "workspace.seat_purchase.next_invoice"),
                         SettingsSeatPurchase.formatMinorAmount(flow.preview.nextInvoiceAmount, currency: flow.preview.currency) ?? "—")
                    Divider()
                    Text(tr("billing", "workspace.seat_purchase.tax_notice"))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            } else if flow.phase != .error {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(flow.phase == .inviting ? tr("settings", "members.inviting") : tr("settings", "members.seat_purchase_waiting"))
                        .font(Theme.Font.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            if flow.phase == .review || flow.phase == .error {
                Button(tr("settings", "members.confirm_cancel"), action: onCancel).keyboardShortcut(.cancelAction)
            }
            if flow.phase == .review {
                Button(tr("settings", "members.purchase_seat_and_invite"), action: onConfirm).keyboardShortcut(.defaultAction)
            }
            if flow.phase == .error && flow.retryable {
                Button(tr("settings", "members.retry_seat_purchase"), action: onConfirm).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(Theme.Font.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
