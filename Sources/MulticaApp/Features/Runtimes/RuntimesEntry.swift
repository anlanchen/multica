import MulticaCore
import SwiftUI

/// Inputs that machine grouping derives from; compared (not hashed) so the
/// grouping reruns only when one of them changed.
struct RuntimesMachineInputs: Equatable {
    var runtimes: [RuntimeDeviceRecord]
    var agents: [AgentRecord]
    var tasks: [AgentTask]
    var local: RuntimesLocalContext
    var userID: String
    var tick: Int
}

extension RuntimesMachineInputs {
    func build() -> [RuntimesMachine] {
        RuntimesKit.buildMachines(runtimes, options: RuntimesMachineOptions(
            now: Date(), localDaemonID: local.daemonID, localMachineName: local.machineName, currentUserID: userID,
            workloadByRuntimeID: RuntimesKit.workloadIndex(agents: agents, tasks: tasks), ensureLocalMachine: true))
    }
}

/// Loads everything the runtimes routes share and keeps it live.
struct RuntimesLiveData: ViewModifier {
    @Environment(WorkspaceSession.self) private var session

    func body(content: Content) -> some View {
        let store = session.runtimesStore
        content
            .task {
                async let runtimes: Void = session.runtimeRecords.loadIfNeeded()
                async let profiles: Void = store.profiles.loadIfNeeded()
                async let agents: Void = session.agentRecords.loadIfNeeded()
                async let members: Void = session.memberRecords.loadIfNeeded()
                async let tasks: Void = store.loadTasksIfNeeded()
                _ = await (runtimes, profiles, agents, members, tasks)
            }
            .onChange(of: session.revision("daemon")) {
                Task {
                    await session.runtimeRecords.load()
                    await store.profiles.load()
                }
            }
            .onChange(of: session.revision("runtime")) {
                Task { await session.runtimeRecords.load() }
            }
            .onChange(of: session.directory.revision) { store.scheduleTasksRefresh() }
    }
}

struct RuntimesPage: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @State private var showConnect = false
    @State private var showCloud = false
    @State private var tick = 0
    @State private var machines: [RuntimesMachine] = []
    @State private var computed = false

    private var cloudRuntimeEnabled: Bool {
        ProcessInfo.processInfo.environment["MULTICA_CLOUD_RUNTIME_ENABLED"] == "true"
            || UserDefaults.standard.bool(forKey: "multica.cloudRuntimeEnabled")
    }

    var body: some View {
        let store = session.runtimesStore
        let local = env.runtimesLocalContext
        let inputs = RuntimesMachineInputs(runtimes: session.runtimeRecords.items, agents: session.agentRecords.items,
                                           tasks: store.tasks, local: local, userID: session.currentUser.id, tick: tick)
        let loading = !(session.runtimeRecords.isLoaded || session.runtimeRecords.error != nil)
            || !(store.profiles.isLoaded || store.profiles.error != nil) || !computed
        VStack(spacing: 0) {
            RuntimesCollectionHeader(icon: "server.rack", title: tr("runtimes", "page.title"), count: machines.count,
                                     description: tr("runtimes", "page.tagline"),
                                     learnMore: (tr("runtimes", "page.learn_more"), RuntimesDocs.daemonRuntimes())) {
                if cloudRuntimeEnabled {
                    Button { showCloud = true } label: { Label(tr("runtimes", "cloud_runtime.action"), systemImage: "cloud") }
                }
                Button { showConnect = true } label: { Label(tr("runtimes", "page.connect_remote"), systemImage: "plus") }
            }
            if loading {
                RuntimesListSkeleton()
            } else {
                content(local: local, orphans: orphanRuntimes(store.profiles.items))
            }
        }
        .modifier(RuntimesLiveData())
        .modifier(RuntimesNowTick(tick: $tick))
        .task(id: inputs) {
            machines = inputs.build()
            computed = true
        }
        .sheet(isPresented: $showConnect) { RuntimesConnectRemoteDialog() }
        .sheet(isPresented: $showCloud) { RuntimesCloudRuntimeDialog() }
        .tabTitle(tr("runtimes", "page.title"))
    }

    /// Custom profiles with no local machine to register on (web only;
    /// desktop always has a local machine).
    private func orphanRuntimes(_ profiles: [RuntimeProfile]) -> [RuntimeDeviceRecord] {
        guard !machines.contains(where: { $0.mode == "local" }) else { return [] }
        return profiles.map {
            RuntimesKit.pendingRuntime(profile: $0, createdAt: Timestamp.parse($0.createdAt) ?? Date(timeIntervalSince1970: 0),
                                       fallbackMachineName: "Unassigned")
        }
    }

    @ViewBuilder
    private func content(local: RuntimesLocalContext, orphans: [RuntimeDeviceRecord]) -> some View {
        if machines.isEmpty && orphans.isEmpty && !local.bootstrapping {
            RuntimesStateView(icon: "server.rack", title: tr("runtimes", "page.empty.title"), message: tr("runtimes", "page.empty.hint")) {
                Button { showConnect = true } label: { Label(tr("runtimes", "page.connect_remote"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    RuntimesMikaSetupCard()
                    if !machines.isEmpty || local.bootstrapping {
                        RuntimesMachineList(machines: machines, bootstrapping: local.bootstrapping)
                    }
                    if !orphans.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("runtimes", "profiles.unassigned_title")).font(Theme.Font.bodyMedium)
                            Text(tr("runtimes", "profiles.unassigned_description")).font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, machines.isEmpty ? 0 : 24)
                        .padding(.bottom, 12)
                        RuntimesCard { RuntimesRuntimeList(runtimes: orphans, tick: tick) }
                    }
                }
                .pageContent(maxWidth: 1180)
            }
        }
    }
}

