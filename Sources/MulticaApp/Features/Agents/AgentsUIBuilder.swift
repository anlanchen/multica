import MulticaCore
import Observation
import SwiftUI

// MARK: - AI create (setup)

/// Pick the runtime + model the hidden builder agent runs on, or resume an
/// unfinished conversation (upstream ai-create-agent-page).
struct AgentsUIAICreatePage: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav

    @State private var draft = AgentsUI.Draft()
    @State private var starting = false
    @State private var error: String?

    var body: some View {
        let squad = nav.query("squad")
        let form = AgentsUICreateForm(session: session)
        let selected = form.selectedRuntime(draft)
        let hasOnline = !form.usableRuntimes.isEmpty
        AgentsUICreateShell(title: squad != nil ? tr("agents", "creation_studio.squad_title") : tr("agents", "creation_studio.title"),
                            step: tr("agents", "creation_studio.step_ai"),
                            onBack: { nav.agentsUIBack(or: .newAgent) }) {
            AgentsUICreateChip(text: tr("agents", "creation_studio.modes.ai.title"))
            if let selected { AgentsUICreateChip(text: AgentsUI.runtimeDisplayLabel(selected)) }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AgentsUIUnfinishedDrafts(sessions: session.agentsUIStore.builderSessions) { open($0, runtimeID: nil) }
                    VStack(alignment: .leading, spacing: 0) {
                        Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 18)).foregroundStyle(Theme.brand)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.brand.opacity(0.1)))
                        Text(tr("agents", "creation_studio.builder.setup_title")).font(.system(size: 20, weight: .semibold)).padding(.top, 20)
                        Text(tr("agents", "creation_studio.builder.setup_description")).font(Theme.Font.body).foregroundStyle(.secondary).padding(.top, 8)
                        VStack(spacing: 16) {
                            AgentsUICreateRuntimePicker(selectedID: draft.runtimeId) { id in
                                if id != draft.runtimeId { draft = draft.withRuntime(id) }
                            }
                            AgentsUIModelDropdown(runtimeID: selected?.id, runtimeOnline: selected?.status == "online", value: draft.model,
                                                  disabled: selected == nil) { draft = draft.withModel($0) }
                        }
                        .padding(.top, 24)
                        if let error {
                            Text(error).font(Theme.Font.body).foregroundStyle(Theme.destructive).padding(.top, 16)
                        }
                        HStack {
                            Spacer()
                            if hasOnline {
                                Button(action: start) {
                                    HStack(spacing: 6) {
                                        if starting { ProgressView().controlSize(.mini) }
                                        Text(tr("agents", "creation_studio.builder.start"))
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                                .disabled(starting || selected?.status != "online")
                            } else {
                                Button(tr("agents", "creation_studio.builder.connect_runtime")) { nav.push(.runtimes) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.top, 24)
                    }
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                    .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
                }
                .frame(maxWidth: 576)
                .padding(.horizontal, 20)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            async let r: Void = session.runtimeRecords.loadIfNeeded()
            async let b: Void = session.agentsUIStore.loadBuilderSessions()
            _ = await (r, b)
        }
    }

    private func open(_ sessionID: String, runtimeID: String?) {
        var q: [String: String] = [:]
        if let s = nav.query("squad") { q["squad"] = s }
        if let runtimeID { q["runtime"] = runtimeID }
        nav.replace(.newAgentAISession(sessionID), query: q)
    }

    private func start() {
        guard let rt = AgentsUICreateForm(session: session).selectedRuntime(draft), rt.status == "online" else { return }
        starting = true
        error = nil
        let model = draft.model.trimmingCharacters(in: .whitespaces)
        Task {
            defer { starting = false }
            do {
                let s = try await session.api.createAgentBuilderSession(runtimeId: rt.id, model: model.isEmpty ? nil : model)
                guard !s.sessionId.isEmpty else { error = tr("agents", "creation_studio.builder.start_failed"); return }
                open(s.sessionId, runtimeID: rt.id)
            } catch {
                self.error = (error as? APIError)?.message ?? tr("agents", "creation_studio.builder.start_failed")
            }
        }
    }
}

/// Resume banner for unfinished conversations: one opens directly, several
/// open a picker (upstream unfinished-drafts).
struct AgentsUIUnfinishedDrafts: View {
    let sessions: [AgentBuilderSessionSummary]
    let onResume: (String) -> Void
    @State private var picking = false

