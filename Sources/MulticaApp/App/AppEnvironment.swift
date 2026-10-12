import Foundation
import MulticaCore
import Observation

/// App-wide state: the core `AppModel` plus things only the macOS app owns
/// (server settings, the local daemon, the log tail).
@MainActor
@Observable
final class AppEnvironment {
    let app: AppModel
    let tabs: TabStore
    let shell = ShellState()
    let toaster = Toaster()
    let modals = ModalCenter()
    let shortcuts = ShortcutStore()
    let navigator: Navigator
    @ObservationIgnored let keyMonitor = KeyMonitor()
    @ObservationIgnored let notifications = SystemNotifications()

    /// Invitations to other workspaces addressed to the signed-in user.
    private(set) var myInvitations: [Invitation] = []
    private(set) var appConfig: AppConfigResponse?
    /// The chat session on screen (main chat page or floating panel), so its
    /// messages do not count as unread.
    var activeChatSessionID: String?
    /// Unsent create-issue dialog content (sidebar shows a dot).
    var issueDraft: CreateIssueDraft? = nil {
        didSet { hasIssueDraft = issueDraft.map { !$0.title.isEmpty || !$0.description.isEmpty } ?? false }
    }
    private(set) var hasIssueDraft = false
    /// Bumped when the UI language changes; the root view is keyed on it.
    private(set) var languageRevision = 0
    var appearance: String {
        didSet { UserDefaults.standard.set(appearance, forKey: Keys.appearance) }
    }

