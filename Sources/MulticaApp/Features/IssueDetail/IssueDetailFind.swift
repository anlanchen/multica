import MulticaCore
import SwiftUI

struct IssueDetailFindState: Equatable {
    var query: String
    var currentID: String?
}

struct IssueDetailFindMatch: Equatable {
    var rowID: String
    var count: Int
}

/// Upstream FindBar (⌘F): query field, n/total, previous/next, close. The
/// native page matches at comment granularity and scrolls each match into
/// view with a flash, since rendered Markdown is not a DOM to walk.
struct IssueDetailFindBar: View {
    @Binding var query: String
    @Binding var index: Int
    let matches: [IssueDetailFindMatch]
    let onClose: () -> Void
    let onMove: () -> Void
    @FocusState private var focused: Bool

    private var total: Int { matches.reduce(0) { $0 + $1.count } }

    var body: some View {
        HStack(spacing: 6) {
            TextField(tr("issues", "detail.find.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                .onKeyPress(.escape) { onClose(); return .handled }
            Text(query.isEmpty ? "" : total == 0 ? tr("issues", "detail.find.no_matches")
                 : tr("issues", "detail.find.count", ["current": index + 1, "total": total]))
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 54, alignment: .trailing)
            Divider().frame(height: 14)
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .help(tr("issues", "detail.find.previous"))
                .disabled(total == 0)
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .help(tr("issues", "detail.find.next"))
                .disabled(total == 0)
            Button(action: onClose) { Image(systemName: "xmark") }
                .help(tr("issues", "detail.find.close"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .onAppear { focused = true }
    }

    private func step(_ delta: Int) {
        guard total > 0 else { return }
        index = (index + delta + total) % total
        onMove()
    }
}

/// Upstream ThreadMinimap: a rail of ticks along the content's right edge,
/// one per comment thread (replies as shorter ticks); hover previews, click
/// jumps.
struct IssueDetailThreadRail: View {
    let store: IssueDetailStore

    var body: some View {
        let threads = store.layout.items.compactMap(\.thread).filter { !$0.root.isDeletedComment || !$0.visibleReplies.isEmpty }
        if threads.count >= 2 {
            VStack(spacing: 0) {
                ForEach(threads, id: \.root.id) { thread in
                    IssueDetailRailTick(store: store, thread: thread)
                    Spacer(minLength: 2)
                }
            }
            .frame(width: 16)
            .frame(maxHeight: .infinity)
            .accessibilityLabel(tr("issues", "detail.thread_nav_label"))
        }
    }
}

private struct IssueDetailRailTick: View {
    @Environment(WorkspaceSession.self) private var session
    let store: IssueDetailStore
    let thread: IssueDetailThread
    @State private var hovering = false

    var body: some View {
        let resolved = thread.resolution != .none
        VStack(alignment: .trailing, spacing: 2) {
            Capsule()
                .fill(resolved ? Color.secondary.opacity(0.35) : (hovering ? Theme.brand : Color.secondary.opacity(0.7)))
                .frame(width: hovering ? 14 : 10, height: 3)
            ForEach(thread.visibleReplies.prefix(6), id: \.id) { _ in
                Capsule().fill(Color.secondary.opacity(resolved ? 0.2 : 0.4)).frame(width: 6, height: 2)
            }
        }
        .frame(width: 16, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.jump(to: thread.root.id) }
        .help(label)
    }

    private var label: String {
        let title = thread.root.isDeletedComment ? tr("issues", "comment.deleted_placeholder") : IssueDetailFormat.preview(thread.root.content ?? "", limit: 140)
        let author = session.actorInfo(type: thread.root.actorType, id: thread.root.actorID).name
        let line = tr("issues", "detail.thread_nav_reply_label", ["author": author, "title": title])
        return thread.resolution != .none ? tr("issues", "detail.thread_nav_resolved_label", ["title": line]) : line
    }
}
