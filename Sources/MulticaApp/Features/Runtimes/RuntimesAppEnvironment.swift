import AppKit
import MulticaCore

/// "This machine" as the runtimes pages see it (desktop
/// `use-desktop-runtime-context.ts`).
struct RuntimesLocalContext: Equatable {
    var daemonID: String?
    var machineName: String?
    var bootstrapping: Bool
}

enum RuntimesDaemonPrefs {
    static let autoStopKey = "multica.daemon.autoStop"
}

@MainActor
private enum RuntimesDaemonHooks {
    static var quitObserver: NSObjectProtocol?
    /// The last daemon identity seen, so a stopped daemon still maps to the
    /// same local machine across route changes.
    static var lastIdentity: (daemonID: String, deviceName: String?)?
    /// `os.hostname()`, which is what the daemon reports as its device name.
    static let hostName: String = {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        return String(cString: buffer)
    }()
}

extension AppEnvironment {
    /// Auto-stop on quit: stop the daemon synchronously while the app
    /// terminates, when the user turned that on.
    func installDaemonQuitHook(_ controller: DaemonController) {
        guard RuntimesDaemonHooks.quitObserver == nil else { return }
        RuntimesDaemonHooks.quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            guard UserDefaults.standard.bool(forKey: RuntimesDaemonPrefs.autoStopKey) else { return }
            controller.stopForQuit()
        }
    }

    var runtimesLocalContext: RuntimesLocalContext {
        let health = daemonStatus.health
        if let id = health?.daemonID, !id.isEmpty {
            RuntimesDaemonHooks.lastIdentity = (id, health?.deviceName)
        }
        let last = RuntimesDaemonHooks.lastIdentity
        let state = daemonStatus.state
        return RuntimesLocalContext(
            daemonID: health?.daemonID ?? last?.daemonID,
            machineName: health?.deviceName ?? last?.deviceName ?? RuntimesDaemonHooks.hostName,
            bootstrapping: state == .installingCLI || state == .starting || state == .running)
    }

    func runtimesStartDaemon() async -> RuntimesDaemonActionResult {
        guard let user = app.user, let daemon else { return .failed("Not signed in") }
        return await daemon.start(userID: user.id)
    }

    func runtimesStopDaemon() async -> RuntimesDaemonActionResult {
        guard let daemon else { return .ok }
        return await daemon.stop()
    }

    func runtimesRestartDaemon() async -> RuntimesDaemonActionResult {
        guard let user = app.user, let daemon else { return .failed("Not signed in") }
        return await daemon.restart(userID: user.id)
    }

    func runtimesRetryInstall() async {
        await daemon?.retryInstall()
    }

    /// Desktop `reauthenticateDaemon`: only a rejected session signs out;
    /// transient failures keep the user signed in and toast.
    func runtimesReauthenticateDaemon() async {
        guard let user = app.user, let daemon else {
            await signOut()
            return
        }
        switch await daemon.reauthenticate(userID: user.id) {
        case .ok:
            break
        case .sessionInvalid:
            await signOut()
        case .transient(let message):
            toaster.error(tr("settings", "desktop.daemon.reconnect_failed") + " — "
                + (message.isEmpty ? tr("settings", "desktop.daemon.try_again_moment") : message))
        }
    }
}
