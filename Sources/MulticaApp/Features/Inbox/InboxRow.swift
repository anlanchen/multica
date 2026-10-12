import AppKit
import MulticaCore
import SwiftUI

/// One notification row (upstream inbox-list-item.tsx). Equatable on its
/// data, so a change to one notification re-renders one row.
struct InboxRow: View, Equatable {
    let item: InboxItem
    let view: InboxView
    let onAction: () -> Void
    var onHover: (Bool) -> Void = { _ in }
    @State private var hovering = false

    static func == (a: InboxRow, b: InboxRow) -> Bool {
        a.item == b.item && a.view == b.view
    }

    private var isArchived: Bool { view == .archived }
    /// Archiving keeps `read` untouched for a later restore, so archived rows
    /// never show the unread marker.
    private var showUnread: Bool { !item.read && !isArchived }

    var body: some View {
        HStack(spacing: 12) {
            InboxActorAvatar(type: item.actorType ?? item.recipientType, id: item.actorID ?? item.recipientID, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if showUnread {
                        Circle().fill(Theme.brand).frame(width: 6, height: 6)
                    }
                    Text(InboxText.title(item))
                        .font(showUnread ? Theme.Font.bodyMedium : Theme.Font.body)
                        .foregroundStyle(showUnread ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if hovering {
                        Button(action: onAction) {
                            Image(systemName: isArchived ? "tray.and.arrow.up" : "archivebox")
                                .font(.system(size: 11))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(isArchived ? tr("inbox", "list.unarchive_tooltip") : tr("inbox", "list.archive_tooltip"))
                    }
                    if item.issueStatus != nil || item.issueID != nil {
                        InboxRowStatus(item: item)
                    }
                }
                HStack(spacing: 6) {
                    InboxDetailLabel(item: item)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let issueID = item.issueID {
                        InboxRowActivity(issueID: issueID)
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(InboxText.timeAgo(item.createdAt))
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
    }
}

/// Actor avatar; system notifications carry the Multica mark.
struct InboxActorAvatar: View {
    let type: String
    let id: String
    var size: CGFloat = 20

    var body: some View {
        if type == "system" {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: size, height: size)
                .help("Multica")
        } else {
            ActorAvatar(type: type, id: id, size: size)
        }
    }
}

/// The issue's current status: live from the issue cache when loaded (an
/// `issue:updated` repaints this icon alone), else the row's projection.
private struct InboxRowStatus: View {
    @Environment(WorkspaceSession.self) private var session
    let item: InboxItem

    var body: some View {
        let live = item.issueID.flatMap { session.issues.model($0) }?.issue.status
        if let key = live ?? item.issueStatus {
            session.issues.catalog.icon(for: key, size: 13)
                .help(session.issues.catalog.localizedName(for: key))
        }
    }
}

/// "An agent is on this" — badge only (upstream MUL-5189).
private struct InboxRowActivity: View {
    @Environment(WorkspaceSession.self) private var session
    let issueID: String

    var body: some View {
        if let runs = session.issues.model(issueID)?.activeRuns, runs > 0 {
            RunningIndicator(count: runs)
        }
    }
}
