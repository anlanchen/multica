import MulticaCore
import SwiftUI

/// Signed in with no workspace (upstream desktop WindowOverlay routing):
/// not onboarded → pending invitations, else the onboarding steps;
/// onboarded → the create-workspace flow.
struct OnboardingFlow: View {
    @Environment(AppEnvironment.self) private var env
    @State private var gate: OnboardingGate?
    private let links = OnboardingLinkRouter.shared

    var body: some View {
        ZStack {
            switch gate {
            case nil:
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .invitations:
                OnboardingInvitationsPage(style: .gate) { gate = .steps(.firstRun) }
            case .steps(let mode):
                OnboardingSteps(mode: mode, onCancel: nil)
                    .id(mode == .firstRun ? "first" : "new")
            }
        }
        .overlay {
            if let id = links.invitationID {
                OnboardingInvitePage(invitationID: id, onBack: nil) { links.invitationID = nil }
            }
        }
        .overlay(alignment: .bottomTrailing) { ToastOverlay() }
        .background(Theme.canvas)
        .task {
            let user = try? await env.app.api.getMe()
            gate = await OnboardingGate.resolve(env: env, user: user, hasWorkspaces: false)
        }
    }
}

enum OnboardingGate: Equatable {
    case invitations
    case steps(OnboardingMode)

    /// Upstream's overlay decision. Nil means no gate (onboarded and in a
    /// workspace).
    @MainActor static func resolve(env: AppEnvironment, user: UserRecord?, hasWorkspaces: Bool) async -> OnboardingGate? {
        guard let user, user.onboardedAt == nil else { return hasWorkspaces ? nil : .steps(.newWorkspace) }
        let invites = (try? await env.app.api.listMyInvitations()) ?? []
        return invites.isEmpty ? .steps(.firstRun) : .invitations
    }
}

/// Deep links for this area: `multica://invite/<id>` and workspace links the
/// user cannot open.
@MainActor
@Observable
final class OnboardingLinkRouter {
    static let shared = OnboardingLinkRouter()
    var invitationID: String?
    var noAccessSlug: String?
}

/// The step flow, hosting welcome or the shell with the current step.
struct OnboardingSteps: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster
    let mode: OnboardingMode
    let onCancel: (() -> Void)?
    var onFinished: (() -> Void)?
    @State private var model: OnboardingFlowModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard model == nil else { return }
            let m = OnboardingFlowModel(mode: mode)
            m.env = env
            m.toaster = toaster
            m.onCancel = onCancel
            m.onFinished = onFinished
            model = m
        }
        .task {
            await model?.load()
        }
    }

    @ViewBuilder private func content(_ model: OnboardingFlowModel) -> some View {
        if model.step == .welcome {
            OnboardingWelcomeStep(
                onNext: { model.welcomeNext() },
                onSkip: model.canSkipWelcome ? { await model.skipWelcome() } : nil
            )
        } else {
            OnboardingStepShell(
                currentStep: model.step,
                onBack: back(model),
                backDisabled: model.stepBusy,
                onStepChange: model.isNewWorkspace ? nil : { model.go($0) }
            ) {
                switch model.step {
                case .aboutYou:
                    OnboardingAboutYouStep(answers: model.answers, onChange: { model.applyAnswers($0) }) {
                        model.advance(from: .aboutYou)
                    }
                case .workspace:
                    OnboardingWorkspaceStep(existing: model.existingWorkspace, onCreated: { model.workspaceCreated($0) }) {
                        model.stepBusy = $0
                    }
                case .runtime:
                    if let ws = model.workspace {
                        OnboardingRuntimeStep(workspace: ws) { runtime, modelID in
                            await model.runtimeNext(runtime, model: modelID)
                        }
                    }
                case .welcome:
                    EmptyView()
                }
            }
        }
    }

    private func back(_ model: OnboardingFlowModel) -> (() -> Void)? {
        switch model.step {
        case .aboutYou: return { model.back(from: .aboutYou) }
        case .workspace:
            if model.isNewWorkspace && onCancel == nil { return nil }
            return { model.back(from: .workspace) }
        case .runtime: return model.isNewWorkspace ? nil : { model.back(from: .runtime) }
        case .welcome: return nil
        }
    }
}

/// "Create workspace" from the workspace switcher: the onboarding flow
/// entered at the workspace step, so the new workspace gets its own runtime
/// and Mika too.
struct CreateWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OnboardingSteps(mode: .newWorkspace, onCancel: { dismiss() }, onFinished: { dismiss() })
            .frame(width: 900, height: 660)
    }
}

/// Pending invitations to other workspaces, accepted in a batch.
struct InvitationsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OnboardingInvitationsPage(style: .sheet) { dismiss() }
            .frame(width: 560, height: 560)
    }
}
