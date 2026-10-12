import AppKit
import MulticaCore
import SwiftUI

/// The frame every onboarding step renders into: the progress rail on the
/// left, the step's column scrolling on the right (upstream step-shell.tsx +
/// step-sidebar.tsx).
struct OnboardingStepShell<Content: View>: View {
    let currentStep: OnboardingStep
    var onBack: (() -> Void)?
    var backDisabled = false
    var onStepChange: ((OnboardingStep) -> Void)?
    var showLogout = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            OnboardingRail(currentStep: currentStep, onBack: onBack, backDisabled: backDisabled, onStepChange: onStepChange, showLogout: showLogout)
                .frame(width: 300)
                .padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .frame(maxWidth: 448, minHeight: 0, alignment: .topLeading)
                .padding(.horizontal, 40)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.canvas)
    }
}

private struct OnboardingRail: View {
    let currentStep: OnboardingStep
    let onBack: (() -> Void)?
    let backDisabled: Bool
    let onStepChange: ((OnboardingStep) -> Void)?
    let showLogout: Bool

    var body: some View {
        let current = currentStep.index ?? 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
                Text(tr("onboarding", "step_nav.wordmark")).font(Theme.Font.bodyMedium)
                Spacer()
                if let onBack {
                    Button(action: onBack) { Image(systemName: "arrow.left") }
                        .buttonStyle(.borderless)
                        .disabled(backDisabled)
                        .help(tr("onboarding", "common.back"))
                }
            }
            .frame(minHeight: 32)
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(OnboardingStep.order.enumerated()), id: \.element) { i, step in
                    let done = i < current
                    let isCurrent = i == current
                    let canReturn = done && onStepChange != nil && !backDisabled
                    let row = HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle().strokeBorder(done ? Color.white : (isCurrent ? Color.white.opacity(0.6) : Color.white.opacity(0.2)), lineWidth: 1)
                                .background(Circle().fill(done ? Color.white : .clear))
                            if done {
                                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.black)
                            } else if isCurrent {
                                Circle().fill(Color.white).frame(width: 6, height: 6)
                            }
                        }
                        .frame(width: 16, height: 16)
                        .padding(.top, 1)
                        Text(tr("onboarding", "step_nav.\(step.rawValue).label"))
                            .font(Theme.Font.body)
                            .foregroundStyle(isCurrent || done ? Color.white : Color.white.opacity(0.5))
                        Spacer()
                    }
                    .padding(.bottom, i < OnboardingStep.order.count - 1 ? 24 : 0)
                    .background(alignment: .topLeading) {
                        if i < OnboardingStep.order.count - 1 {
                            Rectangle()
                                .fill(done ? Color.white.opacity(0.5) : Color.white.opacity(0.15))
                                .frame(width: 1)
                                .padding(.top, 22)
                                .padding(.bottom, 4)
                                .offset(x: 7.5)
                        }
                    }
                    if canReturn {
                        Button { onStepChange?(step) } label: { row.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                    } else {
                        row
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(tr("onboarding", "step_nav.label"))
            Spacer()
            if showLogout {
                OnboardingLogoutButton(inline: true)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity)
        .background {
            ZStack {
                Color(white: 0.07)
                OnboardingDotField()
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }
}

/// A static dot field fading out from a few soft centres (stands in for
/// upstream's animated DotSphere without a per-frame cost).
private struct OnboardingDotField: View {
    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 19
            let centres = [CGPoint(x: size.width * 0.2, y: size.height * 0.25), CGPoint(x: size.width * 0.85, y: size.height * 0.6), CGPoint(x: size.width * 0.35, y: size.height * 0.9)]
            let radius = max(size.width, size.height) * 0.35
            var y: CGFloat = gap / 2
            while y < size.height {
                var x: CGFloat = gap / 2
                while x < size.width {
                    let d = centres.map { hypot($0.x - x, $0.y - y) }.min() ?? radius
                    let t = max(0, 1 - d / radius)
                    if t > 0.02 {
                        let r = 0.4 + 1.5 * t
                        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.06 + 0.22 * t)))
                    }
                    x += gap
                }
                y += gap
            }
        }
        .allowsHitTesting(false)
    }
}

/// Title + supporting line for a step.
struct OnboardingStepHeading: View {
    let title: String
    var description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 20, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if let description {
                Text(description).font(Theme.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The step's stacked full-width actions with an optional status line.
struct OnboardingStepFooter<Content: View>: View {
    var hint: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let hint {
                Text(hint).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Full-width primary / secondary buttons used in step footers.
struct OnboardingWideButton: View {
    let title: String
    var prominent = true
    var busy = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small) }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .modifier(OnboardingButtonKind(prominent: prominent))
        .disabled(disabled || busy)
    }
}

private struct OnboardingButtonKind: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.borderless)
        }
    }
}

/// The "Log out" escape hatch present on every onboarding screen.
struct OnboardingLogoutButton: View {
    @Environment(AppEnvironment.self) private var env
    var inline = false

    var body: some View {
        Button {
            Task { await env.signOut() }
        } label: {
            Label(tr("onboarding", "common.log_out"), systemImage: "rectangle.portrait.and.arrow.right")
                .font(Theme.Font.body)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}

/// A questionnaire chip: icon + label, check when selected (upstream
/// IconOptionCard). The "Other" variant turns its label into a text field.
struct OnboardingOptionChip: View {
    let icon: String
    let label: String
    let selected: Bool
    var otherText: Binding<String>?
    var placeholder = ""
    var onConfirm: (() -> Void)?
    let onSelect: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Theme.brand : .secondary)
            if selected, let otherText {
                TextField(placeholder, text: Binding(
                    get: { otherText.wrappedValue },
                    set: { otherText.wrappedValue = String($0.prefix(80)) }
                ))
                .textFieldStyle(.plain)
                .frame(width: 140)
                .focused($focused)
                .onSubmit {
                    if !otherText.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty { onConfirm?() }
                }
                .onAppear { focused = true }
            } else {
                Text(label)
            }
            if selected && otherText == nil {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
            }
        }
        .font(Theme.Font.body)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(selected ? Theme.brand.opacity(0.06) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(selected ? Theme.brand.opacity(0.35) : Color.primary.opacity(0.12)))
        .contentShape(Rectangle())
        .onTapGesture {
            if !(selected && otherText != nil) { onSelect() }
        }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Wrapping layout for chips.
struct OnboardingFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 448
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

/// Radio marker used by the workspace picker cards.
struct OnboardingRadioMark: View {
    let selected: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(selected ? Color.primary : Color.primary.opacity(0.2), lineWidth: 1.5)
            if selected { Circle().fill(Color.primary).padding(3.5) }
        }
        .frame(width: 16, height: 16)
    }
}

/// Card chrome shared by the option cards (thin border, inset ring when
/// selected).
struct OnboardingCardBackground: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.primary : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
    }
}
