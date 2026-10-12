import Foundation
import Observation

/// Top-level app state: authentication, workspace selection, and the active
/// workspace session.
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable {
        case launching
        case signedOut
        case signedIn
    }

    public private(set) var phase: Phase = .launching
    public private(set) var user: User?
    public private(set) var workspaces: [Workspace] = []
    public private(set) var session: WorkspaceSession?
    public var authError: String?

    @ObservationIgnored public let config: ServerConfig
    @ObservationIgnored public let api: APIClient
    @ObservationIgnored private let tokenStore: TokenStore
    @ObservationIgnored private let connector: WebSocketConnector
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let identity: ClientIdentity

    static let lastWorkspaceKey = "multica.lastWorkspaceSlug"

    public init(
        config: ServerConfig,
        tokenStore: TokenStore,
        identity: ClientIdentity = ClientIdentity(),
        transport: HTTPTransport = URLSessionTransport(),
        connector: WebSocketConnector = URLSessionWebSocketConnector(),
        defaults: UserDefaults = .standard
    ) {
        self.config = config
        self.tokenStore = tokenStore
        self.identity = identity
        self.connector = connector
        self.defaults = defaults
        self.api = APIClient(config: config, identity: identity, transport: transport, token: tokenStore.load())
    }

    // MARK: Bootstrap

    public func bootstrap() async {
        await api.setUnauthorizedHandler { [weak self] in
            Task { @MainActor in await self?.signOut(serverRejected: true) }
        }
        guard tokenStore.load() != nil else {
            phase = .signedOut
            return
        }
        await loadAccount()
    }

    private func loadAccount() async {
        let api = self.api
        let me = Task { try await api.me() }
        let list = Task { try await api.workspaces() }
        do {
            user = try await me.value
            workspaces = try await list.value
            phase = .signedIn
            let preferred = defaults.string(forKey: Self.lastWorkspaceKey)
            if let ws = workspaces.first(where: { $0.slug == preferred }) ?? workspaces.first {
                await select(ws)
            }
        } catch let e as APIError where e.isUnauthorized {
            await signOut(serverRejected: true)
        } catch {
            authError = (error as? APIError)?.message ?? error.localizedDescription
            phase = .signedOut
        }
    }

    // MARK: Sign in

    public func sendCode(email: String) async -> Bool {
        do {
            try await api.sendCode(email: email)
            authError = nil
            return true
        } catch {
            authError = (error as? APIError)?.message ?? error.localizedDescription
            return false
        }
    }

    public func verify(email: String, code: String) async {
        do {
            let r = try await api.verifyCode(email: email, code: code)
            try await adopt(token: r.token)
        } catch {
            authError = (error as? APIError)?.message ?? error.localizedDescription
        }
    }

    /// Token delivered by the browser sign-in deep link
    /// (`multica://auth/callback?token=...`).
    public func adopt(token: String) async throws {
        try tokenStore.save(token)
        await api.setToken(token)
        authError = nil
        await loadAccount()
    }

    public func handleDeepLink(_ url: URL) async {
        guard url.scheme == "multica" else { return }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if url.host == "auth", let token = parts?.queryItems?.first(where: { $0.name == "token" })?.value, !token.isEmpty {
            try? await adopt(token: token)
        }
    }

    public var browserSignInURL: URL {
        var c = URLComponents(url: config.appURL.appendingPathComponent("login"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "platform", value: "desktop")]
        return c.url!
    }

    // MARK: Workspace

    public func select(_ workspace: Workspace) async {
        guard session?.workspace.id != workspace.id, let user else { return }
        if let old = session { await old.stop() }
        defaults.set(workspace.slug, forKey: Self.lastWorkspaceKey)
        let api = self.api
        let realtime = RealtimeClient(config: config, identity: identity, connector: connector) {
            await api.currentToken()
        }
        let s = WorkspaceSession(workspace: workspace, user: user, api: api, realtime: realtime)
        session = s
        await s.start()
    }

    /// Refetches the workspace list (after create/rename/delete/leave or an
    /// accepted invitation). Leaves the current workspace if it is gone.
    public func reloadWorkspaces(select slug: String? = nil) async {
        guard let list = try? await api.workspaces() else { return }
        workspaces = list
        if let slug, let ws = list.first(where: { $0.slug == slug }) {
            await select(ws)
        } else if let current = session?.workspace, !list.contains(where: { $0.id == current.id }) {
            await session?.stop()
            session = nil
            if let first = list.first { await select(first) }
        } else if session == nil, let first = list.first {
            await select(first)
        }
    }

    /// Replaces the signed-in user after a profile edit.
    public func setUser(_ updated: User) {
        user = updated
    }

    /// Updates a workspace in the list after a settings change.
    public func replaceWorkspace(_ ws: Workspace) {
        if let i = workspaces.firstIndex(where: { $0.id == ws.id }) { workspaces[i] = ws }
    }

    public func signOut(serverRejected: Bool = false) async {
        if let s = session { await s.stop() }
        session = nil
        if !serverRejected {
            try? await api.sendIgnoringResponse(.post, "/auth/logout")
        }
        tokenStore.clear()
        await api.setToken(nil)
        user = nil
        workspaces = []
        phase = .signedOut
        if serverRejected { authError = "Your session expired. Sign in again." }
    }
}