private struct RuntimesMachineList: View {
    let machines: [RuntimesMachine]
    let bootstrapping: Bool

    var body: some View {
        if machines.isEmpty {
            RuntimesStateView(icon: "server.rack",
                              title: tr("runtimes", bootstrapping ? "page.bootstrapping.title" : "page.empty.title"),
                              message: tr("runtimes", bootstrapping ? "page.bootstrapping.hint" : "page.empty.hint"))
        } else {
            RuntimesCard {
                LazyVStack(spacing: 0) {
                    ForEach(Array(machines.enumerated()), id: \.element.id) { index, machine in
                        if index > 0 { Divider() }
                        RuntimesMachineRow(machine: machine).equatable()
                    }
                }
            }
        }
    }
}

private struct RuntimesMachineRow: View, Equatable {
    @Environment(Navigator.self) private var nav
    let machine: RuntimesMachine
    @State private var hovering = false

    static func == (a: RuntimesMachineRow, b: RuntimesMachineRow) -> Bool { a.machine == b.machine }

    var body: some View {
        Button { nav.push(.runtime(machine.id), title: machine.title) } label: {
            HStack(spacing: 12) {
                Image(systemName: machine.section == .cloud ? "cloud" : "desktopcomputer")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    .overlay(alignment: .bottomTrailing) {
                        RuntimesHealthDot(health: machine.health)
                            .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: 2).frame(width: 12, height: 12))
                            .offset(x: 2, y: 2)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(machine.title).font(Theme.Font.bodyMedium).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(machine.subtitle ?? tr("runtimes", machine.section == .cloud ? "machine.metrics.cloud_worker" : "machine.metrics.local_daemon"))
                            .lineLimit(1)
                        if machine.isCurrent { RuntimesTag(text: tr("runtimes", "machine.this_machine")) }
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ViewThatFits(in: .horizontal) {
                    columns(workload: true, lastSeen: true)
                    columns(workload: false, lastSeen: true)
                    columns(workload: false, lastSeen: false)
                    EmptyView()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? .secondary : .tertiary)
                    .offset(x: hovering ? 2 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .background(hovering ? Theme.hover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button(tr("common", "navigation.open_in_new_tab")) { nav.openInNewTab(.runtime(machine.id), title: machine.title) }
        }
    }

    private func columns(workload: Bool, lastSeen: Bool) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                RuntimesHealthIcon(health: machine.health)
                Text(machine.health.label)
            }
            .font(Theme.Font.caption)
            .frame(width: 136, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("runtimes", "machine.runtime_count", ["count": machine.runtimes.count]))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                RuntimesProviderStack(providers: machine.providerNames)
            }
            .frame(width: 150, alignment: .leading)
            if workload {
                Text(machine.busyCount > 0
                     ? tr("runtimes", "machine.metrics.workload_hint", ["running": machine.runningCount, "queued": machine.queuedCount])
                     : tr("runtimes", "machine.metrics.workload_idle"))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                    .frame(width: 136, alignment: .leading)
            }
            if lastSeen {
                Group {
                    if let seen = machine.lastSeenAt { RelativeTime(timestamp: seen) } else { Text("—") }
                }
                .font(Theme.Font.caption).foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            }
        }
        .fixedSize()
    }
}

