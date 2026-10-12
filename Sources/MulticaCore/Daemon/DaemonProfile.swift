import Foundation

/// The CLI profile this app drives the local daemon through.
///
/// Naming and port derivation match the Go CLI
/// (`server/cmd/multica/cmd_daemon.go` `healthPortForProfile`) and the
/// Electron shell (`apps/desktop/src/main/daemon-profile.ts`), so the native
/// app and the official desktop app agree on which daemon belongs to which
/// backend and never touch the user's default `~/.multica` profile.
public struct DaemonProfile: Sendable, Hashable {
    public static let defaultHealthPort = 19514

    public let name: String
    public let home: URL

    public init(targetAPIURL: URL, prefix: String = "desktop", home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.name = DaemonProfile.deriveName(targetAPIURL: targetAPIURL, prefix: prefix)
        self.home = home
    }

    public init(name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        precondition(!name.isEmpty, "an unresolved profile would act on the user's default CLI profile")
        self.name = name
        self.home = home
    }

    /// `https://api.multica.ai` → `desktop-api.multica.ai`;
    /// `http://localhost:8080` → `desktop-localhost-8080`.
    public static func deriveName(targetAPIURL: URL, prefix: String = "desktop") -> String {
        guard let host = targetAPIURL.host, !host.isEmpty else { return prefix }
        var authority = host
        // WHATWG `URL.host` (what the Electron shell hashes) omits the
        // scheme's default port, so an explicit :443 / :80 must not change
        // the profile name.
        let defaultPort = targetAPIURL.scheme == "http" ? 80 : 443
        if let port = targetAPIURL.port, port != defaultPort { authority += ":\(port)" }
        return "\(prefix)-" + authority.replacingOccurrences(of: ":", with: "-").lowercased()
    }

    /// Never the default port: probing 19514 would report the user's own CLI
    /// daemon as this app's.
    public var healthPort: Int {
        let sum = name.utf8.reduce(0) { $0 + Int($1) }
        return DaemonProfile.defaultHealthPort + 1 + (sum % 1000)
    }

    public var directory: URL { home.appendingPathComponent(".multica/profiles/\(name)", isDirectory: true) }
    public var configURL: URL { directory.appendingPathComponent("config.json") }
    public var logURL: URL { directory.appendingPathComponent("daemon.log") }
    public var pidURL: URL { directory.appendingPathComponent("daemon.pid") }
    /// Sidecar recording which user the cached PAT belongs to (shared with
    /// the Electron shell; the Go CLI never reads it).
    public var userIDURL: URL { directory.appendingPathComponent(".desktop-user-id") }

    public var cliArguments: [String] { ["--profile", name] }
    public var healthURL: URL { URL(string: "http://127.0.0.1:\(healthPort)/health")! }
}

/// `GET /health` payload of the local daemon.
public struct DaemonHealth: Sendable, Hashable, Decodable {
    public var status: String
    public var pid: Int?
    public var os: String?
    public var uptime: String?
    public var daemonID: String?
    public var deviceName: String?
    public var serverURL: String?
    public var cliVersion: String?
    public var activeTaskCount: Int?
    public var agents: [String]

    enum CodingKeys: String, CodingKey {
        case status, pid, os, uptime, agents
        case daemonID = "daemon_id"
        case deviceName = "device_name"
        case serverURL = "server_url"
        case cliVersion = "cli_version"
        case activeTaskCount = "active_task_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.lossy(String.self, .status, default: "unknown")
        pid = c.lossy(Int.self, .pid)
        os = c.lossy(String.self, .os)
        uptime = c.lossy(String.self, .uptime)
        daemonID = c.lossy(String.self, .daemonID)
        deviceName = c.lossy(String.self, .deviceName)
        serverURL = c.lossy(String.self, .serverURL)
        cliVersion = c.lossy(String.self, .cliVersion)
        activeTaskCount = c.lossy(Int.self, .activeTaskCount)
        agents = c.lossyArray(String.self, .agents)
    }

    /// Mirrors Go `daemonAlive()`: "starting" means the port is bound and a
    /// second start must not be attempted.
    public var isAlive: Bool { status == "running" || status == "starting" }
}

public enum DaemonState: String, Sendable, Hashable {
    case unknown
    case running
    case starting
    case stopping
    case stopped
    case cliNotFound
    case authExpired
    case failed

    public var label: String {
        switch self {
        case .unknown: return "Checking…"
        case .running: return "Running"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .stopped: return "Stopped"
        case .cliNotFound: return "CLI not found"
        case .authExpired: return "Sign-in expired"
        case .failed: return "Failed to start"
        }
    }

    public var isTransitioning: Bool { self == .starting || self == .stopping || self == .unknown }
}

public struct DaemonStatus: Sendable, Hashable {
    public var state: DaemonState
    public var health: DaemonHealth?
    public var message: String?

    public init(state: DaemonState, health: DaemonHealth? = nil, message: String? = nil) {
        self.state = state
        self.health = health
        self.message = message
    }
}
