import AppKit
import MulticaCore
import SwiftUI

/// Upstream `project-detail.tsx`: the project's issues with a resizable
/// properties sidebar.
struct ProjectDetailPage: View {
    let projectID: String
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(ShellState.self) private var shell
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster
    @State private var loading = true
    @State private var confirmDelete = false
    @AppStorage("multica.projectDetail.sidebarWidth") private var sidebarWidth: Double = 320

    var body: some View {
        Group {
            if let project = session.projects.item(projectID) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        header(project)
                        IssueCollectionView(scope: .project(projectID))
                    }
                    .frame(minWidth: 360)
                    if shell.rightPanelOpen {
                        ProjectsResizeHandle(width: $sidebarWidth, range: 260...420)
                        ProjectsDetailSidebar(project: project)
                            .frame(width: sidebarWidth)
                            .transition(.move(edge: .trailing))
                    }
                }
                .tabTitle(project.title)
                .projectsDeleteConfirmation(isPresented: $confirmDelete) { delete(project) }
            } else if loading {
                ProjectsDetailSkeleton()
            } else {
                Text(tr("projects", "detail.not_found"))
                    .font(Theme.Font.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: projectID) {
            loading = session.projects.item(projectID) == nil
            async let pins: Void = session.pins.loadIfNeeded()
            _ = try? await session.projectsFetch(projectID)
            _ = await pins
            loading = false
        }
    }

    private func header(_ project: Project) -> some View {
        let pinned = session.projectsIsPinned(project.id)
        return PageHeader {
            Breadcrumb(parent: tr("projects", "detail.breadcrumb_fallback"), parentRoute: .projects, title: project.title)
        } trailing: {
            Button {
                Task {
                    do { try await session.projectsSetPinned(project.id, !pinned) } catch { toaster.error(error) }
                }
            } label: {
                Image(systemName: pinned ? "pin.slash" : "pin").foregroundStyle(pinned ? .primary : .secondary)
            }
            .buttonStyle(.borderless)
            .help(pinned ? tr("projects", "detail.unpin_tooltip") : tr("projects", "detail.pin_tooltip"))
            Menu {
                Button {
                    let url = nav.webURL(.project(project.id), appURL: env.app.config.appURL)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    toaster.success(tr("projects", "detail.toast_link_copied"))
                } label: { Label(tr("projects", "detail.copy_link"), systemImage: "link") }
                if session.projectsIsWorkspaceAdmin {
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label(tr("projects", "detail.delete_action"), systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button {
                withAnimation(.snappy(duration: 0.2)) { shell.rightPanelOpen.toggle() }
            } label: {
                Image(systemName: "sidebar.right").foregroundStyle(shell.rightPanelOpen ? .primary : .secondary)
            }
            .buttonStyle(.borderless)
            .help(tr("projects", "detail.sidebar_tooltip"))
        }
    }

    private func delete(_ project: Project) {
        Task {
            do {
                try await session.projectsDelete(project.id)
                toaster.success(tr("projects", "detail.toast_project_deleted"))
                nav.push(.projects)
            } catch {
                toaster.error(error)
            }
        }
    }
}

/// Vertical drag handle between the page and a right sidebar.
struct ProjectsResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                let base = start ?? width
                                if start == nil { start = width }
                                width = min(range.upperBound, max(range.lowerBound, base - v.translation.width))
                            }
                            .onEnded { _ in start = nil }
                    )
            }
    }
}

