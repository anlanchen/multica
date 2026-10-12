import MulticaCore
import SwiftUI

/// Step 3 — pick where Mika runs (upstream steps/step-runtime-connect.tsx).
/// When this Mac has no Multica CLI the local daemon cannot come up, so the
/// step offers the terminal path instead (upstream step-platform-fork.tsx).
struct OnboardingRuntimeStep: View {
    @Environment(AppEnvironment.self) private var env
    let workspace: Workspace
    let onNext: (RuntimeDeviceRecord?, String) async -> Void
    @State private var picker = OnboardingRuntimePicker()

    var body: some View {
        Group {
            if env.daemonStatus.state == .cliNotFound {
                OnboardingPlatformFork(picker: picker, onNext: onNext)
            } else {
                OnboardingRuntimeConnect(picker: picker, onNext: onNext)
            }
        }
        .task(id: workspace.id) {
            await picker.poll(api: env.app.api, slug: workspace.slug)
        }
    }
}

/// The runtime list: polled every 2 s while empty (no realtime exists before
/// the workspace opens), auto-selecting an online runtime first.
@MainActor
@Observable
final class OnboardingRuntimePicker {
    private(set) var runtimes: [RuntimeDeviceRecord] = []
    var selectedID: String?
    var model = ""
    @ObservationIgnored private var refreshRequested = false

    var selected: RuntimeDeviceRecord? { runtimes.first { $0.id == selectedID } }

    func poll(api: APIClient, slug: String) async {
        while !Task.isCancelled {
            if let list = try? await api.listRuntimes(owner: "me", workspaceSlug: slug) {
                runtimes = list
                if selectedID == nil || !list.contains(where: { $0.id == selectedID }) {
                    selectedID = (list.first { $0.status == "online" } ?? list.first)?.id
                }
            }
            let start = Date()
            while !Task.isCancelled, !refreshRequested, !(runtimes.isEmpty && Date().timeIntervalSince(start) >= 2) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            refreshRequested = false
        }
    }

    func refreshNow() { refreshRequested = true }

    func select(_ id: String) {
        if id != selectedID { model = "" }
        selectedID = id
    }

    static func label(_ r: RuntimeDeviceRecord) -> String {
        OnboardingRuntimeLabel.label(name: r.name, customName: r.customName, provider: r.provider)
    }
}

/// "Meet Mika" — the subject of the step, stated before its prerequisite.
private struct OnboardingMikaIntro: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingStepHeading(title: tr("onboarding", "mika_intro.headline"))
            HStack(alignment: .top, spacing: 12) {
                Text("🦄")
                    .font(.system(size: 18))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                    .accessibilityLabel(tr("onboarding", "mika_intro.name"))
                VStack(alignment: .leading, spacing: 3) {
                    (Text(tr("onboarding", "mika_intro.name")) + Text(" · " + tr("onboarding", "mika_intro.role")).foregroundColor(.secondary))
                        .font(Theme.Font.bodyMedium)
                    Text(tr("onboarding", "mika_intro.blurb")).font(Theme.Font.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        }
    }
}

// MARK: Connect (desktop path)

private struct OnboardingRuntimeConnect: View {
    @Environment(AppEnvironment.self) private var env
    let picker: OnboardingRuntimePicker
    let onNext: (RuntimeDeviceRecord?, String) async -> Void
    @State private var softTimedOut = false
    @State private var hardTimedOut = false
    @State private var scanEpoch = 0
    @State private var submitting = false
    @State private var refreshing = false

    private enum Phase { case scanning, found, empty }

    /// The local daemon is still booting or registering CLIs it already
    /// found — an empty list then is not yet "no runtime" (MUL-5119).
    private var runtimesPending: Bool {
        switch env.daemonStatus.state {
        case .unknown, .starting: return true
        case .running: return !(env.daemonStatus.health?.agents.isEmpty ?? true)
        default: return false
        }
    }

    private var phase: Phase {
        if !picker.runtimes.isEmpty { return .found }
        return hardTimedOut || (softTimedOut && !runtimesPending) ? .empty : .scanning
    }