    var body: some View {
        if !sessions.isEmpty {
            Button {
                if sessions.count == 1 { onResume(sessions[0].sessionId) } else { picking = true }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left").foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                    Text(tr("agents", "creation_studio.drafts.banner", ["count": sessions.count])).font(Theme.Font.body)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $picking) { picker }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("agents", "creation_studio.drafts.title")).font(Theme.Font.title)
            Text(tr("agents", "creation_studio.drafts.pick_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(sessions, id: \.sessionId) { s in
                        Button {
                            picking = false
                            onResume(s.sessionId)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    let title = s.draft?.name.trimmingCharacters(in: .whitespaces) ?? ""
                                    Text(title.isEmpty ? tr("agents", "creation_studio.drafts.untitled") : title).font(Theme.Font.bodyMedium).lineLimit(1)
                                    Spacer()
                                    if !s.lastMessageAt.isEmpty {
                                        Text(Formatters.relative(s.lastMessageAt)).font(Theme.Font.micro).foregroundStyle(.secondary)
                                    }
                                }
                                Text(preview(s)).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 8)
                    }
                }
            }
            .frame(maxHeight: 384)
            HStack {
                Spacer()
                Button(tr("common", "cancel")) { picking = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func preview(_ s: AgentBuilderSessionSummary) -> String {
        guard !s.lastMessageContent.isEmpty else { return "" }
        return s.lastMessageRole == "user" ? AgentsUI.decodeBuilderInput(s.lastMessageContent) : AgentsUI.stripBuilderDraft(s.lastMessageContent)
    }
}

// MARK: - Builder conversation

/// Messages, pending task and draft sync for one builder conversation.
@MainActor
@Observable
final class AgentsUIBuilderModel {
    let sessionID: String
    private(set) var messages: [ChatMessage] = [] {
        didSet { updateLatestDraft() }
    }
    /// The newest assistant reply carrying an `<agent_draft>` block.
    private(set) var latestDraftID: String?
    @ObservationIgnored private(set) var latestDraftPayload: [String: JSONValue]?
    private(set) var messagesLoaded = false
    private(set) var missing = false
    private(set) var pendingTaskID: String?
    private(set) var switchingRuntime = false
    private(set) var closing = false
    var error: String?
    var restoreText: String?
    var restored = false
    @ObservationIgnored var appliedMessageID: String?
    @ObservationIgnored private var saved: AgentsUI.StoredDraft?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var pendingDraft: AgentsUI.StoredDraft?

    init(sessionID: String) { self.sessionID = sessionID }

    private func updateLatestDraft() {
        for m in messages.reversed() where m.role == "assistant" {
            if let payload = AgentsUI.parseBuilderDraft(m.content) {
                latestDraftPayload = payload
                if latestDraftID != m.id { latestDraftID = m.id }
                return
            }
        }
        latestDraftPayload = nil
        if latestDraftID != nil { latestDraftID = nil }
    }

    var pending: Bool { pendingTaskID != nil }

    func refresh(api: APIClient) async {
        async let m = api.listChatMessages(sessionId: sessionID)
        async let p = try? api.getPendingChatTask(sessionId: sessionID)
        do {
            let list = try await m
            if list != messages { messages = list }
            missing = false
        } catch {
            if (error as? APIError)?.status == 404 { missing = true }
        }
        messagesLoaded = true
        let task = await p
        pendingTaskID = (task?.taskId?.isEmpty == false) ? task?.taskId : nil
    }

    func checkRestores(api: APIClient) async {
        guard let list = try? await api.listChatDraftRestores(sessionId: sessionID), let latest = list.restores.last else { return }
        restoreText = AgentsUI.decodeBuilderInput(latest.content)
        try? await api.consumeChatDraftRestore(sessionId: sessionID, restoreId: latest.id)
    }

    func restore(from stored: AgentBuilderSessionSummary?, runtimeID: String, into draft: inout AgentsUI.Draft) {
        guard !restored else { return }
        if let s = stored?.draft {
            let d = AgentsUI.StoredDraft(s)
            appliedMessageID = d.appliedMessageId
            saved = d
            draft = d.draft(runtimeID: runtimeID)
        } else if !runtimeID.isEmpty {
            draft.runtimeId = runtimeID
        }
        restored = true
    }

    /// Debounced write-back of the configuration (armed only after restore).
    func scheduleSave(_ draft: AgentsUI.Draft, api: APIClient) {
        guard restored else { return }
        let next = AgentsUI.StoredDraft(draft, appliedMessageID: appliedMessageID)
        if next == saved { return }
        pendingDraft = next
        pendingSave?.cancel()
        pendingSave = Task { [sessionID] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self.saved = next
            self.pendingDraft = nil
            do { try await api.saveAgentBuilderDraft(sessionId: sessionID, draft: next.json) } catch { self.saved = nil }
        }
    }

    func flush(api: APIClient) {
        pendingSave?.cancel()
        guard let d = pendingDraft else { return }
        pendingDraft = nil
        saved = d
        let id = sessionID
        Task { try? await api.saveAgentBuilderDraft(sessionId: id, draft: d.json) }
    }

    func send(_ text: String, encoded: String, api: APIClient) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !pending, !switchingRuntime else { return false }
        error = nil
        do {
            let r = try await api.sendChatMessage(sessionId: sessionID, content: encoded)
            messages.append(ChatMessage(id: r.messageId, chatSessionId: sessionID, role: "user", content: encoded, taskId: r.taskId,
                                        createdAt: ISO8601DateFormatter().string(from: Date())))
            pendingTaskID = r.taskId
            return true
        } catch {
            self.error = (error as? APIError)?.message ?? tr("agents", "creation_studio.builder.send_failed")
            return false
        }
    }

    func stop(api: APIClient) async {
        guard let taskID = pendingTaskID else { return }
        pendingTaskID = nil
        do {
            let r = try await api.cancelTaskById(taskID)
            if let m = r.cancelledChatMessage {
                messages.removeAll { $0.id == m.messageId }
                if m.restoreToInput { restoreText = AgentsUI.decodeBuilderInput(m.content) }
            }
        } catch {
            self.error = (error as? APIError)?.message ?? tr("agents", "creation_studio.builder.stop_failed")
        }
        await refresh(api: api)
    }

    func switchRuntime(_ runtimeID: String, api: APIClient, toaster: Toaster) async -> String? {
        guard !switchingRuntime else { return nil }
        switchingRuntime = true
        error = nil
        defer { switchingRuntime = false }
        do {
            let r = try await api.switchAgentBuilderRuntime(sessionId: sessionID, runtimeId: runtimeID)
            toaster.success(tr("agents", "creation_studio.builder.switch_runtime_success"))
            return r.runtimeId.isEmpty ? runtimeID : r.runtimeId
        } catch {
            self.error = (error as? APIError)?.message ?? tr("agents", "creation_studio.builder.switch_runtime_failed")
            return nil
        }
    }

    func destroy(api: APIClient) async -> Bool {
        closing = true
        defer { closing = false }
        do {
            try await api.deleteChatSession(sessionID)
            return true
        } catch {
            self.error = (error as? APIError)?.message ?? tr("agents", "creation_studio.builder.stop_failed")
            return false
        }
    }
}

struct AgentsUIBuilderSessionPage: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let sessionID: String

    @State private var model: AgentsUIBuilderModel
    @State private var draft = AgentsUI.Draft()
    @State private var creating = false
    @State private var nameError: String?
    @State private var formError: String?
    @State private var confirmDiscard = false

    init(sessionID: String) {
        self.sessionID = sessionID
        _model = State(initialValue: AgentsUIBuilderModel(sessionID: sessionID))
    }

    private var store: AgentsUIStore { session.agentsUIStore }
    private var summary: AgentBuilderSessionSummary? { store.builderSessions.first { $0.sessionId == sessionID } }
    private var runtimeKnown: Bool { store.builderSessionsLoaded && !draft.runtimeId.isEmpty }

    var body: some View {
        let squad = nav.query("squad")
        let form = AgentsUICreateForm(session: session)
        let selected = form.selectedRuntime(draft)
        AgentsUICreateShell(title: squad != nil ? tr("agents", "creation_studio.squad_title") : tr("agents", "creation_studio.title"),
                            step: tr("agents", "creation_studio.step_ai"),
                            onBack: { nav.agentsUIBack(or: .newAgent) }) {
            AgentsUICreateChip(text: tr("agents", "creation_studio.modes.ai.title"))
            if let selected { AgentsUICreateChip(text: AgentsUI.runtimeDisplayLabel(selected)) }
        } content: {
            HSplitView {
                AgentsUIBuilderConversation(model: model, runtimeOnline: selected?.status == "online") { text in
                    await model.send(text, encoded: encode(text), api: session.api)
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tr("agents", "creation_studio.live_draft")).font(.system(size: 15, weight: .semibold))
                                if model.messages.isEmpty && model.messagesLoaded {
                                    Text(tr("agents", "creation_studio.live_draft_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                                }
                            }
                            AgentsUIConfigurationPanel(draft: $draft, nameError: nameError, compact: true, onNameChange: { nameError = nil },
                                                       onRuntimeSelect: { id in switchRuntime(id) },
                                                       runtimeSwitchPending: model.pending,
                                                       runtimeSwitchInFlight: model.switchingRuntime || !runtimeKnown)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                    }
                    AgentsUICreateFooter(canCreate: !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && form.ready(draft) && !creating && !model.pending,
                                         creating: creating, squad: squad != nil, error: formError, onCreate: create,
                                         onDiscard: { confirmDiscard = true }, discarding: model.closing)
                }
                .frame(minWidth: 340, idealWidth: 420, maxHeight: .infinity)
                .background(Color.primary.opacity(0.015))
            }
        }
        .task {
            async let r: Void = session.runtimeRecords.loadIfNeeded()
            async let s: Void = session.skills.loadIfNeeded()
            async let b: Void = store.loadBuilderSessions()
            _ = await (r, s, b)
            model.restore(from: summary, runtimeID: summary?.runtimeId.isEmpty == false ? summary!.runtimeId : (nav.query("runtime") ?? ""), into: &draft)
        }
        .task(id: session.revision("chat") &+ session.revision("task")) {
            if model.messagesLoaded {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            await model.refresh(api: session.api)
            if !model.pending { await model.checkRestores(api: session.api) }
        }
        .task(id: session.agentsUISyncKey) { session.agentsUISync() }
        .onChange(of: draft) { model.scheduleSave(draft, api: session.api) }
        .onChange(of: model.latestDraftID) { applyLatestDraft() }
        .onChange(of: model.restored) { applyLatestDraft() }
        .onChange(of: model.missing) { if model.missing { leave() } }
        .onDisappear { model.flush(api: session.api) }
        .alert(tr("agents", "creation_studio.drafts.discard_title"), isPresented: $confirmDiscard) {
            Button(tr("agents", "creation_studio.drafts.discard_cancel"), role: .cancel) {}
            Button(tr("agents", "creation_studio.drafts.discard"), role: .destructive) {
                Task {
                    if await model.destroy(api: session.api) {
                        await store.loadBuilderSessions()
                        leave()
                    }
                }
            }
        } message: {
            Text(tr("agents", "creation_studio.drafts.discard_confirm"))
        }
    }

    private func applyLatestDraft() {
        guard model.restored, let id = model.latestDraftID, id != model.appliedMessageID, let payload = model.latestDraftPayload else { return }
        model.appliedMessageID = id
        let validModels: Set<String>? = {
            guard let rt = session.runtimeRecords.item(draft.runtimeId), rt.status == "online",
                  case .loaded(let r) = store.modelsState(rt.id) else { return nil }
            return Set(r.supported ? r.models.map(\.id) : [])
        }()
        draft = AgentsUI.mergeBuilderDraft(draft, payload: payload, validSkillIDs: Set(session.skills.items.map(\.id)),
                                           validMemberIDs: Set(session.directory.members.map(\.userID)), validModelIDs: validModels)
    }

    private func encode(_ text: String) -> String {
        let rt = session.runtimeRecords.item(draft.runtimeId)
        let models: [RuntimeModel]? = {
            guard let rt, rt.status == "online", case .loaded(let r) = store.modelsState(rt.id) else { return nil }
            return r.supported ? r.models : []
        }()
        return AgentsUI.encodeBuilderInput(text, draft: draft, catalog: AgentsUI.BuilderCatalog(
            skills: session.skills.items.map { (id: $0.id, name: $0.name, description: $0.description) },
            members: session.directory.members.map { (id: $0.userID, name: $0.name) },
            runtime: rt.map { (id: $0.id, name: $0.name, provider: $0.provider) },
            models: models))
    }

    private func switchRuntime(_ id: String) {
        guard runtimeKnown, !id.isEmpty, id != draft.runtimeId else { return }
        Task {
            if let bound = await model.switchRuntime(id, api: session.api, toaster: toaster) {
                draft = draft.withRuntime(bound)
            }
        }
    }

    private func leave() {
        var q: [String: String] = [:]
        if let s = nav.query("squad") { q["squad"] = s }
        nav.replace(.newAgentAI, query: q)
    }

    private func create() {
        let runtimeID = draft.runtimeId
        guard !runtimeID.isEmpty, !creating else { return }
        creating = true
        nameError = nil
        formError = nil
        let api = session.api
        let id = sessionID
        Task {
            let errors = await AgentsUICreateSubmit.create(session: session, toaster: toaster, nav: nav, draft: draft, runtimeID: runtimeID,
                                                          squadID: nav.query("squad"), template: "agent_builder") { _ in
                _ = try? await api.setChatSessionArchived(id, archived: true)
                await store.loadBuilderSessions()
            }
            if let errors {
                nameError = errors.name
                formError = errors.form
                creating = false
            }
        }
    }
}

/// The builder chat column: transcript, live reply, prompt chips, composer.
struct AgentsUIBuilderConversation: View {
    @Environment(WorkspaceSession.self) private var session
    let model: AgentsUIBuilderModel
    let runtimeOnline: Bool
    let onSend: (String) async -> Bool

    @State private var composer = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("agents", "creation_studio.builder.chat_title")).font(.system(size: 13, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    AgentsUIRuntimeDot(online: runtimeOnline, size: 7)
                    Text(runtimeOnline ? tr("agents", "creation_studio.builder.runtime_online") : tr("agents", "creation_studio.builder.runtime_offline"))
                }
                .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 56)
            .overlay(alignment: .bottom) { Divider() }
            if !model.messagesLoaded {
                LoadingView()
            } else if model.messages.isEmpty && !model.pending {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.messages, id: \.id) { m in AgentsUIBuilderMessageRow(message: m).equatable() }
                        if let taskID = model.pendingTaskID {
                            AgentsUIBuilderLiveReply(taskID: taskID)
                        }
                    }
                    .padding(20)
                }
                .defaultScrollAnchor(.bottom)
            }
            if let error = model.error {
                Text(error).font(Theme.Font.body).foregroundStyle(Theme.destructive)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.destructive.opacity(0.06)))
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            composerView
        }
        .onChange(of: model.restoreText) {
            if let text = model.restoreText {
                if composer.isEmpty { composer = text }
                model.restoreText = nil
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(tr("agents", "creation_studio.builder.empty_title")).font(.system(size: 15, weight: .semibold))
            Text(tr("agents", "creation_studio.builder.empty_description")).font(Theme.Font.body).foregroundStyle(.secondary)
            AgentsUIFlowLayout(spacing: 8) {
                ForEach(["prompt_review", "prompt_research", "prompt_assistant"], id: \.self) { key in
                    let prompt = tr("agents", "creation_studio.builder.\(key)")
                    Button(prompt) { Task { _ = await onSend(prompt) } }
                        .buttonStyle(.plain)
                        .font(Theme.Font.caption)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Capsule().strokeBorder(Theme.border))
                        .disabled(!runtimeOnline)
                }
            }
            .frame(maxWidth: 480)
            .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composerView: some View {
        HStack(alignment: .bottom, spacing: 8) {
            MarkdownEditor(text: $composer, placeholder: tr("agents", "creation_studio.builder.placeholder"), minHeight: 36, maxHeight: 200,
                           isEditable: runtimeOnline, onSubmit: send)
            if model.pending {
                Button { Task { await model.stop(api: session.api) } } label: { Image(systemName: "stop.circle.fill").font(.system(size: 22)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !runtimeOnline ? Color.secondary : Theme.brand)
                    .disabled(composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !runtimeOnline)
                    .help(tr("agents", "creation_studio.builder.send"))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.14)))
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .opacity(runtimeOnline ? 1 : 0.6)
    }

    private func send() {
        let text = composer
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.pending else { return }
        Task {
            if await onSend(text) { composer = "" }
        }
    }
}

