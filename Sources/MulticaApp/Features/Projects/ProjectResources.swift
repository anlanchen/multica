import AppKit
import MulticaCore
import SwiftUI

/// Upstream `project-resources-section.tsx`: attached GitHub repos and local
/// directories, the attach popover, and the branch / execution-mode dialogs.
struct ProjectsResourcesSection: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster
    let projectID: String
    @State private var open = true
    @State private var resources: [ProjectResource] = []
    @State private var addOpen = false
    @State private var repos = ProjectsWorkspaceRepos()
    @State private var picking = false
    @State private var creating = false
    @State private var modeDialog: ProjectsModeDialogState?
    @State private var modeSaving = false
    @State private var modeError: String?
    @State private var refDialog: ProjectResource?
    @State private var refSaving = false
    @State private var refError: String?

    private var localDaemonID: String? { env.projectsLocalDaemonID }

    private var attachedLocalPaths: Set<String> {
        Set(resources.compactMap { r in r.projectsLocalRef.flatMap { $0.daemonID == localDaemonID ? $0.localPath : nil } })
    }

    var body: some View {
        let attachedLocal = attachedLocalPaths
        let hasLocalForThisDaemon = localDaemonID != nil && !attachedLocal.isEmpty
        VStack(alignment: .leading, spacing: 4) {
            ProjectsSectionHeader(title: tr("projects", "resources.section_header"), isOpen: $open)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    if resources.isEmpty {
                        Text(tr("projects", "resources.empty")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(resources) { r in
                                    ProjectsResourceRow(
                                        resource: r,
                                        repoDescription: r.projectsGithubRef.flatMap { repos.description(for: $0.url) },
                                        localDaemonID: localDaemonID,
                                        onRemove: { remove(r) },
                                        onEditRef: { refError = nil; refDialog = r },
                                        onEditMode: {
                                            guard let ref = r.projectsLocalRef else { return }
                                            modeError = nil
                                            modeDialog = ProjectsModeDialogState(path: ref.localPath, daemonID: ref.daemonID,
                                                                                 mode: ref.executionMode, isGitRepo: nil, resource: r)
                                        }
                                    )
                                }
                            }
                            .padding(.trailing, 4)
                        }
                        .frame(maxHeight: 256)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Button { addOpen.toggle() } label: {
                        Label(tr("projects", "resources.add_button"), systemImage: "plus").font(Theme.Font.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .popover(isPresented: $addOpen, arrowEdge: .bottom) { addPopover }
                    VStack(alignment: .leading, spacing: 2) {
                        Button { Task { await attachLocalDirectory() } } label: {
                            Label(tr("projects", "resources.add_local_directory_button"), systemImage: "folder").font(Theme.Font.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(picking || creating || !env.projectsLocalDaemonRunning || hasLocalForThisDaemon)
                        if !env.projectsLocalDaemonRunning {
                            hint(tr("projects", "resources.local_daemon_offline_hint"))
                        } else if hasLocalForThisDaemon {
                            hint(tr("projects", "resources.local_daemon_already_attached_hint"))
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
        .task(id: "\(projectID):\(session.revision("project_resource"))") { await reload() }
        .task { await repos.load(session) }
        .sheet(item: $refDialog) { r in
            ProjectsGithubRefDialog(url: r.projectsGithubRef?.url ?? "", value: r.projectsGithubRef?.ref ?? "",
                                    errorMessage: refError, saving: refSaving) { next in
                Task { await saveRef(r, next) }
            } onCancel: {
                refDialog = nil
                refError = nil
            }
        }
        .sheet(item: $modeDialog) { state in
            ProjectsModeDialog(
                path: state.path,
                initial: state.mode,
                blocker: ProjectsWorktreeBlocker.reason(isGitRepo: state.isGitRepo, serverValidates: env.projectsServerValidatesWorktree),
                errorMessage: modeError,
                saving: modeSaving,
                confirmLabel: state.resource == nil ? tr("projects", "resources.mode_add") : tr("projects", "resources.mode_save")
            ) { mode in
                Task { await confirmMode(state, mode) }
            } onCancel: {
                modeDialog = nil
                modeError = nil
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(Theme.Font.micro).foregroundStyle(.secondary).padding(.horizontal, 2).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Attach popover

    private var addPopover: some View {
        ProjectsAttachRepoPopover(
            repos: repos.repos,
            attachedURLs: Set(resources.compactMap { $0.projectsGithubRef?.url }),
            creating: creating
        ) { url, ref in
            await attach(url: url, ref: ref)
            addOpen = false
        }
    }

    // MARK: Actions

    private func reload() async {
        if let list = try? await session.api.listProjectResources(projectId: projectID) {
            resources = list.resources
        }
    }

    private func attach(url: String, ref: String?) async {
        creating = true
        defer { creating = false }
        do {
            let created = try await session.api.createProjectResource(
                projectId: projectID,
                CreateProjectResourceRequest(resourceType: "github_repo", resourceRef: ProjectsResourceRefs.github(url: url, ref: ref)))
            if !resources.contains(where: { $0.id == created.id }) { resources.append(created) }
            toaster.success(tr("projects", "resources.toast_attached"))
        } catch {
            toaster.error(message(error, fallback: tr("projects", "resources.toast_attach_failed")))
        }
    }

    private func attachLocalDirectory() async {
        guard !picking else { return }
        picking = true
        defer { picking = false }
        guard let daemonID = localDaemonID, env.projectsLocalDaemonRunning else {
            toaster.error(tr("projects", "resources.toast_local_daemon_not_running"))
            return
        }
        if !attachedLocalPaths.isEmpty {
            toaster.error(tr("projects", "resources.toast_local_daemon_already_attached"))
            return
        }
        guard let picked = await ProjectsLocalPicker.pick() else { return }
        if attachedLocalPaths.contains(picked.path) {
            toaster.error(tr("projects", "resources.toast_local_already_attached"))
            return
        }
        switch await ProjectsLocalPicker.validate(picked.path) {
        case .failed(let failure):
            toaster.error(ProjectsResourceText.validationMessage(failure))
        case .ok(let isGitRepo):
            await session.runtimeRecords.loadIfNeeded()
            let advertises = ProjectsResourceRefs.runtimeAdvertisesLocalWorktree(session.runtimeRecords.items, daemonID: daemonID)
            modeError = nil
            modeDialog = ProjectsModeDialogState(
                path: picked.path, daemonID: daemonID,
                mode: isGitRepo && env.projectsServerValidatesWorktree && advertises ? .worktree : .inPlace,
                isGitRepo: isGitRepo, resource: nil, label: picked.basename)
            addOpen = false
        }
    }

    private func confirmMode(_ state: ProjectsModeDialogState, _ mode: ProjectsExecutionMode) async {
        guard !modeSaving else { return }
        modeSaving = true
        modeError = nil
        defer { modeSaving = false }
        do {
            if let r = state.resource {
                if r.projectsLocalRef?.executionMode == mode {
                    modeDialog = nil
                    return
                }
                let updated = try await session.api.updateProjectResource(
                    projectId: projectID, resourceId: r.id,
                    UpdateProjectResourceRequest(resourceRef: ProjectsResourceRefs.setting(r.resourceRef, "execution_mode", mode.rawValue)))
                replace(updated)
                toaster.success(tr("projects", "resources.toast_local_mode_updated"))
            } else {
                guard let daemonID = localDaemonID else { return }
                let created = try await session.api.createProjectResource(
                    projectId: projectID,
                    CreateProjectResourceRequest(resourceType: "local_directory",
                                                 resourceRef: ProjectsResourceRefs.localDirectory(localPath: state.path, daemonID: daemonID,
                                                                                                  label: state.label ?? state.path, mode: mode)))
                if !resources.contains(where: { $0.id == created.id }) { resources.append(created) }
                toaster.success(tr("projects", "resources.toast_local_attached"))
            }
            modeDialog = nil
        } catch {
            modeError = message(error, fallback: tr("projects", "resources.toast_local_mode_update_failed"))
        }
    }

    private func saveRef(_ r: ProjectResource, _ next: String) async {
        guard !refSaving else { return }
        if (r.projectsGithubRef?.ref ?? "") == next {
            refDialog = nil
            return
        }
        refSaving = true
        refError = nil
        defer { refSaving = false }
        do {
            let updated = try await session.api.updateProjectResource(
                projectId: projectID, resourceId: r.id,
                UpdateProjectResourceRequest(resourceRef: ProjectsResourceRefs.setting(r.resourceRef, "ref", next.isEmpty ? nil : next)))
            replace(updated)
            toaster.success(next.isEmpty ? tr("projects", "resources.toast_ref_cleared") : tr("projects", "resources.toast_ref_updated"))
            refDialog = nil
        } catch {
            refError = message(error, fallback: tr("projects", "resources.toast_ref_update_failed"))
        }
    }

    private func remove(_ r: ProjectResource) {
        let before = resources
        resources.removeAll { $0.id == r.id }
        Task {
            do {
                try await session.api.deleteProjectResource(projectId: projectID, resourceId: r.id)
                toaster.success(tr("projects", "resources.toast_removed"))
            } catch {
                resources = before
                toaster.error(message(error, fallback: tr("projects", "resources.toast_remove_failed")))
            }
        }
    }

    private func replace(_ r: ProjectResource) {
        if let i = resources.firstIndex(where: { $0.id == r.id }) { resources[i] = r }
    }

    private func message(_ error: Error, fallback: String) -> String {
        let m = (error as? APIError)?.message ?? error.localizedDescription
        return m.isEmpty ? fallback : m
    }
}

struct ProjectsModeDialogState: Identifiable {
    var id: String { resource?.id ?? "new:\(path)" }
    var path: String
    var daemonID: String?
    var mode: ProjectsExecutionMode
    /// `nil` = could not check (existing rows are not re-validated).
    var isGitRepo: Bool?
    var resource: ProjectResource?
    var label: String?
}

enum ProjectsResourceText {
    static func validationMessage(_ f: ProjectsLocalDirectory.Failure) -> String {
        switch f {
        case .notAbsolute: return tr("projects", "resources.local_validate_not_absolute")
        case .notFound: return tr("projects", "resources.local_validate_not_found")
        case .notADirectory: return tr("projects", "resources.local_validate_not_a_directory")
        case .notReadable: return tr("projects", "resources.local_validate_not_readable")
        case .notWritable: return tr("projects", "resources.local_validate_not_writable")
        case .error(let m): return m.isEmpty ? tr("projects", "resources.toast_local_pick_failed") : m
        }
    }

    /// `nil` when the value is acceptable (github-ref-field.tsx).
    static func refError(_ value: String) -> String? {
        if ProjectsGitRef.looksLikeCommitSha(value) { return tr("projects", "resources.ref_error_commit") }
        switch ProjectsGitRef.validate(value) {
        case nil: return nil
        case .tooLong: return tr("projects", "resources.ref_error_too_long")
        case .invalidCharacters: return tr("projects", "resources.ref_error_characters")
        case .invalidFormat: return tr("projects", "resources.ref_error_format")
        }
    }
}

// MARK: - Rows

private struct ProjectsResourceRow: View {
    let resource: ProjectResource
    let repoDescription: String?
    let localDaemonID: String?
    let onRemove: () -> Void
    let onEditRef: () -> Void
    let onEditMode: () -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            if let gh = resource.projectsGithubRef {
                github(gh)
            } else if let local = resource.projectsLocalRef {
                localRow(local)
            } else {
                HStack(spacing: 8) {
                    Text(resource.label?.projectsNilIfEmpty ?? resource.resourceType).lineLimit(1)
                    Spacer()
                    iconButton("trash", tr("projects", "resources.remove_tooltip"), action: onRemove)
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(Theme.Font.caption)
        .onHover { hovering = $0 }
    }

    private func github(_ gh: ProjectsGithubRef) -> some View {
        let display = resource.label?.projectsNilIfEmpty ?? ProjectsGitRef.githubShortLabel(gh.url)
        let description = resource.label?.projectsNilIfEmpty == nil ? repoDescription : nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed").foregroundStyle(.secondary).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Button { if let u = URL(string: gh.url) { NSWorkspace.shared.open(u) } } label: {
                        Text(display).lineLimit(1).truncationMode(.tail)
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.primary)
                    .help(gh.ref.map { "\(gh.url)\nref: \($0)" } ?? gh.url)
                    if let description {
                        Text(description).font(Theme.Font.micro).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                iconButton("arrow.triangle.branch", tr("projects", "resources.ref_edit_tooltip"), action: onEditRef)
                    .opacity(hovering ? 1 : 0)
                iconButton("trash", tr("projects", "resources.remove_tooltip"), action: onRemove)
                    .opacity(hovering ? 1 : 0)
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                Text(gh.ref?.projectsNilIfEmpty ?? tr("projects", "resources.ref_default_label")).lineLimit(1)
            }
            .font(Theme.Font.micro)
            .foregroundStyle(.secondary)
            .padding(.leading, 22)
            .help(gh.ref?.projectsNilIfEmpty.map { tr("projects", "resources.ref_badge_tooltip", ["ref": $0]) }
                  ?? tr("projects", "resources.ref_default_tooltip"))
        }
    }

    private func localRow(_ ref: ProjectsLocalRef) -> some View {
        let foreign = localDaemonID != nil && ref.daemonID != localDaemonID
        let unknown = localDaemonID == nil
        let mismatch = foreign || unknown
        let tooltip = [ref.localPath, mismatch ? (unknown ? tr("projects", "resources.local_no_daemon_tooltip")
                                                          : tr("projects", "resources.local_other_machine_tooltip")) : nil]
            .compactMap { $0 }.joined(separator: "\n")
        return HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 14)
            Text(resource.projectsLocalDirectoryLabel).lineLimit(1).help(tooltip)
            Spacer(minLength: 4)
            if ref.executionMode == .worktree {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                    Text(tr("projects", "resources.mode_badge_worktree"))
                }
                .font(Theme.Font.micro)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .help(tr("projects", "resources.mode_badge_worktree_tooltip"))
            }
            iconButton("arrow.triangle.branch", tr("projects", "resources.mode_edit_tooltip"), action: onEditMode)
                .opacity(hovering ? 1 : 0)
            iconButton("trash", tr("projects", "resources.remove_tooltip"), action: onRemove)
                .opacity(hovering ? 1 : 0)
        }
        .opacity(mismatch ? 0.6 : 1)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Theme.Radius.small)
        .help(help)
    }
}

// MARK: - Attach popover

private struct ProjectsAttachRepoPopover: View {
    let repos: [WorkspaceRepo]
    let attachedURLs: Set<String>
    let creating: Bool
    let onAttach: (String, String?) async -> Void
    @State private var search = ""

    var body: some View {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = repos.filter { q.isEmpty || $0.url.lowercased().contains(q) }
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("projects", "resources.popover_title")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if !repos.isEmpty {
                SearchField(text: $search, prompt: tr("projects", "resources.repos_search_placeholder"), autofocus: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if filtered.isEmpty && !q.isEmpty {
                            Text(tr("projects", "resources.repos_search_empty"))
                                .font(Theme.Font.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        ForEach(filtered, id: \.url) { repo in
                            let attached = attachedURLs.contains(repo.url)
                            Button {
                                Task { await onAttach(repo.url, nil) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "book.closed").frame(width: 14)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(ProjectsGitRef.githubShortLabel(repo.url)).lineLimit(1).help(repo.url)
                                        if let d = repo.description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                                            Text(d).font(Theme.Font.micro).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    if attached {
                                        Text(tr("projects", "resources.attached_badge")).font(Theme.Font.micro).foregroundStyle(.secondary)
                                    }
                                }
                                .font(Theme.Font.caption)
                            }
                            .buttonStyle(HoverRowButtonStyle())
                            .disabled(attached || creating)
                            .opacity(attached || creating ? 0.5 : 1)
                        }
                    }
                }
                .frame(maxHeight: 192)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ProjectsCustomRepoForm(submitLabel: tr("projects", "resources.url_submit"),
                                   placeholder: tr("projects", "resources.url_placeholder")) { url, ref in
                await onAttach(url, ref)
            }
        }
        .padding(8)
        .frame(width: 288)
    }
}

/// URL + optional branch; a pasted `/tree/<branch>` URL is split into both.
struct ProjectsCustomRepoForm: View {
    let submitLabel: String
    let placeholder: String
    let onSubmit: (String, String?) async -> Void
    @State private var url = ""
    @State private var ref = ""
    @State private var submitting = false

    var body: some View {
        let refInvalid = ProjectsGitRef.hasError(ref)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(placeholder, text: Binding(get: { url }, set: { setURL($0) }))
                    .textFieldStyle(.plain)
                    .font(Theme.Font.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .onSubmit { submit() }
                Button(submitLabel) { submit() }
                    .controlSize(.small)
                    .disabled(trimmedURL.isEmpty || refInvalid || submitting)
            }
            if !trimmedURL.isEmpty {
                ProjectsGitRefField(value: $ref)
            }
        }
    }

    private func setURL(_ next: String) {
        let split = ProjectsGitRef.splitGithubURL(next)
        url = split.ref == nil ? next : split.url
        if let r = split.ref { ref = r }
    }

    private func submit() {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !ProjectsGitRef.hasError(r), !submitting else { return }
        submitting = true
        Task {
            await onSubmit(u, r.isEmpty ? nil : r)
            url = ""
            ref = ""
            submitting = false
        }
    }
}

/// Upstream `GithubRefField`: free-text starting branch with inline
/// validation.
struct ProjectsGitRefField: View {
    @Binding var value: String
    var onSubmit: (() -> Void)? = nil
    var autofocus = false
    @FocusState private var focused: Bool

    var body: some View {
        let error = ProjectsResourceText.refError(value)
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("projects", "resources.ref_label")).font(.system(size: 11, weight: .medium))
            TextField(tr("projects", "resources.ref_placeholder"), text: $value)
                .textFieldStyle(.plain)
                .font(Theme.Font.mono)
                .autocorrectionDisabled()
                .focused($focused)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .strokeBorder(error != nil ? Theme.destructive : Theme.border))
                .onSubmit { onSubmit?() }
            Text(error ?? tr("projects", "resources.ref_hint"))
                .font(Theme.Font.micro)
                .foregroundStyle(error != nil ? Theme.destructive : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if autofocus { focused = true } }
    }
}

// MARK: - Dialogs

struct ProjectsDialogError: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
            Text(message).fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.destructive)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.destructive.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.destructive.opacity(0.3)))
    }
}

