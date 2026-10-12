import MulticaCore
import SwiftUI

/// Step 2 — create a workspace, or continue with one from an earlier
/// session (upstream steps/step-workspace.tsx).
struct OnboardingWorkspaceStep: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster
    let existing: Workspace?
    let onCreated: (Workspace) -> Void
    let onBusyChange: (Bool) -> Void

    @State private var mode: Mode?
    @State private var name = ""
    @State private var slug = ""
    @State private var slugServerError: String?
    @State private var slugTouched = false
    @State private var prefix = ""
    @State private var prefixTouched = false
    @State private var creating = false
    @FocusState private var nameFocused: Bool

    private enum Mode { case existing, create }

    private var creationAllowed: Bool { !env.workspaceCreationDisabled }
    private var urlHost: String { OnboardingSlug.urlHost(env.appConfig?.daemonAppUrl ?? env.app.config.appURL.absoluteString) }

    private var slugError: String? {
        if !slug.isEmpty && !OnboardingSlug.isValid(slug) { return tr("onboarding", "step_workspace.slug_format_error") }
        if !slug.isEmpty && OnboardingSlug.isReserved(slug) { return tr("onboarding", "step_workspace.slug_reserved_error") }
        return slugServerError
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !slug.trimmingCharacters(in: .whitespaces).isEmpty && slugError == nil
    }

    private var derivedPrefix: String { OnboardingSlug.issuePrefix(slug) }
    private var effectivePrefix: String { prefix.isEmpty ? derivedPrefix : prefix }

    var body: some View {
        let reusing = existing
        VStack(alignment: .leading, spacing: 32) {
            OnboardingStepHeading(title: headline(reusing), description: lede(reusing))
            if let reusing {
                VStack(spacing: 12) {
                    existingCard(reusing)
                    if creationAllowed { createCard }
                }
            } else if !creationAllowed {
                Button { Task { await env.signOut() } } label: {
                    Text(tr("onboarding", "step_workspace.creation_disabled_logout")).frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            } else {
                createFields
            }
        }
        .padding(.top, 8)
        .onAppear {
            if !creationAllowed && existing != nil { mode = .existing }
        }
        .onChange(of: creating) { onBusyChange(creating) }
        .onDisappear { onBusyChange(false) }
        if !(env.workspaceCreationDisabled && reusing == nil) {
            let cta = footer(reusing)
            OnboardingStepFooter(hint: cta.hint) {
                OnboardingWideButton(title: cta.label, disabled: cta.disabled, action: cta.action)
            }
        }
    }

    private func headline(_ reusing: Workspace?) -> String {
        if let reusing {
            return creationAllowed
                ? tr("onboarding", "step_workspace.headline_resume", ["name": reusing.name])
                : tr("onboarding", "step_workspace.creation_disabled_headline_resume", ["name": reusing.name])
        }
        return creationAllowed ? tr("onboarding", "step_workspace.headline_first") : tr("onboarding", "step_workspace.creation_disabled_headline")
    }

    private func lede(_ reusing: Workspace?) -> String {
        if reusing != nil {
            return creationAllowed ? tr("onboarding", "step_workspace.lede_resume") : tr("onboarding", "step_workspace.creation_disabled_lede_resume")
        }
        return creationAllowed ? tr("onboarding", "step_workspace.lede_first") : tr("onboarding", "step_workspace.creation_disabled_lede")
    }

    private struct CTA {
        var hint: String
        var label: String
        var disabled: Bool
        var action: () -> Void
    }

    private func footer(_ reusing: Workspace?) -> CTA {
        if let reusing, mode == .existing {
            return CTA(hint: tr("onboarding", "step_workspace.hint_opening", ["name": reusing.name]),
                       label: tr("onboarding", "step_workspace.cta_open", ["name": reusing.name]),
                       disabled: creating) { onCreated(reusing) }
        }
        if creationAllowed && (reusing == nil || mode == .create) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if creating {
                return CTA(hint: tr("onboarding", "step_workspace.hint_creating_pending", ["name": trimmed.isEmpty ? tr("onboarding", "step_workspace.hint_creating_fallback") : trimmed]),
                           label: tr("onboarding", "step_workspace.cta_creating"), disabled: true) {}
            }
            if canCreate {
                return CTA(hint: tr("onboarding", "step_workspace.hint_creating", ["name": trimmed]),
                           label: tr("onboarding", "step_workspace.cta_create_named", ["name": trimmed]),
                           disabled: false, action: create)
            }
            return CTA(hint: tr("onboarding", "step_workspace.hint_name_first"), label: tr("onboarding", "step_workspace.cta_create_workspace"), disabled: true) {}
        }
        return CTA(hint: tr("onboarding", "step_workspace.hint_pick"), label: tr("onboarding", "common.continue"), disabled: true) {}
    }

    // MARK: Fields

    private var createFields: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("onboarding", "step_workspace.name_label")).font(Theme.Font.bodyMedium)
                HStack(spacing: 8) {
                    TextField(tr("onboarding", "step_workspace.name_placeholder"), text: Binding(get: { name }, set: nameChanged))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .focused($nameFocused)
                        .onSubmit(create)
                    Button(action: randomName) {
                        Label(tr("onboarding", "step_workspace.random_name"), systemImage: "dice")
                    }
                    .controlSize(.large)
                    .disabled(creating)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("onboarding", "step_workspace.url_label")).font(Theme.Font.bodyMedium)
                HStack(spacing: 0) {
                    Text("\(urlHost)/").font(Theme.Font.mono).foregroundStyle(.secondary).padding(.leading, 10)
                    TextField(tr("onboarding", "step_workspace.slug_placeholder"), text: Binding(get: { slug }, set: { slugTouched = true; applySlug($0) }))
                        .textFieldStyle(.plain)
                        .font(Theme.Font.mono)
                        .padding(.vertical, 7)
                        .padding(.trailing, 8)
                        .onSubmit(create)
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(slugError == nil ? Color.primary.opacity(0.15) : Theme.destructive))
                if let slugError {
                    Text(slugError).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("onboarding", "step_workspace.issue_prefix_label")).font(Theme.Font.bodyMedium)
                TextField(derivedPrefix, text: Binding(get: { prefix }, set: { prefixTouched = true; prefix = OnboardingSlug.normalizePrefix($0) }))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.mono)
                    .frame(width: 128)
                    .onSubmit(create)
                Group {
                    if effectivePrefix.isEmpty {
                        Text(tr("onboarding", "step_workspace.issue_prefix_pending"))
                    } else {
                        Text(tr("onboarding", "step_workspace.issue_prefix_prefix"))
                            + Text("\(effectivePrefix)-123").font(Theme.Font.mono).foregroundColor(.primary)
                            + Text(tr("onboarding", "step_workspace.issue_prefix_suffix"))
                    }
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { nameFocused = true }
    }

    private func existingCard(_ ws: Workspace) -> some View {
        Button { mode = mode == .existing ? nil : .existing } label: {
            HStack(spacing: 16) {
                WorkspaceAvatar(name: ws.name, url: ws.avatarURL, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ws.name).font(Theme.Font.bodyMedium).lineLimit(1)
                    Text("\(urlHost)/\(ws.slug)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                OnboardingRadioMark(selected: mode == .existing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(OnboardingCardBackground(selected: mode == .existing))
    }

    private var createCard: some View {
        VStack(spacing: 0) {
            Button { mode = mode == .create ? nil : .create } label: {
                HStack(spacing: 16) {
                    Image(systemName: "plus")
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.06)))
                        .foregroundStyle(.secondary)
                    Text(tr("onboarding", "step_workspace.create_new_title")).font(Theme.Font.bodyMedium)
                    Spacer()
                    OnboardingRadioMark(selected: mode == .create)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if mode == .create {
                Divider()
                createFields.padding(20)
            }
        }
        .modifier(OnboardingCardBackground(selected: mode == .create))
    }

    // MARK: Actions

    private func applySlug(_ value: String) {
        slug = value
        slugServerError = nil
        if !prefixTouched { prefix = OnboardingSlug.issuePrefix(value) }
    }

    private func nameChanged(_ value: String) {
        name = value
        if !slugTouched {
            applySlug(OnboardingSlug.fromName(value, locale: L10n.shared.language, romanize: OnboardingRomanizer.pinyin))
        }
    }

    private func randomName() {
        let identity = OnboardingSlug.randomCelestial(locale: L10n.shared.language)
        slugTouched = true
        name = identity.name
        applySlug(identity.slug)
    }

    private func create() {
        guard canCreate, !creating else { return }
        creating = true
        let request = (name.trimmingCharacters(in: .whitespaces), slug.trimmingCharacters(in: .whitespaces), effectivePrefix)
        Task {
            do {
                let ws = try await env.app.api.createWorkspace(name: request.0, slug: request.1, issuePrefix: request.2)
                creating = false
                onCreated(ws)
            } catch let e as APIError where e.status == 409 {
                creating = false
                slugServerError = tr("onboarding", "step_workspace.slug_taken_error")
                toaster.error(tr("onboarding", "step_workspace.slug_conflict_toast"))
            } catch {
                creating = false
                let message = (error as? APIError)?.message ?? ""
                toaster.error(message.isEmpty ? tr("onboarding", "step_workspace.create_failed_toast") : message)
            }
        }
    }
}

/// Toneless pinyin for a run of Han characters (Foundation's ICU
/// transliterator stands in for upstream's pinyin-pro).
enum OnboardingRomanizer {
    static func pinyin(_ run: String) -> String {
        let latin = run.applyingTransform(.mandarinToLatin, reverse: false) ?? run
        return latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
    }
}