struct RuntimesListSkeleton: View {
    var body: some View {
        RuntimesCard {
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { i in
                    if i > 0 { Divider() }
                    HStack(spacing: 12) {
                        RuntimesSkeleton(width: 40, height: 40, radius: 8)
                        VStack(alignment: .leading, spacing: 8) {
                            RuntimesSkeleton(width: 176, height: 14)
                            RuntimesSkeleton(width: 112, height: 10)
                        }
                        Spacer()
                        RuntimesSkeleton(width: 96, height: 14)
                        RuntimesSkeleton(width: 112, height: 14)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 76)
                }
            }
        }
        .pageContent(maxWidth: 1180)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: Mika

/// "Your runtime is ready. Start with Mika." — shown until this member has
/// a kicked-off Mika conversation.
private struct RuntimesMikaSetupCard: View {
    @Environment(WorkspaceSession.self) private var session
    @State private var open = false

    var body: some View {
        let agents = session.agentRecords
        let chats = session.chatSessions
        let show = agents.isLoaded && chats.isLoaded && !session.runtimeRecords.items.isEmpty
            && RuntimesKit.memberNeedsMikaSetup(agents: agents.items, sessions: chats.items)
        Group {
            if show {
                HStack(spacing: 16) {
                    Text("🦄")
                        .font(.system(size: 20))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(RuntimesPalette.muted))
                        .accessibilityLabel(tr("runtimes", "mika_setup.title"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("runtimes", "mika_setup.title")).font(Theme.Font.bodyMedium)
                        Text(tr("runtimes", "mika_setup.description")).font(Theme.Font.body).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(tr("runtimes", "mika_setup.action")) { open = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 12).fill(RuntimesPalette.card))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                .padding(.bottom, 24)
                .sheet(isPresented: $open) { RuntimesMikaDialog() }
            }
        }
        .task { await session.chatSessions.loadIfNeeded() }
    }
}

private struct RuntimesMikaDialog: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    @State private var runtimeID = ""
    @State private var model = ""
    @State private var pending = false

