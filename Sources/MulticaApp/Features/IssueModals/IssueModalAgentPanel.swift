import AppKit
import MulticaCore
import SwiftUI

/// Agent-mode body of the create dialog (upstream AgentCreatePanel): an
/// agent or squad files the issue from a free-text prompt.
struct IssueModalAgentPanel: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let store: IssueModalDraftStore
    let opener: CreateIssueDraft
    let context: IssueModalCreateContext?
    let carry: IssueModalCarry
    let source: IssueModalSourceContext?
    @Binding var expanded: Bool
    let onClose: () -> Void
    let onSwitchMode: (IssueModalCarry) -> Void
    let onLimitReached: () -> Void

    enum Field: String { case project, priority, dueDate = "due_date" }

    @State private var actor: ActorRef?
    @State private var projectID: String?
    @State private var priority: IssuePriority = .none
    @State private var dueDate: String?
    @State private var fieldPickerOpen: Field?
    @State private var hasContent = false
    @State private var justSent = false
    @State private var sentCount = 0
    @State private var error: String?
    @State private var submitting = false
    @State private var settings = IssueModalCreateSettings()
    @State private var seeded = false
    @State private var formResetKey = 0
    @State private var target = IssueModalEditorTarget()

    private var visibleAgents: [AgentRecord] {
        let userID = session.currentUser.id
        let role = session.issueModalRole
        return session.agentRecords.items.filter {
            $0.archivedAt == nil && IssueModalAgentAccess.isRuntimeBound($0) && IssueModalAgentAccess.denial($0, userID: userID, role: role) == nil
        }
    }

    private func visibleSquads(_ agents: [AgentRecord]) -> [Squad] {
        let ids = Set(agents.map(\.id))
        return session.squads.items.filter { $0.archivedAt == nil && ids.contains($0.leaderId) }
    }

    private func resolve(_ type: String?, _ id: String?, agents: [AgentRecord], squads: [Squad]) -> ActorRef? {
        guard let type, let id else { return nil }
        if type == "squad", squads.contains(where: { $0.id == id }) { return ActorRef(type: "squad", id: id) }
        if type == "agent", agents.contains(where: { $0.id == id }) { return ActorRef(type: "agent", id: id) }
        return nil
    }

    /// Opener seed, then the unfinished draft, the last successful pick, and
    /// finally the first visible agent.
    private func seedActor(agents: [AgentRecord], squads: [Squad]) -> ActorRef? {
        resolve("agent", context?.agentID, agents: agents, squads: squads)
            ?? resolve("squad", context?.squadID, agents: agents, squads: squads)
            ?? resolve(store.draft.agent.actorType, store.draft.agent.actorID, agents: agents, squads: squads)
            ?? resolve(store.lastActorType, store.lastActorID, agents: agents, squads: squads)
            ?? agents.first.map { ActorRef(type: "agent", id: $0.id) }
    }

    var body: some View {
        let agents = visibleAgents
        let squads = visibleSquads(agents)
        let selectedAgent: AgentRecord? = {
            guard let actor else { return nil }
            if actor.type == "agent" { return agents.first { $0.id == actor.id } }
            guard let squad = squads.first(where: { $0.id == actor.id }) else { return nil }
            return agents.first { $0.id == squad.leaderId }
        }()
        let selectedSquad = actor?.type == "squad" ? squads.first { $0.id == actor?.id } : nil
        let gate = versionGate(selectedAgent)
        VStack(spacing: 0) {
            IssueModalCreateHeader(breadcrumb: tr("modals", "create_issue.agent_breadcrumb"), expanded: $expanded, onClose: onClose)
            IssueModalActorPicker(actor: actor, agents: agents, squads: squads, selectedAgent: selectedAgent, selectedSquad: selectedSquad) { next in
                actor = next
                store.update { $0.agent.actorType = next.type; $0.agent.actorID = next.id }
                error = nil
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .padding(.bottom, 8)
            if selectedAgent != nil, gate.blocked {
                Text(gate.check.state == .missing
                     ? tr("modals", "create_issue.agent.version_missing", ["min": gate.check.min])
                     : tr("modals", "create_issue.agent.version_below", ["current": gate.check.current, "min": gate.check.min]))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Color(light: 0xB45309, dark: 0xFCD34D))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.orange.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.orange.opacity(0.3)))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            editor
                .padding(.horizontal, 15)
                .padding(.bottom, 8)
            IssueModalUploadChips(store: store)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            if let source {
                IssueModalSourceContextCard(source: source)
                    .frame(maxHeight: source.expanded ? 300 : nil)
            }
            if let error {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            toolbar
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            Divider()
            IssueModalAgentFooter(store: store, hasContent: hasContent, hasActor: actor != nil, submitting: submitting,
                                  blocked: gate.blocked, minVersion: gate.check.min, justSent: justSent, sentCount: sentCount,
                                  sourceUnavailable: source != nil && source?.usablePreview == nil,
                                  onUpload: upload, onSwitch: switchToManual, onSubmit: submit)
        }
        .onAppear { seed(agents: agents, squads: squads) }
        .onChange(of: agents.map(\.id) + squads.map(\.id)) {
            if let actor, resolve(actor.type, actor.id, agents: agents, squads: squads) != nil { return }
            actor = seedActor(agents: agents, squads: squads)
        }
        .onChange(of: session.projects.isLoaded) { sweepStaleProject() }
        .onExitCommand(perform: onClose)
        .task {
            async let a: Void = session.agentRecords.loadIfNeeded()
            async let s: Void = session.squads.loadIfNeeded()
            async let r: Void = session.runtimeRecords.loadIfNeeded()
            async let p: Void = session.projects.loadIfNeeded()
            _ = await (a, s, r, p)
            sweepStaleProject()
        }
    }

    @ViewBuilder
    private var editor: some View {
        let placeholder = source != nil ? tr("modals", "create_issue.agent.source_context_prompt_placeholder") : tr("modals", "create_issue.agent.prompt_placeholder")
        if expanded || source != nil {
            GeometryReader { geo in
                IssueModalBodyEditor(store: store, mode: .agent, placeholder: placeholder, target: target,
                                     minHeight: geo.size.height, maxHeight: geo.size.height, autofocus: true,
                                     initialText: context?.prompt, onContent: { if hasContent != $0 { hasContent = $0 } },
                                     onSubmit: submit, onFiles: upload)
                    .id(formResetKey)
            }
            .frame(minHeight: 140)
        } else {
            IssueModalBodyEditor(store: store, mode: .agent, placeholder: placeholder, target: target,
                                 minHeight: 140, maxHeight: max(200, (NSApp.mainWindow?.frame.height ?? 860) * 0.45), autofocus: true,
                                 initialText: context?.prompt, onContent: { if hasContent != $0 { hasContent = $0 } },
                                 onSubmit: submit, onFiles: upload)
                .id(formResetKey)
        }
    }

    // MARK: Version gate

    private struct Gate {
        var check: IssueModalCLIVersion.Check
        var blocked: Bool
    }

    /// Pre-checks the daemon CLI only when its runtime row is visible; an
    /// invisible runtime defers to the server's authoritative gate (#7633).
    private func versionGate(_ agent: AgentRecord?) -> Gate {
        let runtime = agent.flatMap { a in a.runtimeId.isEmpty ? nil : session.runtimeRecords.item(a.runtimeId) }
        let version = IssueModalCLIVersion.runtimeCLIVersion(runtime?.metadata)
        let base = IssueModalCLIVersion.check(version, minimum: IssueModalCLIVersion.minQuickCreate)
        let fields = IssueModalCLIVersion.check(version, minimum: IssueModalCLIVersion.minQuickCreateFields)
        let explicit = priority != .none || dueDate != nil
        let canPrecheck = runtime != nil
        let blocked = canPrecheck && (base.state != .ok || (explicit && fields.state != .ok))
        return Gate(check: explicit ? fields : base, blocked: blocked)
    }

    // MARK: Toolbar

    private func fieldBinding(_ f: Field) -> Binding<Bool> {
        Binding(get: { fieldPickerOpen == f }, set: { open in
            if open { fieldPickerOpen = f } else if fieldPickerOpen == f { fieldPickerOpen = nil }
        })
    }

    private var toolbar: some View {
        IssueModalFlowLayout(spacing: 6, lineSpacing: 6) {
            if settings.quickFields.contains("project") || projectID != nil || fieldPickerOpen == .project {
                IssueModalPill(isPresented: fieldBinding(.project), onClear: projectID == nil ? nil : { setProject(nil) },
                               clearLabel: tr("projects", "picker.clear_aria")) {
                    if let p = projectID.flatMap({ session.projects.item($0) }) {
                        ProjectIconView(icon: p.icon, size: 13)
                        Text(p.title).lineLimit(1)
                    } else {
                        ProjectIconView(icon: nil, size: 13)
                        IssueModalPlaceholder(text: tr("projects", "picker.no_project"))
                    }
                } content: { dismiss in
                    IssueModalProjectMenu(currentID: projectID) { setProject($0); dismiss() }
                }
            }
            if settings.quickFields.contains("priority") || priority != .none || fieldPickerOpen == .priority {
                IssueModalPill(isPresented: fieldBinding(.priority)) {
                    PriorityIcon(priority: priority, size: 13)
                    Text(priority.localizedName).lineLimit(1)
                } content: { dismiss in
                    IssueModalPriorityMenu(current: priority) { setPriority($0); dismiss() }
                }
            }
            if settings.quickFields.contains("due_date") || dueDate != nil || fieldPickerOpen == .dueDate {
                IssueModalPill(isPresented: fieldBinding(.dueDate)) {
                    Image(systemName: "calendar").foregroundStyle(.secondary)
                    if let dueDate {
                        Text(IssueModalDates.short(dueDate)).foregroundStyle(IssueModalDates.isPast(dueDate) ? Theme.destructive : .primary)
                    } else {
                        IssueModalPlaceholder(text: tr("issues", "pickers.due_date.trigger_label"))
                    }
                } content: { dismiss in
                    IssueModalDateMenu(value: dueDate, emptyLabel: tr("issues", "pickers.due_date.none")) { setDueDate($0); dismiss() }
                }
            }
            Menu {
                if !settings.quickFields.contains("project") && projectID == nil {
                    Button { fieldPickerOpen = .project } label: { Label(tr("modals", "create_issue.agent.set_project"), systemImage: "folder") }
                }
                if !settings.quickFields.contains("priority") && priority == .none {
                    Button { fieldPickerOpen = .priority } label: { Label(tr("modals", "create_issue.agent.set_priority"), systemImage: "minus") }
                }
                if !settings.quickFields.contains("due_date") && dueDate == nil {
                    Button { fieldPickerOpen = .dueDate } label: { Label(tr("modals", "create_issue.agent.set_due_date"), systemImage: "calendar") }
                }
                Divider()
                Button {
                    IssueModalNavigation.openFieldSettings(nav, close: onClose)
                } label: {
                    Label(tr("modals", "create_issue.agent.customize_fields"), systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(height: 24)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14)))
            .help(tr("modals", "create_issue.agent.more_fields_aria"))
            .accessibilityLabel(tr("modals", "create_issue.agent.more_fields_aria"))
            if carry.parentIssueID != nil {
                let text = tr("modals", "create_issue.agent.sub_issue_of", ["identifier": carry.parentIdentifier ?? ""])
                Text(text)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .help(text)
                    .fixedSize()
            }
        }
    }

    // MARK: State

    private func seed(agents: [AgentRecord], squads: [Squad]) {
        guard !seeded else { return }
        seeded = true
        let d = store.draft
        projectID = opener.projectID ?? d.shared.projectID
        priority = opener.priority ?? IssuePriority(rawValue: d.shared.priority) ?? .none
        dueDate = opener.dueDate ?? d.shared.dueDate
        actor = seedActor(agents: agents, squads: squads)
        settings = IssueModalCreateSettings.load(workspaceID: session.workspace.id)
        store.update { $0.activeMode = "agent" }
    }

    private func setProject(_ v: String?) { projectID = v; store.update { $0.shared.projectID = v } }
    private func setPriority(_ v: IssuePriority) { priority = v; store.update { $0.shared.priority = v.rawValue } }
    private func setDueDate(_ v: String?) { dueDate = v; store.update { $0.shared.dueDate = v } }

    /// A project deleted elsewhere is dropped from local state and the draft.
    private func sweepStaleProject() {
        guard session.projects.isLoaded, let id = projectID, session.projects.item(id) == nil else { return }
        projectID = nil
        if store.draft.shared.projectID == id { store.update { $0.shared.projectID = nil } }
    }

    private func upload(_ urls: [URL]) {
        IssueModalUploads.upload(urls, session: session, store: store, mode: .agent, target: target, toaster: toaster)
    }

    private func switchToManual() {
        guard !IssueModalUploadGate.uploading(store) else { return }
        let a = actor
        store.update { d in
            d.shared.projectID = projectID
            d.shared.priority = priority.rawValue
            d.shared.dueDate = dueDate
            if d.manual.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !d.agent.prompt.isEmpty {
                d.manual.description = d.agent.prompt
            }
            if d.manual.assigneeID == nil, let a {
                d.manual.assigneeType = a.type
                d.manual.assigneeID = a.id
            }
            d.activeMode = "manual"
        }
        onSwitchMode(carry)
    }

    // MARK: Submit

    private func submit() {
        let agents = visibleAgents
        let selectedAgent: AgentRecord? = actor.flatMap { a in
            if a.type == "agent" { return agents.first { $0.id == a.id } }
            return visibleSquads(agents).first { $0.id == a.id }.flatMap { s in agents.first { $0.id == s.leaderId } }
        }
        let gate = versionGate(selectedAgent)
        guard let actor, !gate.blocked, !(source != nil && source?.usablePreview == nil) else { return }
        let prompt = store.draft.agent.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !submitting, !IssueModalUploadGate.uploading(store) else { return }
        submitting = true
        error = nil
        let generation = store.generation
        let attachmentIDs = store.draft.shared.attachments.filter { $0.isReferenced(in: prompt) }.compactMap(\.attachmentID)
        let minVersion = gate.check.min
        Task {
            await perform(actor: actor, prompt: prompt, attachmentIDs: attachmentIDs, generation: generation, minVersion: minVersion)
            submitting = false
        }
    }

    private func perform(actor: ActorRef, prompt: String, attachmentIDs: [String], generation: Int, minVersion: String) async {
        let api = session.api
        do {
            if let source, let preview = source.usablePreview {
                var quick: [String: JSONValue] = ["prompt": .string(prompt)]
                quick[actor.type == "agent" ? "agent_id" : "squad_id"] = .string(actor.id)
                if let projectID { quick["project_id"] = .string(projectID) }
                if priority != .none { quick["priority"] = .string(priority.rawValue) }
                if let dueDate { quick["due_date"] = .string(dueDate) }
                if !attachmentIDs.isEmpty { quick["attachment_ids"] = JSONValue(attachmentIDs) }
                _ = try await api.createCommentSubIssue(anchorCommentId: source.anchorCommentID,
                                                        agent: CreateCommentSubIssueAgentRequest(mode: "agent", captureToken: preview.captureToken, quickCreate: .object(quick)))
            } else {
                _ = try await api.quickCreateIssue(prompt: prompt,
                                                   agentId: actor.type == "agent" ? actor.id : nil,
                                                   squadId: actor.type == "squad" ? actor.id : nil,
                                                   priority: priority != .none ? priority.rawValue : nil,
                                                   dueDate: dueDate, projectId: projectID, parentIssueId: carry.parentIssueID,
                                                   attachmentIds: attachmentIDs.isEmpty ? nil : attachmentIDs)
            }
            store.setLastActor(type: actor.type, id: actor.id)
            IssueModalPending.setLastMode(.agent)
            toaster.success(tr("modals", "create_issue.agent.toast_sent"))
            accepted(generation: generation)
        } catch {
            await handle(error, minVersion: minVersion)
        }
    }

    private func accepted(generation: Int) {
        let untouched = store.generation == generation
        if untouched { store.clearDraft() }
        guard untouched else { return }
        if store.keepOpen {
            hasContent = false
            formResetKey += 1
            sentCount += 1
            justSent = true
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                justSent = false
            }
        } else {
            onClose()
        }
    }

    private func handle(_ e: Error, minVersion: String) async {
        let code = source != nil ? session.issueModalSourceCode(e) : IssueModalErrors.code(e)
        let body = IssueModalErrors.body(e)
        switch code {
        case "issue_limit_reached":
            onLimitReached()
            return
        case "agent_unavailable":
            error = body?["reason"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? tr("modals", "create_issue.agent.error_agent_unavailable_fallback")
            return
        case "daemon_version_unsupported":
            let current = body?["current_version"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            let min = body?["min_version"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? minVersion
            error = tr("modals", "create_issue.agent.error_daemon_version", ["current": current, "min": min])
            return
        default:
            break
        }
        if let source {
            switch code {
            case "source_context_changed", "anchor_comment_deleted", "source_issue_deleted":
                await source.load(session.api)
                error = IssueModalSourceContext.failureMessage(e) ?? tr("issues", "source_context.error_source_changed")
                return
            case "source_context_quick_create_unsupported":
                error = tr("issues", "source_context.error_agent_unsupported")
                return
            case "source_context_server_unsupported":
                error = tr("issues", "source_context.error_server_unsupported")
                return
            case "source_context_too_large":
                error = IssueModalSourceContext.failureMessage(e) ?? tr("issues", "source_context.error_too_large")
                return
            default:
                break
            }
        }
        error = IssueModalErrors.message(e, fallback: tr("modals", "create_issue.agent.error_unknown"))
    }
}

/// Footer: attach, sent counter, switch to manual, keep-open, Create.
private struct IssueModalAgentFooter: View {
    let store: IssueModalDraftStore
    let hasContent: Bool
    let hasActor: Bool
    let submitting: Bool
    let blocked: Bool
    let minVersion: String
    let justSent: Bool
    let sentCount: Int
    let sourceUnavailable: Bool
    let onUpload: ([URL]) -> Void
    let onSwitch: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        let uploading = IssueModalUploadGate.uploading(store)
        let disabled = !hasContent || !hasActor || submitting || blocked || uploading || sourceUnavailable
        HStack(spacing: 8) {
            IssueModalAttachButton(onFiles: onUpload)
            if store.keepOpen && sentCount > 0 {
                Text(tr("modals", "create_issue.agent.sent_count", ["count": sentCount]))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.success)
            }
            Spacer(minLength: 8)
            Button(action: onSwitch) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right")
                    Text(tr("modals", "create_issue.switch_to_manual"))
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: Theme.Radius.small)
            .disabled(uploading)
            .help(tr("modals", "create_issue.switch_to_manual_tooltip"))
            IssueModalKeepOpenToggle(store: store)
            Button(action: onSubmit) {
                HStack(spacing: 6) {
                    if submitting {
                        Text(tr("modals", "create_issue.agent.sending"))
                    } else if uploading {
                        Text(tr("modals", "create_issue.agent.uploading"))
                    } else if justSent {
                        Image(systemName: "checkmark")
                        Text(tr("modals", "create_issue.agent.sent_label"))
                    } else {
                        Text(tr("modals", "create_issue.agent.submit"))
                        IssueModalSendKeyCaps()
                    }
                }
                .frame(minWidth: 88)
            }
            .buttonStyle(IssueModalPrimaryButtonStyle(tint: justSent ? Theme.success : Theme.brand))
            .modifier(IssueModalSendShortcut())
            .disabled(disabled)
            .help(blocked ? tr("modals", "create_issue.agent.version_blocked_tooltip", ["min": minVersion]) : "")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// "Created by" trigger with a searchable list of agents and squads
/// (upstream ActorPicker). A squad pick routes to its leader agent.
private struct IssueModalActorPicker: View {
    let actor: ActorRef?
    let agents: [AgentRecord]
    let squads: [Squad]
    let selectedAgent: AgentRecord?
    let selectedSquad: Squad?
    let onPick: (ActorRef) -> Void
    @State private var open = false

    var body: some View {
        HStack {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Text(tr("modals", "create_issue.agent.created_by")).foregroundStyle(.secondary)
                    if let s = selectedSquad {
                        HStack(spacing: 6) {
                            AvatarView(name: s.name, url: s.avatarUrl, kind: .squad, size: 16)
                            Text(s.name)
                        }
                    } else if let a = selectedAgent {
                        HStack(spacing: 6) {
                            AvatarView(name: a.name, url: a.avatarUrl, kind: .agent, size: 16)
                            Text(a.name)
                        }
                    } else {
                        Text(tr("modals", "create_issue.agent.pick_an_agent")).foregroundStyle(.secondary)
                    }
                }
                .font(Theme.Font.caption)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("modals", "create_issue.agent.select_agent_aria"))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                if agents.isEmpty && squads.isEmpty {
                    Text(tr("modals", "create_issue.agent.no_agents"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(width: 256, alignment: .leading)
                } else {
                    IssueModalOptionList(
                        options: agents.map { a in
                            IssueModalOption(id: "agent:\(a.id)", title: a.name, group: tr("modals", "create_issue.agent.agents_group"),
                                             leading: AnyView(AvatarView(name: a.name, url: a.avatarUrl, kind: .agent, size: 16)))
                        } + squads.map { s in
                            IssueModalOption(id: "squad:\(s.id)", title: s.name, group: tr("modals", "create_issue.agent.squads_group"),
                                             leading: AnyView(AvatarView(name: s.name, url: s.avatarUrl, kind: .squad, size: 16)))
                        },
                        selected: [actor.map { "\($0.type):\($0.id)" } ?? ""],
                        searchPlaceholder: tr("modals", "create_issue.agent.search_placeholder")
                    ) { key in
                        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                        guard parts.count == 2 else { return }
                        onPick(ActorRef(type: parts[0], id: parts[1]))
                        open = false
                    }
                }
            }
            Spacer()
        }
    }
}
