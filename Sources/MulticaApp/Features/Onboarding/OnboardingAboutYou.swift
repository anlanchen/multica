import MulticaCore
import SwiftUI

/// Step 1 — role (single) and use case (multi) on one screen (upstream
/// steps/step-about-you.tsx). Every change is persisted as it happens.
struct OnboardingAboutYouStep: View {
    let answers: OnboardingQuestionnaire
    let onChange: ((inout OnboardingQuestionnaire) -> Void) -> Void
    let onAdvance: () -> Void

    static let roles: [(slug: String, icon: String)] = [
        ("engineer", "chevron.left.forwardslash.chevron.right"), ("product", "briefcase"), ("designer", "paintpalette"),
        ("founder", "paperplane"), ("marketing", "megaphone"), ("writer", "pencil.line"), ("research", "magnifyingglass"),
        ("ops", "gearshape.2"), ("student", "graduationcap"), ("other", "ellipsis"),
    ]

    static let useCases: [(slug: String, icon: String)] = [
        ("ship_code", "chevron.left.forwardslash.chevron.right"), ("manage_team", "checklist"), ("personal_tasks", "person"),
        ("plan_research", "brain"), ("write_publish", "square.and.pencil"), ("automate_ops", "gearshape.2"),
        ("evaluate", "safari"), ("other", "ellipsis"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            OnboardingStepHeading(title: tr("onboarding", "questions.about_you.question"))
            group(question: tr("onboarding", "questions.role.question")) {
                ForEach(Self.roles, id: \.slug) { o in
                    OnboardingOptionChip(
                        icon: o.icon,
                        label: tr("onboarding", "questions.role.\(o.slug)"),
                        selected: answers.role == o.slug,
                        otherText: o.slug == "other" ? Binding(get: { answers.roleOther ?? "" }, set: { v in onChange { $0.roleOther = v } }) : nil,
                        placeholder: tr("onboarding", "questions.role.other_placeholder"),
                        onConfirm: confirm
                    ) { onChange { $0.pickRole(o.slug) } }
                }
            }
            group(question: tr("onboarding", "questions.use_case.question")) {
                ForEach(Self.useCases, id: \.slug) { o in
                    OnboardingOptionChip(
                        icon: o.icon,
                        label: tr("onboarding", "questions.use_case.\(o.slug)"),
                        selected: answers.useCase.contains(o.slug),
                        otherText: o.slug == "other" ? Binding(get: { answers.useCaseOther ?? "" }, set: { v in onChange { $0.useCaseOther = v } }) : nil,
                        placeholder: tr("onboarding", "questions.use_case.other_placeholder"),
                        onConfirm: confirm
                    ) { onChange { $0.toggleUseCase(o.slug) } }
                }
            }
        }
        .padding(.top, 8)
        OnboardingStepFooter(hint: answers.canContinueAboutYou ? nil : tr("onboarding", "step_question.hint_pick")) {
            OnboardingWideButton(title: tr("onboarding", "common.continue"), disabled: !answers.canContinueAboutYou, action: confirm)
                .keyboardShortcut(.defaultAction)
            OnboardingWideButton(title: tr("onboarding", "common.skip"), prominent: false) {
                onChange { $0.skipAboutYou() }
                onAdvance()
            }
        }
    }

    private func group<Content: View>(question: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question).font(Theme.Font.bodyMedium)
            OnboardingFlowLayout { content() }
        }
    }

    private func confirm() {
        guard answers.canContinueAboutYou else { return }
        if !answers.roleAnswered || !answers.useCaseAnswered {
            onChange { $0.stampUnanswered() }
        }
        onAdvance()
    }
}
