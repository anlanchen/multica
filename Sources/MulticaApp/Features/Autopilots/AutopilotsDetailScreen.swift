import MulticaCore
import SwiftUI

private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
    tr("autopilots", key, args)
}

/// Autopilot detail (upstream autopilot-detail-page): properties, triggers,
/// webhook deliveries, run history and the danger zone.
struct AutopilotsDetailScreen: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let autopilotID: String
    @State private var model: AutopilotsDetailModel
    @State private var addTriggerOpen = false
    @State private var editOpen = false
    @State private var deleteOpen = false
    @State private var runPending = false
    @State private var fetchedProject: Project?
    @State private var projectMissing = false

    init(autopilotID: String) {
        self.autopilotID = autopilotID
        _model = State(initialValue: AutopilotsDetailModel(id: autopilotID))
    }

    var body: some View {
        Group {
            if model.isLoading && model.detail == nil {
                skeleton
            } else if let autopilot = model.autopilot {
                content(autopilot)
            } else {
                Text(t("detail.not_found")).font(Theme.Font.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: session.revision("autopilot")) { await model.load(session) }
        .tabTitle(model.autopilot?.title)
    }

    // MARK: Loading

    private var skeleton: some View {
        VStack(spacing: 0) {
            PageHeader {
                HStack(spacing: 8) {
                    AutopilotsSkeleton(width: 16, height: 16)
                    Text("/").foregroundStyle(.secondary)
                    AutopilotsSkeleton(width: 128, height: 16)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 16) {
                        AutopilotsSkeleton(width: 80)
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) { AutopilotsSkeleton(width: 48); AutopilotsSkeleton(width: 128, height: 20) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) { AutopilotsSkeleton(width: 48); AutopilotsSkeleton(width: 96, height: 20) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        AutopilotsSkeleton(width: 64, height: 16)
                        AutopilotsSkeleton(height: 40, cornerRadius: Theme.Radius.medium)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        AutopilotsSkeleton(width: 96, height: 16)
                        ForEach(0..<3, id: \.self) { _ in AutopilotsSkeleton(height: 40) }
                    }
                }
                .frame(maxWidth: 896, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Content

    private func content(_ autopilot: Autopilot) -> some View {
        let canWrite = autopilot.canWrite != false
        let canManageAccess = autopilot.canManageAccess ?? canWrite
        return VStack(spacing: 0) {
            header(autopilot, canWrite: canWrite)
            if autopilot.pauseReason == "agent_runtime_required" {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack").font(.system(size: 11))
                    Text(t("detail.paused_runtime_required")).frame(maxWidth: .infinity, alignment: .leading)
                    if autopilot.assigneeType == "agent" {
                        Button(t("detail.bind_runtime")) { nav.push(.agent(autopilot.assigneeId), query: ["view": "general"]) }
                            .buttonStyle(.link)
                            .fontWeight(.medium)
                    }
                }
                .font(Theme.Font.caption)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.1))
                .overlay(alignment: .bottom) { Rectangle().fill(Color.orange.opacity(0.3)).frame(height: 1) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    properties(autopilot)
                    triggersSection(canWrite: canWrite)
                    if model.triggers.contains(where: { $0.kind == "webhook" }) {
                        AutopilotsDeliveriesSection(autopilotID: autopilotID)
                    }
                    runsSection(autopilot)
                    if canWrite {
                        VStack(alignment: .leading, spacing: 12) {
                            Divider().padding(.bottom, 4)
                            AutopilotsSectionTitle(text: t("detail.section_danger"), destructive: true)
                            Button(role: .destructive) { deleteOpen = true } label: {
                                Label(t("detail.delete_button"), systemImage: "trash")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.destructive)
                            .controlSize(.small)
                        }
                    }
                }
                .frame(maxWidth: 896, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $addTriggerOpen) {
            AutopilotsAddTriggerSheet(autopilotID: autopilotID) { Task { await model.load(session) } }
        }
        .sheet(isPresented: $editOpen) {
            AutopilotsDialog(mode: .edit(model, canManageAccess: canManageAccess))
        }
        .sheet(isPresented: $deleteOpen) {
            AutopilotsConfirmSheet(
                title: t("detail.delete_dialog.title"),
                message: t("detail.delete_dialog.description", ["title": autopilot.title]),
                cancelLabel: t("detail.delete_dialog.cancel"),
                confirmLabel: t("detail.delete_dialog.confirm"),
                busyLabel: t("detail.delete_dialog.deleting")
            ) {
                do {
                    try await AutopilotsActions.delete([autopilot], session: session)
                    toaster.success(t("detail.toast_deleted"))
                    nav.push(.autopilots)
                    return true
                } catch {
                    toaster.error((error as? APIError)?.message ?? t("detail.toast_delete_failed"))
                    return false
                }
            }
        }
    }

    private func header(_ autopilot: Autopilot, canWrite: Bool) -> some View {
        PageHeader {
            HStack(spacing: 8) {
                Breadcrumb(parent: t("page.title"), parentRoute: .autopilots, title: autopilot.title)
                Toggle("", isOn: Binding(get: { autopilot.status == "active" }, set: { on in
                    Task { await setStatus(autopilot, on ? "active" : "paused") }
                }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(autopilot.status == "archived")
                .accessibilityLabel(autopilot.status == "active" ? t("detail.pause_aria") : t("detail.activate_aria"))
                Text(AutopilotsLabels.status(autopilot.status))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(autopilot.status == "active" ? Theme.success : autopilot.status == "paused" ? Color.orange : .secondary)
            }
        } trailing: {
            if canWrite {
                HStack(spacing: 6) {
                    Button { editOpen = true } label: { Label(t("detail.edit"), systemImage: "pencil") }
                    Button { Task { await runNow() } } label: {
                        HStack(spacing: 4) {
                            if runPending { ProgressView().controlSize(.mini) } else { Image(systemName: "play.fill") }
                            Text(runPending ? t("detail.running") : t("detail.run_now"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(autopilot.status != "active" || runPending)
                }
                .controlSize(.small)
            }
        }
    }

    private func properties(_ autopilot: Autopilot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            AutopilotsSectionTitle(text: t("detail.section_properties"))
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow {
                    property(t("detail.field_agent")) {
                        ActorAvatar(type: autopilot.assigneeType, id: autopilot.assigneeId, size: 20, showName: true)
                    }
                    property(t("detail.field_created_by")) {
                        ActorAvatar(type: autopilot.createdByType, id: autopilot.createdById, size: 20, showName: true)
                    }
                }
                GridRow {
                    property(t("detail.field_output_mode")) { Text(AutopilotsLabels.executionMode(autopilot.executionMode)) }
                    property(t("detail.field_project")) { projectValue(autopilot.projectId) }
                }
                if autopilot.executionMode == "create_issue" {
                    GridRow {
                        property(t("detail.field_subscribers")) { subscriberChips(autopilot.subscribers) }
                            .gridCellColumns(2)
                    }
                }
                if let prompt = autopilot.description, !prompt.isEmpty {
                    GridRow {
                        property(t("detail.field_prompt")) { MarkdownView(source: prompt) }
                            .gridCellColumns(2)
                    }
                }
            }
        }
        .font(Theme.Font.body)
        .task(id: autopilot.projectId) { await resolveProject(autopilot.projectId) }
    }

    private func property<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.Font.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func projectValue(_ projectID: String?) -> some View {
        if let projectID {
            if let project = session.projects.item(projectID) ?? fetchedProject.flatMap({ $0.id == projectID ? $0 : nil }) {
                Button { nav.push(.project(project.id), title: project.title) } label: {
                    HStack(spacing: 6) {
                        ProjectIconView(icon: project.icon, size: 18)
                        Text(project.title).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .autopilotsLinkCursor()
            } else if projectMissing {
                Text(t("detail.project_unavailable")).foregroundStyle(.secondary)
            } else {
                AutopilotsSkeleton(width: 128, height: 20)
            }
        } else {
            Text(t("detail.no_project")).foregroundStyle(.secondary)
        }
    }

    private func resolveProject(_ projectID: String?) async {
        projectMissing = false
        guard let projectID else { return }
        await session.projects.loadIfNeeded()
        guard session.projects.item(projectID) == nil else { return }
        if let p = try? await session.api.getProject(projectID) {
            fetchedProject = p
        } else {
            projectMissing = true
        }
    }

    @ViewBuilder
    private func subscriberChips(_ subscribers: [AutopilotSubscriber]?) -> some View {
        let members = (subscribers ?? []).filter { $0.userType == "member" }
        if members.isEmpty {
            Text(t("detail.field_subscribers_none")).foregroundStyle(.secondary)
        } else {
            AutopilotsFlowLayout(spacing: 6) {
                ForEach(members, id: \.userId) { s in
                    ActorAvatar(type: "member", id: s.userId, size: 14, showName: true, nameFont: Theme.Font.caption)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Capsule().strokeBorder(Theme.border))
                }
            }
        }
    }

    private func triggersSection(canWrite: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AutopilotsSectionTitle(text: t("detail.section_triggers"))
                Spacer()
                if canWrite {
                    Button { addTriggerOpen = true } label: { Label(t("detail.add_trigger"), systemImage: "plus") }
                        .controlSize(.small)
                }
            }
            if model.triggers.isEmpty {
                AutopilotsDashedBox { Text(t("detail.no_triggers")) }
            } else {
                VStack(spacing: 8) {
                    ForEach(model.triggers) { trigger in
                        AutopilotsTriggerRow(trigger: trigger, autopilotID: autopilotID, canWrite: canWrite) {
                            Task { await model.load(session) }
                        }
                    }
                }
            }
        }
    }

    private func runsSection(_ autopilot: Autopilot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AutopilotsSectionTitle(text: t("detail.section_run_history"))
            if model.runsLoading {
                VStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in AutopilotsSkeleton(height: 40) } }
            } else if model.runs.isEmpty {
                AutopilotsDashedBox { Text(t("detail.no_runs")) }
            } else {
                AutopilotsRunHistory(runs: model.runs, agentID: autopilot.assigneeId,
                                     agentName: session.actorInfo(type: autopilot.assigneeType, id: autopilot.assigneeId).name)
            }
        }
    }

    // MARK: Actions

    private func setStatus(_ autopilot: Autopilot, _ status: String) async {
        let previous = autopilot
        var optimistic = autopilot
        optimistic.status = status
        model.apply(optimistic, session: session)
        do {
            model.apply(try await session.api.updateAutopilot(autopilot.id, UpdateAutopilotRequest(status: status)), session: session)
        } catch {
            model.apply(previous, session: session)
            toaster.error(error)
        }
        await model.load(session)
    }

    /// Manual runs answer 200 even when admission blocks them, so the toast
    /// follows the run's status and reason code, not the HTTP status.
    private func runNow() async {
        runPending = true
        defer { runPending = false }
        do {
            let run = try await session.api.triggerAutopilot(autopilotID)
            let message = t("detail.\(AutopilotsRunNow.blockedKey(run.reasonCode))")
            switch AutopilotsRunNow.toastKind(run.status) {
            case .success: toaster.success(t("detail.toast_triggered"))
            case .warning: toaster.show(message, kind: .info)
            case .error: toaster.error(message)
            }
        } catch {
            if let reason = (error as? APIError)?.reasonCode, !reason.isEmpty {
                toaster.error(t("detail.\(AutopilotsRunNow.blockedKey(reason))"))
            } else {
                toaster.error(AutopilotsRunNow.clientErrorMessage(error) ?? t("detail.toast_trigger_failed"))
            }
        }
        await model.load(session)
    }
}
