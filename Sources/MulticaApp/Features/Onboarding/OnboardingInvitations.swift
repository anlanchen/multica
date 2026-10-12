import MulticaCore
import SwiftUI

/// Batch invitation handling (upstream invitations/invitations-page.tsx).
/// As a gate (first contact, not onboarded) zero selected continues to
/// onboarding; as a sheet it simply closes. Unselected invitations stay
/// pending.
struct OnboardingInvitationsPage: View {
    enum Style { case gate, sheet }

    @Environment(AppEnvironment.self) private var env
    let style: Style
    let onSkip: () -> Void
    @State private var invitations: [Invitation]?
    @State private var selected: Set<String> = []
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Group {
                if let invitations {
                    if invitations.isEmpty { empty } else { list(invitations) }
                } else {
                    loading
                }
            }
            .frame(maxWidth: style == .gate ? 512 : .infinity)
            .padding(style == .gate ? 24 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if style == .gate {
                OnboardingLogoutButton().padding(24)
            }
        }
        .background(Theme.canvas)
        .task { await load() }
    }

    private func load() async {
        invitations = (try? await env.app.api.listMyInvitations()) ?? []
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 4).fill(Theme.hover).frame(width: 190, height: 22)
            RoundedRectangle(cornerRadius: 4).fill(Theme.hover).frame(width: 280, height: 14)
            RoundedRectangle(cornerRadius: 8).fill(Theme.hover).frame(height: 60)
            RoundedRectangle(cornerRadius: 8).fill(Theme.hover).frame(height: 60)
        }
        .padding(40)
        .modifier(OnboardingInviteCard())
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope")
                .font(.system(size: 20)).foregroundStyle(.secondary)
                .frame(width: 48, height: 48).background(Circle().fill(Color.primary.opacity(0.06)))
            Text(tr("invite", "batch.empty_title")).font(Theme.Font.title)
            Text(tr("invite", "batch.empty_hint")).font(Theme.Font.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(style == .gate ? tr("invite", "batch.empty_continue") : tr("common", "close"), action: onSkip)
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 48).padding(.horizontal, 32)
        .modifier(OnboardingInviteCard())
    }

    private func list(_ invitations: [Invitation]) -> some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "person.2")
                    .font(.system(size: 20)).foregroundStyle(Theme.brand)
                    .frame(width: 48, height: 48).background(Circle().fill(Theme.brand.opacity(0.1)))
                Text(tr("invite", "batch.title")).font(.system(size: 18, weight: .semibold))
                Text(tr("invite", "batch.subtitle")).font(Theme.Font.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(invitations) { inv in
                        OnboardingInvitationRow(invitation: inv, checked: selected.contains(inv.id)) {
                            if selected.contains(inv.id) { selected.remove(inv.id) } else { selected.insert(inv.id) }
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
            Button(action: submit) {
                Text(submitting ? tr("invite", "batch.joining")
                     : selected.isEmpty ? (style == .gate ? tr("invite", "batch.submit_skip") : tr("common", "close"))
                     : tr("invite", "batch.submit_join", ["count": selected.count]))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(submitting)
            if let error {
                Text(error).font(Theme.Font.body).foregroundStyle(Theme.destructive).multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 36).padding(.horizontal, 28)
        .modifier(OnboardingInviteCard())
    }

    private func submit() {
        error = nil
        guard !selected.isEmpty else {
            onSkip()
            return
        }
        submitting = true
        let api = env.app.api
        let order = (invitations ?? []).filter { selected.contains($0.id) }
        Task {
            var accepted: [Invitation] = []
            do {
                for inv in order {
                    _ = try await api.acceptInvitation(inv.id)
                    accepted.append(inv)
                }
                _ = try? await api.markOnboardingComplete(completionPath: OnboardingCompletionPath.inviteAccept.rawValue, workspaceId: accepted.first?.workspaceId)
                await env.reloadInvitations()
                await env.app.reloadWorkspaces()
                let target = accepted.first.flatMap { inv in env.app.workspaces.first { $0.id == inv.workspaceId } }
                submitting = false
                if style == .sheet { onSkip() }
                await OnboardingCompletion.land(env: env, workspace: target, destination: nil)
            } catch {
                let message = (error as? APIError)?.message ?? ""
                self.error = message.isEmpty ? tr("invite", "batch.error_generic") : message
                if !accepted.isEmpty { await env.app.reloadWorkspaces() }
                await env.reloadInvitations()
                await load()
                selected.subtract(accepted.map(\.id))
                submitting = false
            }
        }
    }
}

private struct OnboardingInvitationRow: View {
    let invitation: Invitation
    let checked: Bool
    let toggle: () -> Void

    var body: some View {
        let inviter = [invitation.inviterName, invitation.inviterEmail].compactMap { $0 }.first { !$0.isEmpty } ?? tr("invite", "batch.row_inviter_fallback")
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Theme.brand : .secondary)
                    .font(.system(size: 15))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(invitation.workspaceName ?? tr("invite", "batch.row_workspace_fallback")).font(Theme.Font.bodyMedium).lineLimit(1)
                    Text(invitation.role == "admin" ? tr("invite", "batch.row_invited_admin", ["inviter": inviter])
                         : tr("invite", "batch.row_invited_member", ["inviter": inviter]))
                        .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .hoverHighlight(cornerRadius: 8)
    }
}

struct OnboardingInviteCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }
}

