import MulticaCore
import SwiftUI

/// The issue detail page (upstream IssueDetailRoute + IssueDetail). Hosted
/// by tabs, standalone issue windows and the inbox's right pane; accepts a
/// UUID or an identifier (`MUL-123`).
struct IssueDetailPage: View {
    let issueID: String

    @Environment(WorkspaceSession.self) private var session
    @State private var store: IssueDetailStore?
    @State private var openedFor: String?
    @State private var notFound = false

    var body: some View {
        Group {
            if let store, !store.notFound {
                IssueDetailScreen(store: store)
            } else if notFound || store?.notFound == true {
                IssueDetailNotFound()
            } else {
                IssueDetailSkeleton()
            }
        }
        .task(id: issueID) { await open() }
        .onDisappear { store?.close() }
    }

    private func open() async {
        if let store, openedFor == issueID {
            store.reopenIfNeeded()
            await store.loadAll()
            return
        }
        store?.close()
        store = nil
        notFound = false
        var id = issueID
        if !IssueDetailIDs.isUUID(id) {
            if let m = session.issues.model(identifier: id) {
                id = m.id
            } else {
                do {
                    let fetched = try await session.api.issueDetailFetch(id)
                    session.issues.upsert(fetched.issue)
                    id = fetched.issue.id
                } catch {
                    guard !Task.isCancelled else { return }
                    notFound = true
                    return
                }
            }
        }
        guard !Task.isCancelled else { return }
        let s = IssueDetailStore(session: session, issueID: id)
        store = s
        openedFor = issueID
        await s.loadAll()
    }
}

struct IssueDetailNotFound: View {
    @Environment(Navigator.self) private var nav

    var body: some View {
        VStack(spacing: 12) {
            Text(tr("issues", "detail.not_found")).font(Theme.Font.body).foregroundStyle(.secondary)
            Button {
                if nav.canGoBack { nav.back() } else { nav.replace(.issues) }
            } label: {
                Label(tr("issues", "detail.back"), systemImage: "chevron.left")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Upstream IssueDetailSkeleton: header, title, body lines and a sidebar.
struct IssueDetailSkeleton: View {
    @Environment(ShellState.self) private var shell

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                bar(64, 12); bar(12, 12); bar(96, 12)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .overlay(alignment: .bottom) { Divider() }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    bar(420, 26)
                    VStack(alignment: .leading, spacing: 8) { bar(.infinity, 12); bar(520, 12); bar(380, 12) }
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(Color.primary.opacity(0.07)).frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 8) { bar(120, 12); bar(.infinity, 56) }
                    }
                    Spacer()
                }
                .frame(maxWidth: 896)
                .padding(32)
                .frame(maxWidth: .infinity)
                if shell.rightPanelOpen {
                    Divider()
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(0..<4, id: \.self) { _ in HStack { bar(60, 10); bar(96, 16) } }
                        Divider()
                        ForEach(0..<3, id: \.self) { _ in HStack { bar(60, 10); bar(110, 12) } }
                        Spacer()
                    }
                    .padding(16)
                    .frame(width: 320)
                }
            }
        }
        .redacted(reason: .placeholder)
    }

    private func bar(_ width: CGFloat, _ height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.primary.opacity(0.07))
            .frame(maxWidth: width == .infinity ? .infinity : width)
            .frame(width: width == .infinity ? nil : width, height: height)
    }
}

/// The loaded page: header, the content column (with the find bar and the
/// thread rail floating over it) and the properties sidebar.
struct IssueDetailScreen: View {
    let store: IssueDetailStore

    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(ShellState.self) private var shell
    @AppStorage("multica.issueDetail.sidebarWidth") private var sidebarWidth: Double = 320
    @State private var findOpen = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    @State private var findMatches: [IssueDetailFindMatch] = []
    @State private var dragStart: Double?
    @State private var runConfirm: IssueDetailRunGate?
    @State private var consumedHighlight: String?

