import AppKit
import MulticaCore
import SwiftUI

/// The inbox: notification list on the left, the selected item's issue (or
/// the notification itself) on the right (upstream inbox-page.tsx).
struct InboxPage: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    @Environment(ModalCenter.self) private var modals
    @State private var model: InboxPageModel?

    var body: some View {
        Group {
            if let model {
                InboxSplit(model: model)
                    .onChange(of: session.inbox.items) { model.liveRefresh() }
                    .onChange(of: session.inbox.lastArrived?.id) { if model.isArchived { model.liveRefresh() } }
                    .onChange(of: session.inbox.unread(in: session.workspace.id)) { if model.isArchived { model.liveRefresh() } }
                    .onChange(of: InboxFilterStore.shared.filters(session.workspace.id)) { model.filtersChanged() }
                    .onChange(of: nav.query("issue")) { syncFromURL(model) }
                    .onChange(of: nav.query("view")) { syncFromURL(model) }
                    .onChange(of: session.issues.loadedCount) { old, new in if new < old { model.issueRemoved() } }
                    .onChange(of: session.issues.catalog) { model.recompute() }
                    .onReceive(NotificationCenter.default.publisher(for: .multicaArchiveInboxItem)) { _ in
                        guard modals.current == nil else { return }
                        _ = model.actionOnSelected()
                    }
            } else {
                Color.clear
            }
        }
        .tabTitle(tr("inbox", "page.title"))
        .onAppear {
            guard model == nil else { return }
            let m = InboxPageModel(session: session)
            m.nav = nav
            m.toaster = toaster
            model = m
        }
        .task {
            guard let model else { return }
            await model.start(urlKey: nav.query("issue") ?? "", urlView: urlView)
        }
    }

    private var urlView: InboxView {
        nav.query("view") == InboxView.archivedParam ? .archived : .inbox
    }

    private func syncFromURL(_ model: InboxPageModel) {
        model.applyURL(key: nav.query("issue") ?? "", view: urlView)
    }
}

private struct InboxSplit: View {
    let model: InboxPageModel

    var body: some View {
        HSplitView {
            InboxListPane(model: model)
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 400)
            InboxDetailPane(model: model)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: List pane

private struct InboxListPane: View {
    @Environment(WorkspaceSession.self) private var session
    let model: InboxPageModel

    var body: some View {
        VStack(spacing: 0) {
            if model.viewLoading {
                InboxSkeleton()
            } else {
                header
                if model.isArchived { archivedBackRow }
                if model.needsLookup && model.lookupLoading {
                    Text(tr("inbox", "list.loading_selection"))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Divider() }
                }
                if model.needsLookup && model.lookupError && model.selected == nil {
                    HStack(spacing: 8) {
                        Text(tr("inbox", "errors.archived_lookup_failed"))
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(tr("inbox", "list.retry")) { model.retryLookup() }
                            .controlSize(.small)
                            .disabled(model.lookupLoading)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Divider() }
                }
                if model.isArchived && model.archivedError {
                    VStack(spacing: 10) {
                        Image(systemName: "archivebox").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                        Text(tr("inbox", "errors.archived_load_failed")).font(Theme.Font.body).foregroundStyle(.secondary)
                        Button(tr("inbox", "list.retry")) { Task { await model.loadArchived() } }
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    InboxList(model: model)
                }
            }
        }
        .background(Theme.canvas)
    }

    private var header: some View {
        PageHeader {
            HStack(spacing: 8) {
                Text(tr("inbox", "page.title")).font(Theme.Font.bodyMedium)
                let unread = session.inbox.unread(in: session.workspace.id)
                if unread > 0 {
                    Text("\(unread)").font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } trailing: {
            HStack(spacing: 2) {
                InboxFilterMenu(model: model)
                if !model.isArchived {
                    Menu {
                        Button { model.markAllRead() } label: { Label(tr("inbox", "menu.mark_all_read"), systemImage: "checkmark.circle") }
                        Divider()
                        Button { model.archiveAll() } label: { Label(tr("inbox", "menu.archive_all"), systemImage: "archivebox") }
                        Button { model.archiveAllRead() } label: { Label(tr("inbox", "menu.archive_all_read"), systemImage: "book.closed") }
                        Button { model.archiveCompleted() } label: { Label(tr("inbox", "menu.archive_completed"), systemImage: "checklist") }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 24)
                }
            }
        }
    }

    private var archivedBackRow: some View {
        Button { model.setView(.inbox) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text(tr("inbox", "list.archived_title")).font(Theme.Font.caption.weight(.medium)).lineLimit(1)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 0)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct InboxSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 4).fill(Theme.hover).frame(width: 64, height: 18)
                .padding(.horizontal, 16).frame(height: 44)
                .overlay(alignment: .bottom) { Divider() }
            VStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: 12) {
                        Circle().fill(Theme.hover).frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.hover).frame(height: 12).frame(maxWidth: 170)
                            RoundedRectangle(cornerRadius: 3).fill(Theme.hover).frame(height: 10).frame(maxWidth: 110)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
            }
            .padding(8)
            Spacer()
        }
    }
}

