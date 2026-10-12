import Foundation

/// User-facing runtime health: the server's binary status split into
/// time-bucketed offline flavors (upstream `deriveRuntimeHealth`).
public enum RuntimesHealth: String, Sendable, Hashable, CaseIterable {
    case online
    case recentlyLost = "recently_lost"
    case offline
    case longOffline = "long_offline"

    static let recentlyLostWindow: TimeInterval = 5 * 60
    static let longOfflineThreshold: TimeInterval = 6 * 24 * 3600

    public static func derive(status: String, lastSeenAt: String?, now: Date) -> RuntimesHealth {
        if status == "online" { return .online }
        let lastSeen = lastSeenAt.flatMap(Timestamp.parse) ?? Date(timeIntervalSince1970: 0)
        let offlineFor = now.timeIntervalSince(lastSeen)
        if offlineFor < recentlyLostWindow { return .recentlyLost }
        if offlineFor > longOfflineThreshold { return .longOffline }
        return .offline
    }

    public static func of(_ runtime: RuntimeDeviceRecord, now: Date) -> RuntimesHealth {
        derive(status: runtime.status, lastSeenAt: runtime.lastSeenAt, now: now)
    }

    var severity: Int {
        switch self {
        case .online: return 0
        case .recentlyLost: return 1
        case .offline: return 2
        case .longOffline: return 3
        }
    }

    public var isOfflineLike: Bool { self == .offline || self == .longOffline }
}

/// Agents bound to a runtime plus its active task counts.
public struct RuntimesWorkload: Sendable, Hashable {
    public var agentIDs: [String] = []
    public var runningCount = 0
    public var queuedCount = 0

    public init(agentIDs: [String] = [], runningCount: Int = 0, queuedCount: Int = 0) {
        self.agentIDs = agentIDs
        self.runningCount = runningCount
        self.queuedCount = queuedCount
    }

    public var activeCount: Int { runningCount + queuedCount }
}

public enum RuntimesMachineSection: String, Sendable, Hashable {
    case local, remote, cloud

    var rank: Int {
        switch self {
        case .local: return 0
        case .remote: return 1
        case .cloud: return 2
        }
    }
}

public enum RuntimesMachineFilter: String, Sendable, Hashable, CaseIterable {
    case all, online, issues
}

/// Runtimes grouped by the daemon (machine) that registered them.
public struct RuntimesMachine: Sendable, Hashable, Identifiable {
    public var id: String
    public var daemonID: String?
    public var title: String
    public var subtitle: String?
    public var deviceInfo: String?
    public var cliVersion: String?
    public var launchedBy: String?
    public var mode: String
    public var section: RuntimesMachineSection
    public var isCurrent: Bool
    public var health: RuntimesHealth
    public var runtimes: [RuntimeDeviceRecord]
    public var onlineCount: Int
    public var issueCount: Int
    public var runningCount: Int
    public var queuedCount: Int
    public var providerNames: [String]
    public var lastSeenAt: String?

    public var busyCount: Int { runningCount + queuedCount }
}

public struct RuntimesMachineOptions: Sendable {
    public var now: Date
    public var localDaemonID: String?
    public var localMachineName: String?
    /// Only a local runtime owned by this user may be matched to "this
    /// machine" by device name; the list spans the whole workspace.
    public var currentUserID: String?
    public var workloadByRuntimeID: [String: RuntimesWorkload]
    /// Guarantees a machine flagged `isCurrent` (desktop always owns one).
    public var ensureLocalMachine: Bool

    public init(now: Date = Date(), localDaemonID: String? = nil, localMachineName: String? = nil, currentUserID: String? = nil,
                workloadByRuntimeID: [String: RuntimesWorkload] = [:], ensureLocalMachine: Bool = false) {
        self.now = now
        self.localDaemonID = localDaemonID
        self.localMachineName = localMachineName
        self.currentUserID = currentUserID
        self.workloadByRuntimeID = workloadByRuntimeID
        self.ensureLocalMachine = ensureLocalMachine
    }
}