private struct ProjectsDetailSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 4).frame(width: 128, height: 20)
            RoundedRectangle(cornerRadius: 4).frame(width: 256, height: 32)
            RoundedRectangle(cornerRadius: 4).frame(maxWidth: 384).frame(height: 16)
            RoundedRectangle(cornerRadius: 6).frame(height: 160).padding(.top, 32)
        }
        .foregroundStyle(Color.primary.opacity(0.06))
        .frame(maxWidth: 896, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Sidebar

struct ProjectsDetailSidebar: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let project: Project
    @State private var iconOpen = false
    @State private var propertiesOpen = true
    @State private var progressOpen = true
    @State private var descriptionOpen = true

    var body: some View {
        let metrics = ProjectsIssueMetrics(project)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Button { iconOpen.toggle() } label: {
                        ProjectsIconGlyph(icon: project.icon, size: 30)
                            .padding(4)
                            .hoverHighlight(cornerRadius: Theme.Radius.large)
                    }
                    .buttonStyle(.plain)
                    .help(tr("projects", "detail.icon_tooltip"))
                    .popover(isPresented: $iconOpen, arrowEdge: .bottom) {
                        ProjectsEmojiPicker { emoji in
                            iconOpen = false
                            update(ProjectsPatch(icon: emoji))
                        }
                    }
                    ProjectsTitleEditor(projectID: project.id, title: project.title) { update(ProjectsPatch(title: $0)) }
                }

                VStack(alignment: .leading, spacing: 4) {
                    ProjectsSectionHeader(title: tr("projects", "detail.section_properties"), isOpen: $propertiesOpen)
                    if propertiesOpen { properties.padding(.leading, 8) }
                }

                if metrics.totalCount > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        ProjectsSectionHeader(title: tr("projects", "detail.section_progress"), isOpen: $progressOpen)
                        if progressOpen {
                            HStack(spacing: 12) {
                                ProjectsProgressBar(value: Double(metrics.percent) / 100)
                                Text("\(metrics.completedCount)/\(metrics.totalCount)")
                                    .font(Theme.Font.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.leading, 8)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    ProjectsSectionHeader(title: tr("projects", "detail.section_description"), isOpen: $descriptionOpen)
                    if descriptionOpen {
                        VStack(alignment: .leading, spacing: 4) {
                            ProjectsDescriptionEditor(projectID: project.id, description: project.description ?? "") { md in
                                update(ProjectsPatch(description: .some(md.isEmpty ? nil : md)))
                            }
                            Text(tr("projects", "detail.description_hint"))
                                .font(Theme.Font.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                        }
                        .padding(.leading, 8)
                    }
                }

                ProjectsResourcesSection(projectID: project.id)
            }
            .padding(16)
        }
        .background(Theme.sidebar.opacity(0.35))
    }

    private var properties: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProjectsPropRow(label: tr("projects", "table.status")) {
                ProjectsMenuTrigger {
                    HStack(spacing: 6) {
                        ProjectsStatusDot(status: project.status)
                        Text(ProjectsLabels.status(project.status))
                    }
                } menu: { close in
                    ProjectsStatusMenu(current: project.status) { s in
                        close()
                        if s != project.status { update(ProjectsPatch(status: s)) }
                    }
                }
            }
            ProjectsPropRow(label: tr("projects", "table.priority")) {
                ProjectsMenuTrigger {
                    HStack(spacing: 6) {
                        PriorityIcon(priority: IssuePriority(rawValue: project.priority) ?? .none, size: 13)
                        Text(ProjectsLabels.priority(project.priority))
                    }
                } menu: { close in
                    ProjectsPriorityMenu(current: project.priority) { p in
                        close()
                        if p != project.priority { update(ProjectsPatch(priority: p)) }
                    }
                }
            }
            ProjectsPropRow(label: tr("projects", "table.lead")) {
                ProjectsLeadPicker(leadType: project.leadType, leadID: project.leadId, onChange: { update(ProjectsPatch(lead: .some($0))) }) { name in
                    HStack(spacing: 6) {
                        if let t = project.leadType, let id = project.leadId, let name {
                            ActorAvatar(type: t, id: id, size: 16)
                            Text(name)
                        } else {
                            Text(tr("projects", "lead.no_lead")).foregroundStyle(.secondary)
                        }
                    }
                    .font(Theme.Font.caption)
                    .contentShape(Rectangle())
                }
            }
            ProjectsPropRow(label: tr("projects", "detail.prop_start_date")) {
                ProjectsDatePicker(value: project.startDate, placeholder: tr("projects", "detail.prop_start_date"),
                                   emptyLabel: tr("projects", "detail.no_start_date"), icon: "calendar.badge.clock") {
                    update(ProjectsPatch(startDate: .some($0)))
                }
            }
            ProjectsPropRow(label: tr("projects", "detail.prop_due_date")) {
                ProjectsDatePicker(value: project.dueDate, placeholder: tr("projects", "detail.prop_due_date"),
                                   emptyLabel: tr("projects", "detail.no_due_date"), icon: "calendar", highlightOverdue: true) {
                    update(ProjectsPatch(dueDate: .some($0)))
                }
            }
        }
    }

    private func update(_ patch: ProjectsPatch) {
        let id = project.id
        Task {
            do { try await session.projectsUpdate(id, patch) } catch { toaster.error(error) }
        }
    }
}

/// Sidebar property row: 64pt label, value on the right, hover tint.
struct ProjectsPropRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.Font.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 30)
        .padding(.horizontal, 8)
        .hoverHighlight()
    }
}

/// A plain trigger that opens a popover menu.
struct ProjectsMenuTrigger<Label: View, Menu: View>: View {
    @ViewBuilder let label: () -> Label
    @ViewBuilder let menu: (_ close: @escaping () -> Void) -> Menu
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { label().font(Theme.Font.caption).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) { menu { open = false } }
    }
}

struct ProjectsProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(ProjectsLabels.emerald).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

/// Upstream `TitleEditor` in the sidebar: commits a trimmed, changed title
/// on blur or Return.
private struct ProjectsTitleEditor: View {
    let projectID: String
    let title: String
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(tr("projects", "detail.title_placeholder"), text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 17, weight: .semibold))
            .focused($focused)
            .onSubmit(commit)
            .onAppear { draft = title }
            .onChange(of: title) { if !focused { draft = title } }
            .onChange(of: projectID) { draft = title }
            .onChange(of: focused) { if !focused { commit() } }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != title {
            onCommit(trimmed)
        } else if trimmed.isEmpty {
            draft = title
        }
    }
}

/// Description editor with the upstream 1.5 s autosave debounce; a pending
/// save is flushed when the editor goes away.
private struct ProjectsDescriptionEditor: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let projectID: String
    let description: String
    let onSave: (String) -> Void
    @State private var draft = ""
    @State private var saved = ""
    @State private var pending: Task<Void, Never>?

    var body: some View {
        MarkdownEditor(
            text: $draft,
            placeholder: tr("projects", "detail.description_placeholder"),
            minHeight: 60,
            maxHeight: 420,
            onFiles: { urls in upload(urls) },
            mentions: { session.mentionCandidates($0) }
        )
        .padding(.horizontal, 4)
        .onAppear {
            draft = description
            saved = description
        }
        .onChange(of: description) {
            if draft == saved {
                draft = description
            }
            saved = description
        }
        .onChange(of: draft) {
            guard draft != saved else { return }
            pending?.cancel()
            pending = Task {
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                flush()
            }
        }
        .onDisappear {
            pending?.cancel()
            flush()
        }
    }

    private func flush() {
        let md = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard md != saved.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        saved = draft
        onSave(md)
    }

    private func upload(_ urls: [URL]) {
        for url in urls {
            Task {
                do {
                    let a = try await session.upload(fileAt: url)
                    let md = AttachmentUpload.markdown(for: a)
                    draft += draft.isEmpty || draft.hasSuffix("\n") ? md : "\n" + md
                } catch {
                    toaster.error(error)
                }
            }
        }
    }
}
