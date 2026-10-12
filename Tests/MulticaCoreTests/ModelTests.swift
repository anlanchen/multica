import XCTest
@testable import MulticaCore

final class TimestampTests: XCTestCase {
    func testParsesUTCAndFractions() {
        XCTAssertEqual(Timestamp.parse("1970-01-01T00:00:00Z")?.timeIntervalSince1970, 0)
        XCTAssertEqual(Timestamp.parse("2026-09-01T12:30:15Z")?.timeIntervalSince1970, 1_788_265_815)
        let frac = Timestamp.parse("2026-09-01T12:30:15.250Z")!.timeIntervalSince1970
        XCTAssertEqual(frac, 1_788_265_815.25, accuracy: 1e-6)
    }

    func testParsesOffsets() {
        let a = Timestamp.parse("2026-09-01T20:30:15+08:00")
        let b = Timestamp.parse("2026-09-01T12:30:15Z")
        XCTAssertEqual(a, b)
        XCTAssertEqual(Timestamp.parse("2026-09-01T07:30:15-05:00"), b)
    }

    func testMatchesFoundationOnSamples() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        for s in ["2000-02-29T23:59:59Z", "2024-12-31T00:00:00Z", "1999-01-01T01:02:03Z", "2100-03-01T10:00:00Z"] {
            XCTAssertEqual(Timestamp.parse(s), f.date(from: s), s)
        }
    }

    func testRejectsGarbage() {
        XCTAssertNil(Timestamp.parse(""))
        XCTAssertNil(Timestamp.parse("2026-13-01T00:00:00Z"))
        XCTAssertNil(Timestamp.parse("2026-09-01"))
        XCTAssertNil(Timestamp.parse("2026-09-01T00:00:00Zjunk"))
    }
}

final class DecodingTests: XCTestCase {
    func testIssueDecodesWithMissingAndUnknownFields() throws {
        let json = #"{"id":"i1","status":"triage_custom","priority":"bogus","assignee_type":"agent","assignee_id":"a1","labels":[{"id":"l1"},{"bad":true}],"future_field":{"x":1}}"#
        let issue = try JSONCoders.decoder.decode(Issue.self, from: Data(json.utf8))
        XCTAssertEqual(issue.status.rawValue, "triage_custom")
        XCTAssertEqual(issue.priority, .none)
        XCTAssertEqual(issue.assignee, ActorRef(type: "agent", id: "a1"))
        XCTAssertEqual(issue.labels.map(\.id), ["l1"])
        XCTAssertEqual(issue.category(in: nil), .unstarted)
    }

    func testCustomStatusResolvesThroughCatalog() throws {
        let catalog = StatusCatalog([IssueStatusEntry(id: "s", key: "qa", name: "QA", category: .started)])
        let issue = Issue(id: "i", number: 1, identifier: "X-1", title: "t", status: "qa")
        XCTAssertEqual(issue.category(in: catalog), .started)
        XCTAssertEqual(catalog.columns(including: ["qa", "mystery"]), ["qa", "mystery"])
    }

    func testLossyListSkipsMalformedElements() throws {
        let json = #"[{"id":"w1","slug":"a","name":"A"},{"name":"missing id"},{"id":"w2","slug":"b"}]"#
        let list = try JSONCoders.decoder.decode(LossyList<Workspace>.self, from: Data(json.utf8))
        XCTAssertEqual(list.items.map(\.id), ["w1", "w2"])
    }