/// One invitation from a `multica://invite/<id>` link (upstream
/// invite/invite-page.tsx).
struct OnboardingInvitePage: View {
    @Environment(AppEnvironment.self) private var env
    let invitationID: String
    let onBack: (() -> Void)?
    let onClose: () -> Void
    @State private var invitation: Invitation?
    @State private var loading = true
    @State private var accepting = false
    @State private var declining = false
    @State private var error: String?
    @State private var done: Done?

    private enum Done { case accepted, declined }

    var body: some View {
        VStack {
            Group {
                if loading {
                    VStack(spacing: 14) {
                        Circle().fill(Theme.hover).frame(width: 48, height: 48)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.hover).frame(width: 190, height: 18)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.hover).frame(width: 250, height: 14)
                    }
                    .padding(.vertical, 48)
                } else if let invitation {
                    switch done {
                    case .accepted: accepted(invitation)
                    case .declined: declined
                    case nil: main(invitation)
                    }
                } else {
                    notFound
                }
            }
            .modifier(OnboardingInviteCard())
            .frame(maxWidth: 448)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if let onBack {
                Button(action: onBack) { Label(tr("invite", "header.back"), systemImage: "arrow.left") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).padding(24)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { Task { await env.signOut() } } label: {
                Label(tr("invite", "header.log_out"), systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary).padding(24)
        }
        .background(Theme.canvas)
        .task(id: invitationID) {
            loading = true
            invitation = try? await env.app.api.getInvitation(invitationID)
            loading = false
        }
    }