private struct ProjectsMonoBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.05)))
    }
}

/// Upstream `GithubRefDialog`.
struct ProjectsGithubRefDialog: View {
    let url: String
    let value: String
    let errorMessage: String?
    let saving: Bool
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @State private var draft = ""

    var body: some View {
        let invalid = ProjectsGitRef.hasError(draft)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("projects", "resources.ref_dialog_title")).font(Theme.Font.title)
                Text(tr("projects", "resources.ref_dialog_description"))
                    .font(Theme.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ProjectsMonoBox(text: ProjectsGitRef.githubShortLabel(url))
            ProjectsGitRefField(value: $draft, onSubmit: {
                if !invalid && !saving { onConfirm(draft.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }, autofocus: true)
            if let errorMessage { ProjectsDialogError(message: errorMessage) }
            HStack {
                Spacer()
                Button(tr("projects", "resources.ref_cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(tr("projects", "resources.ref_save")) { onConfirm(draft.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || invalid)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { draft = value }
    }
}

/// Upstream `LocalDirectoryModeDialog`.
struct ProjectsModeDialog: View {
    let path: String
    let initial: ProjectsExecutionMode
    let blocker: ProjectsWorktreeBlocker?
    let errorMessage: String?
    let saving: Bool
    let confirmLabel: String
    let onConfirm: (ProjectsExecutionMode) -> Void
    let onCancel: () -> Void
    @State private var selected: ProjectsExecutionMode = .inPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("projects", "resources.mode_dialog_title")).font(Theme.Font.title)
                Text(tr("projects", "resources.mode_dialog_description"))
                    .font(Theme.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ProjectsMonoBox(text: path)
            ProjectsModeOptions(value: $selected, blocker: blocker)
            if let errorMessage { ProjectsDialogError(message: errorMessage) }
            HStack {
                Spacer()
                Button(tr("projects", "resources.mode_cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(confirmLabel) { onConfirm(selected) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { selected = initial }
    }
}

/// The two-option execution-mode choice, shared by the dialog and the
/// create-project picker.
struct ProjectsModeOptions: View {
    @Binding var value: ProjectsExecutionMode
    let blocker: ProjectsWorktreeBlocker?
    var onPick: ((ProjectsExecutionMode) -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            option(.inPlace, icon: "pencil", title: tr("projects", "resources.mode_in_place_title"),
                   description: tr("projects", "resources.mode_in_place_description"), disabledReason: nil)
            option(.worktree, icon: "arrow.triangle.branch", title: tr("projects", "resources.mode_worktree_title"),
                   description: tr("projects", "resources.mode_worktree_description"),
                   disabledReason: blocker.map {
                       $0 == .notGit ? tr("projects", "resources.mode_worktree_needs_git")
                                     : tr("projects", "resources.mode_worktree_needs_server_upgrade")
                   })
        }
    }

    private func option(_ mode: ProjectsExecutionMode, icon: String, title: String, description: String, disabledReason: String?) -> some View {
        let selected = value == mode
        let disabled = disabledReason != nil
        return Button {
            value = mode
            onPick?(mode)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(selected ? Theme.brand : .secondary).frame(width: 16).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(Theme.Font.bodyMedium)
                        Text(mode.rawValue).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Text(description).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let disabledReason {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).padding(.top, 1)
                            Text(disabledReason).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.warning)
                        .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.001)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large)
                .strokeBorder(selected ? Theme.brand : Theme.border, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
    }
}

/// Upstream `LocalDirectoryHint`: the banner an issue's activity section
/// shows when its project is pinned to a local directory on this machine.
struct ProjectsLocalDirectoryHint: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    let projectID: String?
    @State private var resources: [ProjectResource] = []

    var body: some View {
        let daemonID = env.projectsLocalDaemonID
        let matches = daemonID == nil ? [] : resources.filter { $0.projectsLocalRef?.daemonID == daemonID }
        Group {
            if projectID != nil && !matches.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(matches) { r in
                        let ref = r.projectsLocalRef
                        let worktree = ref?.executionMode == .worktree
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Image(systemName: worktree ? "arrow.triangle.branch" : "folder").font(.system(size: 10))
                                (Text(worktree ? tr("projects", "resources.chat_hint_worktree_prefix") : tr("projects", "resources.chat_hint_prefix"))
                                 + Text(" \(r.projectsLocalDirectoryLabel) ").fontWeight(.medium).foregroundColor(.primary)
                                 + Text("(\(ref?.localPath ?? ""))").font(.system(size: 10, design: .monospaced)))
                                    .lineLimit(1)
                            }
                            if worktree {
                                Text(tr("projects", "resources.chat_hint_worktree_note")).opacity(0.8).padding(.leading, 18)
                            }
                        }
                    }
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
        }
        .task(id: "\(projectID ?? ""):\(session.revision("project_resource"))") {
            guard let projectID else { resources = []; return }
            resources = (try? await session.api.listProjectResources(projectId: projectID).resources) ?? []
        }
    }
}
