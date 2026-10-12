import MulticaCore
import SwiftUI

/// Faceted filters for the list on screen (upstream inbox-filter-menu.tsx):
/// unread only, then From / Status / Priority submenus, each count ignoring
/// its own dimension.
struct InboxFilterMenu: View {
    let model: InboxPageModel
    @State private var open = false

    var body: some View {
        let active = InboxFiltering.count(model.effectiveFilters)
        let label = active > 0 ? tr("inbox", "filters.active_count", ["count": active]) : tr("inbox", "filters.tooltip")
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                if active > 0 { Text("\(active)").font(Theme.Font.caption).monospacedDigit() }
            }
            .foregroundStyle(active > 0 ? Color.white : Color.secondary)
            .padding(.horizontal, active > 0 ? 8 : 5)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(active > 0 ? Theme.brand : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            InboxFilterPopover(model: model)
        }
    }
}

private enum InboxFilterPage: Hashable {
    case root, from, status, priority
}

private struct InboxFacetInputs: Hashable {
    var filters: InboxFilters
    var rows: [InboxItem]
    var archived: Bool
}

private struct ActorOption: Identifiable {
    var id: String { key }
    var key: String
    var type: String
    var name: String
    var avatarURL: String?
}

private struct InboxFilterPopover: View {
    @Environment(WorkspaceSession.self) private var session
    let model: InboxPageModel
    @State private var page: InboxFilterPage = .root
    @State private var facets = InboxFiltering.Facets()
    @State private var actors: [ActorOption] = []
    @State private var statusKeys: [IssueStatusKey] = []
    @State private var facetsLoading = false
    @State private var facetsError = false

