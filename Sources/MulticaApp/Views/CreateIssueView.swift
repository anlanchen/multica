import MulticaCore
import SwiftUI

struct CreateIssueView: View {
    let session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var status: IssueStatusKey = .todo
    @State private var priority: IssuePriority = .none
    @State private var assignee: ActorRef?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New issue").font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.title3)
            TextField("Description (Markdown)", text: $description, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(4...12)
            HStack {
                Picker("Status", selection: $status) {
                    ForEach(session.issues.catalog.entries) { Text($0.name).tag($0.key) }
                }
                .fixedSize()
                Picker("Priority", selection: $priority) {
                    ForEach(IssuePriority.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Picker("Assignee", selection: $assignee) {
                    Text("Unassigned").tag(ActorRef?.none)
                    ForEach(session.directory.agents) { a in
                        Text("🤖 \(a.name)").tag(ActorRef?.some(ActorRef(type: "agent", id: a.id)))
                    }
                    ForEach(session.directory.members) { m in
                        Text(m.name).tag(ActorRef?.some(ActorRef(type: "member", id: m.userID)))
                    }
                }
                .fixedSize()
            }
            if assignee?.type == "agent" {
                Text("The agent picks this up as soon as it is created.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create issue") { create() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// Waits for the server before closing: creation is never optimistic.
    private func create() {
        busy = true
        let request = CreateIssueRequest(
            title: title.trimmingCharacters(in: .whitespaces),
            description: description.isEmpty ? nil : description,
            status: status,
            priority: priority,
            assignee: assignee
        )
        Task {
            do {
                _ = try await session.createIssue(request)
                dismiss()
            } catch {
                self.error = (error as? APIError)?.message ?? error.localizedDescription
                busy = false
            }
        }
    }
}
