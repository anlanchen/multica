import AppKit
import MulticaCore
import SwiftUI

/// Step 0 — the product intro: editorial hero on the left, a stack of mock
/// activity cards on the right (upstream steps/step-welcome.tsx).
struct OnboardingWelcomeStep: View {
    let onNext: () async -> Void
    let onSkip: (() async -> Void)?
    @State private var pending: Pending?

    private enum Pending { case next, skip }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 32) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                    Text(tr("onboarding", "welcome.wordmark"))
                        .font(.system(size: 17, weight: .medium, design: .serif))
                }
                (Text(tr("onboarding", "welcome.headline_line1")) + Text("\n")
                    + Text(tr("onboarding", "welcome.headline_line2")) + Text(" ")
                    + Text(tr("onboarding", "welcome.headline_emphasis")).italic().foregroundColor(Theme.brand))
                    .font(.system(size: 50, weight: .medium, design: .serif))
                    .lineSpacing(0)
                    .fixedSize(horizontal: false, vertical: true)
                Text(tr("onboarding", "welcome.lede"))
                    .font(.system(size: 16))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button {
                        run(.next, onNext)
                    } label: {
                        HStack(spacing: 6) {
                            if pending == .next { ProgressView().controlSize(.small) }
                            Text(tr("onboarding", "welcome.start_exploring"))
                            Image(systemName: "arrow.right")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pending != nil)
                    if let onSkip {
                        Button {
                            run(.skip, onSkip)
                        } label: {
                            HStack(spacing: 6) {
                                if pending == .skip { ProgressView().controlSize(.small) }
                                Text(tr("onboarding", "welcome.skip_existing"))
                            }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.large)
                        .disabled(pending != nil)
                    }
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
            .padding(.horizontal, 72)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            OnboardingWelcomeIllustration()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.03))
                .overlay(alignment: .leading) { Divider() }
        }
        .overlay(alignment: .topTrailing) {
            OnboardingLogoutButton().padding(24)
        }
        .background(Theme.canvas)
    }

    private func run(_ which: Pending, _ action: @escaping () async -> Void) {
        guard pending == nil else { return }
        pending = which
        Task {
            await action()
            pending = nil
        }
    }
}

private struct OnboardingWelcomeIllustration: View {
    var body: some View {
        VStack(spacing: 12) {
            OnboardingMockCard(actor: .user(tr("onboarding", "welcome.illustration.card1_actor_name"), tr("onboarding", "welcome.illustration.card1_actor_initial")),
                               issue: "MCA-42",
                               content: mention("welcome.illustration.card1_mention_content") + plain("welcome.illustration.card1_body_prefix")
                                   + mention("welcome.illustration.card1_mention_research") + plain("welcome.illustration.card1_body_suffix"))
            OnboardingMockCard(actor: .agent(tr("onboarding", "welcome.illustration.card2_actor_name"), "C"), issue: "MCA-42",
                               content: plain("welcome.illustration.card2_body"), status: .inProgress)
                .offset(x: -20).rotationEffect(.degrees(-1.2))
            OnboardingMockCard(actor: .agent(tr("onboarding", "welcome.illustration.card3_actor_name"), "H"), issue: "MCA-38",
                               content: plain("welcome.illustration.card3_body"), status: .done,
                               timestamp: tr("onboarding", "welcome.illustration.card3_timestamp"))
                .offset(x: 32).rotationEffect(.degrees(1.6))
            OnboardingMockCard(actor: .agent(tr("onboarding", "welcome.illustration.card4_actor_name"), "O"), issue: "MCA-42",
                               content: plain("welcome.illustration.card4_body"), status: .inReview)
                .offset(x: -24).rotationEffect(.degrees(-0.8))
            OnboardingMockCard(actor: .agent(tr("onboarding", "welcome.illustration.card5_actor_name"), "C"), issue: "MCA-35",
                               content: plain("welcome.illustration.card5_body_prefix") + mention("welcome.illustration.card5_mention_you") + plain("welcome.illustration.card5_body_suffix"),
                               status: .done, timestamp: tr("onboarding", "welcome.illustration.card5_timestamp"))
                .offset(x: 24).rotationEffect(.degrees(1))
        }
        .frame(maxWidth: 440)
        .padding(32)
    }

    private func plain(_ key: String) -> Text { Text(tr("onboarding", key)) }
    private func mention(_ key: String) -> Text { Text(tr("onboarding", key)).fontWeight(.medium).foregroundColor(Theme.brand) }
}

private struct OnboardingMockCard: View {
    enum Actor {
        case user(String, String)
        case agent(String, String)
    }

    let actor: Actor
    let issue: String
    let content: Text
    var status: IssueStatusKey?
    var timestamp: String?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                switch actor {
                case .user(let name, let initial):
                    Text(initial).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 24, height: 24).background(Circle().fill(Color.primary))
                    Text(name).font(Theme.Font.bodyMedium)
                case .agent(let name, let mark):
                    Text(mark).font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                        .overlay(Circle().strokeBorder(Theme.border))
                    Text(name).font(Theme.Font.bodyMedium)
                }
                Spacer()
                Text(issue).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            content.font(Theme.Font.body).fixedSize(horizontal: false, vertical: true)
            if let status {
                HStack(spacing: 6) {
                    StatusIcon(status: status, size: 13)
                    Text(tr("issues", "status.\(status.rawValue)")).font(Theme.Font.caption.weight(.medium))
                    if let timestamp {
                        Text("·").foregroundStyle(.secondary)
                        Text(timestamp).foregroundStyle(.secondary)
                    }
                }
                .font(Theme.Font.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 8 : 3, y: hovering ? 4 : 1)
        .offset(y: hovering ? -2 : 0)
        .animation(.easeOut(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
    }
}
