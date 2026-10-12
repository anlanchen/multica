import AppKit
import MulticaCore
import SwiftUI
import UniformTypeIdentifiers

/// The conversation pane shared by the chat tab and the floating window:
/// transcript (or skeleton / empty state), the banner slot, the queue and
/// the composer.
struct ChatUIConversationBody: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    let surface: ChatUISurface
    var leftAdornment: AnyView? = nil
    var focusOnAppear = false
    var onProjectChange: ((String?) -> Void)? = nil

    var body: some View {
        let store = session.chatUI
        let ctx = store.context
        let active = store.activeSessionID
        let conv = active.map { store.conversation($0) }
        GeometryReader { g in
            VStack(spacing: 0) {
                if let conv, !conv.messagesLoaded || !conv.pendingLoaded {
                    ChatUIMessageSkeleton()
                } else if let conv, conv.hasContent {
                    ChatUIMessageList(conversation: conv, surface: surface, quickActionsDisabled: quickActionsDisabled(conv, ctx))
                        .id(conv.id)
                } else {
                    ChatUIEmptyState(
                        agent: ctx.activeAgent,
                        hasSessions: !session.chatSessions.items.isEmpty,
                        canCustomize: ctx.canEditActiveAgent && ctx.activeAgent?.archivedAt == nil && env.appConfig?.agentConversationStartersSupported == true,
                        onPick: { store.prefillStarter($0) }
                    )
                }
                ChatUIBannerSlot(context: ctx, surface: surface)
                if let conv {
                    ChatUIQueue(conversation: conv, sendNowDisabled: ctx.isAgentAccessRevoked)
                }
                ChatUIComposer(surface: surface, focusOnAppear: focusOnAppear, leftAdornment: leftAdornment, onProjectChange: onProjectChange)
                    .zIndex(1)
            }
            .environment(\.chatUIGutter, ChatUILayout.gutter(forWidth: g.size.width))
        }
        .task(id: active) {
            guard let active else { return }
            store.view(active)
            await ChatUIUntilCancelled.wait()
            store.leave(active)
        }
        .onChange(of: conv?.quickActionsFailure) { _, n in
            if (n ?? 0) > 0 { store.toast?(tr("chat", "message_list.quick_actions_regenerate_failed"), true) }
        }
    }

    private func quickActionsDisabled(_ c: ChatUIConversation, _ ctx: ChatUIContext) -> Bool {
        c.pendingTaskID != nil || ctx.isSessionArchived || ctx.isAgentArchived || ctx.isAgentAccessRevoked || !ctx.isAgentRuntimeBound || ctx.noAgent
    }
}

// MARK: Composer

