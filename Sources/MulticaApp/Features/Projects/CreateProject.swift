import AppKit
import MulticaCore
import SwiftUI

/// Upstream `useProjectDraftStore`: unsent create-project fields, per workspace.
struct ProjectsCreateDraft: Codable, Equatable {
    var title = ""
    var description = ""
    var status = "planned"
    var priority = "none"
    var leadType: String?
    var leadId: String?
    var icon: String?
    var startDate: String?
    var dueDate: String?
}

/// Upstream `modals/create-project.tsx`.
struct CreateProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster

    @State private var draft = ProjectsCreateDraft()
    @State private var draftLoaded = false
    @State private var expanded = false
    @State private var submitting = false
    @State private var iconOpen = false
    @State private var startOpen = false
    @State private var dueOpen = false
    @State private var sourceOpen = false
    @State private var source = ProjectsCreateSource()
    @State private var repos = ProjectsWorkspaceRepos()
    @FocusState private var titleFocused: Bool

    private var draftKey: String { "multica_project_draft:\(session.workspace.slug)" }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 6) {
                Button { iconOpen.toggle() } label: {
                    ProjectsIconGlyph(icon: draft.icon, size: 26).padding(4).hoverHighlight(cornerRadius: Theme.Radius.large)
                }
                .buttonStyle(.plain)
                .help(tr("modals", "create_project.icon_tooltip"))
                .popover(isPresented: $iconOpen, arrowEdge: .bottom) {
                    ProjectsEmojiPicker { emoji in
                        iconOpen = false
                        draft.icon = emoji
                    }
                }
                TextField(tr("modals", "create_project.title_placeholder"), text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))
                    .focused($titleFocused)
                    .onSubmit { Task { await submit() } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    MarkdownEditor(text: $draft.description,
                                   placeholder: tr("modals", "create_project.description_placeholder"),
                                   minHeight: 80, maxHeight: 2000,
                                   onFiles: { upload($0) },
                                   mentions: { session.mentionCandidates($0) })
                    Text(tr("modals", "create_project.description_hint"))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
            }
            .frame(maxHeight: .infinity)

            ProjectsFlowLayout(spacing: 6) { pills }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            HStack {
                Spacer()
                Button(submitting ? tr("modals", "create_project.submitting") : tr("modals", "create_project.submit")) {
                    Task { await submit() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canSubmit)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Divider() }
        }
        .frame(width: expanded ? 896 : 672, height: expanded ? 640 : 384)
        .animation(.easeOut(duration: 0.25), value: expanded)
        .onAppear {
            if !draftLoaded {
                draft = ProjectsDefaults.load(ProjectsCreateDraft.self, key: draftKey) ?? ProjectsCreateDraft()
                draftLoaded = true
            }
            titleFocused = true
        }
        .onChange(of: draft) { if draftLoaded { ProjectsDefaults.save(draft, key: draftKey) } }
        .task {
            await repos.load(session)
            await session.runtimeRecords.loadIfNeeded()
        }
    }

    private var canSubmit: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !submitting
            && !(source.mode == .repos && source.hasRejectedRef)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(session.workspace.name).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
            Text(tr("modals", "create_project.title_breadcrumb")).fontWeight(.medium)
            Spacer()
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help(expanded ? tr("modals", "common.collapse_tooltip") : tr("modals", "common.expand_tooltip"))
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help(tr("modals", "common.close"))
        }
        .font(Theme.Font.caption)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var pills: some View {
        ProjectsMenuPill {
            HStack(spacing: 6) {
                ProjectsStatusDot(status: draft.status)
                Text(ProjectsLabels.status(draft.status))
            }
        } menu: { close in
            ProjectsStatusMenu(current: draft.status) { draft.status = $0; close() }
        }
        ProjectsMenuPill {
            HStack(spacing: 6) {
                PriorityIcon(priority: IssuePriority(rawValue: draft.priority) ?? .none, size: 13)
                Text(ProjectsLabels.priority(draft.priority))
            }
        } menu: { close in
            ProjectsPriorityMenu(current: draft.priority) { draft.priority = $0; close() }
        }
        ProjectsLeadPicker(
            leadType: draft.leadType, leadID: draft.leadId,
            noLeadLabel: tr("modals", "create_project.no_lead"),
            placeholder: tr("modals", "create_project.lead_placeholder"),
            membersGroup: tr("modals", "create_project.members_group"),
            agentsGroup: tr("modals", "create_project.agents_group"),
            noResults: tr("modals", "create_project.no_results")
        ) { ref in
            draft.leadType = ref?.type
            draft.leadId = ref?.id
        } trigger: { name in
            HStack(spacing: 6) {
                if let t = draft.leadType, let id = draft.leadId, let name {
                    ActorAvatar(type: t, id: id, size: 16)
                    Text(name).lineLimit(1)
                } else {
                    Text(tr("modals", "create_project.lead")).foregroundStyle(.secondary)
                }
            }
            .modifier(ProjectsPillChrome())
        }
        if draft.startDate != nil || startOpen {
            ProjectsDatePicker(value: draft.startDate, placeholder: tr("projects", "detail.prop_start_date"),
                               emptyLabel: tr("projects", "detail.no_start_date"), icon: "calendar.badge.clock",
                               pill: true, isPresented: $startOpen) { draft.startDate = $0 }
        }
        if draft.dueDate != nil || dueOpen {
            ProjectsDatePicker(value: draft.dueDate, placeholder: tr("projects", "detail.prop_due_date"),
                               emptyLabel: tr("projects", "detail.no_due_date"), icon: "calendar",
                               highlightOverdue: true, pill: true, isPresented: $dueOpen) { draft.dueDate = $0 }
        }
        Button { sourceOpen.toggle() } label: {
            HStack(spacing: 6) {
                if source.mode == .local {
                    Image(systemName: "folder").font(.system(size: 10))
                    Text(source.localPath.map { source.localLabel ?? $0 } ?? tr("modals", "create_project.source_pill_local"))
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 192)
                } else {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 9))
                    Text(source.selectedRepos.isEmpty ? tr("modals", "create_project.repos_pill")
                         : tr("modals", "create_project.repos_pill_count", ["count": source.selectedRepos.count]))
                }
            }
        }
        .buttonStyle(PillButtonStyle())
        .popover(isPresented: $sourceOpen, arrowEdge: .top) {
            ProjectsCreateSourcePopover(source: $source, repos: repos.repos)
        }
        if draft.startDate == nil || draft.dueDate == nil {
            Menu {
                if draft.dueDate == nil {
                    Button { dueOpen = true } label: { Label(tr("modals", "create_project.set_due_date"), systemImage: "calendar") }
                }
                if draft.startDate == nil {
                    Button { startOpen = true } label: { Label(tr("modals", "create_project.set_start_date"), systemImage: "calendar.badge.clock") }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(PillButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("modals", "create_project.more_options_aria"))
        }
    }

    private func upload(_ urls: [URL]) {
        for url in urls {
            Task {
                do {
                    let a = try await session.upload(fileAt: url)
                    let md = AttachmentUpload.markdown(for: a)
                    draft.description += draft.description.isEmpty || draft.description.hasSuffix("\n") ? md : "\n" + md
                } catch {
                    toaster.error(error)
                }
            }
        }
    }

    private func submit() async {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !submitting else { return }
        if source.mode == .repos && source.hasRejectedRef { return }
        var resources: [CreateProjectResourceRequest]?
        switch source.mode {
        case .repos where !source.selectedRepos.isEmpty:
            resources = source.selectedRepos.map { url in
                CreateProjectResourceRequest(resourceType: "github_repo",
                                             resourceRef: ProjectsResourceRefs.github(url: url, ref: source.repoRefs[url]?.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        case .local:
            if let path = source.localPath, let daemonID = env.projectsLocalDaemonID {
                resources = [CreateProjectResourceRequest(
                    resourceType: "local_directory",
                    resourceRef: ProjectsResourceRefs.localDirectory(localPath: path, daemonID: daemonID, label: source.localLabel,
                                                                     mode: effectiveLocalMode))]
            }
        default:
            break
        }
        submitting = true
        defer { submitting = false }
        do {
            let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let project = try await session.api.createProject(CreateProjectRequest(
                title: title,
                description: description.isEmpty ? nil : description,
                icon: draft.icon,
                status: draft.status,
                priority: draft.priority,
                leadType: draft.leadType,
                leadId: draft.leadId,
                startDate: draft.startDate,
                dueDate: draft.dueDate,
                resources: resources))
            session.projects.upsert(project)
            UserDefaults.standard.removeObject(forKey: draftKey)
            draftLoaded = false
            dismiss()
            toaster.success(tr("modals", "create_project.toast_created"))
            nav.push(.project(project.id), title: project.title)
        } catch {
            let m = (error as? APIError)?.message ?? error.localizedDescription
            toaster.error(m.isEmpty ? tr("modals", "create_project.toast_failed") : m)
        }
    }

    private var effectiveLocalMode: ProjectsExecutionMode {
        let blocker = ProjectsWorktreeBlocker.reason(isGitRepo: source.localIsGitRepo, serverValidates: env.projectsServerValidatesWorktree)
        let advertises = ProjectsResourceRefs.runtimeAdvertisesLocalWorktree(session.runtimeRecords.items, daemonID: env.projectsLocalDaemonID)
        return ProjectsResourceRefs.effectiveMode(chosen: source.localMode, isGitRepo: source.localIsGitRepo,
                                                  advertises: advertises, blocker: blocker)
    }
}

/// The project's code source: GitHub repos OR one local directory. Switching
/// tabs keeps the other side's selection; only the active side is submitted.
struct ProjectsCreateSource: Equatable {
    enum Mode { case repos, local }
    var mode: Mode = .repos
    var selectedRepos: [String] = []
    /// Checkout ref per repo URL; kept when a repo is toggled off and on.
    var repoRefs: [String: String] = [:]
    var localPath: String?
    var localLabel: String?
    /// `nil` = the user has not picked; the folder-derived preselection applies.
    var localMode: ProjectsExecutionMode?
    var localIsGitRepo: Bool?

    var hasRejectedRef: Bool { selectedRepos.contains { ProjectsGitRef.hasError(repoRefs[$0] ?? "") } }

    mutating func toggleRepo(_ url: String) {
        if let i = selectedRepos.firstIndex(of: url) { selectedRepos.remove(at: i) } else { selectedRepos.append(url) }
    }

    mutating func setRef(_ url: String, _ ref: String) {
        let t = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        repoRefs[url] = t.isEmpty ? nil : t
    }

    mutating func clearLocal() {
        localPath = nil
        localLabel = nil
        localIsGitRepo = nil
        localMode = nil
    }
}

private struct ProjectsCreateSourcePopover: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Binding var source: ProjectsCreateSource
    let repos: [WorkspaceRepo]
    @State private var search = ""
    @State private var customURL = ""
    @State private var customRef = ""
    @State private var editingRefFor: String?
    @State private var picking = false
    @State private var pickError: String?
    @State private var modeOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { source.mode }, set: { source.mode = $0; pickError = nil })) {
                Text(tr("modals", "create_project.source_tab_repos")).tag(ProjectsCreateSource.Mode.repos)
                Text(tr("modals", "create_project.source_tab_local")).tag(ProjectsCreateSource.Mode.local)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if source.mode == .repos { reposPane } else { localPane }
        }
        .padding(8)
        .frame(width: 304)
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
    }

    // MARK: Repos

    @ViewBuilder private var reposPane: some View {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = repos.filter { q.isEmpty || $0.url.lowercased().contains(q) }
        heading(tr("modals", "create_project.repos_heading"))
        if repos.isEmpty {
            Text(tr("modals", "create_project.repos_empty")).font(Theme.Font.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            SearchField(text: $search, prompt: tr("modals", "create_project.repos_search_placeholder"))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if filtered.isEmpty && !q.isEmpty {
                        Text(tr("modals", "create_project.repos_search_empty"))
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    ForEach(filtered, id: \.url) { repo in
                        let checked = source.selectedRepos.contains(repo.url)
                        Button { source.toggleRepo(repo.url) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(checked ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.secondary))
                                repoText(repo.url, repo.description)
                            }
                            .font(Theme.Font.caption)
                        }
                        .buttonStyle(HoverRowButtonStyle(selected: checked))
                    }
                }
            }
            .frame(maxHeight: 192)
            .fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(tr("modals", "create_project.repos_url_placeholder"), text: Binding(get: { customURL }, set: setCustomURL))
                    .textFieldStyle(.plain)
                    .font(Theme.Font.caption)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .onSubmit(addCustom)
                Button(tr("modals", "create_project.repos_add"), action: addCustom)
                    .controlSize(.small)
                    .disabled(customURL.trimmingCharacters(in: .whitespaces).isEmpty || ProjectsGitRef.hasError(customRef))
            }
            if !customURL.trimmingCharacters(in: .whitespaces).isEmpty {
                ProjectsGitRefField(value: $customRef)
            }
        }
        if !source.selectedRepos.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("modals", "create_project.repos_selected").uppercased())
                    .font(.system(size: 10, weight: .medium)).tracking(0.6).foregroundStyle(.secondary)
                ForEach(source.selectedRepos, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                            repoText(url, repos.first { $0.url == url }?.description)
                            Button {
                                editingRefFor = editingRefFor == url ? nil : url
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                                    Text(source.repoRefs[url] ?? tr("modals", "create_project.repos_ref_default")).lineLimit(1).frame(maxWidth: 96)
                                }
                                .font(Theme.Font.micro)
                                .foregroundStyle(source.repoRefs[url] == nil ? .secondary : .primary)
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .hoverHighlight(cornerRadius: Theme.Radius.small)
                            }
                            .buttonStyle(.plain)
                            Button {
                                source.toggleRepo(url)
                                if editingRefFor == url { editingRefFor = nil }
                            } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                        .font(Theme.Font.caption)
                        if editingRefFor == url {
                            ProjectsGitRefField(value: Binding(get: { source.repoRefs[url] ?? "" }, set: { source.setRef(url, $0) }),
                                                onSubmit: { editingRefFor = nil }, autofocus: true)
                                .padding(.leading, 20)
                        }
                    }
                }
            }
        }
    }

    private func repoText(_ url: String, _ description: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(ProjectsGitRef.githubShortLabel(url)).lineLimit(1)
            if let d = description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                Text(d).font(Theme.Font.micro).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(url)
    }

    private func setCustomURL(_ next: String) {
        let split = ProjectsGitRef.splitGithubURL(next)
        customURL = split.ref == nil ? next : split.url
        if let r = split.ref { customRef = r }
    }

    private func addCustom() {
        let url = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !ProjectsGitRef.hasError(customRef) else { return }
        if !source.selectedRepos.contains(url) { source.selectedRepos.append(url) }
        source.setRef(url, customRef)
        customURL = ""
        customRef = ""
    }

    // MARK: Local

    @ViewBuilder private var localPane: some View {
        let blocker = ProjectsWorktreeBlocker.reason(isGitRepo: source.localIsGitRepo, serverValidates: env.projectsServerValidatesWorktree)
        let advertises = ProjectsResourceRefs.runtimeAdvertisesLocalWorktree(session.runtimeRecords.items, daemonID: env.projectsLocalDaemonID)
        let mode = ProjectsResourceRefs.effectiveMode(chosen: source.localMode, isGitRepo: source.localIsGitRepo,
                                                      advertises: advertises, blocker: blocker)
        heading(tr("modals", "create_project.local_heading"))
        if env.projectsLocalDaemonID != nil && env.projectsLocalDaemonRunning {
            Text(tr("modals", "create_project.local_on_device",
                    ["device": env.projectsLocalDeviceName ?? tr("modals", "create_project.local_this_machine")]))
                .font(Theme.Font.micro).foregroundStyle(.secondary)
        } else {
            Text(tr("modals", "create_project.local_daemon_offline")).font(Theme.Font.micro).foregroundStyle(.orange)
        }
        if let path = source.localPath {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        if let label = source.localLabel { Text(label).fontWeight(.medium).lineLimit(1) }
                        Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button { source.clearLocal(); pickError = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(tr("modals", "create_project.local_clear"))
                }
                .font(Theme.Font.caption)
                HStack(spacing: 6) {
                    Button { modeOpen.toggle() } label: {
                        Label(mode == .worktree ? tr("projects", "resources.mode_badge_worktree") : tr("projects", "resources.mode_badge_in_place"),
                              systemImage: mode == .worktree ? "arrow.triangle.branch" : "pencil")
                            .font(Theme.Font.caption)
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .popover(isPresented: $modeOpen, arrowEdge: .bottom) {
                        ProjectsModeOptions(value: Binding(get: { mode }, set: { source.localMode = $0 }), blocker: blocker) { _ in
                            modeOpen = false
                        }
                        .padding(8)
                        .frame(width: 320)
                    }
                    Button(tr("modals", "create_project.local_change")) { Task { await pick() } }
                        .buttonStyle(.borderless)
                        .font(Theme.Font.caption)
                        .disabled(picking || !env.projectsLocalDaemonRunning)
                }
            }
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
        } else {
            Button { Task { await pick() } } label: {
                Label(picking ? tr("modals", "create_project.local_picking") : tr("modals", "create_project.local_pick"), systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(picking || !env.projectsLocalDaemonRunning)
        }
        if let pickError {
            Text(pickError).font(Theme.Font.micro).foregroundStyle(Theme.destructive)
        }
        Text(tr("modals", "create_project.local_hint"))
            .font(Theme.Font.micro).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func pick() async {
        guard !picking else { return }
        pickError = nil
        picking = true
        defer { picking = false }
        guard let picked = await ProjectsLocalPicker.pick(defaultPath: source.localPath) else { return }
        switch await ProjectsLocalPicker.validate(picked.path) {
        case .failed(let f):
            if case .error(let m) = f, !m.isEmpty { pickError = m } else { pickError = tr("modals", "create_project.local_invalid_dir") }
        case .ok(let isGitRepo):
            source.localPath = picked.path
            source.localLabel = picked.basename
            source.localIsGitRepo = isGitRepo
        }
    }
}

/// Pill with a popover menu (status / priority pills of the create dialogs).
struct ProjectsMenuPill<Label: View, Menu: View>: View {
    @ViewBuilder let label: () -> Label
    @ViewBuilder let menu: (_ close: @escaping () -> Void) -> Menu
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { label() }
            .buttonStyle(PillButtonStyle())
            .popover(isPresented: $open, arrowEdge: .bottom) { menu { open = false } }
    }
}

/// `PillButtonStyle` chrome for custom triggers that are not buttons.
struct ProjectsPillChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.Font.caption)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
            .contentShape(Rectangle())
    }
}

/// Left-aligned wrapping row (the create dialogs' property pill toolbar).
struct ProjectsFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth && !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(i)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