    var body: some View {
        VStack(spacing: 0) {
            IssueDetailHeader(store: store, runConfirm: $runConfirm)
            HStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    IssueDetailMainColumn(store: store, find: findState, runConfirm: $runConfirm)
                    if findOpen {
                        IssueDetailFindBar(query: $findQuery, index: $findIndex, matches: findMatches) {
                            findOpen = false
                            findQuery = ""
                        } onMove: { jumpToMatch() }
                        .padding(.top, 10)
                        .padding(.trailing, 36)
                    }
                    IssueDetailThreadRail(store: store)
                        .padding(.trailing, 6)
                        .padding(.vertical, 12)
                }
                if shell.rightPanelOpen {
                    resizeHandle
                    IssueDetailSidebar(store: store, runConfirm: $runConfirm)
                        .frame(width: sidebarWidth)
                }
            }
        }
        .tabTitle(tabTitle)
        .onChange(of: shell.findRequest) {
            guard isActiveRoute else { return }
            findOpen = true
        }
        .onChange(of: store.issue?.revision) { store.issueRevisionChanged() }
        .onChange(of: session.issues.model(store.issueID) == nil) { _, gone in if gone && store.record != nil { store.markDeleted() } }
        .task(id: session.issues.loadedCount) {
            guard store.children != nil else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await store.loadChildren()
        }
        .task(id: store.layout.items.count) {
            guard let target = nav.query("comment"), consumedHighlight != target,
                  store.layout.items.contains(where: { $0.thread?.root.id == target || store.layout.replyToRoot[target] != nil }) else { return }
            consumedHighlight = target
            store.jump(to: target)
        }
        .onChange(of: findQuery) {
            findIndex = 0
            recomputeMatches()
            jumpToMatch()
        }
        .onChange(of: store.layout) { if findOpen { recomputeMatches() } }
        .onChange(of: findOpen) { if !findOpen { findMatches = [] } }
        .task(id: session.revision("subscriber")) { if session.revision("subscriber") > 0 { await store.loadSubscribers() } }
        .task(id: session.revision("issue_reaction")) { if session.revision("issue_reaction") > 0 { await store.loadRecord() } }
        .task(id: session.revision("issue_properties") &+ session.revision("issue_metadata")) {
            if session.revision("issue_properties") + session.revision("issue_metadata") > 0 { await store.loadRecord() }
        }
        .task(id: session.revision("issue_attachments")) { if session.revision("issue_attachments") > 0 { await store.loadAttachments() } }
        .sheet(item: Binding(get: { runConfirm.map(IssueDetailRunConfirmItem.init) }, set: { if $0 == nil { runConfirm = nil } })) { item in
            IssueDetailRunConfirmSheet(store: store, intent: item.intent)
        }
    }

    private var isActiveRoute: Bool {
        if case .issue = nav.route { return true }
        return false
    }

    private var tabTitle: String? {
        guard case .issue = nav.route, let issue = store.issue else { return nil }
        return "\(issue.identifier) \(issue.title)"
    }

    private var resizeHandle: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                        let start = dragStart ?? sidebarWidth
                        dragStart = start
                        sidebarWidth = min(420, max(260, start - v.translation.width))
                    }.onEnded { _ in dragStart = nil })
            }
    }

    // MARK: Find

    var findState: IssueDetailFindState {
        IssueDetailFindState(query: findOpen ? findQuery : "", currentID: currentMatchID)
    }

    /// Matches per timeline row, in page order (title + description first).
    private func recomputeMatches() {
        let q = findQuery.trimmingCharacters(in: .whitespaces)
        guard findOpen, !q.isEmpty else {
            findMatches = []
            return
        }
        var out: [IssueDetailFindMatch] = []
        let head = (store.issue?.title ?? "") + "\n" + (store.issue?.description ?? store.record?.description ?? "")
        let n = IssueDetailFormat.occurrences(of: q, in: head)
        if n > 0 { out.append(IssueDetailFindMatch(rowID: IssueDetailMainColumn.topID, count: n)) }
        for item in store.layout.items {
            guard let thread = item.thread else { continue }
            for e in [thread.root] + thread.replies where !e.isDeletedComment {
                let c = IssueDetailFormat.occurrences(of: q, in: e.content ?? "")
                if c > 0 { out.append(IssueDetailFindMatch(rowID: e.id, count: c)) }
            }
        }
        findMatches = out
    }

    private var currentMatchID: String? {
        let matches = findMatches
        guard !matches.isEmpty else { return nil }
        var remaining = findIndex
        for m in matches {
            if remaining < m.count { return m.rowID }
            remaining -= m.count
        }
        return matches.last?.rowID
    }

    private func jumpToMatch() {
        guard let id = currentMatchID else { return }
        if id == IssueDetailMainColumn.topID {
            store.scrollRequest = (id, Int.random(in: 1...Int.max))
        } else {
            store.jump(to: id)
        }
    }
}

struct IssueDetailRunConfirmItem: Identifiable {
    let intent: IssueDetailRunGate
    var id: String { "\(intent)" }
}
