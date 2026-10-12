import MulticaCore
import SwiftUI

/// Everything this area layers over the signed-in workspace shell:
/// the onboarding gate for an un-onboarded account (upstream renders the
/// flow as a window overlay above the tabs), the welcome after a
/// runtime-skipped onboarding, the source-attribution prompt, and the
/// invitation / no-access deep-link screens.
struct OnboardingShellOverlays: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @Environment(WorkspaceSession.self) private var session
    @State private var gate: OnboardingGate?
    @State private var me: UserRecord?
    private let links = OnboardingLinkRouter.shared
    private let welcome = OnboardingWelcomeStore.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if let gate {
                    Group {
                        switch gate {
                        case .invitations:
                            OnboardingInvitationsPage(style: .gate) { self.gate = .steps(.firstRun) }
                        case .steps(let mode):
                            OnboardingSteps(mode: mode, onCancel: nil, onFinished: { self.gate = nil })
                        }
                    }
                    .background(Theme.canvas)
                    .transition(.opacity)
                }
            }
            .overlay {
                if let id = links.invitationID {
                    OnboardingInvitePage(invitationID: id, onBack: { links.invitationID = nil }) { links.invitationID = nil }
                }
            }
            .overlay {
                if links.noAccessSlug != nil {
                    OnboardingNoAccessPage { links.noAccessSlug = nil }
                }
            }
            .overlay {
                if gate == nil, let ws = welcome.signalWorkspaceID, !welcome.dismissed, ws == session.workspace.id {
                    OnboardingSkipWelcome(workspaceID: ws)
                }
            }
            .modifier(OnboardingSourcePrompt(user: gate == nil ? me : nil))
            .task(id: session.workspace.id) {
                let user = try? await env.app.api.getMe()
                gate = await OnboardingGate.resolve(env: env, user: user, hasWorkspaces: true)
                me = user
            }
    }
}

// MARK: Welcome after a runtime-skipped onboarding

/// Seeds one install-runtime guide issue, then shows what was added
/// (upstream workspace/welcome-after-onboarding.tsx).
private struct OnboardingSkipWelcome: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let workspaceID: String
    @State private var issueID: String?
    @State private var failed = false
    @State private var attempt = 0

    @MainActor private static var pending: [String: Task<Issue, Error>] = [:]

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            if failed {
                errorDialog
            } else if issueID != nil {
                doneDialog
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(tr("onboarding", "welcome_after_onboarding.skip.loading")).font(Theme.Font.body).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial)
            }
        }
        .task(id: attempt) { await seed() }
    }

    private func seed() async {
        guard issueID == nil else { return }
        let key = "\(workspaceID):install-runtime"
        let lang = OnboardingTemplates.contentLanguage(L10n.shared.language)
        let request = CreateIssueRequest(
            title: OnboardingTemplates.installRuntimeIssueTitle[lang] ?? "",
            description: OnboardingTemplates.installRuntimeIssueBody[lang],
            status: .inProgress, priority: .high,
            assignee: ActorRef(type: "member", id: session.currentUser.id)
        )
        let task = Self.pending[key] ?? Task { try await session.createIssue(request) }
        Self.pending[key] = task
        do {
            let issue = try await task.value
            Self.pending[key] = nil
            issueID = issue.id
        } catch {
            Self.pending[key] = nil
            failed = true
        }
    }

    private var errorDialog: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("onboarding", "welcome_after_onboarding.skip.error_title")).font(Theme.Font.title)
            Text(tr("onboarding", "welcome_after_onboarding.skip.error_body")).font(Theme.Font.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("onboarding", "welcome_after_onboarding.skip.dismiss")) { OnboardingWelcomeStore.shared.dismiss() }
                Button(tr("onboarding", "welcome_after_onboarding.skip.retry")) {
                    failed = false
                    attempt += 1
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .frame(width: 440)
        .modifier(OnboardingDialogChrome())
    }

    private var doneDialog: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Text("🎉").font(.system(size: 56))
                Text(tr("onboarding", "welcome_after_onboarding.skip.title")).font(.system(size: 22, weight: .semibold))
                Text(tr("onboarding", "welcome_after_onboarding.skip.subtitle"))
                    .font(Theme.Font.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            .padding(.top, 12)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(tr("onboarding", "welcome_after_onboarding.skip.cards.install_runtime.title")).font(Theme.Font.bodyMedium)
                    Text(tr("onboarding", "welcome_after_onboarding.skip.status_in_progress"))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.brand)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.brand.opacity(0.1)))
                }
                Text(tr("onboarding", "welcome_after_onboarding.skip.cards.install_runtime.subtitle"))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .padding(.top, 24)
            HStack {
                Spacer()
                Button(tr("onboarding", "welcome_after_onboarding.skip.got_it")) {
                    OnboardingWelcomeStore.shared.dismiss()
                    if let issueID { nav.push(.issue(issueID)) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
        }
        .padding(28)
        .frame(width: 560)
        .modifier(OnboardingDialogChrome())
        .onExitCommand { OnboardingWelcomeStore.shared.dismiss() }
    }
}

struct OnboardingDialogChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
    }
}

// MARK: Source backfill

