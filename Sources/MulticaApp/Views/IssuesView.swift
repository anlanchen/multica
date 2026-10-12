import AppKit
import MulticaCore
import SwiftUI

enum IssueScope {
    case all, mine
}

enum IssueLayout: String, CaseIterable, Identifiable {
    case list, board
    var id: String { rawValue }
}

struct IssuesView: View {
    let session: WorkspaceSession
    let scope: IssueScope
    @AppStorage("multica.issues.layout") private var layout: IssueLayout = .list
    @State private var creating = false

    var body: some View {
        @Bindable var issues = session.issues
        Group {
            if !session.isBootstrapped {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if issues.sections.allSatisfy({ $0.items.isEmpty }) {
                ContentUnavailableView(
                    issues.searchText.isEmpty ? "No issues" : "No matches",
                    systemImage: "square.stack.3d.up.slash"
                )
            } else {
                switch layout {
                case .list: IssueListView(session: session)
                case .board: IssueBoardView(session: session)
                }
            }
        }
        .navigationTitle(scope == .mine ? "My Issues" : "Issues")
        .navigationSubtitle("\(issues.loadedCount) of \(issues.totalOnServer)")
        .searchable(text: $issues.searchText, placement: .toolbar, prompt: "Filter issues")
        .toolbar {
            ToolbarItemGroup {
                if scope == .all {
                    Picker("Filter", selection: $issues.filter) {
                        ForEach(IssueFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Picker("Layout", selection: $layout) {
                    Image(systemName: "list.bullet").tag(IssueLayout.list).help("List")
                    Image(systemName: "rectangle.split.3x1").tag(IssueLayout.board).help("Board")
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Button {
                    creating = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New issue (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $creating) {
            CreateIssueView(session: session)
        }
        .onAppear {
            let store = session.issues
            if scope == .mine {
                store.filter = .assignedToMe
            } else if store.filter == .assignedToMe {
                store.filter = .all
            }
        }
    }
}

// MARK: - List

struct IssueListView: View {
    let session: WorkspaceSession

    var body: some View {
        let issues = session.issues
        // `List` is backed by NSTableView: rows are created lazily and reused,
        // and each row observes only its own IssueModel.
        List {
            ForEach(issues.sections) { section in
                if !section.items.isEmpty {
                    Section {
                        ForEach(section.items) { model in
                            NavigationLink(value: IssueRoute(id: model.id)) {
                                IssueRow(model: model, session: session)
                            }
                            .contextMenu { IssueContextMenu(model: model, session: session) }
                        }
                    } header: {
                        SectionHeader(section: section)
                    }
                }
            }
            if issues.loadedCount < issues.totalOnServer {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .task { await session.loadMoreIfNeeded() }
            }
        }
        .listStyle(.inset)
    }
}

struct SectionHeader: View {
    let section: IssueSection

    var body: some View {
        HStack(spacing: 6) {
            StatusIcon(category: section.category, color: section.color)
            Text(section.name).font(.subheadline.weight(.semibold))
            Text("\(section.items.count)").font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct IssueRow: View {
    let model: IssueModel
    let session: WorkspaceSession

    var body: some View {
        let issue = model.issue
        HStack(spacing: 10) {
            PriorityIcon(priority: issue.priority)
            Text(issue.identifier)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .leading)
            session.issues.catalog.icon(for: issue.status)
            Text(issue.title).lineLimit(1)
            Spacer(minLength: 8)
            if model.activeRuns > 0 {
                RunningIndicator(count: model.activeRuns)
            }
            ForEach(issue.labels.prefix(2)) { LabelChip(label: $0) }
            ActorBadge(ref: issue.assignee, directory: session.directory)
            Text(Formatters.relative(issue.updatedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

struct IssueContextMenu: View {
    let model: IssueModel
    let session: WorkspaceSession

    var body: some View {
        Menu("Status") {
            ForEach(session.issues.catalog.entries) { entry in
                Button(entry.name) {
                    var r = UpdateIssueRequest()
                    r.status = entry.key
                    Task { await session.updateIssue(model.id, r) }
                }
            }
        }
        Menu("Priority") {
            ForEach(IssuePriority.allCases, id: \.self) { p in
                Button(p.label) {
                    var r = UpdateIssueRequest()
                    r.priority = p
                    Task { await session.updateIssue(model.id, r) }
                }
            }
        }
        AssigneeMenu(model: model, session: session)
        Divider()
        Button("Copy Identifier") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.issue.identifier, forType: .string)
        }
    }
}

struct AssigneeMenu: View {
    let model: IssueModel
    let session: WorkspaceSession

    var body: some View {
        Menu("Assignee") {
            Button("Unassigned") { assign(nil) }
            Section("Agents") {
                ForEach(session.directory.agents) { agent in
                    Button(agent.name) { assign(ActorRef(type: "agent", id: agent.id)) }
                }
            }
            Section("Members") {
                ForEach(session.directory.members) { member in
                    Button(member.name) { assign(ActorRef(type: "member", id: member.userID)) }
                }
            }
        }
    }

    private func assign(_ ref: ActorRef?) {
        var r = UpdateIssueRequest()
        if let ref {
            r.assigneeType = .set(ref.type)
            r.assigneeID = .set(ref.id)
        } else {
            r.assigneeType = .clear
            r.assigneeID = .clear
        }
        Task { await session.updateIssue(model.id, r) }
    }
}

// MARK: - Board

struct IssueBoardView: View {
    let session: WorkspaceSession

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(session.issues.sections) { section in
                    BoardColumn(section: section, session: session)
                }
            }
            .padding(12)
        }
    }
}

struct BoardColumn: View {
    let section: IssueSection
    let session: WorkspaceSession
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(section: section).padding(.horizontal, 4)
            ScrollView(.vertical) {
                // Lazy: a 2000-card column materialises only what is visible.
                LazyVStack(spacing: 8) {
                    ForEach(section.items) { model in
                        NavigationLink(value: IssueRoute(id: model.id)) {
                            IssueCard(model: model, session: session)
                        }
                        .buttonStyle(.plain)
                        .draggable(model.id)
                        .contextMenu { IssueContextMenu(model: model, session: session) }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(width: 290)
        .padding(8)
        .background(targeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: String.self) { ids, _ in
            var request = UpdateIssueRequest()
            request.status = section.key
            let move = request
            for id in ids where session.issues.model(id)?.issue.status != section.key {
                Task { await session.updateIssue(id, move) }
            }
            return true
        } isTargeted: { targeted = $0 }
    }
}

struct IssueCard: View {
    let model: IssueModel
    let session: WorkspaceSession

    var body: some View {
        let issue = model.issue
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(issue.identifier).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if model.activeRuns > 0 { RunningIndicator(count: model.activeRuns) }
                ActorBadge(ref: issue.assignee, directory: session.directory)
            }
            Text(issue.title)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                PriorityIcon(priority: issue.priority)
                ForEach(issue.labels.prefix(2)) { LabelChip(label: $0) }
                Spacer()
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
