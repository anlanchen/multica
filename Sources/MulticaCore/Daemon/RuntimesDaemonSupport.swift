import Foundation

public enum RuntimesDaemonLogLevel: String, Sendable, Hashable, CaseIterable {
    case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR"
}

/// One daemon log line split into timestamp, level, message and trailing
/// `key=value` fields. Lines that do not match keep only `raw`.
public struct RuntimesDaemonLogLine: Sendable, Hashable, Identifiable {
    public var id: Int
    public var timestamp: String?
    public var level: RuntimesDaemonLogLevel?
    public var message: String
    public var fields: [Field]
    public var raw: String

    public struct Field: Sendable, Hashable {
        public var key: String
        public var value: String
    }

    public func field(_ key: String) -> String? { fields.first { $0.key == key }?.value }
}

/// A rendered row: a single line, or a run of consecutive lines with the
/// same message folded behind their first occurrence.
public enum RuntimesDaemonLogItem: Sendable, Hashable, Identifiable {
    case line(RuntimesDaemonLogLine)
    case group(first: RuntimesDaemonLogLine, rest: [RuntimesDaemonLogLine])

    public var id: Int {
        switch self {
        case .line(let l): return l.id
        case .group(let f, _): return f.id
        }
    }
}

/// Parser for the daemon's slog/tint log format (upstream
/// `parse-daemon-log.ts`):
///
///     HH:MM:SS.mmm  LEVEL  message text  key=value key2="quoted value"
public enum RuntimesDaemonLog {
    public static let maxLines = 500

    static let levels: [String: RuntimesDaemonLogLevel] = [
        "DEBUG": .debug, "DBG": .debug, "INFO": .info, "INF": .info,
        "WARN": .warn, "WRN": .warn, "ERROR": .error, "ERR": .error,
    ]

    public static func parse(_ raw: String, id: Int) -> RuntimesDaemonLogLine {
        let fallback = RuntimesDaemonLogLine(id: id, timestamp: nil, level: nil, message: raw, fields: [], raw: raw)
        guard let m = raw.wholeMatch(of: /(\d{2}:\d{2}:\d{2}\.\d{3})\s+(DEBUG|DBG|INFO|INF|WARN|WRN|ERROR|ERR)(?:[+-]\d+)?\s+(.+)/),
              let level = levels[String(m.2)] else { return fallback }
        let (message, fields) = trailingFields(String(m.3))
        return RuntimesDaemonLogLine(id: id, timestamp: String(m.1), level: level, message: message, fields: fields, raw: raw)
    }

    /// Parses a batch off the main actor; ids continue from `firstID`.
    public static func parseBatch(_ lines: [String], firstID: Int) async -> [RuntimesDaemonLogLine] {
        lines.enumerated().map { parse($0.element, id: firstID + $0.offset) }
    }

    static func trailingFields(_ rest: String) -> (String, [RuntimesDaemonLogLine.Field]) {
        var fields: [RuntimesDaemonLogLine.Field] = []
        var work = Substring(rest)
        while let m = work.firstMatch(of: /\s+([a-zA-Z_][a-zA-Z0-9_.]*)=("(?:[^"\\]|\\.)*"|\S+)$/) {
            fields.insert(.init(key: String(m.1), value: unquote(String(m.2))), at: 0)
            work = work[..<m.range.lowerBound]
        }
        return (work.trimmingCharacters(in: .whitespacesAndNewlines), fields)
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Folds consecutive lines sharing a message (the poll heartbeat).
    public static func fold(_ lines: [RuntimesDaemonLogLine]) -> [RuntimesDaemonLogItem] {
        var out: [RuntimesDaemonLogItem] = []
        for line in lines {
            guard let last = out.last else {
                out.append(.line(line))
                continue
            }
            switch last {
            case .line(let l) where !l.message.isEmpty && l.message == line.message:
                out[out.count - 1] = .group(first: l, rest: [line])
            case .group(let f, var rest) where !f.message.isEmpty && f.message == line.message:
                rest.append(line)
                out[out.count - 1] = .group(first: f, rest: rest)
            default:
                out.append(.line(line))
            }
        }
        return out
    }

    /// Level toggles plus a case-insensitive search over the raw line;
    /// unparsed lines always pass the level filter.
    public static func filter(_ lines: [RuntimesDaemonLogLine], levels: Set<RuntimesDaemonLogLevel>, search: String) -> [RuntimesDaemonLogLine] {
        let q = search.lowercased()
        return lines.filter { l in
            if let level = l.level, !levels.contains(level) { return false }
            return q.isEmpty || l.raw.lowercased().contains(q)
        }
    }

    /// `max` content characters, then an ellipsis.
    public static func truncate(_ value: String, max: Int = 36) -> String {
        let limit = max + 1
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)).replacing(/\s+$/, with: "") + "…"
    }
}

/// When to confirm and recover a daemon that disappeared while the user
/// wants it running (upstream `DaemonRecoveryPolicy`): three consecutive
/// misses, backoff 15 s → 30 s → 2 min → 10 min, at most five starts in
/// thirty minutes before pausing until an explicit start.
public struct RuntimesDaemonRecoveryPolicy: Sendable {
    public enum Decision: Sendable, Equatable { case none, confirm, pause }

