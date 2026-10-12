import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
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
    func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> CommandResult
}

/// Runs a child process without blocking any thread while it executes.
public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
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

/// Drives the local agent daemon through the `multica` CLI, the same way the
/// Electron shell does, but with less background work:
///
/// - `/health` is probed adaptively: every second while starting/stopping,
///   every 5 s while the app is active, every 60 s in the background, and not
///   at all when nothing observes it. Electron polled every 5 s regardless.
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

    public func setCLIOverride(_ url: URL?) { cliOverride = url }

    // MARK: CLI discovery

    public nonisolated static func candidateCLIPaths(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                                     environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var out: [URL] = []
        if let explicit = environment["MULTICA_CLI_PATH"], !explicit.isEmpty { out.append(URL(fileURLWithPath: explicit)) }
        // Managed copy installed by the official desktop app.
        out.append(home.appendingPathComponent("Library/Application Support/Multica/bin/multica"))
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

    public func locateCLI() -> URL? {
        if let cliOverride { return cliOverride }
        return Self.candidateCLIPaths().first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Health

    public func probe() async -> DaemonHealth? {
        do {
            let (data, response) = try await probeSession.data(from: profile.healthURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONCoders.decoder.decode(DaemonHealth.self, from: data)
        } catch {
            return nil
        }
    }

    @discardableResult
    public func refresh() async -> DaemonStatus {
        let health = await probe()
        var next = status
        if let health, health.isAlive {
            next.health = health
            if status.state != .stopping {
                next.state = health.status == "running" ? .running : .starting
            }
            next.message = nil
        } else {
            next.health = nil
            switch status.state {
            case .starting, .authExpired, .failed, .cliNotFound:
                break // keep the explanation until the next explicit action
            default:
                next.state = locateCLI() == nil ? .cliNotFound : .stopped
            }
        }
        publish(next)
        return next
    }

    private func publish(_ s: DaemonStatus) {
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

    // MARK: Lifecycle

    /// Writes the profile config the CLI reads: the target server and a
    /// personal access token minted for `userID` (reused while the user is
    /// unchanged).
    public func ensureConfig(userID: String) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: profile.directory, withIntermediateDirectories: true)
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: profile.configURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = obj
        }
        let previousUser = (try? String(contentsOf: profile.userIDURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cachedToken = config["token"] as? String
        if previousUser != userID || !(cachedToken?.hasPrefix("mul_") ?? false) {
            config["token"] = try await api.mintPersonalAccessToken(name: "Multica Native")
            try Data(userID.utf8).write(to: profile.userIDURL, options: .atomic)
        }
        config["server_url"] = api.config.apiURL.absoluteString
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: profile.configURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profile.configURL.path)
    }

    public func start(userID: String) async {
        guard let cli = locateCLI() else {
            publish(DaemonStatus(state: .cliNotFound, message: "Install the multica CLI (brew install multica-ai/tap/multica) or set MULTICA_CLI_PATH."))
            return
        }
        if let h = await probe(), h.isAlive {
            publish(DaemonStatus(state: h.status == "running" ? .running : .starting, health: h))
            return
        }
        publish(DaemonStatus(state: .starting))
        do {
            try await ensureConfig(userID: userID)
        } catch let e as APIError where e.isUnauthorized {
            publish(DaemonStatus(state: .authExpired, message: e.message))
            return
        } catch {
            publish(DaemonStatus(state: .failed, message: "Could not prepare the daemon profile: \(error)"))
            return
        }
        // The CLI blocks until the daemon reports ready (up to 45 s for
        // cold agent detection), so the timeout must exceed that.
        let result = try? await runner.run(cli, arguments: ["daemon", "start"] + profile.cliArguments, timeout: .seconds(60))
        if let result, result.exitCode == 0 {
            await refresh()
        } else {
            let output = result?.output ?? "failed to launch"
            let lowered = output.lowercased()
            let state: DaemonState = (lowered.contains("401") || lowered.contains("unauthorized") || lowered.contains("expired"))
                ? .authExpired : .failed
            publish(DaemonStatus(state: state, message: String(output.suffix(400))))
        }
    }

    public func stop() async {
        guard let cli = locateCLI() else { return }
        publish(DaemonStatus(state: .stopping, health: status.health))
        _ = try? await runner.run(cli, arguments: ["daemon", "stop"] + profile.cliArguments, timeout: .seconds(20))
        publish(DaemonStatus(state: .stopped))
        await refresh()
    }

    public func restart(userID: String) async {
        await stop()
        await start(userID: userID)
    }
}
