import Foundation
import MulticaCore
import Observation

/// App-wide state: the core `AppModel` plus things only the macOS app owns
/// (server settings, the local daemon, the log tail).
@MainActor
@Observable
final class AppEnvironment {
    let app: AppModel
    private(set) var daemon: DaemonController?
    private(set) var daemonStatus = DaemonStatus(state: .unknown)
    private(set) var daemonLog: [String] = []

    var autoStartDaemon: Bool {
        didSet { UserDefaults.standard.set(autoStartDaemon, forKey: Keys.autoStart) }
    }

    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var logTask: Task<Void, Never>?
    @ObservationIgnored private var logTailer: LogTailer?
    @ObservationIgnored private var logViewers = 0
    @ObservationIgnored private var autoStartAttemptedFor: String?

    enum Keys {
        static let apiURL = "multica.server.apiURL"
        static let appURL = "multica.server.appURL"
        static let autoStart = "multica.daemon.autoStart"
    }

    static func savedServerConfig() -> ServerConfig {
        let d = UserDefaults.standard
        if let api = d.string(forKey: Keys.apiURL).flatMap(URL.init(string:)),
           let web = d.string(forKey: Keys.appURL).flatMap(URL.init(string:)) {
            return ServerConfig(apiURL: api, appURL: web)
        }
        return .production
    }

    static func saveServerConfig(apiURL: URL, appURL: URL) {
        UserDefaults.standard.set(apiURL.absoluteString, forKey: Keys.apiURL)
        UserDefaults.standard.set(appURL.absoluteString, forKey: Keys.appURL)
    }

    static func resetServerConfig() {
        UserDefaults.standard.removeObject(forKey: Keys.apiURL)
        UserDefaults.standard.removeObject(forKey: Keys.appURL)
    }

    init() {
        let config = Self.savedServerConfig()
        let identity = ClientIdentity(
            platform: "macos-native",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? MulticaCoreVersion.string,
            os: "macos"
        )
        app = AppModel(
            config: config,
            tokenStore: KeychainTokenStore(service: "ai.multica.native.\(config.apiURL.host ?? "server")"),
            identity: identity
        )
        autoStartDaemon = UserDefaults.standard.object(forKey: Keys.autoStart) as? Bool ?? true
    }

    func bootstrap() async {
        await app.bootstrap()
        startDaemonMonitoring()
        await autoStartIfNeeded()
    }

    // MARK: Daemon

    private func startDaemonMonitoring() {
        guard daemon == nil else { return }
        let controller = DaemonController(api: app.api, profile: DaemonProfile(targetAPIURL: app.config.apiURL))
        daemon = controller
        statusTask = Task { [weak self] in
            for await status in controller.statuses {
                self?.daemonStatus = status
            }
        }
        Task { await controller.startPolling() }
    }

    /// Mirrors the official desktop app: once signed in, this computer comes
    /// online as a runtime unless the user turned that off.
    func autoStartIfNeeded() async {
        guard autoStartDaemon, let user = app.user, autoStartAttemptedFor != user.id, let daemon else { return }
        autoStartAttemptedFor = user.id
        let status = await daemon.refresh()
        if status.state == .stopped {
            await daemon.start(userID: user.id)
        }
    }

    func startDaemon() async {
        guard let user = app.user else { return }
        await daemon?.start(userID: user.id)
    }

    func stopDaemon() async {
        await daemon?.stop()
    }

    func restartDaemon() async {
        guard let user = app.user else { return }
        await daemon?.restart(userID: user.id)
    }

    func setAppActive(_ active: Bool) {
        Task { await daemon?.setAppActive(active) }
    }

    // MARK: Log tail (only while a view shows it)

    func attachLogViewer() {
        logViewers += 1
        guard logViewers == 1, let daemon else { return }
        let tailer = LogTailer(url: daemon.profile.logURL)
        logTailer = tailer
        tailer.start()
        logTask = Task { [weak self] in
            for await lines in tailer.lines {
                guard let self else { return }
                self.daemonLog.append(contentsOf: lines)
                if self.daemonLog.count > 500 { self.daemonLog.removeFirst(self.daemonLog.count - 500) }
            }
        }
    }

    func detachLogViewer() {
        logViewers = max(0, logViewers - 1)
        guard logViewers == 0 else { return }
        logTailer?.stop()
        logTailer = nil
        logTask?.cancel()
        logTask = nil
    }
}