    public static let stoppedThreshold = 3
    public static let stableRunning: TimeInterval = 60
    public static let backoff: [TimeInterval] = [15, 30, 120, 600]
    public static let attemptBudget = 5
    public static let attemptWindow: TimeInterval = 30 * 60
    public static let pidDeferralLimit = 3
    public static let pidRecheck: TimeInterval = 30

    private var consecutiveStopped = 0
    private var runningSince: Date?
    private var failureCount = 0
    private var nextAttemptAt = Date.distantPast
    private var pidDeferrals = 0
    private var attempts: [Date] = []
    public private(set) var isPaused = false

    public init() {}

    public mutating func observe(desiredRunning: Bool, externallyManaged: Bool, lifecycleBusy: Bool, state: DaemonState, now: Date) -> Decision {
        prune(now)
        if state == .running {
            consecutiveStopped = 0
            if runningSince == nil { runningSince = now }
            if let since = runningSince, now.timeIntervalSince(since) >= Self.stableRunning {
                failureCount = 0
                nextAttemptAt = .distantPast
                pidDeferrals = 0
                isPaused = false
            }
            return .none
        }
        runningSince = nil
        guard desiredRunning, !externallyManaged, !lifecycleBusy, state == .stopped else {
            consecutiveStopped = 0
            return .none
        }
        if isPaused { return .pause }
        consecutiveStopped += 1
        guard consecutiveStopped >= Self.stoppedThreshold else { return .none }
        consecutiveStopped = 0
        guard now >= nextAttemptAt else { return .none }
        if attempts.count >= Self.attemptBudget {
            isPaused = true
            return .pause
        }
        return .confirm
    }

    public mutating func recordAttempt(_ now: Date) {
        prune(now)
        attempts.append(now)
        nextAttemptAt = now.addingTimeInterval(Self.backoff[min(failureCount, Self.backoff.count - 1)])
        failureCount += 1
        pidDeferrals = 0
    }

    /// Returns true once a stale/reused PID must stop blocking recovery.
    public mutating func recordPIDDeferral(_ now: Date) -> Bool {
        pidDeferrals += 1
        nextAttemptAt = now.addingTimeInterval(Self.pidRecheck)
        guard pidDeferrals >= Self.pidDeferralLimit else { return false }
        pidDeferrals = 0
        return true
    }

    public mutating func recordPIDAbsent() { pidDeferrals = 0 }

    public mutating func reset() { self = RuntimesDaemonRecoveryPolicy() }

    private mutating func prune(_ now: Date) {
        let cutoff = now.addingTimeInterval(-Self.attemptWindow)
        attempts.removeAll { $0 <= cutoff }
    }
}

public enum RuntimesDaemonRules {
    public enum AuthProbe: Sendable, Equatable { case authExpired, ok, unknown }

    /// Only an explicit 401 (or a missing token) means the login expired;
    /// network failures and 5xx stay inconclusive.
    public static func classifyAuthProbe(status: Int? = nil, noToken: Bool = false, networkError: Bool = false) -> AuthProbe {
        if noToken { return .authExpired }
        if networkError { return .unknown }
        if status == 401 { return .authExpired }
        if let status, (200..<300).contains(status) { return .ok }
        return .unknown
    }

    public enum VersionAction: Sendable, Equatable { case restart, deferred, ok, notRunning }

    /// Restart a running daemon whose CLI version differs from the binary we
    /// would spawn, but only once it has no active tasks.
    public static func versionAction(bundled: String?, health: DaemonHealth?) -> VersionAction {
        guard let health, health.status == "running" else { return .notRunning }
        guard let bundled, !bundled.isEmpty, let running = health.cliVersion, !running.isEmpty, running != bundled else { return .ok }
        return (health.activeTaskCount ?? 0) > 0 ? .deferred : .restart
    }

    /// A daemon reporting another OS than the host (e.g. inside a VM) can't
    /// be driven by the native CLI. Unknown OS fails safe to manageable.
    public static func isExternallyManaged(daemonOS: String?, hostOS: String = "darwin") -> Bool {
        guard let daemonOS, !daemonOS.isEmpty else { return false }
        return daemonOS != hostOS
    }

    public static func parsePID(_ raw: String) -> Int32? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.allSatisfy(\.isASCII), t.allSatisfy(\.isNumber), let pid = Int32(t), pid > 0 else { return nil }
        return pid
    }

    static func normalizeURL(_ u: String) -> String {
        var s = u.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public static func urlsMatch(_ a: String, _ b: String) -> Bool {
        let na = normalizeURL(a)
        return !na.isEmpty && na == normalizeURL(b)
    }

    /// Picks the release archive for a platform from `checksums.txt` names:
    /// `multica-cli-<v>-<os>-<arch>.tar.gz`, else the legacy name.
    public static func releaseAssetName(_ names: [String], os: String = "darwin", arch: String) -> String? {
        let ext = os == "windows" ? "zip" : "tar.gz"
        let suffix = "-\(os)-\(arch).\(ext)"
        let matches = names.filter { $0.hasPrefix("multica-cli-") && $0.hasSuffix(suffix) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { return nil }
        let legacy = "multica_\(os)_\(arch).\(ext)"
        return names.contains(legacy) ? legacy : nil
    }

    /// `<sha256>  <file>` lines of a goreleaser checksums.txt.
    public static func parseChecksums(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let m = line.wholeMatch(of: /([a-fA-F0-9]{64})\s+\*?(\S+)/) else { continue }
            out[String(m.2)] = String(m.1).lowercased()
        }
        return out
    }
}