    func testUpdateRequestEncodesExplicitNullToClear() throws {
        var r = UpdateIssueRequest()
        r.status = .done
        r.assigneeType = .clear
        r.assigneeID = .clear
        let json = String(decoding: try JSONCoders.encoder.encode(r), as: UTF8.self)
        XCTAssertEqual(json, #"{"assignee_id":null,"assignee_type":null,"status":"done"}"#)
    }

    func testUpdateRequestAppliesOptimistically() {
        var r = UpdateIssueRequest()
        r.status = .inReview
        r.assigneeType = .set("agent")
        r.assigneeID = .set("a9")
        let before = Issue(id: "i", number: 1, identifier: "X-1", title: "t")
        let after = r.applied(to: before)
        XCTAssertEqual(after.status, .inReview)
        XCTAssertEqual(after.statusCategory, .started)
        XCTAssertEqual(after.assignee, ActorRef(type: "agent", id: "a9"))
    }

    func testTaskMessageKeepsOpenType() throws {
        let json = #"{"task_id":"t","seq":3,"type":"future_kind","input":{"file_path":"/a.swift","n":2}}"#
        let m = try JSONCoders.decoder.decode(TaskMessage.self, from: Data(json.utf8))
        XCTAssertEqual(m.kind.rawValue, "future_kind")
        XCTAssertEqual(m.input?["file_path"]?.stringValue, "/a.swift")
        XCTAssertEqual(m.input?["n"]?.stringValue, "2")
    }

    func testJSONPreviewIsClipped() {
        let big = JSONValue.object(["content": .string(String(repeating: "x", count: 10_000)), "file_path": .string("/f")])
        let p = big.preview(limit: 50)
        XCTAssertLessThanOrEqual(p.count, 51)
        XCTAssertTrue(p.hasSuffix("…"))
    }
}

final class DaemonProfileTests: XCTestCase {
    // Expected values computed with the TypeScript implementation (WHATWG URL
    // host + byte sum) to pin cross-client parity.
    func testProfileNameMatchesElectronShell() {
        XCTAssertEqual(DaemonProfile.deriveName(targetAPIURL: URL(string: "https://api.multica.ai")!), "desktop-api.multica.ai")
        XCTAssertEqual(DaemonProfile.deriveName(targetAPIURL: URL(string: "http://localhost:8080")!), "desktop-localhost-8080")
        XCTAssertEqual(DaemonProfile.deriveName(targetAPIURL: URL(string: "https://API.multica.ai:443")!), "desktop-api.multica.ai")
    }

    func testHealthPortMatchesGoCLI() {
        XCTAssertEqual(DaemonProfile(name: "desktop-api.multica.ai").healthPort, 19681)
        XCTAssertEqual(DaemonProfile(name: "desktop-localhost-8080").healthPort, 19544)
        XCTAssertEqual(DaemonProfile(name: "desktop-multica-api.copilothub.ai").healthPort, 19807)
    }

    func testPathsStayInsideOwnProfile() {
        let p = DaemonProfile(name: "desktop-x", home: URL(fileURLWithPath: "/Users/me"))
        XCTAssertEqual(p.configURL.path, "/Users/me/.multica/profiles/desktop-x/config.json")
        XCTAssertEqual(p.cliArguments, ["--profile", "desktop-x"])
        XCTAssertNotEqual(p.healthPort, DaemonProfile.defaultHealthPort)
    }