/// Pure runtime/machine logic shared by the runtimes screens (upstream
/// `runtime-machines.ts`, `pending-runtime.ts`, `utils.ts` and
/// `@multica/core/runtimes`).
public enum RuntimesKit {
    public static let placeholderMachineID = "local:placeholder"
    public static let pendingWarningInterval: TimeInterval = 45
    static let pendingIDPrefix = "pending-runtime-profile:"

    // MARK: Names

    /// `"Claude (host)"` → base `"Claude"`, hostname `"host"`.
    public static func splitRuntimeName(_ name: String) -> (base: String, hostname: String?) {
        guard let m = name.wholeMatch(of: /(.+?)\s+\(([^)]+)\)/) else { return (name, nil) }
        return (String(m.1), String(m.2))
    }

    /// The custom override when set, else the daemon-proposed name.
    public static func displayName(_ runtime: RuntimeDeviceRecord) -> String {
        let custom = runtime.customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? runtime.name : custom
    }

    /// Display name that always surfaces the provider when an alias is set.
    public static func displayLabel(_ runtime: RuntimeDeviceRecord) -> String {
        let display = displayName(runtime)
        let hasCustom = !(runtime.customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        let provider = runtime.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasCustom, !provider.isEmpty else { return display }
        return "\(display) (\(providerDisplayName(provider)))"
    }

    static let providerDisplayNames: [String: String] = [
        "codearts": "CodeArts",
        "dsh": "DeepSeek Harness",
        "qoderclicn": "Qoder CN",
        "traecli": "Trae",
        "qwen": "Qwen Code",
        "qwenpaw": "QwenPaw",
        "mcode": "MiniMax Code",
        "omp": "Oh-My-Pi",
        "zeroclaw": "ZeroClaw",
    ]

    public static func providerDisplayName(_ provider: String) -> String {
        if let known = providerDisplayNames[provider] { return known }
        return provider.prefix(1).uppercased() + provider.dropFirst()
    }

    /// Label for a runtime under its machine: a machine-level rename stamps
    /// the same custom name on every runtime, so it collapses to the
    /// provider base; a one-off per-runtime alias stays.
    public static func runtimeRowLabel(_ runtime: RuntimeDeviceRecord, machineTitle: String) -> String {
        let custom = runtime.customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty && custom != machineTitle { return custom }
        return splitRuntimeName(runtime.name).base
    }

    /// The custom name shared by every runtime of a machine, if any.
    public static func sharedCustomName(_ runtimes: [RuntimeDeviceRecord]) -> String? {
        guard let first = runtimes.first?.customName?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty else { return nil }
        let allSame = runtimes.allSatisfy { ($0.customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == first }
        return allSame ? first : nil
    }

    // MARK: Device info

    static let osLabels = ["darwin": "macOS", "linux": "Linux", "windows": "Windows", "freebsd": "FreeBSD", "openbsd": "OpenBSD", "netbsd": "NetBSD"]
    static let archLabels = ["amd64": "x86_64", "arm64": "arm64", "386": "x86", "arm": "arm"]

    /// `"host · darwin-arm64"` → `"host · macOS (arm64)"`.
    public static func formatDeviceInfo(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.components(separatedBy: " · ").map(prettifyOSArch).joined(separator: " · ")
    }

    static func prettifyOSArch(_ part: String) -> String {
        guard let m = part.lowercased().wholeMatch(of: /(darwin|linux|windows|freebsd|openbsd|netbsd)-(amd64|arm64|386|arm)/) else { return part }
        let os = String(m.1), arch = String(m.2)
        return "\(osLabels[os] ?? os) (\(archLabels[arch] ?? arch))"
    }

    /// Splits `device_info` on the first `" · "` into host and runtime halves.
    public static func parseDeviceInfo(_ raw: String) -> (hostname: String, runtime: String?) {
        guard let r = raw.range(of: " · ") else { return (raw, nil) }
        return (String(raw[..<r.lowerBound]), String(raw[r.upperBound...]))
    }

    static func deviceName(_ runtime: RuntimeDeviceRecord) -> String? {
        if let host = splitRuntimeName(runtime.name).hostname { return host }
        let raw = runtime.deviceInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let first = raw.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return first.isEmpty ? nil : first
    }

    static func isAgentVersionLike(_ part: String) -> Bool {
        part.contains(/(?:^|\s)v?\d+\.\d+\.\d+/)
    }

    static func compactDeviceInfo(_ deviceInfo: String?, title: String) -> String? {
        guard let deviceInfo else { return nil }
        let parts = deviceInfo.components(separatedBy: " · ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != title && !isAgentVersionLike($0) }
        guard let primary = parts.first else { return nil }
        if let m = primary.wholeMatch(of: /(.+?)\s+\(([^)]+)\)/) {
            return "\(m.2) \(m.1)"
        }
        return primary
    }

    /// Machine-level short daemon id (`abcdefgh...`).
    public static func shortDaemonID(_ id: String) -> String {
        id.count > 12 ? "\(id.prefix(8))..." : id
    }

    /// Runtime-detail short daemon id (`abcdef··yz`).
    public static func compactDaemonID(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        if id.count <= 10 { return id }
        return "\(id.prefix(6))··\(id.suffix(2))"
    }

    // MARK: Metadata

    public static func metadataString(_ runtime: RuntimeDeviceRecord, _ key: String) -> String? {
        if case .string(let s)? = runtime.metadata[key] { return s }
        return nil
    }

    static func metadataBool(_ runtime: RuntimeDeviceRecord, _ key: String) -> Bool? {
        if case .bool(let b)? = runtime.metadata[key] { return b }
        return nil
    }

    /// The daemon CLI version a local runtime reports.
    public static func cliVersion(_ runtime: RuntimeDeviceRecord) -> String? {
        guard runtime.runtimeMode == "local", let v = metadataString(runtime, "cli_version"), !v.isEmpty else { return nil }
        return v
    }

    /// A live local daemon re-registers a deleted runtime within seconds.
    public static func isSelfHealing(_ runtime: RuntimeDeviceRecord) -> Bool {
        runtime.runtimeMode == "local" && runtime.status == "online"
    }

    /// A private runtime is usable only by its owner, a public one by
    /// everyone, an ownerless one by nobody (server `canUseRuntimeForAgent`).
    public static func isUsable(_ runtime: RuntimeDeviceRecord, by currentUserID: String?) -> Bool {
        guard let owner = runtime.ownerId, !owner.isEmpty else { return false }
        guard let currentUserID else { return true }
        if owner == currentUserID { return true }
        return runtime.visibility == "public"
    }

    // MARK: Workload

    /// Agents per runtime plus running/queued task counts, from the workspace
    /// agent list and task snapshot (upstream `buildWorkloadIndex`).
    public static func workloadIndex(agents: [AgentRecord], tasks: [AgentTask]) -> [String: RuntimesWorkload] {
        var result: [String: RuntimesWorkload] = [:]
        var agentToRuntime: [String: String] = [:]
        for a in agents where !a.runtimeId.isEmpty && a.archivedAt == nil {
            agentToRuntime[a.id] = a.runtimeId
            result[a.runtimeId, default: RuntimesWorkload()].agentIDs.append(a.id)
        }
        for t in tasks {
            guard let rid = agentToRuntime[t.agentID], result[rid] != nil else { continue }
            if t.status == .running {
                result[rid]?.runningCount += 1
            } else if t.status == .queued || t.status == .dispatched {
                result[rid]?.queuedCount += 1
            }
        }
        return result
    }

    // MARK: Machines

    public static func machineID(_ runtime: RuntimeDeviceRecord) -> String {
        if let d = runtime.daemonId, !d.isEmpty { return "\(runtime.runtimeMode):\(d)" }
        if let device = deviceName(runtime) { return "\(runtime.runtimeMode):device:\(device)" }
        return "\(runtime.runtimeMode):runtime:\(runtime.id)"
    }

    public static func buildMachines(_ runtimes: [RuntimeDeviceRecord], options: RuntimesMachineOptions) -> [RuntimesMachine] {
        var order: [String] = []
        var drafts: [String: (daemonID: String?, mode: String, runtimes: [RuntimeDeviceRecord])] = [:]
        for runtime in runtimes {
            let id = machineID(runtime)
            if drafts[id] == nil {
                order.append(id)
                drafts[id] = (runtime.daemonId, runtime.runtimeMode, [])
            }
            drafts[id]?.runtimes.append(runtime)
        }
        var machines = order.compactMap { id in drafts[id].map { finalize(id: id, daemonID: $0.daemonID, mode: $0.mode, runtimes: $0.runtimes, options: options) } }
        if options.ensureLocalMachine && !machines.contains(where: \.isCurrent) {
            machines.append(placeholderLocalMachine(options))
        }
        return machines.sorted(by: machineOrder)
    }

    static func placeholderLocalMachine(_ options: RuntimesMachineOptions) -> RuntimesMachine {
        let daemonID = options.localDaemonID
        return RuntimesMachine(
            id: daemonID.map { "local:\($0)" } ?? placeholderMachineID, daemonID: daemonID,
            title: options.localMachineName ?? "This machine", subtitle: nil, deviceInfo: nil, cliVersion: nil, launchedBy: nil,
            mode: "local", section: .local, isCurrent: true, health: .offline, runtimes: [],
            onlineCount: 0, issueCount: 0, runningCount: 0, queuedCount: 0, providerNames: [], lastSeenAt: nil)
    }

    static func finalize(id: String, daemonID: String?, mode: String, runtimes unsorted: [RuntimeDeviceRecord], options: RuntimesMachineOptions) -> RuntimesMachine {
        let runtimes = unsorted.sorted { $0.provider.localizedCompare($1.provider) == .orderedAscending }
        let providerNames = Array(Set(runtimes.map(\.provider))).sorted()
        let localName = options.localMachineName?.lowercased()
        func matchesLocalName(_ value: String?) -> Bool {
            guard let value, let localName else { return false }
            return value.lowercased() == localName
        }
        let ownsLocalRuntime = options.currentUserID.map { uid in runtimes.contains { $0.ownerId == uid } } ?? false
        let byDaemon = options.localDaemonID.map { !$0.isEmpty && daemonID == $0 } ?? false
        let byName = mode == "local" && options.localMachineName != nil && ownsLocalRuntime
            && (matchesLocalName(daemonID) || runtimes.contains { matchesLocalName(deviceName($0)) })
        let isCurrent = byDaemon || byName
        let title = machineTitle(runtimes, isCurrent: isCurrent, localMachineName: options.localMachineName)
        let deviceInfo = runtimes.first.flatMap { formatDeviceInfo($0.deviceInfo) }
        let subtitle = compactDeviceInfo(deviceInfo, title: title)
            ?? daemonID.flatMap { $0.isEmpty ? nil : "daemon \(shortDaemonID($0))" }
            ?? (mode == "cloud" ? "Cloud worker" : nil)
        let healths = runtimes.map { RuntimesHealth.of($0, now: options.now) }
        let onlineCount = healths.filter { $0 == .online }.count
        let health: RuntimesHealth = onlineCount > 0
            ? .online
            : healths.reduce(.recentlyLost) { $1.severity > $0.severity ? $1 : $0 }
        var running = 0, queued = 0
        for r in runtimes {
            if let w = options.workloadByRuntimeID[r.id] {
                running += w.runningCount
                queued += w.queuedCount
            }
        }
        return RuntimesMachine(
            id: id, daemonID: daemonID, title: title, subtitle: subtitle, deviceInfo: deviceInfo,
            cliVersion: machineMetadata(runtimes, "cli_version"), launchedBy: machineMetadata(runtimes, "launched_by"),
            mode: mode, section: isCurrent ? .local : (mode == "cloud" ? .cloud : .remote), isCurrent: isCurrent,
            health: health, runtimes: runtimes, onlineCount: onlineCount, issueCount: runtimes.count - onlineCount,
            runningCount: running, queuedCount: queued, providerNames: providerNames, lastSeenAt: latestLastSeen(runtimes))
    }

    static func machineTitle(_ runtimes: [RuntimeDeviceRecord], isCurrent: Bool, localMachineName: String?) -> String {
        if let shared = sharedCustomName(runtimes) { return shared }
        if isCurrent, let localMachineName { return localMachineName }
        guard let first = runtimes.first else { return "Unknown machine" }
        if let device = deviceName(first) { return device }
        if first.runtimeMode == "cloud" { return "\(capitalize(first.provider)) cloud" }
        if let d = first.daemonId, !d.isEmpty { return shortDaemonID(d) }
        return "Unknown machine"
    }

    static func capitalize(_ value: String) -> String {
        value.isEmpty ? "Runtime" : value.prefix(1).uppercased() + value.dropFirst()
    }

    static func reportTime(_ runtime: RuntimeDeviceRecord) -> Date {
        Timestamp.parse(runtime.lastSeenAt ?? runtime.updatedAt) ?? .distantPast
    }

    static func machineMetadata(_ runtimes: [RuntimeDeviceRecord], _ key: String) -> String? {
        let online = runtimes.filter { $0.status == "online" }
        let candidates = (online.isEmpty ? runtimes : online).sorted { reportTime($0) > reportTime($1) }
        for r in candidates {
            if let v = metadataString(r, key)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        return nil
    }

    static func latestLastSeen(_ runtimes: [RuntimeDeviceRecord]) -> String? {
        var latest: (String, Date)?
        for r in runtimes {
            guard let s = r.lastSeenAt, let d = Timestamp.parse(s) else { continue }
            if latest == nil || d > latest!.1 { latest = (s, d) }
        }
        return latest?.0
    }

    static func machineOrder(_ a: RuntimesMachine, _ b: RuntimesMachine) -> Bool {
        if a.isCurrent != b.isCurrent { return a.isCurrent }
        if a.section.rank != b.section.rank { return a.section.rank < b.section.rank }
        if a.onlineCount != b.onlineCount { return a.onlineCount > b.onlineCount }
        return a.title.localizedCompare(b.title) == .orderedAscending
    }

    public static func filterMachines(_ machines: [RuntimesMachine], query: String, filter: RuntimesMachineFilter) -> [RuntimesMachine] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return machines.filter { m in
            if filter == .online && m.onlineCount == 0 { return false }
            if filter == .issues && m.issueCount == 0 { return false }
            guard !q.isEmpty else { return true }
            let haystack = [m.title, m.subtitle, m.deviceInfo, m.daemonID, m.providerNames.joined(separator: " "),
                            m.runtimes.map(\.name).joined(separator: " "), m.runtimes.map { $0.customName ?? "" }.joined(separator: " ")]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ").lowercased()
            return haystack.contains(q)
        }
    }

    public static func machineCounts(_ machines: [RuntimesMachine]) -> (all: Int, online: Int, issues: Int) {
        (machines.count, machines.filter { $0.onlineCount > 0 }.count, machines.filter { $0.issueCount > 0 }.count)
    }

    /// Machine id, a legacy runtime id inside it, or the desktop placeholder.
    public static func findMachine(_ machines: [RuntimesMachine], locator: String) -> RuntimesMachine? {
        if let m = machines.first(where: { $0.id == locator || $0.runtimes.contains { $0.id == locator } }) { return m }
        return locator == placeholderMachineID ? machines.first(where: \.isCurrent) : nil
    }

    public static func resolveSettingsTarget(_ runtimes: [RuntimeDeviceRecord], machineID: String, runtimeID: String,
                                             now: Date = Date()) -> (machine: RuntimesMachine, runtime: RuntimeDeviceRecord)? {
        let machines = buildMachines(runtimes, options: RuntimesMachineOptions(now: now))
        guard let machine = machines.first(where: { $0.id == machineID || $0.runtimes.contains { $0.id == machineID } }),
              let runtime = machine.runtimes.first(where: { $0.id == runtimeID }) else { return nil }
        return (machine, runtime)
    }

    /// The runtime a viewer may use to send a machine-wide CLI update: their
    /// own, or a public one when they administer the workspace. Online wins.
    public static func machineUpdateRuntime(_ machine: RuntimesMachine, currentUserID: String?, canManagePublicRuntimes: Bool) -> RuntimeDeviceRecord? {
        guard machine.mode == "local", let uid = currentUserID else { return nil }
        let usable = machine.runtimes.filter { $0.ownerId == uid || (canManagePublicRuntimes && $0.visibility == "public") }
        return usable.first { $0.status == "online" } ?? usable.first
    }

    // MARK: Pending custom runtimes

    public static func pendingRuntimeID(_ profileID: String) -> String { pendingIDPrefix + profileID }

    public static func isPending(_ runtime: RuntimeDeviceRecord) -> Bool {
        metadataBool(runtime, "pending_custom_runtime") == true
    }

    public static func isDisabledPending(_ runtime: RuntimeDeviceRecord) -> Bool {
        isPending(runtime) && metadataBool(runtime, "runtime_profile_enabled") == false
    }

    public static func pendingCommandName(_ runtime: RuntimeDeviceRecord) -> String? {
        guard let c = metadataString(runtime, "command_name"), !c.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return c
    }

    public static func registrationFailure(_ runtime: RuntimeDeviceRecord) -> String? {
        guard metadataBool(runtime, "runtime_profile_registration_error") == true,
              let reason = metadataString(runtime, "runtime_profile_failure_reason"),
              !reason.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return reason
    }

    public static func isPendingWarning(_ runtime: RuntimeDeviceRecord, now: Date) -> Bool {
        guard isPending(runtime), let since = metadataString(runtime, "pending_since"), let start = Timestamp.parse(since) else { return false }
        return now.timeIntervalSince(start) >= pendingWarningInterval
    }

    static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// A placeholder row for a custom runtime profile no daemon has registered yet.
    public static func pendingRuntime(profile: RuntimeProfile, createdAt: Date, ownerID: String? = nil, localDaemonID: String? = nil,
                                      localMachineName: String? = nil, fallbackMachineName: String? = nil) -> RuntimeDeviceRecord {
        let since = isoString(createdAt)
        let machineName = [localMachineName, fallbackMachineName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Pending custom runtimes"
        let metadata: [String: JSONValue] = [
            "pending_custom_runtime": .bool(true),
            "runtime_profile_id": .string(profile.id),
            "runtime_profile_enabled": .bool(profile.enabled),
            "command_name": .string(profile.commandName),
            "pending_since": .string(since),
        ]
        return RuntimeDeviceRecord(
            id: pendingRuntimeID(profile.id), workspaceId: profile.workspaceId, daemonId: localDaemonID,
            name: "\(profile.displayName) (\(machineName))", runtimeMode: "local", provider: profile.protocolFamily,
            launchHeader: profile.protocolFamily, status: "offline", deviceInfo: machineName, metadata: metadata,
            ownerId: ownerID ?? profile.createdBy, visibility: "private", profileId: profile.id,
            lastSeenAt: since, createdAt: since, updatedAt: since)
    }

    /// Appends a pending row for every profile that has no registered runtime.
    public static func withPendingRuntimes(_ runtimes: [RuntimeDeviceRecord], profiles: [RuntimeProfile], ownerID: String? = nil,
                                           localDaemonID: String? = nil, localMachineName: String? = nil,
                                           fallbackMachineName: String? = nil) -> [RuntimeDeviceRecord] {
        guard !profiles.isEmpty else { return runtimes }
        let registered = Set(runtimes.compactMap { $0.profileId?.isEmpty == false ? $0.profileId : nil })
        let pending = profiles.filter { !registered.contains($0.id) }.map {
            pendingRuntime(profile: $0, createdAt: Timestamp.parse($0.createdAt) ?? Date(timeIntervalSince1970: 0), ownerID: ownerID,
                           localDaemonID: localDaemonID, localMachineName: localMachineName, fallbackMachineName: fallbackMachineName)
        }
        return runtimes + pending
    }
}