    var body: some View {
        let phase = self.phase
        VStack(alignment: .leading, spacing: 32) {
            OnboardingMikaIntro()
            switch phase {
            case .scanning: scanning
            case .found: found
            case .empty: empty
            }
        }
        .padding(.top, 8)
        .animation(.easeOut(duration: 0.2), value: phase)
        .task(id: TimerKey(empty: picker.runtimes.isEmpty, epoch: scanEpoch)) {
            guard picker.runtimes.isEmpty else { return }
            softTimedOut = false
            hardTimedOut = false
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            softTimedOut = true
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            hardTimedOut = true
        }
        OnboardingStepFooter(hint: hint(phase)) {
            if phase == .found {
                OnboardingWideButton(title: tr("onboarding", "step_runtime.continue"), busy: submitting, disabled: picker.selected == nil) {
                    submit(picker.selected)
                }
                .keyboardShortcut(.defaultAction)
            }
            if phase != .empty {
                OnboardingWideButton(title: tr("onboarding", "step_runtime.skip"), prominent: false, disabled: submitting) { submit(nil) }
            }
        }
    }

    private struct TimerKey: Hashable {
        var empty: Bool
        var epoch: Int
    }

    private func hint(_ phase: Phase) -> String? {
        switch phase {
        case .found:
            if let s = picker.selected { return tr("onboarding", "step_runtime.hint_selected", ["name": OnboardingRuntimePicker.label(s)]) }
            return tr("onboarding", "step_runtime.hint_pick")
        case .scanning: return tr("onboarding", "step_runtime.hint_waiting")
        case .empty: return nil
        }
    }

    private func submit(_ runtime: RuntimeDeviceRecord?) {
        guard !submitting else { return }
        submitting = true
        Task {
            await onNext(runtime, runtime == nil ? "" : picker.model)
            submitting = false
        }
    }

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            await env.restartDaemon()
            picker.refreshNow()
            scanEpoch += 1
            refreshing = false
        }
    }

    private var toolsLede: (String, String) -> Text {
        { prefix, suffix in
            Text(tr("onboarding", prefix))
                + Text("Claude Code").fontWeight(.medium).foregroundColor(.primary) + Text(", ")
                + Text("Codex").fontWeight(.medium).foregroundColor(.primary) + Text(", ")
                + Text("Cursor").fontWeight(.medium).foregroundColor(.primary)
                + Text(tr("onboarding", suffix))
        }
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("onboarding", "step_runtime.scanning_headline")).font(.system(size: 15, weight: .medium))
            toolsLede("step_runtime.scanning_lede_prefix", "step_runtime.scanning_lede_suffix")
                .font(Theme.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ForEach(0..<2, id: \.self) { _ in OnboardingSkeletonRuntimeCard() }
            }
            .padding(.top, 32)
        }
    }

    private var found: some View {
        let total = picker.runtimes.count
        let online = picker.runtimes.filter { $0.status == "online" }.count
        let status = online == total ? tr("onboarding", "step_runtime.status_all_online")
            : online == 0 ? tr("onboarding", "step_runtime.status_none_online")
            : tr("onboarding", "step_runtime.status_n_online", ["count": online])
        return VStack(alignment: .leading, spacing: 0) {
            Text(tr("onboarding", "step_runtime.found_headline")).font(.system(size: 15, weight: .medium))
            HStack(spacing: 8) {
                Text(tr("onboarding", "step_runtime.runtime_count", ["count": total])).fontWeight(.semibold)
                Text("·").foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Circle().fill(online == 0 ? Color.secondary.opacity(0.4) : Theme.success).frame(width: 6, height: 6)
                    Text(status)
                }
                .foregroundStyle(online == 0 ? Color.secondary : Theme.success)
                Spacer()
                OnboardingRefreshButton(refreshing: refreshing, action: refresh)
            }
            .font(Theme.Font.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .padding(.top, 28)
            OnboardingMikaRuntimeChoice(picker: picker, layout: .dropdown, disabled: submitting)
                .padding(.top, 20)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(tr("onboarding", "step_runtime.empty_headline")).font(.system(size: 15, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                OnboardingRefreshButton(refreshing: refreshing, action: refresh)
            }
            toolsLede("step_runtime.empty_lede_prefix", "step_runtime.empty_lede_suffix")
                .font(Theme.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 14) {
                Button { submit(nil) } label: {
                    OnboardingForkRow(title: tr("onboarding", "step_runtime.empty_skip_title"),
                                      subtitle: tr("onboarding", "step_runtime.empty_skip_subtitle"),
                                      trailing: AnyView(HStack(spacing: 6) {
                                          Text(tr("onboarding", "step_runtime.empty_skip_action"))
                                          Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                                      }
                                      .font(Theme.Font.caption.weight(.medium))
                                      .padding(.horizontal, 14).padding(.vertical, 7)
                                      .background(Capsule().strokeBorder(Color.primary.opacity(0.2)))))
                }
                .buttonStyle(.plain)
                .disabled(submitting)
                OnboardingForkRow(title: tr("onboarding", "step_runtime.empty_waitlist_title"),
                                  subtitle: tr("onboarding", "step_runtime.empty_waitlist_subtitle"),
                                  trailing: AnyView(OnboardingComingSoonBadge(label: tr("onboarding", "step_runtime.empty_waitlist_action"))),
                                  dashed: true)
                    .opacity(0.7)
            }
            .padding(.top, 32)
        }
    }
}

