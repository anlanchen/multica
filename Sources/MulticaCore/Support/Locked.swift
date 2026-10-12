import Foundation

/// Minimal lock-protected box. Used for state that hot paths read
/// synchronously off the main actor (e.g. the WebSocket router asking "is
/// anyone showing this task?") where an actor hop per frame would cost more
/// than the work being guarded.
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value {
        withLock { $0 }
    }
}
