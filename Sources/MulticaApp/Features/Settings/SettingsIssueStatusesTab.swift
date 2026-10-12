import MulticaCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Issue Statuses (upstream issue-statuses-tab.tsx): the status
/// catalog by lifecycle category — reorder within a category, create, edit
/// and archive custom statuses, inspect issues still on a status.
struct SettingsIssueStatusesTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @State private var showArchived = false
    @State private var groups: [(category: StatusCategory, entries: [IssueStatusEntry])] = []
    @State private var creating: StatusCategory?
    @State private var editing: IssueStatusEntry?
    @State private var archiving: IssueStatusEntry?
    @State private var inspecting: IssueStatusEntry?
    @State private var mergeTarget = "done"

    var body: some View {
        let store = session.issueStatusEntries
        let role = session.settingsMyRole
        let isAdmin = role == "owner" || role == "admin"
        let archivedCount = store.items.filter { !$0.isSystem && $0.archivedAt != nil }.count
        SettingsTabView(title: tr("settings", "page.tabs.issue_statuses"), description: isAdmin ? tr("settings", "issue_statuses.reorder_hint") : nil,
                        scope: .workspace, actions: {
            if archivedCount > 0 {
                HStack(spacing: 8) {
                    Text(tr("settings", "issue_statuses.show_archived", ["count": archivedCount]))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                    Toggle("", isOn: $showArchived).toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
            }
        }) {
            if role != nil && !isAdmin { SettingsReadOnlyNotice() }
            if !store.isLoaded {
                SettingsCatalogCard { EmptyView() } content: {
                    SettingsCatalogPlaceholder(title: tr("settings", "issue_statuses.loading"))
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.category) { i, group in
                        if i > 0 { Divider() }
                        SettingsStatusCategorySection(category: group.category, entries: group.entries, canManage: isAdmin, mergeTarget: mergeTarget,
                                                      onCreate: { creating = group.category }, onEdit: { editing = $0 },
                                                      onArchive: { archiving = $0 }, onViewIssues: { inspecting = $0 },
                                                      onMergeBadge: {
                            nav.push(.settings, query: SettingsLocation.query(from: nav.location.query, tab: "code", section: "pr-merge-status"))
                        })
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.settingsCard))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }
        }
        .task { await store.loadIfNeeded() }
        .task(id: session.revision("workspace")) {
            if let ws = try? await session.api.getWorkspace(session.workspace.id) { mergeTarget = SettingsRules.prMergeStatus(settings: ws.settings) }
        }
        .onChange(of: store.items, initial: true) { regroup() }
        .onChange(of: showArchived) { regroup() }
        .sheet(item: Binding(get: { creating.map(SettingsStatusEditing.init(category:)) }, set: { if $0 == nil { creating = nil } })) { e in
            SettingsStatusEditorSheet(category: e.category, status: nil) { creating = nil }
        }
        .sheet(item: $editing) { status in
            SettingsStatusEditorSheet(category: SettingsRules.normalizeCategory(status.category.rawValue) ?? .unstarted, status: status) { editing = nil }
        }
        .sheet(item: $archiving) { status in
            SettingsArchiveStatusSheet(status: status, onClose: { archiving = nil }, onViewIssues: {
                archiving = nil
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    inspecting = status
                }
            })
        }
        .sheet(item: $inspecting) { status in
            SettingsStatusIssuesSheet(status: status) { inspecting = nil }
        }
    }

    private func regroup() {
        let items = session.issueStatusEntries.items
        groups = SettingsRules.statusCategories.map { category in
            (category, items
                .filter { SettingsRules.normalizeCategory($0.category.rawValue) == category && (showArchived || $0.archivedAt == nil) }
                .sorted(by: SettingsRules.compareStatuses))
        }
    }
}

extension IssueStatusEntry {
    /// Localized name for built-ins, the custom name otherwise.
    var settingsDisplayName: String { isSystem ? (key.localizedBuiltInName ?? name) : name }
}

private struct SettingsStatusEditing: Identifiable {
    let category: StatusCategory
    var id: String { category.rawValue }
}