private struct OnboardingRefreshButton: View {
    let refreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(refreshing ? tr("onboarding", "step_runtime.refreshing") : tr("onboarding", "step_runtime.refresh"),
                  systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .font(Theme.Font.caption)
        .disabled(refreshing)
    }
}

private struct OnboardingSkeletonRuntimeCard: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6).fill(Theme.hover).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.hover).frame(width: 110, height: 10)
                RoundedRectangle(cornerRadius: 2).fill(Theme.hover).frame(width: 64, height: 8)
            }
            Spacer()
            Circle().strokeBorder(Theme.hover, lineWidth: 1.5).frame(width: 16, height: 16)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .opacity(pulse ? 0.5 : 1)
        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}

private struct OnboardingForkRow: View {
    let title: String
    let subtitle: String
    let trailing: AnyView
    var dashed = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.Font.bodyMedium)
                Text(subtitle).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 10).fill(dashed ? Color.primary.opacity(0.02) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])))
    }
}

private struct OnboardingComingSoonBadge: View {
    let label: String

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .medium))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Theme.border))
    }
}

// MARK: Runtime + model choice

/// Which runtime Mika uses and on which model (upstream
/// mika-runtime-choice.tsx). Switching runtime resets the model.
struct OnboardingMikaRuntimeChoice: View {
    enum Layout { case dropdown, list }
    let picker: OnboardingRuntimePicker
    let layout: Layout
    var disabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch layout {
            case .dropdown:
                Menu {
                    ForEach(picker.runtimes) { r in
                        Button { picker.select(r.id) } label: {
                            Text("\(OnboardingRuntimePicker.label(r)) — \(r.status == "online" ? tr("agents", "pickers.runtime_online") : tr("agents", "pickers.runtime_offline"))")
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if let s = picker.selected {
                            Circle().fill(s.status == "online" ? Theme.success : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                            Text(OnboardingRuntimePicker.label(s))
                        } else {
                            Text(tr("agents", "pickers.runtime_none")).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .menuStyle(.button)
                .controlSize(.large)
            case .list:
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(picker.runtimes) { r in
                            Button { picker.select(r.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                                    Text(OnboardingRuntimePicker.label(r)).font(Theme.Font.body).lineLimit(1)
                                    Spacer()
                                    Circle().fill(r.status == "online" ? Theme.success : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                                    OnboardingRadioMark(selected: r.id == picker.selectedID)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .modifier(OnboardingCardBackground(selected: r.id == picker.selectedID))
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
            OnboardingModelDropdown(picker: picker)
        }
        .disabled(disabled)
    }
}

/// The selected runtime's models, discovered through the daemon (upstream
/// model-dropdown.tsx); a model ID can always be typed by hand.
private struct OnboardingModelDropdown: View {
    @Environment(AppEnvironment.self) private var env
    let picker: OnboardingRuntimePicker
    @State private var models: [RuntimeModel] = []
    @State private var discovering = false
    @State private var failed = false
    @State private var supported = true
    @State private var custom = ""
    @State private var showCustom = false

    var body: some View {
        let runtime = picker.selected
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("agents", "model_dropdown.label")).font(Theme.Font.bodyMedium)
            if runtime == nil {
                Text(tr("agents", "model_dropdown.select_runtime_first")).font(Theme.Font.caption).foregroundStyle(.secondary)
            } else if !supported {
                Text(tr("agents", "model_dropdown.managed_by_runtime_title")).font(Theme.Font.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Menu {
                        Button(tr("agents", "model_dropdown.default_provider")) { picker.model = "" }
                        if !models.isEmpty { Divider() }
                        ForEach(models) { m in
                            Button(m.label.isEmpty ? m.id : m.label) { picker.model = m.id }
                        }
                        Divider()
                        Button(tr("agents", "pickers.model_search_placeholder")) { showCustom = true }
                    } label: {
                        HStack {
                            Text(currentLabel)
                            Spacer()
                            if discovering { ProgressView().controlSize(.mini) }
                        }
                    }
                    .menuStyle(.button)
                    .controlSize(.large)
                }
                if discovering {
                    Text(tr("agents", "pickers.model_discovering")).font(Theme.Font.caption).foregroundStyle(.secondary)
                } else if failed {
                    Text("\(tr("agents", "pickers.model_discovery_failed_title")) \(tr("agents", "pickers.model_discovery_failed_hint"))")
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                } else if runtime?.status != "online" {
                    Text(tr("agents", "model_dropdown.runtime_offline_manual")).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                if showCustom {
                    TextField(tr("agents", "pickers.model_search_placeholder"), text: $custom)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            let v = custom.trimmingCharacters(in: .whitespaces)
                            if !v.isEmpty { picker.model = v }
                            showCustom = false
                        }
                }
            }
        }
        .task(id: runtime?.status == "online" ? runtime?.id : nil) {
            models = []
            failed = false
            supported = true
            guard let runtime, runtime.status == "online" else { return }
            await discover(runtime.id)
        }
    }

    private var currentLabel: String {
        if picker.model.isEmpty { return tr("agents", "model_dropdown.default_provider") }
        return models.first { $0.id == picker.model }.map { $0.label.isEmpty ? $0.id : $0.label } ?? picker.model
    }

    private func discover(_ runtimeID: String) async {
        discovering = true
        defer { discovering = false }
        let api = env.app.api
        do {
            var current = try await api.initiateListModels(runtimeID)
            let start = Date()
            while current.status == "pending" || current.status == "running" {
                if Date().timeIntervalSince(start) > 100 { failed = true; return }
                try await Task.sleep(for: .milliseconds(500))
                current = try await api.getListModelsResult(runtimeID, requestId: current.id)
            }
            if current.status == "failed" || current.status == "timeout" { failed = true; return }
            supported = current.supported
            models = current.models ?? []
        } catch {
            if !(error is CancellationError) { failed = true }
        }
    }
}

// MARK: Terminal path

/// The CLI path: install the Multica CLI, run `multica setup`, and the
/// computer appears below (upstream step-platform-fork + CLI dialog).
private struct OnboardingPlatformFork: View {
    @Environment(AppEnvironment.self) private var env
    let picker: OnboardingRuntimePicker
    let onNext: (RuntimeDeviceRecord?, String) async -> Void
    @State private var showCLI = false
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            OnboardingStepHeading(title: tr("onboarding", "step_platform.headline"), description: tr("onboarding", "step_platform.lede"))
            VStack(spacing: 8) {
                Button { showCLI = true } label: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(tr("onboarding", "step_platform.download_title"), systemImage: "desktopcomputer")
                                .font(.system(size: 15, weight: .medium))
                            Text(tr("onboarding", "cli_install.intro")).font(Theme.Font.caption).opacity(0.7)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Text(tr("onboarding", "step_platform.cli_action"))
                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                        }
                        .font(Theme.Font.caption.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.15)))
                    }
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .padding(.horizontal, 24).padding(.vertical, 20)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                OnboardingForkRow(title: tr("onboarding", "step_platform.cli_title"),
                                  subtitle: tr("onboarding", "step_platform.cli_subtitle"),
                                  trailing: AnyView(Button(tr("onboarding", "step_platform.cli_action")) { showCLI = true }.controlSize(.small)))
                OnboardingForkRow(title: tr("onboarding", "step_platform.cloud_title"),
                                  subtitle: tr("onboarding", "step_platform.cloud_subtitle"),
                                  trailing: AnyView(OnboardingComingSoonBadge(label: tr("onboarding", "step_platform.cloud_action"))))
                    .opacity(0.7)
                OnboardingCloudWaitlist()
            }
        }
        .padding(.top, 8)
        OnboardingStepFooter(hint: tr("onboarding", "step_platform.hint_default")) {
            OnboardingWideButton(title: tr("onboarding", "step_runtime.skip"), prominent: false) {
                Task { await onNext(nil, "") }
            }
        }
        .sheet(isPresented: $showCLI) {
            OnboardingCLIDialog(picker: picker, connecting: connecting) {
                guard let r = picker.selected, !connecting else { return }
                connecting = true
                Task {
                    await onNext(r, picker.model)
                    connecting = false
                    showCLI = false
                }
            } onRefresh: {
                Task { await env.restartDaemon() }
                picker.refreshNow()
            }
        }
    }
}

