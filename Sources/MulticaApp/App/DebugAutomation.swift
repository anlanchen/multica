import AppKit
import MulticaCore

/// Scripted walkthroughs for local verification and benchmarking, inert
/// unless the app was launched with `MULTICA_DEBUG_SNAPSHOT_DIR`:
///
///     multica://debug/go?route=issues&query=view%3Dboard
///     multica://debug/go?route=first:issue      (first loaded issue, etc.)
///     multica://debug/snapshot?name=issues      (main window → <dir>/issues.png)
///
/// An app can always render its own windows, so this needs no screen
/// recording permission.
@MainActor
enum DebugAutomation {
    static let directory: URL? = ProcessInfo.processInfo.environment["MULTICA_DEBUG_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    static func handle(_ url: URL, env: AppEnvironment) async -> Bool {
        guard url.host == "debug", let directory else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.path {
        case "/go":
            guard let raw = value("route"), let route = await resolve(raw, env: env) else { return true }
            var query: [String: String] = [:]
            for pair in (value("query") ?? "").split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { query[kv[0]] = kv[1] }
            }
            env.navigator.push(route, query: query)
        case "/snapshot":
            snapshot(name: value("name") ?? "snapshot", to: directory)
        default:
            break
        }
        return true
    }

    private static func resolve(_ raw: String, env: AppEnvironment) async -> AppRoute? {
        guard raw.hasPrefix("first:") else { return AppRoute(relativePath: raw) }
        guard let s = env.app.session else { return nil }
        switch raw.dropFirst(6) {
        case "issue": return s.issues.allModels.max { $0.issue.updatedAt < $1.issue.updatedAt }.map { .issue($0.id) }
        case "project": await s.projects.loadIfNeeded(); return s.projects.items.first.map { .project($0.id) }
        case "agent": await s.agentRecords.loadIfNeeded(); return s.agentRecords.items.first { $0.archivedAt == nil }.map { .agent($0.id) }
        case "squad": await s.squads.loadIfNeeded(); return s.squads.items.first.map { .squad($0.id) }
        case "skill": await s.skills.loadIfNeeded(); return s.skills.items.first.map { .skill($0.id) }
        case "autopilot": await s.autopilots.loadIfNeeded(); return s.autopilots.items.first.map { .autopilot($0.id) }
        case "member": return s.directory.members.first.map { .member($0.userID) }
        case "runtime": await s.runtimeRecords.loadIfNeeded(); return s.runtimeRecords.items.compactMap(\.daemonId).first.map { .runtime($0) }
        default: return nil
        }
    }

    private static func snapshot(name: String, to directory: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("main") == true }) ?? NSApp.mainWindow,
              let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