// MARK: List

private struct InboxList: View {
    @Environment(Navigator.self) private var nav
    let model: InboxPageModel
    @State private var nonce = 0

    var body: some View {
        let items = model.visibleItems
        // Read so a ⌘-click (which must not move the selection) re-syncs
        // the table's highlight with the model.
        let _ = nonce
        if items.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    if !(model.isArchived && model.archivedHasMore) {
                        VStack(spacing: 10) {
                            Image(systemName: "tray").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                            Text(emptyLabel).font(Theme.Font.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if model.hasActiveFilters {
                                Button(tr("inbox", "filters.clear")) { InboxFilterStore.shared.clear(model.wsID) }
                                    .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 48)
                        .frame(maxWidth: .infinity)
                    }
                    footer.padding(.horizontal, 8)
                }
            }
            .task(id: model.isArchived && model.archivedHasMore) {
                if model.isArchived && model.archivedHasMore { await model.loadMoreArchived() }
            }
        } else {
            List(selection: selection) {
                ForEach(items) { item in
                    InboxRow(item: item, view: model.view, onAction: { model.action(item.id) })
                        .equatable()
                        .tag(InboxFiltering.key(item))
                        .contextMenu { InboxRowMenu(item: item, model: model) }
                }
                footer
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyLabel: String {
        if model.hasActiveFilters { return tr("inbox", "filters.empty") }
        return model.isArchived ? tr("inbox", "list.archived_empty") : tr("inbox", "list.empty")
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedKey.isEmpty ? nil : model.selectedKey },
            set: { newValue in
                if NSEvent.modifierFlags.contains(.command) {
                    let key = newValue ?? model.selectedKey
                    if let item = model.visibleItems.first(where: { InboxFiltering.key($0) == key }), let issueID = item.issueID {
                        nav.openInNewTab(.issue(issueID), activate: false)
                        nonce += 1
                        return
                    }
                }
                guard let newValue else { return }
                if let item = model.visibleItems.first(where: { InboxFiltering.key($0) == newValue }) {
                    model.click(item)
                } else {
                    model.select(newValue)
                }
            }
        )
    }

    @ViewBuilder private var footer: some View {
        if model.isArchived {
            if model.archivedHasMore {
                VStack(spacing: 6) {
                    if model.loadMoreError {
                        Text(tr("inbox", "errors.archived_load_failed")).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                    }
                    Button(model.loadingMore ? tr("inbox", "list.loading_more")
                           : model.loadMoreError ? tr("inbox", "list.retry") : tr("inbox", "list.load_more")) {
                        Task { await model.loadMoreArchived() }
                    }
                    .buttonStyle(.borderless)
                    .font(Theme.Font.caption)
                    .disabled(model.loadingMore)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .onAppear {
                    if !model.loadMoreError { Task { await model.loadMoreArchived() } }
                }
            }
        } else {
            Button { model.setView(.archived) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox").frame(width: 28)
                    Text(tr("inbox", "list.archived_title")).font(Theme.Font.caption.weight(.medium)).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .frame(height: 36)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            .padding(.top, 4)
        }
    }
}

/// Right-click actions for a row (upstream inbox-item-actions.ts).
struct InboxRowMenu: View {
    @Environment(Navigator.self) private var nav
    let item: InboxItem
    let model: InboxPageModel

    var body: some View {
        if let issueID = item.issueID {
            Button { nav.openInNewTab(.issue(issueID)) } label: {
                Label(tr("inbox", "context_menu.open_in_new_tab"), systemImage: "arrow.up.forward.square")
            }
            Divider()
        }
        if !model.isArchived {
            if item.read {
                Button { model.markUnread(item.id) } label: { Label(tr("inbox", "context_menu.mark_unread"), systemImage: "circle.dashed") }
            } else {
                Button { model.markRead(item.id) } label: { Label(tr("inbox", "context_menu.mark_read"), systemImage: "checkmark") }
            }
            Divider()
        }
        if model.isArchived {
            Button { model.unarchive(item.id) } label: { Label(tr("inbox", "context_menu.unarchive"), systemImage: "tray.and.arrow.up") }
        } else {
            Button { model.archive(item.id) } label: { Label(tr("inbox", "context_menu.archive"), systemImage: "archivebox") }
        }
    }
}