    var body: some View {
        let runtimes = session.runtimeRecords.items
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("runtimes", "mika_setup.dialog_title")).font(Theme.Font.title)
            RuntimesRuntimePicker(runtimes: runtimes, selection: $runtimeID)
                .disabled(pending)
                .onChange(of: runtimeID) { model = "" }
            RuntimesModelPicker(runtime: runtimes.first { $0.id == runtimeID }, model: $model)
                .disabled(runtimeID.isEmpty || pending)
            HStack {
                Spacer()
                Button(tr("runtimes", "mika_setup.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(pending)
                Button {
                    Task { await start() }
                } label: {
                    HStack(spacing: 6) {
                        if pending { ProgressView().controlSize(.small) }
                        Text(tr("runtimes", "mika_setup.action"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(runtimeID.isEmpty || pending)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if runtimeID.isEmpty {
                runtimeID = runtimes.first { $0.status == "online" }?.id ?? runtimes.first?.id ?? ""
            }
        }
    }

    private func start() async {
        pending = true
        defer { pending = false }
        let language = RuntimesKit.mikaContentLanguage(L10n.shared.language)
        let slug = session.workspace.slug
        do {
            let agent = try await session.api.createMikaAgent(runtimeId: runtimeID, language: language, model: model.isEmpty ? nil : model,
                                                              sessionTitle: RuntimesKit.mikaChatTitle(L10n.shared.language), workspaceSlug: slug)
            guard let chat = agent.onboardingSession else { throw APIError(status: 0, message: "Mika onboarding session was not returned") }
            _ = try await session.api.startMikaOnboarding(sessionId: chat.id, language: language, workspaceSlug: slug)
            Task {
                await session.agentRecords.load()
                await session.chatSessions.load()
            }
            dismiss()
            nav.push(.chat, query: ["session": chat.id])
        } catch {
            let message = (error as? APIError)?.message ?? error.localizedDescription
            toaster.error(message.isEmpty ? tr("runtimes", "mika_setup.failed") : message)
        }
    }
}

/// Runtime selector (upstream agents `RuntimePicker`, reduced to a menu).
struct RuntimesRuntimePicker: View {
    @Environment(WorkspaceSession.self) private var session
    let runtimes: [RuntimeDeviceRecord]
    @Binding var selection: String

    var body: some View {
        Picker(tr("agents", "inspector.prop_runtime"), selection: $selection) {
            if runtimes.isEmpty { Text(tr("agents", "pickers.runtime_empty")).tag("") }
            ForEach(runtimes) { r in
                let usable = RuntimesKit.isUsable(r, by: session.currentUser.id)
                Text("\(RuntimesKit.displayLabel(r)) · \(tr("agents", r.status == "online" ? "pickers.runtime_online" : "pickers.runtime_offline"))")
                    .tag(r.id)
                    .selectionDisabled(!usable)
            }
        }
    }
}

/// Model selector backed by daemon model discovery (upstream agents
/// `ModelDropdown`): discovered models, provider default, or a typed id.
struct RuntimesModelPicker: View {
    @Environment(WorkspaceSession.self) private var session
    let runtime: RuntimeDeviceRecord?
    @Binding var model: String
    @State private var models: [RuntimeModel] = []
    @State private var supported = true
    @State private var discovering = false
    @State private var failed = false
    @State private var custom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("agents", "model_dropdown.label")).font(Theme.Font.caption).foregroundStyle(.secondary)
            if runtime == nil {
                Text(tr("agents", "model_dropdown.select_runtime_first")).font(Theme.Font.body).foregroundStyle(.secondary)
            } else if !supported {
                Text(tr("agents", "model_dropdown.managed_by_runtime_title")).font(Theme.Font.body).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Menu {
                        Button(tr("agents", "model_dropdown.default_provider")) { model = "" }
                        if !models.isEmpty { Divider() }
                        ForEach(models) { m in
                            Button(m.label.isEmpty ? m.id : m.label) { model = m.id }
                        }
                    } label: {
                        Text(model.isEmpty ? tr("agents", "model_dropdown.default_provider") : model).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    if discovering { ProgressView().controlSize(.small) }
                }
                TextField(tr("agents", "pickers.model_search_placeholder"), text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !custom.trimmingCharacters(in: .whitespaces).isEmpty { model = custom.trimmingCharacters(in: .whitespaces) } }
                if failed {
                    Text(runtime?.status == "online" ? tr("agents", "pickers.model_discovery_failed_hint") : tr("agents", "model_dropdown.runtime_offline_manual"))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: runtime?.id) { await discover() }
    }

    private func discover() async {
        models = []
        supported = true
        failed = false
        guard let runtime, runtime.status == "online" else {
            failed = runtime != nil
            return
        }
        discovering = true
        defer { discovering = false }
        do {
            var request = try await session.api.initiateListModels(runtime.id)
            let deadline = Date().addingTimeInterval(100)
            while request.status == "pending" || request.status == "running" {
                guard Date() < deadline, !Task.isCancelled else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(500))
                request = try await session.api.getListModelsResult(runtime.id, requestId: request.id)
            }
            supported = request.supported
            models = request.models ?? []
            failed = request.status != "completed"
        } catch {
            failed = true
        }
    }
}
