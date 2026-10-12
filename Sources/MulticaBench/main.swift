import Foundation
import MulticaCore

// Micro-benchmarks for the hot paths the upstream Electron client struggled
// with. Run in release mode:
//
//     swift run -c release multica-bench
//
// Each scenario prints the "upstream-style" strategy next to the strategy this
// client uses, measured in the same process on the same data.

let clock = ContinuousClock()

func measure(_ iterations: Int = 1, _ body: () -> Void) -> Duration {
    body() // warm-up
    var best = Duration.seconds(1_000)
    for _ in 0..<max(1, iterations) {
        let t = clock.measure(body)
        if t < best { best = t }
    }
    return best
}

func ms(_ d: Duration) -> String {
    let v = Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15
    return v < 1 ? String(format: "%.3f ms", v) : String(format: "%.1f ms", v)
}

func us(_ d: Duration, per n: Int) -> String {
    let v = (Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12) / Double(n)
    return String(format: "%.2f µs", v)
}

var report: [String] = []
@MainActor func row(_ cells: String...) { report.append("| " + cells.joined(separator: " | ") + " |") }

/// `--dump <dir>` writes each scenario's input so scripts/perf/js-bench.mjs
/// can run upstream's JavaScript on byte-identical data.
let dumpDir: URL? = {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--dump"), i + 1 < a.count else { return nil }
    let url = URL(fileURLWithPath: a[i + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

func dump(_ name: String, _ lines: [String]) {
    guard let dumpDir else { return }
    try! lines.joined(separator: "\n").write(to: dumpDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

// MARK: - Fixture

func jsonString(_ s: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]), as: UTF8.self)
}

/// A realistic agent stream in the exact wire shape the Go server emits:
/// envelope keys sorted (it marshals a map), payload fields in struct order.
/// Tool inputs carry file bodies, which is what made upstream frames costly.
func makeFrames(task: String, issue: String, count: Int) -> [String] {
    let fileBody = jsonString(String(repeating: "let value = compute(input) // some source line\n", count: 80)) // ~3.7 KB
    let output = jsonString(String(repeating: "PASS Tests/SomeTest.swift line output\n", count: 50))           // ~1.9 KB
    let text = jsonString("I'll update the handler and add a regression test for the edge case. token=sk-ant-abcdefghijklmnopqrstuvwxyz")
    let thinking = jsonString("Considering whether the cache key needs the workspace id as well…")
    var frames: [String] = []
    frames.reserveCapacity(count)
    var seq = 0
    while frames.count < count {
        seq += 1
        let ids = #""task_id":"\#(task)","issue_id":"\#(issue)","seq":\#(seq)"#
        let payload: String
        switch seq % 4 {
        case 0: payload = #"{\#(ids),"type":"text","content":\#(text)}"#
        case 1: payload = #"{"call_id":"c\#(seq)",\#(ids),"type":"tool_use","tool":"Write","input":{"content":\#(fileBody),"file_path":"/repo/Sources/F\#(seq).swift"}}"#
        case 2: payload = #"{"call_id":"c\#(seq - 1)",\#(ids),"type":"tool_result","tool":"Write","output":\#(output)}"#
        default: payload = #"{\#(ids),"type":"thinking","content":\#(thinking)}"#
        }
        frames.append(#"{"actor_id":"","actor_type":"system","payload":\#(payload),"type":"task:message"}"#)
    }
    return frames
}

// MARK: 1. WebSocket fan-out

do {
    let runs = 20
    let perRun = 500
    var frames: [Data] = []
    for r in 0..<runs {
        frames += makeFrames(task: "task-\(r)", issue: "issue-\(r)", count: perRun).map { Data($0.utf8) }
    }
    frames.shuffle()
    let bytes = frames.reduce(0) { $0 + $1.count }
    dump("fanout.jsonl", frames.map { String(decoding: $0, as: UTF8.self) })

    struct Envelope: Decodable { var type: String; var payload: TaskMessage }
    let decoder = JSONDecoder()
    var kept = 0
    let full = measure(3) {
        kept = 0
        for f in frames where (try? decoder.decode(Envelope.self, from: f)) != nil { kept += 1 }
    }

    func routed(fastPath: Bool) -> (Duration, Int) {
        let interest = InterestRegistry()
        interest.retainTask("task-0") // the one run on screen
        let router = FrameRouter(interest: interest, fastPath: fastPath)
        var n = 0
        let t = measure(3) {
            n = 0
            for f in frames { if case .taskMessage = router.decode(f) { n += 1 } }
        }
        return (t, n)
    }
    let (decoderOnly, decoderKept) = routed(fastPath: false)
    let (fast, fastKept) = routed(fastPath: true)
    let routingInterest = InterestRegistry()
    routingInterest.retainTask("task-0")
    var wanted = 0
    let decision = measure(5) {
        wanted = 0
        for f in frames {
            if let k = FastRouting.taskMessageKeys(f), routingInterest.wants(taskID: k.taskID, issueID: k.issueID) { wanted += 1 }
        }
    }

    report.append("### 1. `task:message` fan-out — \(frames.count) frames from \(runs) concurrent runs, \(bytes / 1024) KiB, 1 run on screen")
    report.append("")
    row("Strategy", "Total", "Per frame", "Messages kept")
    row("---", "---", "---", "---")
    row("Decode every frame (upstream before MUL-6396)", ms(full), us(full, per: frames.count), "\(kept)")
    row("Decode routing keys, skip body (single-pass decoder)", ms(decoderOnly), us(decoderOnly, per: frames.count), "\(decoderKept)")
    row("Byte-level prefix scan + decoder fallback (this client)", ms(fast), us(fast, per: frames.count), "\(fastKept)")
    row("… of which the keep/drop decision (byte scan only)", ms(decision), us(decision, per: frames.count), "\(wanted)")
    report.append("")
}

// MARK: 2. Live transcript flushes

do {
    let total = 3000
    let flushSize = 10
    let rawFrames = makeFrames(task: "t", issue: "i", count: total)
    dump("transcript.jsonl", rawFrames)
    let messages: [TaskMessage] = rawFrames.map {
        struct Envelope: Decodable { var payload: TaskMessage }
        return try! JSONDecoder().decode(Envelope.self, from: Data($0.utf8)).payload
    }
    let redactor = Redactor()
    let checkpoints = [500, 1000, 3000]

    func body(_ step: TranscriptStep) -> String {
        step.kind == .tool ? (step.output ?? "") + (step.input?.preview(limit: 8000) ?? "") : step.text
    }

    // Upstream before MUL-7227: every flush rebuilt the timeline and redacted
    // every message body of the run. Measured as one flush at each size.
    var naiveStructure: [Int: Duration] = [:]
    var naiveFull: [Int: Duration] = [:]
    for n in checkpoints {
        let prefix = Array(messages.prefix(n))
        naiveStructure[n] = measure(3) { precondition(!TranscriptBuffer(messages: prefix).steps.isEmpty) }
        naiveFull[n] = measure(2) {
            var chars = 0
            for step in TranscriptBuffer(messages: prefix).steps { chars += redactor.redact(body(step)).count }
            precondition(chars > 0)
        }
    }

    // This client: each kept message is redacted once when it enters the
    // client (on the realtime actor, off the main thread); the main thread
    // only merges the batch and clips the visible rows. Streamed for real;
    // per-flush cost is averaged over the 10 flushes ending at each size.
    var mainThread: [Duration] = []
    var offMain: [Duration] = []
    do {
        var buffer = TranscriptBuffer()
        var clipCache: [Int: (Int, String)] = [:]
        var i = 0
        while i < messages.count {
            let raw = Array(messages[i..<min(i + flushSize, messages.count)])
            let r0 = clock.now
            let batch = raw.map(redactor.redacted)
            let r1 = clock.now
            buffer.merge(batch)
            for step in buffer.steps.suffix(30) where clipCache[step.id]?.0 != step.revision {
                let text = step.kind == .tool ? (step.output ?? "") : step.text
                clipCache[step.id] = (step.revision, String(text.prefix(4000)))
            }
            let r2 = clock.now
            offMain.append(r1 - r0)
            mainThread.append(r2 - r1)
            i += flushSize
        }
    }
    func avg(_ a: [Duration], endingAt n: Int) -> Duration {
        let end = n / flushSize
        let slice = a[max(0, end - 10)..<end]
        return slice.reduce(.zero, +) / slice.count
    }

    report.append("### 2. Live transcript — cost of one flush (\(flushSize) new messages) by transcript length")
    report.append("")
    row("Strategy", "@500 msgs", "@1000 msgs", "@3000 msgs")
    row("---", "---", "---", "---")
    row("Rebuild steps + redact every body (upstream before MUL-7227)", ms(naiveFull[500]!), ms(naiveFull[1000]!), ms(naiveFull[3000]!))
    row("Rebuild steps only (upstream after #8242)", ms(naiveStructure[500]!), ms(naiveStructure[1000]!), ms(naiveStructure[3000]!))
    row("This client, main thread: incremental merge + clip visible rows", ms(avg(mainThread, endingAt: 500)), ms(avg(mainThread, endingAt: 1000)), ms(avg(mainThread, endingAt: 3000)))
    row("This client, realtime actor: redact the \(flushSize) new messages", ms(avg(offMain, endingAt: 500)), ms(avg(offMain, endingAt: 1000)), ms(avg(offMain, endingAt: 3000)))
    report.append("")
}

// MARK: 3. Issue list under realtime updates

await MainActor.run {
    let store = IssueStore()
    let n = 5000
    var issues: [Issue] = []
    let statuses: [IssueStatusKey] = [.backlog, .todo, .inProgress, .inReview, .done]
    for k in 0..<n {
        var i = Issue(id: "i\(k)", number: k, identifier: "MUL-\(k)", title: "Issue \(k)",
                      status: statuses[k % statuses.count], priority: .medium, position: Double(k), revision: 1)
        i.updatedAt = "2026-09-01T00:00:00Z"
        issues.append(i)
    }
    let load = clock.measure {
        store.merge(page: issues, total: n, replacing: true)
        store.resectionIfNeeded()
    }

    let before = store.resectionCount
    let fieldEdits = clock.measure {
        for k in 0..<1000 {
            var i = issues[k]
            i.priority = .urgent
            i.revision = 2
            store.upsert(i)
        }
        store.resectionIfNeeded()
    }
    let fieldResections = store.resectionCount - before

    let before2 = store.resectionCount
    let statusMoves = clock.measure {
        for k in 0..<1000 {
            var i = issues[k]
            i.status = .done
            i.revision = 3
            store.upsert(i)
        }
        store.resectionIfNeeded()
    }
    let moveResections = store.resectionCount - before2

    let lifecycle = clock.measure {
        for k in 0..<1000 {
            store.applyTaskLifecycle(TaskLifecycle(taskID: "t\(k)", agentID: "a", issueID: "i\(k)", status: .running))
        }
    }

    report.append("### 3. Issue store — \(n) issues")
    report.append("")
    row("Operation", "Time", "List re-sections")
    row("---", "---", "---")
    row("Initial load + sectioning", ms(load), "1")
    row("1000 `issue:updated` field edits (row-level invalidation)", ms(fieldEdits), "\(fieldResections)")
    row("1000 status moves in one burst (coalesced)", ms(statusMoves), "\(moveResections)")
    row("1000 task lifecycle events (per-row activity)", ms(lifecycle), "0")
    report.append("")
}

// MARK: 4. Timestamps

do {
    let stamps = (0..<100_000).map { k in String(format: "2026-09-%02dT%02d:%02d:%02d.%03dZ", 1 + k % 28, k % 24, k % 60, (k / 7) % 60, k % 1000) }
    dump("timestamps.txt", stamps)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var a = 0.0, b = 0.0
    let foundation = measure(3) { a = 0; for s in stamps { a += iso.date(from: s)?.timeIntervalSince1970 ?? 0 } }
    let fast = measure(3) { b = 0; for s in stamps { b += Timestamp.parse(s)?.timeIntervalSince1970 ?? 0 } }
    precondition(abs(a - b) < 1e-3 * Double(stamps.count), "parsers disagree")

    report.append("### 4. RFC 3339 parsing — \(stamps.count) timestamps")
    report.append("")
    row("Parser", "Total", "Per value")
    row("---", "---", "---")
    row("ISO8601DateFormatter", ms(foundation), us(foundation, per: stamps.count))
    row("Timestamp.parse (this client)", ms(fast), us(fast, per: stamps.count))
    report.append("")
}

// MARK: 5. Markdown

do {
    func doc(_ k: Int) -> String {
        """
        ## Plan for MUL-\(k)

        I looked at the failing test in `Sources/App/Handler\(k).swift` and the root cause is the cache key. See https://github.com/acme/repo/pull/\(k) and MUL-\(k + 1).

        - [x] Reproduce locally with **debug logging**
        - [ ] Add the workspace id to the key, cc [@Ada](mention://member/u\(k))
        - Keep the _old_ path behind a flag until MUL-\(k + 2) lands

        | Step | Owner | ETA |
        | --- | --- | --- |
        | Fix | agent | today |
        | Review | Ada | tomorrow |

        ```swift
        let key = "\\(workspace.id):\\(issue.id)"
        cache[key] = value // \(k)
        ```

        > Note: the old behaviour stays available via `MULTICA_LEGACY_CACHE=1`.

        !file[trace-\(k).log](/api/attachments/123e4567-e89b-12d3-a456-4266141740\(String(format: "%02d", k % 100))/download)
        """
    }
    let docs = (0..<500).map(doc)
    dump("markdown.jsonl", docs.map(jsonString))
    var blocks = 0
    let parse = measure(5) {
        blocks = 0
        for d in docs { blocks += MarkdownBlocks.parse(MarkdownPreprocess.apply(d)).count }
    }
    #if canImport(Darwin)
    var runs = 0
    let inline = measure(3) {
        runs = 0
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        for d in docs {
            for b in MarkdownBlocks.parse(MarkdownPreprocess.apply(d)) {
                var texts: [String] = []
                switch b {
                case .paragraph(let t), .heading(_, let t), .quote(let t): texts = [t]
                case .list(_, _, let items): texts = items.map(\.text)
                case .table(let h, let r): texts = h + r.flatMap { $0 }
                default: break
                }
                for t in texts { runs += ((try? AttributedString(markdown: t, options: options)).map { $0.runs.count } ?? 0) }
            }
        }
    }
    #endif

    report.append("### 5. Markdown — \(docs.count) comments (\(docs.reduce(0) { $0 + $1.utf8.count } / 1024) KiB), preprocess + parse to a render tree")
    report.append("")
    row("Pipeline", "Total", "Per comment")
    row("---", "---", "---")
    row("Preprocess + block parse (this client)", ms(parse), us(parse, per: docs.count))
    #if canImport(Darwin)
    row("… + inline AttributedString for every block (this client, uncached)", ms(inline), us(inline, per: docs.count))
    #endif
    report.append("")
    precondition(blocks > 0)
}

#if os(Linux)
let platform = "Linux x86_64"
#else
let platform = "macOS"
#endif
print("## multica-bench (\(platform), \(ProcessInfo.processInfo.activeProcessorCount) cores)\n")
print(report.joined(separator: "\n"))