/// "How did you hear about Multica?" for onboarded users who never said,
/// asked only after agents finished real work here (upstream
/// onboarding/source-backfill-modal.tsx). Closing without answering counts
/// toward a dismissal cap.
private struct OnboardingSourcePrompt: ViewModifier {
    @Environment(WorkspaceSession.self) private var session
    let user: UserRecord?
    @State private var open = false
    @State private var stored: [String: JSONValue]?
    @State private var completed = false

    static func dismissKey(_ userID: String) -> String { "multica.source_backfill.dismiss.\(userID)" }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { open }, set: { newValue in
                if !newValue && open && !completed {
                    let key = Self.dismissKey(session.currentUser.id)
                    UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
                }
                open = newValue
            })) {
                OnboardingSourceBackfillDialog(stored: stored) {
                    completed = true
                    open = false
                }
            }
            .task(id: user.map { "\($0.id)|\(session.workspace.id)" }) {
                guard let user else { return }
                await evaluate(user)
            }
    }

    private func evaluate(_ me: UserRecord) async {
        let api = session.api
        let dismissals = UserDefaults.standard.integer(forKey: Self.dismissKey(me.id))
        guard OnboardingSourceBackfill.needed(onboardedAt: me.onboardedAt, questionnaire: me.onboardingQuestionnaire, dismissCount: dismissals) else { return }
        var params = ListIssuesParams()
        params.workspaceId = session.workspace.id
        params.statuses = ["done"]
        params.assigneeTypes = ["agent", "squad"]
        params.limit = 1
        guard let done = try? await api.listIssues(params: params), done.total >= OnboardingSourceBackfill.minAgentDoneIssues else { return }
        stored = me.onboardingQuestionnaire
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled else { return }
        open = true
    }
}

private struct OnboardingSourceBackfillDialog: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster
    let stored: [String: JSONValue]?
    let onComplete: () -> Void
    @State private var picked: String?
    @State private var other = ""
    @State private var busy = false

    static let options: [(slug: String, icon: String, key: String)] = [
        ("friends_colleagues", "person.3", "friends_colleagues"), ("search", "magnifyingglass", "search"),
        ("social_x", "xmark", "social_x"), ("social_linkedin", "link", "social_linkedin"),
        ("social_youtube", "play.rectangle", "social_youtube"), ("social_github", "chevron.left.forwardslash.chevron.right", "social_github"),
        ("social_other", "globe", "social_misc"), ("blog_newsletter", "newspaper", "blog_newsletter"),
        ("ai_assistant", "sparkles", "ai_assistant"), ("from_work", "briefcase", "from_work"),
        ("event_conference", "calendar", "event_conference"), ("dont_remember", "questionmark.circle", "dont_remember"),
        ("other", "ellipsis", "other"),
    ]

    private var canSubmit: Bool {
        guard !busy, let picked else { return false }
        return picked != "other" || !other.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("onboarding", "source_backfill.eyebrow").uppercased())
                    .font(.system(size: 10, weight: .medium)).tracking(0.8).foregroundStyle(.secondary)
                Text(tr("onboarding", "questions.source.question")).font(.system(size: 22, weight: .medium, design: .serif))
                Text(tr("onboarding", "source_backfill.lede")).font(Theme.Font.body).foregroundStyle(.secondary).padding(.top, 4)
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 8)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Self.options, id: \.slug) { o in
                    OnboardingOptionChip(
                        icon: o.icon,
                        label: tr("onboarding", "questions.source.\(o.key)"),
                        selected: picked == o.slug,
                        otherText: o.slug == "other" ? $other : nil,
                        placeholder: tr("onboarding", "questions.source.other_placeholder"),
                        onConfirm: submit
                    ) {
                        if o.slug != "other" || picked != "other" { other = picked == "other" ? other : "" }
                        picked = o.slug
                        if o.slug != "other" { other = "" }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 24).padding(.top, 16)
            HStack(spacing: 8) {
                Text(tr("onboarding", "step_question.hint_pick")).font(Theme.Font.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("onboarding", "common.skip"), action: skip).disabled(busy)
                Button(tr("onboarding", "source_backfill.submit"), action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(Color.primary.opacity(0.03))
            .overlay(alignment: .top) { Divider() }
            .padding(.top, 16)
        }
        .frame(width: 640)
    }

    private func save(source: [String], other: String?, skipped: Bool) {
        busy = true
        let patch = OnboardingQuestionnaire.sourcePatch(stored: stored, source: source, sourceOther: other, sourceSkipped: skipped)
        Task {
            do {
                _ = try await env.app.api.patchOnboarding(questionnaire: patch.json)
                onComplete()
            } catch {
                busy = false
                let message = (error as? APIError)?.message ?? ""
                toaster.error(message.isEmpty ? tr("onboarding", "source_backfill.save_failed_toast") : message)
            }
        }
    }

    private func submit() {
        guard canSubmit, let picked else { return }
        save(source: [picked], other: picked == "other" ? other.trimmingCharacters(in: .whitespaces) : nil, skipped: false)
    }

    private func skip() {
        guard !busy else { return }
        save(source: [], other: nil, skipped: true)
    }
}
