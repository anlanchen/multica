import MulticaCore
import Observation
import SwiftUI

enum OnboardingMode {
    /// First run: welcome → about you → workspace → runtime.
    case firstRun
    /// Someone who already uses Multica creating another workspace: starts
    /// at the workspace step and always creates.
    case newWorkspace
}

enum OnboardingDestination: Equatable {
    case chat(sessionID: String)
    case issue(id: String)
}

/// One-shot signal from the runtime-skipped exit to the workspace shell,
/// which seeds the install-runtime guide (upstream welcome-store.ts).
@MainActor
@Observable
final class OnboardingWelcomeStore {
    static let shared = OnboardingWelcomeStore()
    var signalWorkspaceID: String?
    var dismissed = false

    func set(workspaceID: String) {
        signalWorkspaceID = workspaceID
        dismissed = false
    }

    func dismiss() { dismissed = true }

    func reset() {
        signalWorkspaceID = nil
        dismissed = false
    }
}

/// Opens the workspace a flow ended in and lands on its destination.
enum OnboardingCompletion {
    @MainActor static func land(env: AppEnvironment, workspace: Workspace?, destination: OnboardingDestination?) async {
        if let workspace {
            await env.app.reloadWorkspaces(select: workspace.slug)
        } else {
            await env.app.reloadWorkspaces()
        }
        env.sessionDidChange()
        guard workspace != nil, env.app.session != nil else { return }
        switch destination {
        case .chat(let id): env.navigator.push(.chat, query: ["session": id])
        case .issue(let id): env.navigator.push(.issue(id))
        case nil: env.navigator.push(.issues)
        }
    }
}

/// State of one run through the onboarding steps (upstream
/// onboarding-flow.tsx).
@MainActor
@Observable
final class OnboardingFlowModel {
    let mode: OnboardingMode
    private(set) var step: OnboardingStep
    private(set) var answers = OnboardingQuestionnaire()
    /// The workspace created (or picked) on the workspace step. Every later
    /// call names it explicitly instead of switching the app into it.
    private(set) var workspace: Workspace?
    private(set) var workspaces: [Workspace] = []
    private(set) var workspacesReady = false
    var stepBusy = false
    @ObservationIgnored weak var env: AppEnvironment?
    @ObservationIgnored weak var toaster: Toaster?
    @ObservationIgnored var onCancel: (() -> Void)?
    @ObservationIgnored var onFinished: (() -> Void)?

    init(mode: OnboardingMode) {
        self.mode = mode
        step = mode == .newWorkspace ? .workspace : .welcome
    }

    var isNewWorkspace: Bool { mode == .newWorkspace }
    var existingWorkspace: Workspace? { isNewWorkspace ? workspace : (workspace ?? workspaces.first) }
    var canSkipWelcome: Bool { workspacesReady && !workspaces.isEmpty }

    func load() async {
        guard let api = env?.app.api else { return }
        async let me = try? api.getMe()
        async let list = try? api.workspaces()
        if let user = await me { answers = OnboardingQuestionnaire(resuming: user.onboardingQuestionnaire) }
        if let list = await list { workspaces = list }
        workspacesReady = true
    }

    private func refreshWorkspaces() {
        guard let api = env?.app.api else { return }
        Task {
            if let list = try? await api.workspaces() { workspaces = list }
            workspacesReady = true
        }
    }

    func go(_ next: OnboardingStep) {
        step = next
        if next == .welcome || next == .workspace { refreshWorkspaces() }
    }

    func welcomeNext() { go(OnboardingStep.order[0]) }

    func advance(from: OnboardingStep) {
        if let next = from.next { go(next) }
    }

    func back(from: OnboardingStep) {
        if isNewWorkspace && from == .workspace {
            onCancel?()
            return
        }
        go(from.previous)
    }

    /// The questionnaire saves are optimistic: the next step renders now, a
    /// failed save only toasts.
    func applyAnswers(_ change: (inout OnboardingQuestionnaire) -> Void) {
        change(&answers)
        let snapshot = answers.json
        guard let api = env?.app.api else { return }
        Task {
            do { _ = try await api.patchOnboarding(questionnaire: snapshot) } catch { toaster?.error(error) }
        }
    }

    func workspaceCreated(_ ws: Workspace) {
        workspace = ws
        advance(from: .workspace)
    }

    private func complete(_ path: OnboardingCompletionPath, workspaceID: String?) async throws {
        guard let api = env?.app.api else { return }
        _ = try await api.markOnboardingComplete(completionPath: path.rawValue, workspaceId: workspaceID)
    }

    private func finish(_ ws: Workspace?, _ destination: OnboardingDestination?) async {
        guard let env else { return }
        onFinished?()
        await OnboardingCompletion.land(env: env, workspace: ws, destination: destination)
    }

    /// "I've done this before": mark onboarded and open the existing
    /// workspace without creating anything.
    func skipWelcome() async {
        let ws = workspaces.first
        do {
            try await complete(.skipExisting, workspaceID: ws?.id)
        } catch {
            fail(error, "errors.skip_failed")
            return
        }
        await finish(ws, nil)
    }

    /// Runtime step exit. With a runtime: provision Mika on it, start the
    /// hidden kickoff, open Mika's chat. Without: mark the runtime skipped and
    /// let the workspace seed the install guide.
    func runtimeNext(_ runtime: RuntimeDeviceRecord?, model: String) async {
        guard let ws = workspace, let api = env?.app.api else { return }
        if let runtime {
            let lang = OnboardingTemplates.contentLanguage(L10n.shared.language)
            do {
                _ = try await api.patchOnboarding(questionnaire: answers.json)
                let agent = try await api.createMikaAgent(
                    runtimeId: runtime.id, language: lang, model: model.isEmpty ? nil : model,
                    sessionTitle: OnboardingTemplates.mikaChatTitle[lang], workspaceSlug: ws.slug
                )
                guard let session = agent.onboardingSession else {
                    throw APIError(status: 0, message: "Mika onboarding session was not returned")
                }
                _ = try await api.startMikaOnboarding(sessionId: session.id, language: lang, workspaceSlug: ws.slug)
                try await complete(.full, workspaceID: ws.id)
                await finish(ws, .chat(sessionID: session.id))
            } catch {
                fail(error, "errors.mika_setup_failed")
            }
            return
        }
        do {
            try await complete(.runtimeSkipped, workspaceID: ws.id)
        } catch {
            fail(error, "errors.skip_failed")
            return
        }
        OnboardingWelcomeStore.shared.set(workspaceID: ws.id)
        await finish(ws, nil)
    }

    private func fail(_ error: Error, _ key: String) {
        let message = (error as? APIError)?.message ?? ""
        toaster?.error(message.isEmpty ? tr("onboarding", key) : message)
    }
}
