import MulticaCore
import SwiftUI

/// The repositories agents may clone and push to (upstream repositories-section.tsx).
/// Rows are read-only; adding and editing save on confirm from a dialog.
struct ConnectionsRepositoriesSection: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    @Environment(\.openURL) private var openURL
    let workspace: ConnectionsWorkspaceModel
    let github: ConnectionsGitHubModel
    @State private var draft: ConnectionsRepoDraft?
    @State private var pickerOpen = false
    @State private var connectingGitHub = false
    @State private var confirm: ConnectionsConfirm?

    private var canManage: Bool { session.connectionsIsManager }
    private var repos: [WorkspaceRepo] { workspace.record?.repos ?? [] }

    var body: some View {
        ConnectionsSection(title: tr("settings", "repositories.section_title"), description: tr("settings", "repositories.description"),
                           action: canManage ? AnyView(addMenu) : nil, anchor: "repositories") {
            ConnectionsCard {
                if repos.isEmpty {
                    Text(tr("settings", canManage ? "repositories.empty" : "repositories.manage_hint"))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 32)
                } else {
                    ForEach(Array(repos.enumerated()), id: \.offset) { index, repo in
                        if index > 0 { Divider() }
                        row(index, repo)
                    }
                }
            }
        }
        .sheet(item: $draft) { d in
            ConnectionsRepoDraftDialog(draft: d, repos: repos) { entry in
                var next = repos
                if let i = d.index, i < next.count { next[i] = entry } else { next.append(entry) }
                return await workspace.setRepos(next, session: session, toaster: toaster)
            }
        }
        .sheet(isPresented: $pickerOpen) {
            ConnectionsGitHubRepoPicker(github: github, existing: repos) { additions in
                guard !additions.isEmpty else { return true }
                return await workspace.setRepos(repos + additions, session: session, toaster: toaster)
            }
        }
        .task(id: "\(nav.query("github_connected") ?? "")|\(nav.query("github_error") ?? "")|\(github.loading)") { consumeGitHubReturn() }
        .connectionsConfirm($confirm)
    }

    private func row(_ index: Int, _ repo: WorkspaceRepo) -> some View {
        HStack(spacing: 12) {
            Group {
                if ConnectionsRepository.isGitHub(repo.url) {
                    ConnectionsBrandMark(brand: .github, size: 16)
                } else {
                    Image(systemName: "folder.badge.gearshape").font(.system(size: 13))
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.url).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .help(repo.url).textSelection(.enabled)
                if let d = repo.description, !d.isEmpty {
                    Text(d).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if canManage {
                Menu {
                    Button { draft = ConnectionsRepoDraft(index: index, url: repo.url, description: repo.description ?? "") } label: {
                        Label(tr("settings", "repositories.edit"), systemImage: "pencil")
                    }
                    Button(role: .destructive) { askRemove(index) } label: {
                        Label(tr("settings", "repositories.delete_confirm_action"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("settings", "repositories.actions_aria", ["url": repo.url]))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
    }

    private var addMenu: some View {
        let hasInstallations = !github.installations.isEmpty
        let githubDisabled = connectingGitHub || !github.browseConfigured || (!github.configured && !hasInstallations)
        return Menu {
            Button {
                if hasInstallations { pickerOpen = true } else { connectGitHub() }
            } label: {
                if github.browseConfigured {
                    Text(tr("settings", hasInstallations ? "repositories.choose_from_github" : "repositories.connect_github"))
                } else {
                    Text(tr("settings", hasInstallations ? "repositories.choose_from_github" : "repositories.connect_github"))
                    Text(tr("settings", "repositories.github_browse_not_configured"))
                }
            }
            .disabled(githubDisabled)
            Button { draft = ConnectionsRepoDraft(index: nil, url: "", description: "") } label: {
                Label(tr("settings", "repositories.add_manually"), systemImage: "pencil")
            }
        } label: {
            Label(tr("settings", "repositories.add"), systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .fixedSize()
    }

    private func connectGitHub() {
        connectingGitHub = true
        Task {
            defer { connectingGitHub = false }
            do {
                let r = try await session.api.getGitHubConnectURL(workspaceId: session.workspace.id, returnTo: "repositories")
                guard r.configured, let raw = r.url, let url = URL(string: raw) else {
                    toaster.error(tr("settings", "repositories.github_not_configured"))
                    return
                }
                openURL(url)
            } catch {
                toaster.error((error as? APIError)?.message ?? tr("settings", "repositories.github_connect_failed"))
            }
        }
    }

    /// `?github_connected=1` / `?github_error=` from the App install flow: open
    /// the picker once the new installation is listed, then drop the params.
    private func consumeGitHubReturn() {
        let connected = nav.query("github_connected") == "1"
        let failed = nav.query("github_error") != nil
        guard (connected || failed), canManage else { return }
        if !failed && github.loading { return }
        if failed {
            toaster.error(tr("settings", "repositories.github_connect_failed"))
        } else if !github.installations.isEmpty && github.browseConfigured {
            pickerOpen = true
        } else if !github.installations.isEmpty {
            toaster.error(tr("settings", "repositories.github_browse_not_configured"))
        }
        nav.setQuery("github_connected", nil)
        nav.setQuery("github_error", nil)
    }

    private func askRemove(_ index: Int) {
        confirm = ConnectionsConfirm(
            title: tr("settings", "repositories.delete_confirm_title"),
            message: tr("settings", "repositories.delete_confirm_description"),
            cancel: tr("settings", "repositories.delete_confirm_cancel"),
            confirm: tr("settings", "repositories.delete_confirm_action"),
            destructive: true) {
                var next = repos
                guard index < next.count else { return true }
                next.remove(at: index)
                return await workspace.setRepos(next, session: session, toaster: toaster)
            }
    }
}

struct ConnectionsRepoDraft: Identifiable {
    let id = UUID()
    /// Index being edited, or nil when adding.
    var index: Int?
    var url: String
    var description: String
}

private struct ConnectionsRepoDraftDialog: View {
    @Environment(\.dismiss) private var dismiss
    let draft: ConnectionsRepoDraft
    let repos: [WorkspaceRepo]
    let onSave: (WorkspaceRepo) async -> Bool
    @State private var url = ""
    @State private var description = ""
    @State private var saving = false

    private var duplicate: Bool {
        guard let identity = ConnectionsRepository.identity(url) else { return false }
        return repos.enumerated().contains { i, r in i != draft.index && ConnectionsRepository.identity(r.url) == identity }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("settings", draft.index == nil ? "repositories.add_title" : "repositories.edit_title"))
                    .font(.system(size: 15, weight: .semibold))
                Text(tr("settings", "repositories.description")).font(Theme.Font.body).foregroundStyle(.secondary)
            }
            ConnectionsField(label: tr("settings", "repositories.url_label"), error: duplicate ? tr("settings", "repositories.duplicate") : nil) {
                TextField(tr("settings", "repositories.url_placeholder"), text: $url)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    .disabled(saving)
            }
            ConnectionsField(label: tr("settings", "repositories.description_label")) {
                TextField(tr("settings", "repositories.description_placeholder"), text: $description)
                    .textFieldStyle(.roundedBorder)
                    .disabled(saving)
            }
            HStack {
                Spacer()
                Button(tr("settings", "repositories.github_cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(saving ? tr("settings", "repositories.saving") : tr("settings", "repositories.save")) {
                    let trimmed = url.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, !duplicate else { return }
                    let d = description.trimmingCharacters(in: .whitespaces)
                    saving = true
                    Task {
                        let ok = await onSave(WorkspaceRepo(url: trimmed, description: d.isEmpty ? nil : d))
                        saving = false
                        if ok { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(saving || url.trimmingCharacters(in: .whitespaces).isEmpty || duplicate)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(saving)
        .onAppear {
            url = draft.url
            description = draft.description
        }
    }
}

/// Multi-select import from a GitHub App installation.
private struct ConnectionsGitHubRepoPicker: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let github: ConnectionsGitHubModel
    let existing: [WorkspaceRepo]
    let onImport: ([WorkspaceRepo]) async -> Bool

    @State private var installationID = ""
    @State private var repositories: [GitHubRepository] = []
    @State private var nextPage: Int? = 1
    @State private var loading = false
    @State private var failed = false
    @State private var selected: [Int: GitHubRepository] = [:]
    @State private var search = ""
    @State private var saving = false

    private var existingIdentities: Set<String> { Set(existing.compactMap { ConnectionsRepository.identity($0.url) }) }

    var body: some View {
        let known = existingIdentities
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? repositories : repositories.filter { $0.fullName.lowercased().contains(q) }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("settings", "repositories.github_picker_title")).font(.system(size: 15, weight: .semibold))
                Text(tr("settings", "repositories.github_picker_description")).font(Theme.Font.body).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if github.installations.count > 1 {
                    Picker(tr("settings", "repositories.github_account"), selection: $installationID) {
                        ForEach(github.installations) { Text($0.accountLogin).tag($0.id) }
                    }
                } else if let only = github.installations.first {
                    (Text("\(tr("settings", "repositories.github_account")): ") + Text(only.accountLogin).fontWeight(.medium).foregroundColor(.primary))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                SearchField(text: $search, prompt: tr("settings", "repositories.github_search_placeholder"))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Divider()
            ScrollView {
                if loading && repositories.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(tr("settings", "repositories.github_loading"))
                    }
                    .font(Theme.Font.body).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 48)
                } else if failed && repositories.isEmpty {
                    Text(tr("settings", "repositories.github_load_failed"))
                        .font(Theme.Font.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(48)
                } else if filtered.isEmpty {
                    Text(tr("settings", q.isEmpty ? "repositories.github_empty" : "repositories.github_no_search_results"))
                        .font(Theme.Font.body).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 48)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered, id: \.id) { repo in
                            let identity = ConnectionsRepository.identity(repo.cloneUrl)
                            let added = identity.map { known.contains($0) } ?? false
                            repoRow(repo, added: added)
                            Divider()
                        }
                    }
                }
                if nextPage != nil && !repositories.isEmpty {
                    Button(loading ? tr("settings", "repositories.github_loading") : tr("settings", "repositories.github_load_more")) {
                        Task { await loadPage() }
                    }
                    .buttonStyle(.borderless)
                    .disabled(loading)
                    .padding(12)
                }
            }
            .frame(minHeight: 260)
            Divider()
            HStack(spacing: 8) {
                Text(tr("settings", "repositories.github_selected_count", ["count": selected.count]))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("settings", "repositories.github_cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(tr("settings", "repositories.github_import")) { Task { await importSelected() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || saving)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color.primary.opacity(0.02))
        }
        .frame(width: 640, height: 600)
        .interactiveDismissDisabled(saving)
        .task(id: installationID) {
            if installationID.isEmpty {
                installationID = github.installations.first?.id ?? ""
                return
            }
            repositories = []
            nextPage = 1
            selected = [:]
            await loadPage()
        }
    }

    private func repoRow(_ repo: GitHubRepository, added: Bool) -> some View {
        let disabled = added || repo.archived
        let key = Int(repo.id)
        return Toggle(isOn: Binding(get: { added || selected[key] != nil }, set: { on in
            if on { selected[key] = repo } else { selected[key] = nil }
        })) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(repo.fullName).font(Theme.Font.bodyMedium).lineLimit(1)
                    if repo.private { Badge(text: tr("settings", "repositories.github_private")) }
                    if repo.archived { Badge(text: tr("settings", "repositories.github_archived")) }
                    if added { Badge(text: tr("settings", "repositories.github_added")) }
                }
                if let d = repo.description, !d.isEmpty {
                    Text(d).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(disabled)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadPage() async {
        guard let page = nextPage, !installationID.isEmpty, github.browseConfigured, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await session.api.listGitHubInstallationRepositories(workspaceId: session.workspace.id, installationId: installationID,
                                                                            page: page, perPage: 100)
            repositories += r.repositories
            nextPage = r.nextPage.map { Int($0) }
            failed = false
        } catch {
            failed = true
        }
    }

    private func importSelected() async {
        var known = existingIdentities
        var additions: [WorkspaceRepo] = []
        for repo in selected.values.sorted(by: { $0.fullName < $1.fullName }) {
            guard let identity = ConnectionsRepository.identity(repo.cloneUrl), !known.contains(identity), !repo.archived else { continue }
            known.insert(identity)
            let d = repo.description?.trimmingCharacters(in: .whitespaces)
            additions.append(WorkspaceRepo(url: repo.cloneUrl, description: d?.isEmpty == false ? d : nil))
        }
        saving = true
        let ok = await onImport(additions)
        saving = false
        if ok { dismiss() }
    }
}
