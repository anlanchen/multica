import Foundation

/// One rendered step of an agent run: a text block, a thinking block, an
/// error, or a tool call paired with its result.
public struct TranscriptStep: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case text, thinking, tool, error
    }

    /// `seq` of the message that opened the step. Stable across merges, so
    /// SwiftUI/AppKit reuse the row instead of replacing it (the MUL-7227
    /// regression was a summary node keyed by a changing seq).
    public var id: Int
    public var kind: Kind
    public var tool: String?
    public var callID: String?
    public var text: String
    public var input: JSONValue?
    public var output: String?
    public var outputTruncated: Bool?
    public var hasResult: Bool
    /// Highest seq folded into this step; changes when a result attaches.
    public var revision: Int

    public var summary: String {
        switch kind {
        case .tool:
            let name = tool ?? "tool"
            if let input, let hint = TranscriptStep.inputHint(input) { return "\(name) \(hint)" }
            return name
        case .text, .thinking, .error:
            return text
        }
    }

    /// The most informative short field of a tool input (file path, command,
    /// pattern, url), so a row can label itself without stringifying the
    /// whole input.
    static func inputHint(_ input: JSONValue) -> String? {
        for key in ["file_path", "path", "command", "pattern", "url", "query", "description"] {
            if let v = input[key]?.stringValue, !v.isEmpty {
                return v.count > 120 ? String(v.prefix(120)) + "…" : v
            }
        }
        return nil
    }
}

/// Transcript of one task, maintained incrementally.
///
/// Messages are kept sorted and unique by `seq`. The common case — new
/// messages with increasing `seq` — appends to the message array and touches
/// only the tail of `steps`, so a flush costs O(batch) regardless of how long
/// the run already is. Out-of-order or duplicate-with-changes arrivals (a REST
/// backfill racing live frames) fall back to one O(n) rebuild.
public struct TranscriptBuffer: Sendable {
    public private(set) var messages: [TaskMessage] = []
    public private(set) var steps: [TranscriptStep] = []
    /// Incremented on every change that alters `steps`.
    public private(set) var version = 0
    /// Number of full rebuilds performed (diagnostics / tests).
    public private(set) var rebuildCount = 0

    private var openByCallID: [String: Int] = [:]
    private var openByTool: [String: Int] = [:]

    public init() {}

    public init(messages: [TaskMessage]) {
        merge(messages)
    }

    public var lastSeq: Int? { messages.last?.seq }
    public var isEmpty: Bool { messages.isEmpty }

    /// Merges a batch. Returns true when steps changed.
    @discardableResult
    public mutating func merge(_ batch: [TaskMessage]) -> Bool {
        guard !batch.isEmpty else { return false }
        let ordered = batch.count > 1 && !Self.isSorted(batch) ? batch.sorted { $0.seq < $1.seq } : batch
        var needsRebuild = false
        var changed = false

        for m in ordered {
            if let last = messages.last, m.seq <= last.seq {
                let idx = Self.lowerBound(messages, m.seq)
                if idx < messages.count, messages[idx].seq == m.seq {
                    if messages[idx] != m {
                        messages[idx] = m
                        needsRebuild = true
                        changed = true
                    }
                } else {
                    messages.insert(m, at: idx)
                    needsRebuild = true
                    changed = true
                }
            } else {
                messages.append(m)
                changed = true
                if !needsRebuild { appendStep(for: m) }
            }
        }
        if needsRebuild { rebuildSteps() }
        if changed { version &+= 1 }
        return changed
    }

    /// Clears and re-renders from scratch.
    public mutating func rebuildSteps() {
        steps.removeAll(keepingCapacity: true)
        openByCallID.removeAll(keepingCapacity: true)
        openByTool.removeAll(keepingCapacity: true)
        for m in messages { appendStep(for: m) }
        rebuildCount += 1
    }

    private mutating func appendStep(for m: TaskMessage) {
        switch m.kind {
        case .toolUse:
            let step = TranscriptStep(id: m.seq, kind: .tool, tool: m.tool, callID: m.callID, text: "",
                                      input: m.input, output: nil, outputTruncated: nil, hasResult: false, revision: m.seq)
            steps.append(step)
            let index = steps.count - 1
            if let call = m.callID, !call.isEmpty {
                openByCallID[call] = index
            } else if let tool = m.tool {
                openByTool[tool] = index
            }

        case .toolResult:
            var target: Int?
            if let call = m.callID, !call.isEmpty, let i = openByCallID.removeValue(forKey: call) {
                target = i
            } else if let tool = m.tool, let i = openByTool.removeValue(forKey: tool) {
                target = i
            } else if let i = steps.lastIndex(where: { $0.kind == .tool && !$0.hasResult }) {
                target = i
            }
            if let i = target {
                steps[i].output = m.output ?? m.content
                steps[i].outputTruncated = m.outputTruncated
                steps[i].hasResult = true
                steps[i].revision = m.seq
            } else {
                steps.append(TranscriptStep(id: m.seq, kind: .tool, tool: m.tool, callID: m.callID, text: "",
                                            input: nil, output: m.output ?? m.content, outputTruncated: m.outputTruncated,
                                            hasResult: true, revision: m.seq))
            }

        case .thinking:
            steps.append(TranscriptStep(id: m.seq, kind: .thinking, text: m.content ?? "", hasResult: true, revision: m.seq))
        case .error:
            steps.append(TranscriptStep(id: m.seq, kind: .error, text: m.content ?? m.output ?? "", hasResult: true, revision: m.seq))
        default:
            steps.append(TranscriptStep(id: m.seq, kind: .text, text: m.content ?? "", hasResult: true, revision: m.seq))
        }
    }

    static func isSorted(_ a: [TaskMessage]) -> Bool {
        var prev = Int.min
        for m in a {
            if m.seq < prev { return false }
            prev = m.seq
        }
        return true
    }

    static func lowerBound(_ a: [TaskMessage], _ seq: Int) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if a[mid].seq < seq { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

extension TranscriptStep {
    init(id: Int, kind: Kind, text: String, hasResult: Bool, revision: Int) {
        self.init(id: id, kind: kind, tool: nil, callID: nil, text: text, input: nil, output: nil,
                  outputTruncated: nil, hasResult: hasResult, revision: revision)
    }
}