    var serverVersion: String? { appConfig?.serverVersion.flatMap { $0.isEmpty ? nil : $0 } }
    var workspaceCreationDisabled: Bool { appConfig?.workspaceCreationDisabled ?? false }

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
        static let tabs = "multica.tabs.v1"
        static let language = "multica.language"
        static let appearance = "multica.appearance"
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
        appearance = UserDefaults.standard.string(forKey: Keys.appearance) ?? "system"
        let tabStore = TabStore()
        tabs = tabStore
        navigator = Navigator(tabs: tabStore, slug: "")
        ImageLoader.baseURL = config.apiURL
        ImageLoader.api = app.api
        MarkdownLinks.appURL = config.appURL
        L10n.shared.setLanguage(UserDefaults.standard.string(forKey: Keys.language))
        if let saved = UserDefaults.standard.data(forKey: Keys.tabs) {
            tabs.restore(saved)
        }
        tabs.onChange = { [weak self] data in self?.scheduleTabSave(data) }
    }

    @ObservationIgnored private var tabSaveTask: Task<Void, Never>?

    private func scheduleTabSave(_ data: Data) {
        tabSaveTask?.cancel()
        tabSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(data, forKey: Keys.tabs)
        }
    }

    // MARK: Account & workspaces

    /// Called whenever the active session changes.
    func sessionDidChange() {
        guard let session = app.session else { return }
        navigator.setWorkspace(session.workspace.slug)
        tabs.validateWorkspaceSlugs(Set(app.workspaces.map(\.slug)))
    }

    func loadAccountExtras() async {
        let api = app.api
        let config = Task { try? await api.getConfig() }
        let invitations = Task { try? await api.listMyInvitations() }
        appConfig = await config.value
        if let cdn = appConfig?.cdnDomain, !cdn.isEmpty { MarkdownBlocks.cdnDomain = cdn }
        myInvitations = await invitations.value ?? []
    }

    /// Opens the inbox on an item from a system notification, in the
    /// item's own workspace.
    func openInboxItem(slug: String, itemID: String, issueKey: String) async {
        if app.session?.workspace.slug != slug, let ws = app.workspaces.first(where: { $0.slug == slug }) {
            await switchWorkspace(ws)
        }
        guard let session = app.session, session.workspace.slug == slug else { return }
        navigator.push(.inbox, query: ["issue": issueKey])
        try? await session.api.markInboxRead(id: itemID)
    }

    func reloadInvitations() async {
        myInvitations = (try? await app.api.listMyInvitations()) ?? myInvitations
    }

    func switchWorkspace(_ ws: Workspace) async {
        await app.select(ws)
        sessionDidChange()
    }

    func acceptInvitation(_ inv: Invitation) async {
        do {
            _ = try await app.api.acceptInvitation(inv.id)
            myInvitations.removeAll { $0.id == inv.id }
            await app.reloadWorkspaces()
            if let ws = app.workspaces.first(where: { $0.id == inv.workspaceId }) {
                await switchWorkspace(ws)
            }
        } catch {
            toaster.error(error)
            await reloadInvitations()
        }
    }

    func declineInvitation(_ inv: Invitation) async {
        do {
            try await app.api.declineInvitation(inv.id)
            myInvitations.removeAll { $0.id == inv.id }
        } catch {
            toaster.error(error)
            await reloadInvitations()
        }
    }

    func hasOtherWorkspaceUnread(_ currentID: String, inbox: InboxStore) -> Bool {
        app.workspaces.contains { $0.id != currentID && inbox.unread(in: $0.id) > 0 }
    }

    func signOut() async {
        tabs.reset()
        myInvitations = []
        await app.signOut()
    }

    func setLanguage(_ code: String?) {
        UserDefaults.standard.set(code, forKey: Keys.language)
        L10n.shared.setLanguage(code)
        languageRevision += 1
    }

    var languagePreference: String? { UserDefaults.standard.string(forKey: Keys.language) }

    /// Runs a shortcut action; returns false when it does not apply here.
    func perform(_ action: ShortcutAction) -> Bool {
        guard app.session != nil else { return false }
        switch action {
        case .openSearch: shell.searchOpen.toggle()
        case .createIssue: modals.createIssue(contextualDraft())
        case .toggleSidebar: shell.toggleSidebar()
        case .toggleRightSidebar: shell.rightPanelOpen.toggle()
        case .toggleChat: shell.chatOpen.toggle()
        case .findInIssue:
            guard case .issue = navigator.route else { return false }
            shell.findRequest += 1
        case .archiveInboxItem:
            guard navigator.route == .inbox else { return false }
            NotificationCenter.default.post(name: .multicaArchiveInboxItem, object: nil)
        case .send: return false
        case .goBack: navigator.back()
        case .goForward: navigator.forward()
        default:
            guard let page = action.page else { return false }
            navigator.push(page.route)
        }
        return true
    }

    /// New-issue defaults from the page being viewed (project page → that
    /// project, issue page → nothing, like upstream).
    func contextualDraft() -> CreateIssueDraft {
        var d = issueDraft ?? CreateIssueDraft()
        if case .project(let id) = navigator.route, d.projectID == nil { d.projectID = id }
        return d
    }

    func bootstrap() async {
        keyMonitor.store = shortcuts
        keyMonitor.perform = { [weak self] action in self?.perform(action) ?? false }
        keyMonitor.start()
        keyMonitor.startSwipes()
        notifications.onOpen = { [weak self] slug, itemID, issueKey in
            Task { await self?.openInboxItem(slug: slug, itemID: itemID, issueKey: issueKey) }
        }
        notifications.activate()
        await app.bootstrap()
        sessionDidChange()
        if app.user != nil { await loadAccountExtras() }
        startDaemonMonitoring()
        await autoStartIfNeeded()
    }

    /// `multica://` links: auth callback, or a workspace path such as
    /// `multica://open/acme/issues/<id>` opened in a tab.
    func handleOpenURL(_ url: URL) async {
        if url.host == "auth" {
            await app.handleDeepLink(url)
            return
        }
        if url.host == "invite", let id = url.pathComponents.dropFirst().first {
            OnboardingLinkRouter.shared.invitationID = id
            return
        }
        let path = url.host == "open" ? url.path : "/" + (url.host ?? "") + url.path
        guard let (slug, route) = AppRoute.parse(path: path) else { return }
        if app.session != nil, !app.workspaces.contains(where: { $0.slug == slug }) {
            OnboardingLinkRouter.shared.noAccessSlug = slug
            return
        }
        if app.session?.workspace.slug != slug, let ws = app.workspaces.first(where: { $0.slug == slug }) {
            await switchWorkspace(ws)
        }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        tabs.openTab(TabLocation(route, query: query))
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
