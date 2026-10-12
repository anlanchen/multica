import Foundation

/// Fixed-window batcher with a leading edge.
///
/// The first element after an idle period is released immediately (that is
/// the latency the user sees). It opens a window; elements arriving inside
/// the window are held and released together when it closes, and a window
/// that released something opens the next one. The window is never extended
/// by new arrivals, so a continuous stream still flushes on schedule instead
/// of being starved like a resetting debounce would be.
///
/// Pure state machine: the caller supplies time, which keeps it testable and
/// lets the realtime actor drive it with a single sleeping task.
public struct FixedWindowBatcher<Element> {
    public let window: Duration
    private var pending: [Element] = []
    private var windowEnd: ContinuousClock.Instant?

    public init(window: Duration) {
        self.window = window
    }

    public enum Offer {
        /// Deliver this batch now (leading edge).
        case flushNow([Element])
        /// Held; a flush is already scheduled for `deadline`.
        case held(deadline: ContinuousClock.Instant)
    }

    public mutating func offer(_ element: Element, now: ContinuousClock.Instant) -> Offer {
        if let end = windowEnd, now < end {
            pending.append(element)
            return .held(deadline: end)
        }
        windowEnd = now.advanced(by: window)
        return .flushNow([element])
    }

    /// Called when the window deadline passes. Returns the batch to deliver
    /// (possibly empty) and the next deadline, if a new window opened.
    public mutating func windowElapsed(now: ContinuousClock.Instant) -> (batch: [Element], nextDeadline: ContinuousClock.Instant?) {
        guard let end = windowEnd, now >= end else {
            return ([], windowEnd)
        }
        if pending.isEmpty {
            windowEnd = nil
            return ([], nil)
        }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        windowEnd = now.advanced(by: window)
        return (batch, windowEnd)
    }

    public var hasPending: Bool { !pending.isEmpty }
}

/// Exponential reconnect backoff with ±20% jitter so clients that dropped
/// together do not reconnect in lockstep (same parameters as the web client).
public struct Backoff: Sendable {
    public var base: TimeInterval = 1
    public var cap: TimeInterval = 30
    public var jitter: Double = 0.2
    public private(set) var attempt = 0

    public init(base: TimeInterval = 1, cap: TimeInterval = 30, jitter: Double = 0.2) {
        self.base = base
        self.cap = cap
        self.jitter = jitter
    }

    public mutating func nextDelay(random: Double = Double.random(in: -1...1)) -> TimeInterval {
        let raw = min(base * pow(2, Double(attempt)), cap)
        attempt += 1
        return max(0, min(raw + raw * jitter * random, cap))
    }

    public mutating func reset() { attempt = 0 }
}