/// One message: user prompts decoded from the envelope, replies without the
/// draft block, rendered as Markdown.
struct AgentsUIBuilderMessageRow: View, Equatable {
    let message: ChatMessage

    static func == (a: Self, b: Self) -> Bool { a.message == b.message }

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 48)
                Text(AgentsUI.decodeBuilderInput(message.content))
                    .font(Theme.Font.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.brand.opacity(0.1)))
            }
        } else {
            let text = AgentsUI.stripBuilderDraft(message.content)
            VStack(alignment: .leading, spacing: 4) {
                if !text.isEmpty { MarkdownView(source: text) }
                if let reason = message.failureReason, !reason.isEmpty {
                    Text(AgentsUI.failureLabel(reason).map { label -> String in
                        switch label {
                        case .key(let k): return tr("agents", "task_failure.reasons.\(k)")
                        case .raw(let r): return r
                        }
                    } ?? reason).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The streaming reply of the pending task, with the draft block hidden.
struct AgentsUIBuilderLiveReply: View {
    @Environment(WorkspaceSession.self) private var session
    let taskID: String

    var body: some View {
        let transcript = session.transcript(taskID: taskID)
        let text = AgentsUI.stripBuilderDraft(transcript.steps.filter { $0.kind == .text }
            .map { transcript.displayText(for: $0, limit: 20000).text }.joined(separator: "\n\n"))
        VStack(alignment: .leading, spacing: 6) {
            if !text.isEmpty { MarkdownView(source: text) }
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(tr("agents", "creation_studio.builder.thinking")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { session.watchTranscript(transcript) }
        .onDisappear { session.unwatchTranscript(transcript) }
    }
}