private struct SettingsStatusCategorySection: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let category: StatusCategory
    let entries: [IssueStatusEntry]
    let canManage: Bool
    let mergeTarget: String
    let onCreate: () -> Void
    let onEdit: (IssueStatusEntry) -> Void
    let onArchive: (IssueStatusEntry) -> Void
    let onViewIssues: (IssueStatusEntry) -> Void
    let onMergeBadge: () -> Void
    @State private var order: [IssueStatusEntry] = []
    @State private var saving = false
    @State private var dropTarget: String?

    var body: some View {
        let sortable = order.filter { $0.archivedAt == nil }.map(\.id)
        let canReorder = canManage && sortable.count > 1
        VStack(spacing: 0) {
            HStack {
                Text(tr("settings", "issue_statuses.category_labels.\(category.rawValue)"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if canManage {
                    Button(action: onCreate) { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help(tr("settings", "issue_statuses.add"))
                        .accessibilityLabel("\(tr("settings", "issue_statuses.add")): \(tr("settings", "issue_statuses.category_labels.\(category.rawValue)"))")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Color.primary.opacity(0.03))
            ForEach(Array(order.enumerated()), id: \.element.id) { index, entry in
                Divider()
                let activeIndex = sortable.firstIndex(of: entry.id)
                let canMove = canReorder && !saving && activeIndex != nil
                SettingsStatusRow(entry: entry, canManage: canManage, canReorder: canReorder && entry.archivedAt == nil, saving: saving,
                                  showsMergeBadge: entry.key.rawValue == mergeTarget && entry.archivedAt == nil,
                                  onEdit: { onEdit(entry) }, onArchive: { onArchive(entry) }, onViewIssues: { onViewIssues(entry) },
                                  onMergeBadge: onMergeBadge,
                                  onMoveUp: canMove && (activeIndex ?? 0) > 0 ? {
                                      move(from: index, to: order.firstIndex { $0.id == sortable[(activeIndex ?? 0) - 1] } ?? index)
                                  } : nil,
                                  onMoveDown: canMove && (activeIndex ?? 0) < sortable.count - 1 ? {
                                      move(from: index, to: order.firstIndex { $0.id == sortable[(activeIndex ?? 0) + 1] } ?? index)
                                  } : nil)
                    .overlay(alignment: .top) {
                        if dropTarget == entry.id { Rectangle().fill(Theme.brand).frame(height: 2) }
                    }
                    .dropDestination(for: String.self) { ids, _ in
                        guard canMove, let id = ids.first, let from = order.firstIndex(where: { $0.id == id }) else { return false }
                        move(from: from, to: index)
                        return true
                    } isTargeted: { targeted in
                        if targeted { dropTarget = entry.id } else if dropTarget == entry.id { dropTarget = nil }
                    }
            }
        }
        .onChange(of: entries, initial: true) { order = entries }
    }

    /// Optimistic reorder of the ACTIVE rows; rolled back on failure.
    private func move(from: Int, to: Int) {
        guard canManage, !saving, from != to, order.indices.contains(from), order.indices.contains(to),
              order[from].archivedAt == nil, order[to].archivedAt == nil else { return }
        var next = order
        next.insert(next.remove(at: from), at: to)
        order = next
        saving = true
        let active = next.filter { $0.archivedAt == nil }
        let store = session.issueStatusEntries
        for (i, e) in active.enumerated() {
            var moved = e
            moved.position = Double(i + 1)
            store.upsert(moved)
        }
        Task {
            defer { saving = false }
            do {
                _ = try await session.api.reorderIssueStatuses(category: category.rawValue, ids: active.map(\.id), includeSystem: true)
            } catch {
                order = entries
                toaster.show((error as? APIError)?.message ?? tr("settings", "issue_statuses.reorder_failed"), kind: .error)
                await store.load()
            }
        }
    }
}

private struct SettingsStatusRow: View {
    let entry: IssueStatusEntry
    let canManage: Bool
    let canReorder: Bool
    let saving: Bool
    let showsMergeBadge: Bool
    let onEdit: () -> Void
    let onArchive: () -> Void
    let onViewIssues: () -> Void
    let onMergeBadge: () -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let archived = entry.archivedAt != nil
        let label = entry.settingsDisplayName
        let description = entry.isSystem ? tr("settings", "issue_statuses.built_in_descriptions.\(entry.key.rawValue)") : (entry.description ?? "")
        HStack(spacing: 8) {
            Group {
                if canReorder {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .draggable(entry.id) {
                            HStack(spacing: 6) {
                                StatusIcon(status: entry.key, entry: entry)
                                Text(label)
                            }
                            .padding(6)
                        }
                        .help(tr("settings", "issue_statuses.actions.reorder", ["name": label]))
                        .disabled(saving)
                } else {
                    Color.clear.frame(width: 24, height: 24)
                }
            }
            StatusIcon(status: entry.key, entry: entry, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(label).font(Theme.Font.bodyMedium).lineLimit(1)
                    if showsMergeBadge {
                        Button(action: onMergeBadge) {
                            Label(tr("settings", "issue_statuses.pr_auto_complete_badge"), systemImage: "bolt.fill")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.info)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.info.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                    }
                    if archived {
                        Text(tr("settings", "issue_statuses.archived_badge"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .help(tr("settings", "issue_statuses.archived_hint"))
                    }
                }
                if !description.isEmpty {
                    Text(description).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if archived {
                Button(tr("settings", "issue_statuses.archive_dialog.view_issues"), action: onViewIssues).controlSize(.small)
            }
            if canManage && !archived {
                Menu {
                    Button(action: { onMoveUp?() }) { Label(tr("settings", "issue_statuses.actions.move_up"), systemImage: "arrow.up") }
                        .disabled(onMoveUp == nil)
                    Button(action: { onMoveDown?() }) { Label(tr("settings", "issue_statuses.actions.move_down"), systemImage: "arrow.down") }
                        .disabled(onMoveDown == nil)
                    Divider()
                    Button(action: onEdit) { Label(tr("settings", "issue_statuses.actions.edit"), systemImage: "pencil") }
                        .disabled(entry.isSystem)
                    Button(role: .destructive, action: onArchive) { Label(tr("settings", "issue_statuses.actions.archive"), systemImage: "archivebox") }
                        .disabled(entry.isSystem)
                    if entry.isSystem {
                        Divider()
                        Text(tr("settings", "issue_statuses.built_in_locked"))
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
                .opacity(hovering ? 1 : 0.001)
                .accessibilityLabel(tr("settings", "issue_statuses.actions.open", ["name": label]))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .opacity(archived ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct SettingsStatusEditorSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let category: StatusCategory
    let status: IssueStatusEntry?
    let onClose: () -> Void
    @State private var name = ""
    @State private var details = ""
    @State private var draftCategory: StatusCategory = .unstarted
    @State private var color = SettingsColor.defaultColor
    @State private var icon = ""
    @State private var iconChanged = false
    @State private var saving = false

    static let icons = ["dotted", "circle", "half", "three_quarters", "check", "slash", "cross"]

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        SettingsDialog(title: status == nil ? tr("settings", "issue_statuses.editor.create_title") : tr("settings", "issue_statuses.editor.edit_title"), width: 512) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "issue_statuses.editor.name"))
                    TextField(tr("settings", "issue_statuses.editor.name_placeholder"), text: Binding(get: { name }, set: { name = String($0.prefix(64)) }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                    if let status {
                        Text(tr("settings", "issue_statuses.editor.key_hint", ["key": status.key.rawValue]))
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "issue_statuses.editor.category"))
                    Picker("", selection: $draftCategory) {
                        ForEach(SettingsRules.statusCategories, id: \.self) {
                            Text(tr("settings", "issue_statuses.category_labels.\($0.rawValue)")).tag($0)
                        }
                    }
                    .labelsHidden()
                    .disabled(status != nil)
                    Text(status != nil ? tr("settings", "issue_statuses.editor.category_locked") : tr("settings", "issue_statuses.categories.\(draftCategory.rawValue)"))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "issue_statuses.editor.description"))
                    SettingsTextArea(text: Binding(get: { details }, set: { details = String($0.prefix(256)) }),
                                     placeholder: tr("settings", "issue_statuses.editor.description_placeholder"))
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.contains(.command) else { return .ignored }
                            submit()
                            return .handled
                        }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "issue_statuses.editor.color"))
                    SettingsColorField(color: $color) { glyph(icon, size: 18) }
                        .accessibilityLabel(tr("settings", "issue_statuses.editor.color"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel(tr("settings", "issue_statuses.editor.icon"))
                    HStack(spacing: 8) {
                        ForEach([""] + Self.icons, id: \.self) { shape in
                            let selected = icon == shape
                            Button {
                                iconChanged = true
                                icon = shape
                            } label: {
                                Group {
                                    if shape.isEmpty {
                                        Text(tr("settings", "issue_statuses.editor.icon_shapes.default")).font(Theme.Font.body).padding(.horizontal, 10)
                                    } else {
                                        glyph(shape, size: 18).frame(width: 36)
                                    }
                                }
                                .frame(height: 36)
                                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(selected ? Theme.selected : Theme.settingsCard))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium)
                                    .strokeBorder(selected ? Theme.brand : Theme.border, lineWidth: selected ? 2 : 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(tr("settings", "issue_statuses.editor.icon_shapes.\(shape.isEmpty ? "default" : shape)"))
                            .accessibilityLabel(tr("settings", "issue_statuses.editor.icon_shapes.\(shape.isEmpty ? "default" : shape)"))
                        }
                    }
                }
            }
        } footer: {
            Button(tr("settings", "issue_statuses.editor.cancel"), action: onClose).keyboardShortcut(.cancelAction)
            Button(saving ? tr("settings", "issue_statuses.editor.saving") : tr("settings", "issue_statuses.editor.save"), action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || saving)
        }
        .onAppear {
            draftCategory = category
            if let status {
                name = status.name
                details = status.description ?? ""
                color = status.color
                icon = Self.icons.contains(status.icon ?? "") ? status.icon ?? "" : ""
            }
        }
    }

    private func glyph(_ shape: String, size: CGFloat) -> StatusIcon {
        StatusIcon(glyph: StatusIcon.Glyph(rawValue: shape) ?? StatusIcon.glyph(for: draftCategory), color: Color(hex: color), size: size)
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !saving else { return }
        saving = true
        let description = details.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { saving = false }
            do {
                if let status {
                    _ = try await session.api.updateIssueStatus(status.id, UpdateIssueStatusRequest(name: trimmed, description: description, color: color,
                                                                                                   icon: iconChanged ? icon : nil))
                    await session.issueStatusEntries.load()
                    onClose()
                } else {
                    let created = try await session.api.createIssueStatus(CreateIssueStatusRequest(name: trimmed, description: description,
                                                                                                  category: draftCategory.rawValue, color: color, icon: icon))
                    await session.issueStatusEntries.load()
                    onClose()
                    if !created.key.rawValue.isEmpty {
                        toaster.success(tr("settings", "issue_statuses.editor.created", ["key": created.key.rawValue]))
                    }
                }
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("settings", "issue_statuses.editor.save_failed"), kind: .error)
            }
        }
    }
}

/// Confirms an archive; a status still in use turns into the "move issues
/// first" state with a way to see them.
private struct SettingsArchiveStatusSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let status: IssueStatusEntry
    let onClose: () -> Void
    let onViewIssues: () -> Void
    @State private var issueCount: Int?
    @State private var pending = false

    var body: some View {
        SettingsDialog(title: issueCount != nil ? tr("settings", "issue_statuses.archive_dialog.in_use_title") : tr("settings", "issue_statuses.archive_dialog.title"),
                       description: issueCount.map { tr("settings", "issue_statuses.archive_dialog.in_use", ["count": $0]) }
                        ?? tr("settings", "issue_statuses.archive_dialog.description", ["name": status.name])) {
            EmptyView()
        } footer: {
            Button(tr("settings", "issue_statuses.archive_dialog.cancel"), action: onClose)
                .keyboardShortcut(.cancelAction)
                .disabled(pending)
            Button(pending ? tr("settings", "issue_statuses.archive_dialog.archiving")
                   : issueCount != nil ? tr("settings", "issue_statuses.archive_dialog.retry") : tr("settings", "issue_statuses.archive_dialog.confirm"),
                   action: archive)
                .disabled(pending)
            if issueCount != nil {
                Button(tr("settings", "issue_statuses.archive_dialog.view_issues"), action: onViewIssues)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pending)
            }
        }
        .interactiveDismissDisabled(pending)
    }

    private func archive() {
        pending = true
        Task {
            defer { pending = false }
            do {
                try await session.api.settingsArchiveIssueStatus(status.id)
                await session.issueStatusEntries.load()
                onClose()
            } catch let e as SettingsAPIError where e.issueCount != nil {
                issueCount = e.issueCount
            } catch {
                toaster.show((error as? SettingsAPIError)?.message ?? tr("settings", "issue_statuses.archive_dialog.failed"), kind: .error)
            }
        }
    }
}