    func testHealthDecodes() throws {
        let h = try JSONCoders.decoder.decode(DaemonHealth.self, from: Data(#"{"status":"starting","pid":42,"agents":["claude"]}"#.utf8))
        XCTAssertTrue(h.isAlive)
        XCTAssertEqual(h.agents, ["claude"])
    }
}

final class LogBufferTests: XCTestCase {
    func testSplitsAcrossChunksAndBounds() {
        var b = LogBuffer(capacity: 3)
        XCTAssertEqual(b.append("a\nb"), ["a"])
        XCTAssertEqual(b.append("c\nd\n"), ["bc", "d"])
        XCTAssertEqual(b.append("e\nf\n"), ["e", "f"])
        XCTAssertEqual(b.lines, ["d", "e", "f"])
        XCTAssertEqual(b.append("partial"), [])
    }
}

final class MarkdownCacheTests: XCTestCase {
    func testParsesInlineMarkdownAndCaches() async {
        let cache = MarkdownCache(capacity: 2)
        let text = await cache.render("Fix **bold** and `code`\nnext line")
        #if canImport(Darwin)
        XCTAssertEqual(String(text.characters), "Fix bold and code\nnext line")
        #else
        XCTAssertFalse(text.characters.isEmpty)
        #endif
        XCTAssertNotNil(cache.cached("Fix **bold** and `code`\nnext line"))
        _ = await cache.render("a")
        _ = await cache.render("b")
        XCTAssertNil(cache.cached("Fix **bold** and `code`\nnext line"), "oldest entry is evicted")
    }
}

final class L10nTests: XCTestCase {
    func testLooksUpUpstreamCatalogsInEveryLanguage() {
        let l = L10n()
        l.setLanguage("en")
        XCTAssertEqual(l.t("layout", "nav.inbox"), "Inbox")
        l.setLanguage("zh-CN")
        XCTAssertEqual(l.language, "zh-Hans")
        XCTAssertEqual(l.t("layout", "nav.inbox"), "收件箱")
        l.setLanguage("ja")
        XCTAssertNotEqual(l.t("layout", "nav.inbox"), "nav.inbox")
        XCTAssertEqual(l.t("layout", "no.such.key"), "no.such.key")
    }

    func testPluralsAndInterpolation() {
        let l = L10n()
        l.setLanguage("en")
        let one = l.t("agents", "runtime_filter.agent_count", ["count": 1])
        let many = l.t("agents", "runtime_filter.agent_count", ["count": 3])
        XCTAssertTrue(one.contains("1"), one)
        XCTAssertTrue(many.contains("3"), many)
        XCTAssertNotEqual(one.replacingOccurrences(of: "1", with: ""), many.replacingOccurrences(of: "3", with: ""))
        XCTAssertEqual(L10n.pluralSuffix("zh-Hans", 1), "other")
    }
}

final class MarkdownBlocksTests: XCTestCase {
    func testParsesCommonBlocks() {
        let md = """
        # Title
        Some *text*
        continued.

        - [x] done
        - [ ] todo
          more
        1. one
        2. two

        ```swift
        let a = 1
        ```
        > quoted
        > lines

        | a | b |
        |---|:-:|
        | 1 | 2 |
        ---
        ![shot](https://x/y.png)
        """
        let blocks = MarkdownBlocks.parse(md)
        XCTAssertEqual(blocks.count, 9)
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "Title"))
        XCTAssertEqual(blocks[1], .paragraph("Some *text*\ncontinued."))
        guard case .list(false, _, let items) = blocks[2] else { return XCTFail("\(blocks[2])") }
        XCTAssertEqual(items.map(\.checked), [true, false])
        XCTAssertEqual(items[1].text, "todo\nmore")
        guard case .list(true, 1, let ordered) = blocks[3] else { return XCTFail() }
        XCTAssertEqual(ordered.map(\.text), ["one", "two"])
        XCTAssertEqual(blocks[4], .code(language: "swift", code: "let a = 1"))
        XCTAssertEqual(blocks[5], .quote("quoted\nlines"))
        XCTAssertEqual(blocks[6], .table(header: ["a", "b"], rows: [["1", "2"]]))
        XCTAssertEqual(blocks[7], .rule)
        XCTAssertEqual(blocks[8], .image(alt: "shot", url: "https://x/y.png"))
    }

    func testMentions() {
        let m = MarkdownBlocks.mentions(in: "hi [@Ada](mention://member/u1) and [@Bot](mention://agent/a1), see [MUL-1](mention://issue/i1)")
        XCTAssertEqual(m.map(\.type), ["member", "agent", "issue"])
        XCTAssertEqual(m.map(\.label), ["Ada", "Bot", "MUL-1"])
    }
}

final class SyntaxHighlighterTests: XCTestCase {
    func testSwiftTokens() {
        let code = "let x = \"hi\" // note\nstruct Foo { var n = 42 }"
        let toks = SyntaxHighlighter.tokens(code, language: "swift")
        let u = Array(code.utf16)
        func text(_ t: SyntaxHighlighter.Token) -> String { String(utf16CodeUnits: Array(u[t.range]), count: t.range.count) }
        let pairs = toks.map { (text($0), $0.kind) }
        XCTAssertTrue(pairs.contains { $0 == ("let", .keyword) })
        XCTAssertTrue(pairs.contains { $0 == ("\"hi\"", .string) })
        XCTAssertTrue(pairs.contains { $0 == ("// note", .comment) })
        XCTAssertTrue(pairs.contains { $0 == ("Foo", .type) })
        XCTAssertTrue(pairs.contains { $0 == ("42", .number) })
        XCTAssertTrue(SyntaxHighlighter.tokens(code, language: nil).isEmpty)
        XCTAssertTrue(SyntaxHighlighter.tokens(code, language: "brainfuck").isEmpty)
    }

    func testDiff() {
        let toks = SyntaxHighlighter.tokens("@@ -1 +1 @@\n-old\n+new\n ctx", language: "diff")
        XCTAssertEqual(toks.map(\.kind), [.meta, .deleted, .inserted])
    }
}
