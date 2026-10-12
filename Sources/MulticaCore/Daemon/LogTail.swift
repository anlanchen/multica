import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Bounded line buffer fed with raw chunks of a growing log file.
public struct LogBuffer: Sendable {
    public private(set) var lines: [String] = []
    public let capacity: Int
    private var partial = ""

    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    /// Appends a chunk; returns the complete lines it produced.
    @discardableResult
    public mutating func append(_ chunk: String) -> [String] {
        guard !chunk.isEmpty else { return [] }
        var text = partial + chunk
        partial = ""
        if !text.hasSuffix("\n") {
            if let cut = text.lastIndex(of: "\n") {
                partial = String(text[text.index(after: cut)...])
                text = String(text[...cut])
            } else {
                partial = text
                return []
            }
        }
        let new = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        lines.append(contentsOf: new)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        return new
    }

    public mutating func reset() {
        lines.removeAll()
        partial = ""
    }
}

/// Follows a log file and emits new lines.
///
/// On macOS it is event-driven (a kqueue vnode source wakes it only when the
/// file is written, renamed or deleted). The Electron shell polled the file
/// with `fs.watchFile` every 500 ms for as long as the daemon panel existed.
/// Elsewhere it falls back to a 1 s poll.
public final class LogTailer: @unchecked Sendable {
    public let url: URL
    public let lines: AsyncStream<[String]>
    private let continuation: AsyncStream<[String]>.Continuation
    private let queue = DispatchQueue(label: "multica.logtail", qos: .utility)
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var source: DispatchSourceProtocol?
    private var stopped = false

    public init(url: URL) {
        self.url = url
        (lines, continuation) = AsyncStream.makeStream(of: [String].self, bufferingPolicy: .bufferingNewest(64))
    }

    /// Starts following. `backlogBytes` of existing content are emitted first.
    public func start(backlogBytes: UInt64 = 64 * 1024) {
        queue.async { [self] in
            stopped = false
            open(backlogBytes: backlogBytes)
        }
    }

    public func stop() {
        queue.async { [self] in
            stopped = true
            source?.cancel()
            source = nil
            try? handle?.close()
            handle = nil
        }
    }

    deinit {
        continuation.finish()
    }

    private var buffer = LogBuffer(capacity: 2000)

    private func open(backlogBytes: UInt64) {
        guard !stopped else { return }
        guard let h = try? FileHandle(forReadingFrom: url) else {
            // The daemon has not created its log yet; retry shortly.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.open(backlogBytes: backlogBytes) }
            return
        }
        handle = h
        let size = (try? h.seekToEnd()) ?? 0
        offset = size > backlogBytes ? size - backlogBytes : 0
        readAvailable()
        watch()
    }

    private func readAvailable() {
        guard let h = handle else { return }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0 } // truncated or rotated in place
        guard size > offset else { return }
        try? h.seek(toOffset: offset)
        let data = h.readData(ofLength: Int(min(size - offset, 4 * 1024 * 1024)))
        offset += UInt64(data.count)
        let new = buffer.append(String(decoding: data, as: UTF8.self))
        if !new.isEmpty { continuation.yield(new) }
    }

    private func watch() {
        #if canImport(Darwin)
        guard let h = handle else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: h.fileDescriptor, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, let s = self.source as? DispatchSourceFileSystemObject else { return }
            if s.data.contains(.delete) || s.data.contains(.rename) {
                // Log rotated: reopen the new file from the start.
                s.cancel()
                self.source = nil
                try? self.handle?.close()
                self.handle = nil
                self.queue.asyncAfter(deadline: .now() + 0.5) { self.open(backlogBytes: 0) }
            } else {
                self.readAvailable()
            }
        }
        source = src
        src.resume()
        #else
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.readAvailable() }
        source = timer
        timer.resume()
        #endif
    }
}
