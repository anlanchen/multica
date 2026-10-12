import Foundation

/// Persists the session token. The macOS app uses the Keychain; the file
/// store exists for tests, the benchmark harness, and non-Darwin builds.
public protocol TokenStore: Sendable {
    func load() -> String?
    func save(_ token: String) throws
    func clear()
}

public final class InMemoryTokenStore: TokenStore {
    private let value = Locked<String?>(nil)

    public init(_ token: String? = nil) {
        value.withLock { $0 = token }
    }

    public func load() -> String? { value.current }
    public func save(_ token: String) throws { value.withLock { $0 = token } }
    public func clear() { value.withLock { $0 = nil } }
}

public final class FileTokenStore: TokenStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    public func save(_ token: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
