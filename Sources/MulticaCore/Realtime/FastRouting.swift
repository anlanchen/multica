import Foundation

/// Byte-level fast path for the dominant frame: `task:message`.
///
/// The server marshals the envelope from a Go map, so its keys are sorted —
/// `actor_id`, `actor_type`, `payload`, `type` — and the payload is a Go
/// struct that starts with `call_id`, `task_id`, `issue_id`. That makes two
/// cheap checks possible without tokenising the (often multi-kilobyte) body:
///
/// 1. The frame ends with `"type":"task:message"}`. The last key of a JSON
///    document's closing object is necessarily top-level, so this identifies
///    the event type exactly.
/// 2. Walking the payload's leading scalar keys yields `task_id`/`issue_id`.
///
/// Any deviation — different key order, escapes in an id, a nested value
/// before both ids — returns nil and the caller falls back to the full
/// decoder, so the fast path can only skip work, never change a result.
public enum FastRouting {
    private static let suffix = Array(#""type":"task:message"}"#.utf8)
    private static let payloadKey = Array("payload".utf8)
    private static let taskKey = Array("task_id".utf8)
    private static let issueKey = Array("issue_id".utf8)

    public static func taskMessageKeys(_ data: Data) -> (taskID: String, issueID: String?)? {
        data.withUnsafeBytes { raw -> (String, String?)? in
            let b = raw.bindMemory(to: UInt8.self)
            return scan(b)
        }
    }

    @inline(__always) private static func isWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 }

    private static func scan(_ b: UnsafeBufferPointer<UInt8>) -> (String, String?)? {
        var end = b.count
        while end > 0, isWS(b[end - 1]) { end -= 1 }
        guard end > suffix.count else { return nil }
        for k in 0..<suffix.count where b[end - suffix.count + k] != suffix[k] { return nil }
        var before = end - suffix.count - 1
        while before >= 0, isWS(b[before]) { before -= 1 }
        guard before >= 0, b[before] == UInt8(ascii: ",") || b[before] == UInt8(ascii: "{") else { return nil }

        var p = 0
        func skipWS() { while p < end, isWS(b[p]) { p += 1 } }
        /// Returns the [start, end) of a string's raw contents; p moves past
        /// the closing quote. `escaped` reports whether a backslash occurred.
        func readString() -> (Int, Int, escaped: Bool)? {
            guard p < end, b[p] == UInt8(ascii: "\"") else { return nil }
            p += 1
            let start = p
            var escaped = false
            while p < end {
                let c = b[p]
                if c == UInt8(ascii: "\\") { escaped = true; p += 2; continue }
                if c == UInt8(ascii: "\"") { let r = (start, p, escaped); p += 1; return r }
                p += 1
            }
            return nil
        }
        func equals(_ r: (Int, Int, escaped: Bool), _ word: [UInt8]) -> Bool {
            guard !r.escaped, r.1 - r.0 == word.count else { return false }
            for k in 0..<word.count where b[r.0 + k] != word[k] { return false }
            return true
        }
        /// Skips a scalar value. Returns false on a container.
        func skipScalar() -> Bool {
            if p < end, b[p] == UInt8(ascii: "\"") { return readString() != nil }
            if p < end, b[p] == UInt8(ascii: "{") || b[p] == UInt8(ascii: "[") { return false }
            while p < end, b[p] != UInt8(ascii: ","), b[p] != UInt8(ascii: "}") { p += 1 }
            return true
        }

        skipWS()
        guard p < end, b[p] == UInt8(ascii: "{") else { return nil }
        p += 1
        // Top level: scalars until "payload".
        while true {
            skipWS()
            guard let key = readString() else { return nil }
            skipWS()
            guard p < end, b[p] == UInt8(ascii: ":") else { return nil }
            p += 1
            skipWS()
            if equals(key, payloadKey) { break }
            guard skipScalar() else { return nil }
            skipWS()
            guard p < end, b[p] == UInt8(ascii: ",") else { return nil }
            p += 1
        }
        guard p < end, b[p] == UInt8(ascii: "{") else { return nil }
        p += 1

        var task: String?
        var issue: String?
        var reachedEnd = false
        payload: while true {
            skipWS()
            if p < end, b[p] == UInt8(ascii: "}") { reachedEnd = true; break }
            guard let key = readString() else { return nil }
            skipWS()
            guard p < end, b[p] == UInt8(ascii: ":") else { return nil }
            p += 1
            skipWS()
            let isTask = equals(key, taskKey)
            let isIssue = !isTask && equals(key, issueKey)
            if isTask || isIssue {
                guard let v = readString(), !v.escaped else { return nil }
                let s = String(decoding: UnsafeBufferPointer(rebasing: b[v.0..<v.1]), as: UTF8.self)
                if isTask { task = s } else { issue = s }
                if task != nil && issue != nil { break payload }
            } else if !skipScalar() {
                break payload // nested value: stop before paying for it
            }
            skipWS()
            if p < end, b[p] == UInt8(ascii: ",") { p += 1; continue }
            if p < end, b[p] == UInt8(ascii: "}") { reachedEnd = true; break }
            return nil
        }
        guard let task else { return nil }
        // Without issue_id we may only conclude when the payload really has
        // none; otherwise an issue-level interest could be missed.
        guard issue != nil || reachedEnd else { return nil }
        return (task, issue)
    }
}