/// The chat input (upstream ChatInput): per-session drafts, uploads, the
/// project-context chip and "+" menu, ⌘↩ send, and one action slot that is
/// Send, Queue (while a queue-capable run is live) or Stop.
struct ChatUIComposer: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    @Environment(ShortcutStore.self) private var shortcuts
    let surface: ChatUISurface
    var focusOnAppear = false
    var leftAdornment: AnyView? = nil
    var onProjectChange: ((String?) -> Void)? = nil
    @State private var submitting = false
    @State private var editorGeneration = 0
    @State private var dropTargeted = false
    @State private var projectPickerOpen = false

    var body: some View {
        let store = session.chatUI
        let ctx = store.context
        let key = store.activeSessionID ?? ChatUIStore.draftNewSession
        let pending = store.activeSessionID.map { store.conversation($0).pending }
        let isRunning = pending?.taskId != nil
        let allowQueue = pending?.supportsQueue == true
        let text = store.draft(key)
        let hasNothing = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let uploading = (store.uploadsInFlight[key] ?? 0) > 0
        let disabled = ctx.inputDisabled
        let noAgent = ctx.noAgent
        let uploadEnabled = ctx.activeAgent != nil && !ctx.isAgentAccessRevoked && !disabled && !noAgent
        let projectEnabled = !disabled && !noAgent && !submitting && !ctx.isProjectUpdating
        let selectedProject = ctx.activeProjectID.flatMap { session.projects.item($0) }

        VStack(alignment: .leading, spacing: 0) {
            if let selectedProject {
                projectChip(selectedProject, enabled: projectEnabled, unsupported: ctx.projectContextUnsupported)
            }
            MarkdownEditor(
                text: Binding(get: { store.draft(key) }, set: { store.setDraft(key, $0) }),
                placeholder: placeholder(ctx, disabled: disabled),
                minHeight: 36,
                maxHeight: 280,
                autofocus: editorGeneration > 0,
                isEditable: !submitting && !noAgent,
                onSubmit: { submit(key: key) },
                onFiles: uploadEnabled ? { upload($0, key: key) } : nil,
                mentions: { mentions($0) }
            )
            .id(editorGeneration)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            HStack(spacing: 4) {
                if uploadEnabled || projectEnabled {
                    addMenu(uploadEnabled: uploadEnabled, projectEnabled: projectEnabled, selected: ctx.activeProjectID, unsupported: ctx.projectContextUnsupported, key: key)
                }
                if let leftAdornment { leftAdornment }
                Spacer(minLength: 4)
                actionButton(
                    showStop: isRunning && (!allowQueue || hasNothing || uploading),
                    isRunning: isRunning,
                    canSend: !(hasNothing || submitting || disabled || noAgent),
                    uploading: uploading,
                    key: key
                )
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
        .overlay {
            if dropTargeted && uploadEnabled {
                RoundedRectangle(cornerRadius: Theme.Radius.large)
                    .strokeBorder(Theme.brand.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Theme.brand.opacity(0.02)))
                    .allowsHitTesting(false)
            }
        }
        .opacity(noAgent ? 0.6 : 1)
        .allowsHitTesting(!noAgent)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard uploadEnabled else { return false }
            loadFileURLs(providers) { upload($0, key: key) }
            return true
        }
        .chatUIColumn()
        .padding(.bottom, 12)
        .onAppear {
            if focusOnAppear { editorGeneration += 1 }
            store.applyRestoreIfPossible(draftKey: key)
        }
        .onChange(of: store.focusRequest) { editorGeneration += 1 }
        .onChange(of: store.restoreRequest) { store.applyRestoreIfPossible(draftKey: key) }
        .onChange(of: key) { store.applyRestoreIfPossible(draftKey: key) }
        .onChange(of: hasNothing) { _, empty in if empty { store.applyRestoreIfPossible(draftKey: key) } }
        .onChange(of: uploading) { _, busy in if !busy { store.applyRestoreIfPossible(draftKey: key) } }
        .onChange(of: store.starterRequest) { store.consumeStarter(draftKey: key) }
    }

    private func placeholder(_ ctx: ChatUIContext, disabled: Bool) -> String {
        if ctx.isAgentAccessRevoked { return tr("chat", "input.placeholder_access_revoked") }
        if ctx.noAgent { return tr("chat", "input.placeholder_no_agent") }
        if disabled {
            if ctx.isAgentArchived { return tr("chat", "input.placeholder_archived_agent") }
            if !ctx.isAgentRuntimeBound { return tr("chat", "input.placeholder_runtime_required") }
            return tr("chat", "input.placeholder_archived")
        }
        if let name = ctx.activeAgent?.name { return tr("chat", "input.placeholder_named", ["name": name]) }
        return tr("chat", "input.placeholder_default")
    }

    // MARK: Actions

    private func changeProject(_ id: String?) {
        if let onProjectChange { onProjectChange(id) } else { session.chatUI.changeProject(id) }
    }

    private func submit(key: String) {
        let store = session.chatUI
        let ctx = store.context
        guard !submitting else { return }
        let content = store.draft(key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, (store.uploadsInFlight[key] ?? 0) == 0 else { return }
        let pending = store.activeSessionID.map { store.conversation($0).pending }
        if ctx.inputDisabled || ctx.noAgent || (pending?.taskId != nil && pending?.supportsQueue != true) { return }
        let active = (store.draftAttachments[key] ?? []).filter { ChatUIText.isReferenced($0.attachment, in: content) }
        submitting = true
        Task {
            await store.send(content, attachmentIDs: active.map(\.id), attachments: active, draftKey: key, surface: surface)
            submitting = false
        }
    }

    private func upload(_ urls: [URL], key: String) {
        let store = session.chatUI
        for url in urls {
            store.uploadStarted(key)
            Task {
                do {
                    let a = try await session.upload(fileAt: url)
                    store.uploadFinished(key, attachment: a, markdown: AttachmentUpload.markdown(for: a))
                } catch {
                    store.uploadFailed(key)
                    toaster.error(error)
                }
            }
        }
    }

    private func pickFiles(key: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in upload(urls, key: key) }
        }
    }

    private func loadFileURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in done([url]) }
            }
        }
    }

    /// The tab mentions people, agents and issues; the floating window leads
    /// with the issue/project on screen and recently visited ones.
    private func mentions(_ query: String) -> [MentionCandidate] {
        let search = session.mentionCandidates(query, includeIssues: true)
        guard surface == .floating else { return search }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let context = contextItems().filter { q.isEmpty || $0.label.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false) }
        guard !q.isEmpty else { return context }
        let seen = Set(context.map { "\($0.type):\($0.id)" })
        return context + search.filter { !seen.contains("\($0.type):\($0.id)") }
    }

    private func contextItems() -> [MentionCandidate] {
        var out: [MentionCandidate] = []
        var seen = Set<String>()
        func add(_ route: AppRoute) {
            switch route {
            case .issue(let id):
                guard seen.insert("issue:\(id)").inserted, let issue = session.issues.model(id)?.issue else { return }
                out.append(MentionCandidate(type: "issue", id: issue.id, label: issue.identifier, subtitle: issue.title))
            case .project(let id):
                guard seen.insert("project:\(id)").inserted, let p = session.projects.item(id) else { return }
                out.append(MentionCandidate(type: "project", id: p.id, label: p.title, subtitle: p.description))
            default:
                break
            }
        }
        add(nav.route)
        if nav.route == .inbox, let issue = nav.query("issue") { add(.issue(issue)) }
        for loc in env.tabs.activeGroup?.browsingHistory ?? [] where out.count < 9 { add(loc.route) }
        return out
    }

    // MARK: Pieces

    private func projectChip(_ project: Project, enabled: Bool, unsupported: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button { projectPickerOpen = true } label: {
                    HStack(spacing: 4) {
                        ProjectIconView(icon: project.icon, size: 13)
                        Text(project.title).lineLimit(1)
                    }
                    .font(Theme.Font.caption.weight(.medium))
                    .padding(.leading, 8)
                }
                .buttonStyle(.plain)
                .help(tr("chat", "input.change_project_context"))
                .popover(isPresented: $projectPickerOpen) {
                    OptionList(
                        options: session.projects.items.map { p in PickerOption(id: p.id, title: p.title, icon: AnyView(ProjectIconView(icon: p.icon, size: 14))) },
                        selected: [project.id],
                        searchPlaceholder: tr("projects", "picker.search_placeholder")
                    ) { id in
                        projectPickerOpen = false
                        changeProject(id)
                    }
                }
                Button { changeProject(nil) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tr("chat", "input.remove_project_context"))
                .accessibilityLabel(tr("chat", "input.remove_project_context"))
            }
            .frame(height: 24)
            .background(Capsule().fill(Color.primary.opacity(0.04)))
            .overlay(Capsule().strokeBorder(Theme.border))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.6)
            if unsupported {
                Label(tr("chat", "input.project_context_unsupported"), systemImage: "exclamationmark.triangle")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.warning)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func addMenu(uploadEnabled: Bool, projectEnabled: Bool, selected: String?, unsupported: Bool, key: String) -> some View {
        Menu {
            if uploadEnabled {
                Button { pickFiles(key: key) } label: { Label(tr("chat", "input.upload_file"), systemImage: "photo") }
            }
            if projectEnabled {
                Menu {
                    ForEach(session.projects.items) { p in
                        Button { changeProject(p.id) } label: {
                            if p.id == selected {
                                Label(p.title, systemImage: "checkmark")
                            } else {
                                Text([p.icon ?? "", p.title].filter { !$0.isEmpty }.joined(separator: " "))
                            }
                        }
                    }
                    if session.projects.items.isEmpty {
                        Text(tr("chat", "input.no_projects"))
                    }
                    if selected != nil {
                        Divider()
                        Button { changeProject(nil) } label: { Label(tr("chat", "input.remove_project_context"), systemImage: "xmark") }
                    }
                    if unsupported {
                        Divider()
                        Text(tr("chat", "input.project_context_unsupported"))
                    }
                } label: {
                    Label(tr("chat", "input.project_context"), systemImage: "folder")
                }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 26)
        .help(tr("chat", "input.add_tooltip"))
        .accessibilityLabel(tr("chat", "input.add_tooltip"))
    }

    @ViewBuilder
    private func actionButton(showStop: Bool, isRunning: Bool, canSend: Bool, uploading: Bool, key: String) -> some View {
        let store = session.chatUI
        if showStop {
            Button { store.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.75)))
            }
            .buttonStyle(.plain)
            .help(tr("chat", "input.stop_tooltip"))
            .accessibilityLabel(tr("chat", "input.stop_tooltip"))
        } else {
            let tooltip: String = {
                if uploading { return tr("editor", "upload.in_progress") }
                if isRunning { return tr("chat", "input.queue_send_tooltip") }
                if let chord = shortcuts.chord(for: .send) { return "\(tr("chat", "input.send_tooltip")) · \(chord.display.joined())" }
                return tr("chat", "input.send_tooltip")
            }()
            Button { submit(key: key) } label: {
                ZStack {
                    Circle().fill(canSend && !uploading ? Theme.brand : Color.primary.opacity(0.12))
                    if submitting || uploading {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Image(systemName: isRunning ? "text.append" : "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(canSend ? Color.white : Color.secondary)
                    }
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(!canSend || uploading)
            .help(tooltip)
            .accessibilityLabel(tooltip)
        }
    }
}

// MARK: Queue

/// Follow-ups waiting behind the running reply, tucked under the composer
/// (upstream ChatQueue): steer, remove, edit, clear all.
struct ChatUIQueue: View {
    @Environment(WorkspaceSession.self) private var session
    let conversation: ChatUIConversation
    let sendNowDisabled: Bool
    @State private var busy: String?

    var body: some View {
        let tasks = conversation.pending.queuedTasks ?? []
        if !tasks.isEmpty {
            let head = conversation.pending.status
            let dispatchable = head == "dispatched" || head == "running" || head == "waiting_local_directory"
            let canSendNow = !sendNowDisabled && dispatchable
            let steerLabel = tr("chat", canSendNow ? "queue.steer" : (sendNowDisabled ? "queue.steer_no_permission" : "queue.steer_unavailable"))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tasks, id: \.taskId) { task in
                        row(task, canSendNow: canSendNow, steerLabel: steerLabel)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 16)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
            .padding(.horizontal, 12)
            .chatUIColumn()
            .padding(.bottom, -12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityLabel(tr("chat", "queue.title", ["count": tasks.count]))
        }
    }

    private func row(_ task: ChatQueuedTask, canSendNow: Bool, steerLabel: String) -> some View {
        let store = session.chatUI
        let content = task.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HStack(spacing: 8) {
            Image(systemName: "text.line.last.and.arrowtriangle.forward").font(.system(size: 11)).foregroundStyle(.tertiary)
            Text(content.isEmpty ? tr("chat", "queue.fallback") : content)
                .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Button { run("send:\(task.taskId)") { await store.sendQueuedNow(task.taskId) } } label: {
                HStack(spacing: 3) {
                    if busy == "send:\(task.taskId)" { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.turn.down.right") }
                    Text(tr("chat", "queue.steer"))
                }
                .font(Theme.Font.caption)
            }
            .buttonStyle(.borderless)
            .disabled(busy != nil || !canSendNow)
            .help(steerLabel)
            .accessibilityLabel(steerLabel)
            Button { run("remove:\(task.taskId)") { await store.removeQueued(task.taskId) } } label: {
                if busy == "remove:\(task.taskId)" { ProgressView().controlSize(.mini) } else { Image(systemName: "trash").font(.system(size: 11)) }
            }
            .buttonStyle(.borderless)
            .disabled(busy != nil)
            .help(tr("chat", "queue.remove"))
            .accessibilityLabel(tr("chat", "queue.remove"))
            Menu {
                Button { run("edit:\(task.taskId)") { await store.editQueued(task.taskId) } } label: { Label(tr("chat", "queue.edit"), systemImage: "pencil") }
                Divider()
                Button(role: .destructive) { run("clear:\(task.taskId)") { await store.clearQueued() } } label: { Label(tr("chat", "queue.clear"), systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy != nil)
            .help(tr("chat", "queue.more"))
        }
        .foregroundStyle(.secondary)
        .frame(minHeight: 28)
    }

    private func run(_ key: String, _ action: @escaping () async -> Void) {
        busy = key
        Task {
            await action()
            if busy == key { busy = nil }
        }
    }
}
