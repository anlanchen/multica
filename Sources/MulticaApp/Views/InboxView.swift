import MulticaCore
import SwiftUI

struct InboxView: View {
    let session: WorkspaceSession
    @Binding var path: [IssueRoute]

    var body: some View {
        Group {
            if !session.inbox.isLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.inbox.items.isEmpty {
                ContentUnavailableView("Inbox zero", systemImage: "tray")
            } else {
                List(session.inbox.items) { item in
                    InboxRow(item: item, directory: session.directory)
                        .contentShape(Rectangle())
                        .onTapGesture { open(item) }
                        .contextMenu {
                            if !item.read {
                                Button("Mark as Read") { Task { await session.markInboxRead(item) } }
                            }
                            Button("Archive") { Task { await session.archiveInbox(item) } }
                        }
                        .swipeActions {
                            Button("Archive") { Task { await session.archiveInbox(item) } }
                                .tint(.gray)
                        }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Inbox")
        .toolbar {
            Button {
                Task { await session.markAllInboxRead() }
            } label: {
                SwiftUI.Label("Mark all read", systemImage: "checkmark.circle")
            }
            .disabled(session.inbox.unread(in: session.workspace.id) == 0)
        }
        // The inbox list is fetched only when the user opens it; the badge
        // comes from the unread summary (upstream MUL-6967).
        .task { if !session.inbox.isLoaded { await session.loadInbox() } }
    }

    private func open(_ item: InboxItem) {
        if !item.read { Task { await session.markInboxRead(item) } }
        if let issueID = item.issueID { path.append(IssueRoute(id: issueID)) }
    }
}

struct InboxRow: View {
    let item: InboxItem
    let directory: Directory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.read ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            Avatar(name: actorName, isAgent: item.actorType == "agent", size: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title).font(.callout.weight(item.read ? .regular : .semibold)).lineLimit(1)
                    Spacer()
                    Text(Formatters.relative(item.createdAt)).font(.caption).foregroundStyle(.secondary)
                }
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private var actorName: String {
        guard let type = item.actorType, let id = item.actorID else { return "Multica" }
        return directory.name(type: type, id: id)
    }

    private var summary: String {
        let kind = item.type.replacingOccurrences(of: "_", with: " ")
        if let body = item.body, !body.isEmpty { return "\(actorName) · \(kind) — \(body)" }
        return "\(actorName) · \(kind)"
    }
}
