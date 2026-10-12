import Foundation

/// Where the app talks to. Mirrors the desktop runtime config: an API base
/// URL, the web app URL (for browser sign-in), and a WebSocket URL derived
/// from the API URL unless overridden.
public struct ServerConfig: Sendable, Hashable, Codable {
    public var apiURL: URL
    public var appURL: URL
    public var wsURL: URL

    public init(apiURL: URL, appURL: URL, wsURL: URL? = nil) {
        self.apiURL = apiURL
        self.appURL = appURL
        self.wsURL = wsURL ?? ServerConfig.deriveWebSocketURL(from: apiURL)
    }

    public static let production = ServerConfig(
        apiURL: URL(string: "https://api.multica.ai")!,
        appURL: URL(string: "https://multica.ai")!
    )

    public static let localDevelopment = ServerConfig(
        apiURL: URL(string: "http://localhost:8080")!,
        appURL: URL(string: "http://localhost:3000")!
    )

    /// `https://host/base` → `wss://host/base/ws`.
    public static func deriveWebSocketURL(from api: URL) -> URL {
        var c = URLComponents(url: api, resolvingAgainstBaseURL: false)!
        c.scheme = (c.scheme == "http") ? "ws" : "wss"
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        c.path = path + "/ws"
        c.query = nil
        return c.url!
    }
}

/// Identifies this client to the server, sent as `X-Client-*` headers and
/// as query parameters on the WebSocket upgrade.
public struct ClientIdentity: Sendable, Hashable {
    public var platform: String
    public var version: String
    public var os: String

    public init(platform: String = "macos-native", version: String = MulticaCoreVersion.string, os: String = "macos") {
        self.platform = platform
        self.version = version
        self.os = os
    }
}

public enum MulticaCoreVersion {
    public static let string = "0.1.0"
}