    private var store: InboxFilterStore { InboxFilterStore.shared }
    private var wsID: String { model.wsID }
    private var filters: InboxFilters { model.effectiveFilters }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch page {
            case .root: root
            case .from: fromPage
            case .status: statusPage
            case .priority: priorityPage
            }
        }
        .padding(4)
        .frame(minWidth: 220)
        .task(id: InboxFacetInputs(filters: store.filters(wsID), rows: model.viewItems, archived: model.isArchived)) {
            if model.isArchived {
                await loadFacets()
            } else {
                facets = InboxFiltering.facets(model.viewItems, filters)
                rebuildOptions()
            }
        }
    }

    private func loadFacets() async {
        facetsLoading = true
        facetsError = false
        do {
            facets = InboxFiltering.Facets(try await session.api.getArchivedInboxFacets(store.filters(wsID)))
        } catch {
            facetsError = true
        }
        facetsLoading = false
        rebuildOptions()
    }

    private func rebuildOptions() {
        let actorKeys = model.isArchived
            ? InboxFiltering.actorKeys([], selected: filters.actors, facetKeys: facets.actors.keys.sorted())
            : InboxFiltering.actorKeys(model.viewItems)
        actors = actorKeys.map { key in
            let parts = InboxFiltering.actorKeyParts(key)
            let info = session.actorInfo(type: parts.type, id: parts.id)
            return ActorOption(key: key, type: parts.type, name: info.name, avatarURL: info.avatarURL)
        }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        let keys = InboxFiltering.statusKeys(model.isArchived ? [] : model.viewItems, selected: filters.statuses, facetKeys: Array(facets.statuses.keys))
        let present = Set(keys)
        statusKeys = session.issues.catalog.columns(including: keys.map { IssueStatusKey(rawValue: $0) }).filter { present.contains($0.rawValue) }
    }

    @ViewBuilder private var root: some View {
        if model.isArchived && facetsLoading {
            Text(tr("inbox", "list.loading_more")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
        }
        if model.isArchived && facetsError {
            HStack {
                Text(tr("inbox", "errors.filters_load_failed")).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                Button(tr("inbox", "list.retry")) { Task { await loadFacets() } }.buttonStyle(.link).font(Theme.Font.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        InboxFilterCheckRow(
            icon: AnyView(Image(systemName: "envelope")),
            title: tr("inbox", "filters.unread_only"),
            count: facets.unreadCount,
            checked: filters.unreadOnly
        ) { store.update(wsID) { $0.unreadOnly.toggle() } }
        Divider().padding(.vertical, 3)
        if !actors.isEmpty {
            InboxFilterSubmenuRow(icon: "person", title: tr("inbox", "filters.from"), selected: filters.actors.count) { page = .from }
        }
        InboxFilterSubmenuRow(icon: "circle.dashed", title: tr("inbox", "filters.status"), selected: filters.statuses.count) { page = .status }
        if model.prioritySupport == .supported {
            InboxFilterSubmenuRow(icon: "chart.bar", title: tr("inbox", "filters.priority"), selected: filters.priorities.count) { page = .priority }
        }
        if InboxFiltering.count(filters) > 0 {
            Divider().padding(.vertical, 3)
            Button { store.clear(wsID) } label: {
                Label(tr("inbox", "filters.clear"), systemImage: "arrow.counterclockwise").font(Theme.Font.body)
            }
            .buttonStyle(HoverRowButtonStyle())
        }
    }

    private func back(_ title: String) -> some View {
        Button { page = .root } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Text(title).font(Theme.Font.bodyMedium)
                Spacer()
            }
        }
        .buttonStyle(HoverRowButtonStyle())
    }

    @ViewBuilder private var fromPage: some View {
        back(tr("inbox", "filters.from"))
        Divider().padding(.vertical, 3)
        ScrollView {
            VStack(spacing: 0) {
                ForEach(actors) { o in
                    InboxFilterCheckRow(
                        icon: AnyView(AvatarView(name: o.name, url: o.avatarURL, kind: AvatarKind(actorType: o.type), size: 16)),
                        title: o.name,
                        count: facets.actors[o.key] ?? 0,
                        checked: filters.actors.contains(o.key)
                    ) { store.update(wsID) { $0.actors = InboxFiltering.toggling(o.key, in: $0.actors) } }
                }
            }
        }
        .frame(maxHeight: 320)
    }

    @ViewBuilder private var statusPage: some View {
        let catalog = session.issues.catalog
        back(tr("inbox", "filters.status"))
        Divider().padding(.vertical, 3)
        ScrollView {
            VStack(spacing: 0) {
                ForEach(statusKeys, id: \.self) { key in
                    InboxFilterCheckRow(
                        icon: AnyView(catalog.icon(for: key, size: 13)),
                        title: catalog.localizedName(for: key),
                        count: facets.statuses[key.rawValue] ?? 0,
                        checked: filters.statuses.contains(key.rawValue)
                    ) { store.update(wsID) { $0.statuses = InboxFiltering.toggling(key.rawValue, in: $0.statuses) } }
                }
            }
        }
        .frame(maxHeight: 320)
    }

    @ViewBuilder private var priorityPage: some View {
        back(tr("inbox", "filters.priority"))
        Divider().padding(.vertical, 3)
        ForEach(IssuePriority.displayOrder, id: \.self) { p in
            InboxFilterCheckRow(
                icon: AnyView(PriorityIcon(priority: p, size: 13)),
                title: p.localizedName,
                count: facets.priorities[p.rawValue] ?? 0,
                checked: filters.priorities.contains(p.rawValue)
            ) { store.update(wsID) { $0.priorities = InboxFiltering.toggling(p.rawValue, in: $0.priorities) } }
        }
    }
}

private struct InboxFilterCheckRow: View {
    let icon: AnyView
    let title: String
    let count: Int
    let checked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.brand)
                    .opacity(checked ? 1 : 0)
                    .frame(width: 12)
                icon.frame(width: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 12)
                if count > 0 {
                    Text(tr("inbox", "filters.notification_count", ["count": count]))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            }
            .font(Theme.Font.body)
        }
        .buttonStyle(HoverRowButtonStyle())
    }
}

private struct InboxFilterSubmenuRow: View {
    let icon: String
    let title: String
    let selected: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 12)
                Image(systemName: icon).frame(width: 16).foregroundStyle(.secondary)
                Text(title)
                Spacer(minLength: 12)
                if selected > 0 {
                    Text("\(selected)").font(Theme.Font.caption.weight(.medium)).foregroundStyle(Theme.brand)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .font(Theme.Font.body)
        }
        .buttonStyle(HoverRowButtonStyle())
    }
}