/// Every issue on one status (including done and cancelled ones), with a
/// batch status change to move them off it.
private struct SettingsStatusIssuesSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let status: IssueStatusEntry
    let onClose: () -> Void
    @State private var issues: [Issue] = []
    @State private var loading = true
    @State private var selection = Set<String>()
    @State private var updating = false

    var body: some View {
        let targets = session.issueStatusEntries.items.filter { $0.archivedAt == nil && $0.key != status.key }.sorted(by: SettingsRules.compareStatuses)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: onClose) { Label(tr("settings", "issue_statuses.title"), systemImage: "arrow.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
            HStack(spacing: 8) {
                StatusIcon(status: status.key, entry: status, size: 16)
                Text(status.settingsDisplayName).font(Theme.Font.title)
            }
            HStack(spacing: 12) {
                Text(tr("issues", "batch.selected", ["count": selection.count])).font(Theme.Font.caption).foregroundStyle(.secondary)
                Menu {
                    ForEach(targets) { target in
                        Button { move(to: target.key) } label: { Text(target.settingsDisplayName) }
                    }
                } label: {
                    Label(tr("issues", "batch.status"), systemImage: "circle.dashed")
                }
                .fixedSize()
                .disabled(selection.isEmpty || updating)
                Spacer()
                if updating { ProgressView().controlSize(.small) }
            }
            Group {
                if loading {
                    LoadingView()
                } else if issues.isEmpty {
                    EmptyStateView(icon: "checklist", title: tr("issues", "list.empty_status"))
                } else {
                    List(issues, selection: $selection) { issue in
                        HStack(spacing: 8) {
                            StatusIcon(status: issue.status, entry: status)
                            Text(issue.identifier).font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                                .frame(width: 72, alignment: .leading)
                            Text(issue.title).font(Theme.Font.body).lineLimit(1)
                            Spacer(minLength: 8)
                            if let a = issue.assignee { ActorAvatar(type: a.type, id: a.id, size: 18) }
                        }
                    }
                    .contextMenu(forSelectionType: String.self) { _ in
                        ForEach(targets) { target in
                            Button(target.settingsDisplayName) { move(to: target.key) }
                        }
                    } primaryAction: { ids in
                        if let id = ids.first {
                            onClose()
                            nav.openInNewTab(.issue(id))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(width: 880, height: 600)
        .task { await load() }
    }

    private func load() async {
        var params = ListIssuesParams()
        params.limit = 200
        params.statuses = [status.key.rawValue]
        if let page = try? await session.api.listIssues(params: params) { issues = page.issues }
        loading = false
    }

    private func move(to key: IssueStatusKey) {
        let ids = Array(selection)
        guard !ids.isEmpty else { return }
        updating = true
        Task {
            defer { updating = false }
            do {
                var updates = UpdateIssueRequestRecord()
                updates.status = key.rawValue
                let count = try await session.api.batchUpdateIssues(ids, updates: updates)
                toaster.success(tr("issues", "batch.update_success", ["count": count]))
                selection = []
                await load()
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("issues", "batch.update_failed"), kind: .error)
            }
        }
    }
}
