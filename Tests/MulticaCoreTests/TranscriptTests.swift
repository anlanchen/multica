import XCTest
@testable import MulticaCore

final class TranscriptBufferTests: XCTestCase {
    func msg(_ seq: Int, _ kind: TaskMessageKind = .text, tool: String? = nil, call: String? = nil, content: String? = nil, output: String? = nil) -> TaskMessage {
        TaskMessage(taskID: "t", seq: seq, kind: kind, tool: tool, content: content ?? "m\(seq)", output: output, callID: call)
    }

    func testAppendIsIncrementalAndPairsToolCalls() {
        var b = TranscriptBuffer()
        b.merge([msg(1), msg(2, .toolUse, tool: "Read", call: "c1")])
        b.merge([msg(3, .thinking), msg(4, .toolResult, tool: "Read", call: "c1", output: "file body")])
        XCTAssertEqual(b.steps.map(\.id), [1, 2, 3])
        XCTAssertEqual(b.steps[1].output, "file body")
        XCTAssertTrue(b.steps[1].hasResult)
        XCTAssertEqual(b.steps[1].revision, 4)
        XCTAssertEqual(b.rebuildCount, 0, "in-order arrivals must not rebuild")
    }

    func testPairsByToolNameWithoutCallID() {
        var b = TranscriptBuffer()
        b.merge([msg(1, .toolUse, tool: "Bash"), msg(2, .toolResult, tool: "Bash", output: "ok")])
        XCTAssertEqual(b.steps.count, 1)
        XCTAssertEqual(b.steps[0].output, "ok")
    }

    func testOutOfOrderAndDuplicatesConverge() {
        var b = TranscriptBuffer()
        b.merge([msg(1), msg(3), msg(4)])
        b.merge([msg(2)])                 // backfill fills a gap
        b.merge([msg(3), msg(4)])         // duplicates from REST
        XCTAssertEqual(b.messages.map(\.seq), [1, 2, 3, 4])
        XCTAssertEqual(b.steps.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(b.rebuildCount, 1)
    }

    func testStepIdentityIsStableAcrossFlushes() {
        var b = TranscriptBuffer()
        b.merge([msg(10, .toolUse, tool: "Edit", call: "x")])
        let id = b.steps[0].id
        b.merge([msg(11, .toolResult, tool: "Edit", call: "x", output: "done")])
        XCTAssertEqual(b.steps[0].id, id)
    }

    /// Any split of a message stream into batches, in any arrival order,
    /// yields the same steps as building from the sorted whole.
    func testIncrementalEqualsFullRebuild() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            var all: [TaskMessage] = []
            var openCalls: [String] = []
            for seq in 1...120 {
                switch Int.random(in: 0..<4, using: &rng) {
                case 0:
                    let c = "c\(seq)"
                    openCalls.append(c)
                    all.append(msg(seq, .toolUse, tool: "T", call: c))
                case 1 where !openCalls.isEmpty:
                    all.append(msg(seq, .toolResult, tool: "T", call: openCalls.removeFirst(), output: "o\(seq)"))
                case 2:
                    all.append(msg(seq, .thinking))
                default:
                    all.append(msg(seq))
                }
            }
            let reference = TranscriptBuffer(messages: all)

            var shuffled = all
            // Mostly in order with some late arrivals, like live frames + backfill.
            for i in shuffled.indices where Int.random(in: 0..<10, using: &rng) == 0 {
                shuffled.swapAt(i, Int.random(in: max(0, i - 5)...i, using: &rng))
            }
            var incremental = TranscriptBuffer()
            var i = 0
            while i < shuffled.count {
                let n = Int.random(in: 1...8, using: &rng)
                incremental.merge(Array(shuffled[i..<min(i + n, shuffled.count)]))
                i += n
            }
            incremental.merge(Array(all.suffix(10))) // duplicate replay
            XCTAssertEqual(incremental.steps, reference.steps)
        }
    }
}

final class RedactorTests: XCTestCase {
    let r = Redactor()

    func testMasksCommonCredentials() {
        let input = """
        export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx
        token ghp_abcdefghijklmnopqrstuvwxyz0123456789
        curl -H "Authorization: Bearer abcdefghijklmnop.qrstuv"
        password: hunter2hunter2
        https://user:s3cretpass@github.com/x.git
        aws AKIAABCDEFGHIJKLMNOP
        """
        let out = r.redact(input)
        for secret in ["sk-proj-abcdefghijklmnopqrstuvwx", "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
                       "abcdefghijklmnop.qrstuv", "hunter2hunter2", "s3cretpass", "AKIAABCDEFGHIJKLMNOP"] {
            XCTAssertFalse(out.contains(secret), "leaked \(secret) in \(out)")
        }
        XCTAssertTrue(out.contains("Bearer [REDACTED]"))
        XCTAssertTrue(out.contains("https://user:[REDACTED]@github.com"))
        XCTAssertTrue(out.contains("password: [REDACTED]"))
    }

    func testRedactsBeforeClipping() {
        // The secret straddles the clip boundary; clipping first would leave
        // a prefix the pattern no longer recognises.
        let body = String(repeating: "a", count: 95) + " sk-ant-abcdefghijklmnopqrstuvwxyz"
        let (text, clipped) = r.displayText(body, limit: 110)
        XCTAssertTrue(clipped || text.count <= 110)
        XCTAssertFalse(text.contains("sk-ant-abcdef"))
    }

    func testLeavesOrdinaryTextAlone() {
        let s = "Refactored the skeleton key handler; see tokenizer.swift"
        XCTAssertEqual(r.redact(s), s)
    }
}