    private var notFound: some View {
        VStack(spacing: 14) {
            Image(systemName: "xmark").font(.system(size: 18)).foregroundStyle(.secondary)
                .frame(width: 48, height: 48).background(Circle().fill(Color.primary.opacity(0.06)))
            Text(tr("invite", "not_found.title")).font(Theme.Font.title)
            Text(tr("invite", "not_found.description")).font(Theme.Font.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(tr("invite", "not_found.go_to_dashboard"), action: onClose)
        }
        .padding(.vertical, 48).padding(.horizontal, 28)
    }

    private func accepted(_ inv: Invitation) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark").font(.system(size: 18)).foregroundStyle(Theme.brand)
                .frame(width: 48, height: 48).background(Circle().fill(Theme.brand.opacity(0.1)))
            Text(tr("invite", "accepted.title", ["workspace_name": inv.workspaceName ?? ""])).font(Theme.Font.title).multilineTextAlignment(.center)
            Text(tr("invite", "accepted.redirecting")).font(Theme.Font.body).foregroundStyle(.secondary)
        }
        .padding(.vertical, 48).padding(.horizontal, 28)
    }

    private var declined: some View {
        VStack(spacing: 14) {
            Text(tr("invite", "declined.title")).font(Theme.Font.title)
            Text(tr("invite", "declined.description")).font(Theme.Font.body).foregroundStyle(.secondary)
            Button(tr("invite", "declined.go_to_dashboard"), action: onClose)
        }
        .padding(.vertical, 48).padding(.horizontal, 28)
    }

    private func main(_ inv: Invitation) -> some View {
        let handled = inv.status == "accepted" || inv.status == "declined"
        let expired = inv.status != "pending"
        let inviter = [inv.inviterName, inv.inviterEmail].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return VStack(spacing: 24) {
            Image(systemName: "person.2").font(.system(size: 22)).foregroundStyle(Theme.brand)
                .frame(width: 56, height: 56).background(Circle().fill(Theme.brand.opacity(0.1)))
            VStack(spacing: 8) {
                Text(tr("invite", "main.join_title", ["workspace_name": inv.workspaceName ?? tr("invite", "main.fallback_workspace_name")]))
                    .font(.system(size: 18, weight: .semibold)).multilineTextAlignment(.center)
                (Text(inviter).bold() + Text(" ") + Text(inv.role == "admin" ? tr("invite", "main.invited_role_admin") : tr("invite", "main.invited_role_member")))
                    .font(Theme.Font.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if handled {
                Text(inv.status == "accepted" ? tr("invite", "main.already_handled_accepted") : tr("invite", "main.already_handled_declined"))
                    .font(Theme.Font.body).foregroundStyle(.secondary)
            } else if expired {
                Text(tr("invite", "main.expired")).font(Theme.Font.body).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Button(action: decline) {
                        Text(declining ? tr("invite", "main.declining") : tr("invite", "main.decline")).frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    Button(action: accept) {
                        Text(accepting ? tr("invite", "main.joining") : tr("invite", "main.accept")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .disabled(accepting || declining)
            }
            if let error {
                Text(error).font(Theme.Font.body).foregroundStyle(Theme.destructive).multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 48).padding(.horizontal, 28)
    }

    private func accept() {
        guard let inv = invitation else { return }
        accepting = true
        error = nil
        let api = env.app.api
        Task {
            defer { accepting = false }
            do {
                _ = try await api.acceptInvitation(inv.id)
                _ = try? await api.markOnboardingComplete(completionPath: OnboardingCompletionPath.inviteAccept.rawValue, workspaceId: inv.workspaceId)
                done = .accepted
                await env.reloadInvitations()
                await env.app.reloadWorkspaces()
                try? await Task.sleep(for: .seconds(1))
                let joined = env.app.workspaces.first { $0.id == inv.workspaceId }
                onClose()
                await OnboardingCompletion.land(env: env, workspace: joined, destination: nil)
            } catch {
                let message = (error as? APIError)?.message ?? ""
                self.error = message.isEmpty ? tr("invite", "errors.accept_failed") : message
            }
        }
    }

    private func decline() {
        guard let inv = invitation else { return }
        declining = true
        error = nil
        Task {
            defer { declining = false }
            do {
                try await env.app.api.declineInvitation(inv.id)
                done = .declined
                await env.reloadInvitations()
            } catch {
                let message = (error as? APIError)?.message ?? ""
                self.error = message.isEmpty ? tr("invite", "errors.decline_failed") : message
            }
        }
    }
}

/// A workspace link this account cannot open. Deliberately doesn't say
/// whether the workspace exists (upstream workspace/no-access-page.tsx).
struct OnboardingNoAccessPage: View {
    @Environment(AppEnvironment.self) private var env
    let onRecover: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text(tr("workspace", "no_access.title")).font(.system(size: 22, weight: .semibold))
                Text(tr("workspace", "no_access.description")).font(Theme.Font.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            HStack(spacing: 8) {
                Button(tr("workspace", "no_access.go_to_workspaces"), action: onRecover)
                    .buttonStyle(.borderedProminent)
                Button(tr("workspace", "no_access.sign_in_different")) { Task { await env.signOut() } }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}