private struct OnboardingCLIDialog: View {
    @Environment(\.dismiss) private var dismiss
    let picker: OnboardingRuntimePicker
    let connecting: Bool
    let onConnect: () -> Void
    let onRefresh: () -> Void
    @State private var openedAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("onboarding", "step_platform.cli_dialog_title")).font(Theme.Font.title)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    OnboardingCLIInstructions()
                    if picker.runtimes.isEmpty {
                        TimelineView(.periodic(from: openedAt, by: 1)) { context in
                            OnboardingCLIWaiting(elapsed: Int(context.date.timeIntervalSince(openedAt)))
                        }
                    } else {
                        HStack(spacing: 8) {
                            Circle().fill(Theme.success).frame(width: 8, height: 8)
                            Text(tr("onboarding", "step_platform.runtimes_connected", ["count": picker.runtimes.count])).font(Theme.Font.bodyMedium)
                        }
                        OnboardingMikaRuntimeChoice(picker: picker, layout: .list, disabled: connecting)
                    }
                }
            }
            HStack(spacing: 8) {
                if !picker.runtimes.isEmpty {
                    Text(picker.selected.map { tr("onboarding", "step_runtime.hint_selected", ["name": OnboardingRuntimePicker.label($0)]) }
                         ?? tr("onboarding", "step_platform.cli_dialog_pick_hint"))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(tr("onboarding", "step_runtime.refresh"), action: onRefresh)
                Button(tr("onboarding", "common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action: onConnect) {
                    HStack(spacing: 6) {
                        if connecting { ProgressView().controlSize(.small) }
                        Text(tr("onboarding", "step_runtime.continue"))
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(picker.selected == nil || connecting)
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
    }
}

/// Two copy-and-run commands: the install script and `multica setup`
/// (upstream steps/cli-install-instructions.tsx).
struct OnboardingCLIInstructions: View {
    static let installCommands = [
        ("macosLinux", "curl -fsSL https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh | bash"),
        ("windows", "irm https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.ps1 | iex"),
    ]
    @State private var platform = "macosLinux"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("onboarding", "cli_install.intro")).font(Theme.Font.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. \(tr("onboarding", "cli_install.step1_label"))").font(Theme.Font.caption.weight(.medium))
                Picker(tr("onboarding", "cli_install.platform_group"), selection: $platform) {
                    Text(tr("onboarding", "cli_install.platform_macos_linux")).tag("macosLinux")
                    Text(tr("onboarding", "cli_install.platform_windows")).tag("windows")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                OnboardingCommandRow(command: Self.installCommands.first { $0.0 == platform }?.1 ?? "")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("2. \(tr("onboarding", "cli_install.step2_label"))").font(Theme.Font.caption.weight(.medium))
                OnboardingCommandRow(command: "multica setup")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }
}

private struct OnboardingCommandRow: View {
    let command: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
            Text(command).font(Theme.Font.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: command).buttonStyle(.borderless).help(tr("onboarding", "cli_install.copy_aria"))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

private struct OnboardingCLIWaiting: View {
    let elapsed: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RunningIndicator(count: 1)
                Text(tr("onboarding", "step_platform.live_listening")).font(Theme.Font.bodyMedium)
                Spacer()
                Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            stageText.font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }

    private var stageText: Text {
        let setup = Text("multica setup").font(.system(size: 11, design: .monospaced))
        let stage = elapsed < 15 ? "normal" : elapsed < 45 ? "midway" : elapsed < 90 ? "slow" : "stalled"
        if stage == "stalled" {
            return Text(tr("onboarding", "step_platform.stage_stalled_prefix"))
                + Text(tr("onboarding", "step_platform.stage_stalled_term")).fontWeight(.medium).foregroundColor(.primary)
                + Text(tr("onboarding", "step_platform.stage_stalled_suffix"))
        }
        return Text(tr("onboarding", "step_platform.stage_\(stage)_prefix")) + setup + Text(tr("onboarding", "step_platform.stage_\(stage)_suffix"))
    }
}

/// Interest capture for cloud runtimes; does not advance the flow
/// (upstream components/cloud-waitlist-expand.tsx).
private struct OnboardingCloudWaitlist: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster
    @State private var email = ""
    @State private var reason = ""
    @State private var submitting = false
    @State private var submitted = false

    private var canSubmit: Bool {
        !submitted && !submitting && email.trimmingCharacters(in: .whitespaces).range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil && reason.count <= 500
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            (Text(tr("onboarding", "cloud_waitlist.intro_main")) + Text(" ") + Text(tr("onboarding", "cloud_waitlist.intro_warning")).foregroundColor(.secondary))
                .font(Theme.Font.body).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("onboarding", "cloud_waitlist.email_label")).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                TextField(tr("onboarding", "cloud_waitlist.email_placeholder"), text: $email)
                    .textFieldStyle(.roundedBorder).disabled(submitted).onSubmit(submit)
            }
            VStack(alignment: .leading, spacing: 4) {
                (Text(tr("onboarding", "cloud_waitlist.reason_label")) + Text("  " + tr("onboarding", "cloud_waitlist.optional")).fontWeight(.regular))
                    .font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                TextField(tr("onboarding", "cloud_waitlist.reason_placeholder"), text: Binding(get: { reason }, set: { reason = String($0.prefix(500)) }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3...5).disabled(submitted)
            }
            HStack {
                Spacer()
                Button(action: submit) {
                    HStack(spacing: 6) {
                        if submitting { ProgressView().controlSize(.small) }
                        if submitted {
                            Image(systemName: "checkmark")
                            Text(tr("onboarding", "cloud_waitlist.on_list"))
                        } else {
                            Text(tr("onboarding", "cloud_waitlist.join"))
                            Image(systemName: "arrow.right")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }

    private func submit() {
        guard canSubmit else { return }
        submitting = true
        Task {
            defer { submitting = false }
            do {
                _ = try await env.app.api.joinCloudWaitlist(email: email.trimmingCharacters(in: .whitespaces), reason: reason.trimmingCharacters(in: .whitespaces))
                toaster.success(tr("onboarding", "cloud_waitlist.success_toast"))
                submitted = true
            } catch {
                let message = (error as? APIError)?.message ?? ""
                toaster.error(message.isEmpty ? tr("onboarding", "cloud_waitlist.failed_toast") : message)
            }
        }
    }
}
