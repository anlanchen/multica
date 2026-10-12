import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

public protocol CommandRunner: Sendable {
    func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> CommandResult
}

extension CommandRunner {
    public func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> CommandResult {
        try await run(executable, arguments: arguments, environment: nil, timeout: timeout)
    }
}

/// Runs a child process without blocking any thread while it executes.
public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let collected = Locked(Data())
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { collected.withLock { $0.append(d) } }
        }

        return try await withCheckedThrowingContinuation { cont in
            let finished = Locked(false)
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                collected.withLock { $0.append(rest) }
                guard finished.withLock({ f -> Bool in defer { f = true }; return !f }) else { return }
                cont.resume(returning: CommandResult(exitCode: p.terminationStatus,
                                                     output: String(decoding: collected.current, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                guard finished.withLock({ f -> Bool in defer { f = true }; return !f }) else { return }
                cont.resume(throwing: error)
                return
            }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

public struct RuntimesDaemonActionResult: Sendable, Equatable {
    public var success: Bool
    public var error: String?

    public static let ok = RuntimesDaemonActionResult(success: true, error: nil)
    public static func failed(_ message: String) -> RuntimesDaemonActionResult { RuntimesDaemonActionResult(success: false, error: message) }
}

public enum RuntimesDaemonReauthResult: Sendable, Equatable {
    case ok
    /// The session token itself was rejected (401): sign in again.
    case sessionInvalid
    case transient(String)
}

/// Drives the local agent daemon through the `multica` CLI with the same
/// lifecycle as the Electron shell's daemon-manager (CLI bootstrap, token
/// sync, auth probe, crash recovery with a backoff budget, version-match
/// restarts), but with less background work:
///
/// - `/health` is probed adaptively: every second while transitioning,
///   every 5 s while the app is active, every 60 s in the background.
///   Electron polled every 5 s regardless.
/// - Probes go straight to 127.0.0.1 from this process; there is no
///   main↔renderer IPC hop per status update.
public actor DaemonController {
    public nonisolated let profile: DaemonProfile
    public nonisolated let statuses: AsyncStream<DaemonStatus>
    private let continuation: AsyncStream<DaemonStatus>.Continuation
    private let api: APIClient
    private let runner: CommandRunner
    private let probeSession: URLSession
    private var status = DaemonStatus(state: .unknown)
    private var pollTask: Task<Void, Never>?
    private var appActive = true
    private var cliOverride: URL?
    private var startingSince: ContinuousClock.Instant?

    private var resolvedCLI: URL?
    private var resolvedCLIVersion: String?
    private var cliResolved = false
    private var resolving: Task<URL?, Never>?

    /// The user wants the daemon up: set by start/restart/auto-start,
    /// cleared by stop and sign-out. Recovery only acts while it is set.
    private var desiredRunning = false
    private var recovery = RuntimesDaemonRecoveryPolicy()
    private var lifecycleOps = 0
    private var externalObserved = false
    private var authProbeDone = false
    private var authExpired = false
    private var pendingVersionRestart = false

    /// Read synchronously by the quit hook, which cannot hop onto the actor.
    private nonisolated let quitState = Locked<(cli: URL?, external: Bool)>((nil, false))

    /// Longer than the CLI's own 45 s readiness wait.
    static let startDeadline: Duration = .seconds(90)
    static let authProbeGrace: Duration = .seconds(10)
    static let launchEnvironment = ["MULTICA_LAUNCHED_BY": "desktop"]
    static let releaseBase = "https://github.com/multica-ai/multica/releases/latest/download"

    public init(api: APIClient, profile: DaemonProfile, runner: CommandRunner = ProcessRunner()) {
        self.api = api
        self.profile = profile
        self.runner = runner
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.connectionProxyDictionary = [:]
        probeSession = URLSession(configuration: cfg)
        (statuses, continuation) = AsyncStream.makeStream(of: DaemonStatus.self, bufferingPolicy: .bufferingNewest(1))
    }

    public var current: DaemonStatus { status }

    public func setCLIOverride(_ url: URL?) {
        cliOverride = url
        cliResolved = false
        resolvedCLI = nil
    }

    // MARK: CLI discovery

    /// Where a managed copy is installed when no CLI is found; the same
    /// location the official desktop app uses, so both share one binary.
    public nonisolated static func managedCLIPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Multica/bin/multica")
    }

    public nonisolated static func candidateCLIPaths(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                                     environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var out: [URL] = []
        if let explicit = environment["MULTICA_CLI_PATH"], !explicit.isEmpty { out.append(URL(fileURLWithPath: explicit)) }
        out.append(managedCLIPath(home: home))
        out.append(home.appendingPathComponent(".multica/bin/multica"))
        out.append(URL(fileURLWithPath: "/opt/homebrew/bin/multica"))
        out.append(URL(fileURLWithPath: "/usr/local/bin/multica"))
        out.append(home.appendingPathComponent(".local/bin/multica"))
        // GUI apps on macOS do not inherit the shell PATH, which is why the
        // fixed locations above come first.
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            out.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("multica"))
        }
        return out
    }

    /// The resolved CLI without probing or installing (nil until bootstrap).
    public func locateCLI() -> URL? {
        if let cliOverride { return cliOverride }
        return resolvedCLI ?? Self.candidateCLIPaths().first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public var isCLIInstalled: Bool { resolvedCLI != nil }
    public var cliVersion: String? { resolvedCLIVersion }

    /// `multica version --output json` → version, or nil for an unusable binary.
    func probeVersion(_ bin: URL) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: bin.path),
              let r = try? await runner.run(bin, arguments: ["version", "--output", "json"], timeout: .seconds(5)), r.exitCode == 0,
              let start = r.output.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(r.output[start...].utf8)) as? [String: Any],
              let v = obj["version"] as? String, !v.isEmpty else { return nil }
        return v
    }

    /// Finds a working CLI (override, managed copy, Homebrew, PATH), and
    /// installs the latest release when there is none. Single-flight.
    func resolveCLI() async -> URL? {
        if cliResolved { return resolvedCLI }
        if let resolving { return await resolving.value }
        let task = Task { await self.performResolve() }
        resolving = task
        let url = await task.value
        resolving = nil
        return url
    }

    private func performResolve() async -> URL? {
        var candidates = Self.candidateCLIPaths()
        if let cliOverride { candidates.insert(cliOverride, at: 0) }
        var seen = Set<String>()
        for c in candidates where seen.insert(c.path).inserted {
            if let v = await probeVersion(c) {
                setResolved(c, version: v)
                return c
            }
        }
        if let installed = try? await installManagedCLI(), let v = await probeVersion(installed) {
            setResolved(installed, version: v)
            return installed
        }
        cliResolved = true
        resolvedCLI = nil
        resolvedCLIVersion = nil
        quitState.withLock { $0.cli = nil }
        return nil
    }

    private func setResolved(_ url: URL, version: String) {
        cliResolved = true
        resolvedCLI = url
        resolvedCLIVersion = version
        quitState.withLock { $0.cli = url }
    }

    /// Downloads the platform archive from the latest GitHub release,
    /// verifies it against `checksums.txt`, and installs it.
    func installManagedCLI() async throws -> URL {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        let session = URLSession(configuration: .ephemeral)
        let (sumsData, sumsResponse) = try await session.data(from: URL(string: "\(Self.releaseBase)/checksums.txt")!)
        guard (sumsResponse as? HTTPURLResponse)?.statusCode == 200 else { throw APIError(status: 0, message: "checksums.txt unavailable") }
        let sums = RuntimesDaemonRules.parseChecksums(String(decoding: sumsData, as: UTF8.self))
        guard let asset = RuntimesDaemonRules.releaseAssetName(Array(sums.keys), arch: arch), let expected = sums[asset] else {
            throw APIError(status: 0, message: "no release asset for darwin/\(arch)")
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("multica-cli-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let (archiveData, archiveResponse) = try await session.data(from: URL(string: "\(Self.releaseBase)/\(asset)")!)
        guard (archiveResponse as? HTTPURLResponse)?.statusCode == 200 else { throw APIError(status: 0, message: "download failed") }
        let archive = work.appendingPathComponent(asset)
        try archiveData.write(to: archive)
        let sum = try await runner.run(URL(fileURLWithPath: "/usr/bin/shasum"), arguments: ["-a", "256", archive.path], timeout: .seconds(30))
        guard sum.output.split(separator: " ").first.map({ $0.lowercased() }) == expected else {
            throw APIError(status: 0, message: "checksum mismatch for \(asset)")
        }
        let untar = try await runner.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xf", archive.path, "-C", work.path], timeout: .seconds(60))
        let extracted = work.appendingPathComponent("multica")
        guard untar.exitCode == 0, fm.fileExists(atPath: extracted.path) else { throw APIError(status: 0, message: "archive did not contain multica") }
        let target = Self.managedCLIPath()
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: extracted, to: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        _ = try? await runner.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["-s", "-", "--force", target.path], timeout: .seconds(30))
        return target
    }

    /// First-launch setup: resolve (or install) the CLI, then begin the
    /// stopped/running state machine.
    public func bootstrap() async {
        publish(DaemonStatus(state: .installingCLI))
        if await resolveCLI() == nil {
            publish(DaemonStatus(state: .cliNotFound, message: "Install the multica CLI (brew install multica-ai/tap/multica) or set MULTICA_CLI_PATH."))
        } else {
            if status.state == .installingCLI { publish(DaemonStatus(state: .stopped)) }
            await refresh()
        }
    }

    /// Forgets the resolved CLI and runs setup again (Retry setup).
    public func retryInstall() async {
        cliResolved = false
        resolvedCLI = nil
        resolvedCLIVersion = nil
        await bootstrap()
    }

    // MARK: Health

    public func probe(timeout: TimeInterval? = nil) async -> DaemonHealth? {
        var request = URLRequest(url: profile.healthURL)
        if let timeout { request.timeoutInterval = timeout }
        do {
            let (data, response) = try await probeSession.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONCoders.decoder.decode(DaemonHealth.self, from: data)
        } catch {
            return nil
        }
    }

    private func readConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: profile.configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func writeConfig(_ config: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: profile.directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: profile.configURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profile.configURL.path)
    }

    /// Validates the profile token with `GET /api/me`, the same check
    /// `multica auth status` performs.
    private func probeToken() async -> RuntimesDaemonRules.AuthProbe {
        guard let token = readConfig()["token"] as? String, !token.isEmpty else { return RuntimesDaemonRules.classifyAuthProbe(noToken: true) }
        var base = api.config.apiURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/api/me") else { return .unknown }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return RuntimesDaemonRules.classifyAuthProbe(status: (response as? HTTPURLResponse)?.statusCode)
        } catch {
            return RuntimesDaemonRules.classifyAuthProbe(networkError: true)
        }
    }

    @discardableResult
    public func refresh() async -> DaemonStatus {
        if status.state == .installingCLI || (status.state == .cliNotFound && resolvedCLI == nil) { return status }
        let health = await probe()
        var next: DaemonStatus
        if let health, health.status == "running" {
            if let server = health.serverURL, !server.isEmpty, !RuntimesDaemonRules.urlsMatch(server, api.config.apiURL.absoluteString) {
                // Not this backend's daemon.
                next = DaemonStatus(state: .stopped)
            } else {
                authExpired = false
                let external = RuntimesDaemonRules.isExternallyManaged(daemonOS: health.os)
                externalObserved = external
                if external { recovery.reset() }
                quitState.withLock { $0.external = external }
                next = DaemonStatus(state: status.state == .stopping ? .stopping : .running, health: health, externallyManaged: external)
            }
        } else {
            if status.state == .starting, !authExpired, !authProbeDone, let since = startingSince, ContinuousClock.now - since >= Self.authProbeGrace {
                authProbeDone = true
                if await probeToken() == .authExpired { authExpired = true }
            }
            if authExpired {
                next = DaemonStatus(state: .authExpired)
            } else if health?.status == "starting" {
                next = DaemonStatus(state: .starting, health: health)
            } else if status.state == .starting {
                if let since = startingSince, ContinuousClock.now - since > Self.startDeadline {
                    next = DaemonStatus(state: .stopped, message: "The daemon did not become healthy. Check the daemon log.")
                } else {
                    next = DaemonStatus(state: .starting)
                }
            } else if status.state == .stopping {
                next = DaemonStatus(state: .stopping)
            } else {
                next = DaemonStatus(state: recovery.isPaused ? .recoveryPaused : .stopped, message: status.message)
            }
        }
        let decision = recovery.observe(desiredRunning: desiredRunning, externallyManaged: externalObserved,
                                        lifecycleBusy: lifecycleOps > 0, state: next.state, now: Date())
        if decision == .pause { next.state = .recoveryPaused }
        publish(next)
        if decision == .confirm {
            Task { await self.attemptRecovery() }
        }
        if pendingVersionRestart && next.state == .running && lifecycleOps == 0 {
            Task { await self.ensureVersionMatches() }
        }
        return next
    }

    private func publish(_ s: DaemonStatus) {
        if s.state == .starting {
            if status.state != .starting { startingSince = .now }
        } else {
            startingSince = nil
        }
        guard s != status else { return }
        status = s
        continuation.yield(s)
    }

    // MARK: Polling

    public func setAppActive(_ active: Bool) {
        appActive = active
        if pollTask != nil { startPolling() }
    }

    public func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let s = await self.refresh()
                let interval = await self.pollInterval(for: s.state)
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func pollInterval(for state: DaemonState) -> Duration {
        if state.isTransitioning { return .seconds(1) }
        return appActive ? .seconds(5) : .seconds(60)
    }

    // MARK: Credentials

    /// Writes the profile config the CLI reads: the target server and a
    /// personal access token minted for `userID` (reused while the user is
    /// unchanged). Returns whether the profile belonged to another user.
    @discardableResult
    public func ensureConfig(userID: String) async throws -> Bool {
        var config = readConfig()
        let previousUser = (try? String(contentsOf: profile.userIDURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userChanged = previousUser.map { !$0.isEmpty && $0 != userID } ?? false
        let cachedToken = config["token"] as? String
        if previousUser != userID || !(cachedToken?.hasPrefix("mul_") ?? false) {
            config["token"] = try await api.mintPersonalAccessToken(name: "Multica Native")
        }
        config["server_url"] = api.config.apiURL.absoluteString
        try writeConfig(config)
        try Data(userID.utf8).write(to: profile.userIDURL, options: .atomic)
        return userChanged
    }

    /// Drops the cached PAT and the user sidecar so the next sync mints fresh.
    public func clearToken() {
        var config = readConfig()
        if config.removeValue(forKey: "token") != nil { try? writeConfig(config) }
        try? FileManager.default.removeItem(at: profile.userIDURL)
    }

    // MARK: Lifecycle

    private func spawnStart() async -> RuntimesDaemonActionResult {
        guard let cli = await resolveCLI() else { return .failed("multica CLI is not installed") }
        if let h = await probe(), h.isAlive {
            externalObserved = RuntimesDaemonRules.isExternallyManaged(daemonOS: h.os)
            publish(DaemonStatus(state: h.status == "running" ? .running : .starting, health: h, externallyManaged: externalObserved))
            return .ok
        }
        authProbeDone = false
        authExpired = false
        publish(DaemonStatus(state: .starting))
        // The CLI blocks until the daemon reports ready (up to 45 s for
        // cold agent detection), so the timeout must exceed that.
        let result = try? await runner.run(cli, arguments: ["daemon", "start"] + profile.cliArguments,
                                           environment: Self.launchEnvironment, timeout: .seconds(60))
        guard let result, result.exitCode == 0 else {
            let output = result?.output ?? "failed to launch"
            let lowered = output.lowercased()
            if lowered.contains("401") || lowered.contains("unauthorized") || lowered.contains("expired") {
                authExpired = true
                publish(DaemonStatus(state: .authExpired, message: String(output.suffix(400))))
            } else {
                publish(DaemonStatus(state: .stopped, message: String(output.suffix(400))))
            }
            return .failed(String(output.suffix(400)))
        }
        await refresh()
        return .ok
    }

    private func stopProcess() async -> RuntimesDaemonActionResult {
        if let h = await probe(), RuntimesDaemonRules.isExternallyManaged(daemonOS: h.os) { return .ok }
        guard let cli = await resolveCLI() else { return .failed("multica CLI is not installed") }
        authExpired = false
        publish(DaemonStatus(state: .stopping, health: status.health))
        let r = try? await runner.run(cli, arguments: ["daemon", "stop"] + profile.cliArguments, timeout: .seconds(20))
        publish(DaemonStatus(state: .stopped))
        await refresh()
        if let r, r.exitCode == 0 { return .ok }
        return .failed(r.map { String($0.output.suffix(400)) } ?? "failed to stop the daemon")
    }

    @discardableResult
    public func start(userID: String) async -> RuntimesDaemonActionResult {
        desiredRunning = true
        externalObserved = false
        recovery.reset()
        lifecycleOps += 1
        defer { lifecycleOps -= 1 }
        guard await resolveCLI() != nil else {
            publish(DaemonStatus(state: .cliNotFound, message: "Install the multica CLI (brew install multica-ai/tap/multica) or set MULTICA_CLI_PATH."))
            return .failed("multica CLI is not installed")
        }
        if let h = await probe(), h.isAlive {
            return await spawnStart()
        }
        do {
            try await ensureConfig(userID: userID)
        } catch let e as APIError where e.isUnauthorized {
            authExpired = true
            publish(DaemonStatus(state: .authExpired, message: e.message))
            return .failed(e.message)
        } catch {
            publish(DaemonStatus(state: .stopped, message: "Could not prepare the daemon profile: \(error)"))
            return .failed("\(error)")
        }
        return await spawnStart()
    }

    @discardableResult
    public func stop() async -> RuntimesDaemonActionResult {
        desiredRunning = false
        recovery.reset()
        lifecycleOps += 1
        defer { lifecycleOps -= 1 }
        return await stopProcess()
    }

    @discardableResult
    public func restart(userID: String) async -> RuntimesDaemonActionResult {
        desiredRunning = true
        externalObserved = false
        recovery.reset()
        lifecycleOps += 1
        defer { lifecycleOps -= 1 }
        if let h = await probe(), RuntimesDaemonRules.isExternallyManaged(daemonOS: h.os) { return .ok }
        let stopped = await stopProcess()
        guard stopped.success else { return stopped }
        return await start(userID: userID)
    }

    /// Sign-in: sync the profile token (restarting a running daemon when the
    /// account changed), then start it if auto-start is on. A running daemon
    /// built from an older CLI is restarted once idle.
    public func syncLogin(userID: String, autoStart: Bool) async {
        desiredRunning = autoStart
        recovery.reset()
        guard await resolveCLI() != nil else { return }
        let health = await probe()
        if let health, health.isAlive {
            let changed = (try? await ensureConfig(userID: userID)) ?? false
            if changed {
                lifecycleOps += 1
                _ = await stopProcess()
                _ = await spawnStart()
                lifecycleOps -= 1
            } else if autoStart {
                await ensureVersionMatches()
            }
            return
        }
        if autoStart { await start(userID: userID) }
    }

    /// Explicit sign-out: the next user must not inherit this daemon.
    public func signOutCleanup() async {
        desiredRunning = false
        recovery.reset()
        clearToken()
        lifecycleOps += 1
        _ = await stopProcess()
        lifecycleOps -= 1
    }

    /// Recovers from `auth_expired`: drop the cached PAT, mint a fresh one,
    /// restart. Only a 401 on the mint means the session itself is dead.
    public func reauthenticate(userID: String) async -> RuntimesDaemonReauthResult {
        desiredRunning = true
        recovery.reset()
        lifecycleOps += 1
        defer { lifecycleOps -= 1 }
        clearToken()
        do {
            try await ensureConfig(userID: userID)
        } catch let e as APIError where e.isUnauthorized {
            return .sessionInvalid
        } catch {
            return .transient((error as? APIError)?.message ?? error.localizedDescription)
        }
        authExpired = false
        let stopped = await stopProcess()
        guard stopped.success else { return .transient(stopped.error ?? "failed to restart daemon") }
        let started = await spawnStart()
        return started.success ? .ok : .transient(started.error ?? "failed to restart daemon")
    }

    private func ensureVersionMatches() async {
        guard lifecycleOps == 0 else { return }
        let health = await probe()
        if let health, RuntimesDaemonRules.isExternallyManaged(daemonOS: health.os) {
            pendingVersionRestart = false
            return
        }
        switch RuntimesDaemonRules.versionAction(bundled: resolvedCLIVersion, health: health) {
        case .notRunning, .ok:
            pendingVersionRestart = false
        case .deferred:
            pendingVersionRestart = true
        case .restart:
            pendingVersionRestart = false
            lifecycleOps += 1
            _ = await stopProcess()
            _ = await spawnStart()
            lifecycleOps -= 1
        }
    }

    // MARK: Recovery

    private func pidConfirmedAbsent() -> Bool {
        guard let raw = try? String(contentsOf: profile.pidURL, encoding: .utf8) else {
            return !FileManager.default.fileExists(atPath: profile.pidURL.path)
        }
        guard let pid = RuntimesDaemonRules.parsePID(raw) else { return false }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    private func attemptRecovery() async {
        guard lifecycleOps == 0, desiredRunning, !externalObserved else { return }
        lifecycleOps += 1
        defer { lifecycleOps -= 1 }
        // A normal probe gives up after 2 s; confirm death with a longer one
        // before restarting a daemon that is merely busy.
        if let h = await probe(timeout: 10), h.isAlive {
            await refresh()
            return
        }
        guard desiredRunning, !externalObserved else { return }
        if pidConfirmedAbsent() {
            recovery.recordPIDAbsent()
        } else if !recovery.recordPIDDeferral(Date()) {
            return
        }
        guard desiredRunning else { return }
        recovery.recordAttempt(Date())
        let result = await spawnStart()
        if !desiredRunning && result.success {
            _ = await stopProcess()
        }
    }

    // MARK: Quit

    /// Synchronously stops the daemon while the app terminates (auto-stop on
    /// quit). A daemon on another OS is left alone.
    public nonisolated func stopForQuit(timeout: TimeInterval = 15) {
        let state = quitState.current
        guard let cli = state.cli, !state.external else { return }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["daemon", "stop"] + profile.cliArguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
    }
}
