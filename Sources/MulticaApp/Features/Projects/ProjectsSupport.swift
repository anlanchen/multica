import AppKit
import MulticaCore
import SwiftUI

extension WorkspaceSession {
    /// Owner/admin of the workspace (gates delete).
    var projectsIsWorkspaceAdmin: Bool {
        MembersRole.isAdmin(directory.member(userID: currentUser.id)?.role)
    }

    func projectsIsPinned(_ projectID: String) -> Bool {
        pins.items.contains { $0.itemType == "project" && $0.itemId == projectID }
    }

    /// Upstream `useUpdateProject`: patch the catalog row, roll back on
    /// failure, adopt the server's row on success.
    func projectsUpdate(_ id: String, _ patch: ProjectsPatch) async throws {
        let before = projects.item(id)
        if let before { projects.upsert(patch.applied(to: before)) }
        do {
            projects.upsert(try await api.updateProject(id, patch: patch.body))
        } catch {
            if let before { projects.upsert(before) }
            throw error
        }
    }

    /// Upstream `useDeleteProject`: optimistic removal, restored on failure.
    func projectsDelete(_ id: String) async throws {
        let before = projects.item(id)
        projects.remove(id)
        do {
            try await api.deleteProject(id)
            if let pin = pins.items.first(where: { $0.itemType == "project" && $0.itemId == id }) { pins.remove(pin.id) }
        } catch {
            if let before { projects.upsert(before) }
            throw error
        }
    }

    func projectsSetPinned(_ projectID: String, _ pinned: Bool) async throws {
        if pinned {
            guard !projectsIsPinned(projectID) else { return }
            pins.upsert(try await api.createPin(CreatePinRequest(itemType: "project", itemId: projectID)))
        } else {
            guard let pin = pins.items.first(where: { $0.itemType == "project" && $0.itemId == projectID }) else { return }
            pins.remove(pin.id)
            do {
                try await api.deletePin(itemType: "project", itemId: projectID)
            } catch {
                pins.upsert(pin)
                throw error
            }
        }
    }

    /// Fetches one project (detail pages, chips for projects outside the
    /// loaded list) and keeps the catalog row current.
    func projectsFetch(_ id: String) async throws -> Project {
        let p = try await api.getProject(id)
        projects.upsert(p)
        return p
    }
}

/// Per-workspace persisted view preferences (upstream zustand `persist` with
/// workspace-aware storage).
enum ProjectsDefaults {
    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Localized names and colors for project fields (labels.ts, projects/config.ts).
enum ProjectsLabels {
    static func status(_ s: String) -> String { trd("projects", "status.\(s)", s) }
    static func priority(_ p: String) -> String { trd("projects", "priority.\(p)", p) }

    static func relativeDate(_ timestamp: String) -> String {
        switch ProjectsRelativeDate.of(timestamp) {
        case .today: return tr("projects", "relative_date.today")
        case .oneDay: return tr("projects", "relative_date.one_day_ago")
        case .days(let n): return tr("projects", "relative_date.days_ago", ["count": n])
        case .months(let n): return tr("projects", "relative_date.months_ago", ["count": n])
        }
    }

    static func sortField(_ f: ProjectsSortField) -> String { tr("projects", "table.\(f.rawValue)") }
    static func column(_ c: ProjectsColumn) -> String { tr("projects", "table.\(c.rawValue)") }

    static func statusDot(_ s: String) -> Color {
        switch s {
        case "in_progress": return Theme.warning
        case "completed": return Theme.info
        case "cancelled": return Theme.destructive
        default: return .secondary
        }
    }

    static func badge(_ s: String) -> (background: Color, foreground: Color) {
        switch s {
        case "in_progress": return (Theme.warning, .white)
        case "completed": return (Theme.info, .white)
        default: return (Color.primary.opacity(0.07), .secondary)
        }
    }

    static func priorityColor(_ p: String) -> Color {
        switch p {
        case "urgent": return Theme.destructive
        case "high", "medium": return Theme.warning
        case "low": return Theme.info
        default: return .secondary
        }
    }

    static let emerald = Color(light: 0x10B981, dark: 0x10B981)
}

/// The desktop shell's folder picker and daemon identity, natively.
enum ProjectsLocalPicker {
    struct Picked {
        var path: String
        var basename: String
    }

    @MainActor
    static func pick(defaultPath: String? = nil) async -> Picked? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let defaultPath { panel.directoryURL = URL(fileURLWithPath: defaultPath) }
        let response = await withCheckedContinuation { (c: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { c.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return nil }
        return Picked(path: url.path, basename: url.lastPathComponent)
    }

    static func validate(_ path: String) async -> ProjectsLocalDirectory.Validation {
        await Task.detached(priority: .userInitiated) { ProjectsLocalDirectory.validate(path) }.value
    }
}

extension AppEnvironment {
    /// Upstream `useLocalDaemonStatus`.
    var projectsLocalDaemonID: String? {
        guard let id = daemonStatus.health?.daemonID, !id.isEmpty else { return nil }
        return id
    }

    var projectsLocalDaemonRunning: Bool { daemonStatus.state == .running }
    var projectsLocalDeviceName: String? { daemonStatus.health?.deviceName }
    /// The server declares it validates `execution_mode` (fails closed).
    var projectsServerValidatesWorktree: Bool { appConfig?.localWorktreeSupported == true }
}

/// Workspace-level GitHub repos (`workspace.repos`), fetched where the
/// attach flows need them.
@MainActor
@Observable
final class ProjectsWorkspaceRepos {
    private(set) var repos: [WorkspaceRepo] = []
    private(set) var loaded = false

    func load(_ session: WorkspaceSession) async {
        if let ws = try? await session.api.getWorkspace(session.workspace.id) {
            repos = ws.repos
        }
        loaded = true
    }

    func description(for url: String) -> String? {
        repos.first { $0.url == url }?.description?.trimmingCharacters(in: .whitespacesAndNewlines).projectsNilIfEmpty
    }
}

extension String {
    var projectsNilIfEmpty: String? { isEmpty ? nil : self }
}
