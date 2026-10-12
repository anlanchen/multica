import XCTest
@testable import MulticaCore

final class SearchPaletteTests: XCTestCase {
    private func joined(_ segs: [SearchPaletteHighlight.Segment]) -> String {
        segs.map { $0.highlight ? "[\($0.text)]" : $0.text }.joined()
    }

    func testHighlightMatchesWholeQueryThenWords() {
        XCTAssertEqual(joined(SearchPaletteHighlight.segments("Fix the Login bug", query: "login")), "Fix the [Login] bug")
        XCTAssertEqual(joined(SearchPaletteHighlight.segments("login page login", query: "LOGIN")), "[login] page [login]")
        XCTAssertEqual(joined(SearchPaletteHighlight.segments("fix login page", query: "login page")), "fix [login page]")
        XCTAssertEqual(joined(SearchPaletteHighlight.segments("page then login", query: "login page")), "[page] then [login]")
        XCTAssertEqual(joined(SearchPaletteHighlight.segments("a.b(c)", query: "(c")), "a.b[(c])")
        XCTAssertEqual(joined(SearchPaletteHighlight.segments("plain", query: "  ")), "plain")
        XCTAssertEqual(joined(SearchPaletteHighlight.segments("plain", query: "zz")), "plain")
    }

    func testQueryNumberMirrorsServerPattern() {
        XCTAssertEqual(SearchPaletteRank.queryNumber("MUL-123"), 123)
        XCTAssertEqual(SearchPaletteRank.queryNumber("v2-12"), 12)
        XCTAssertEqual(SearchPaletteRank.queryNumber(" 42 "), 42)
        XCTAssertNil(SearchPaletteRank.queryNumber("2V-12"))
        XCTAssertNil(SearchPaletteRank.queryNumber("MUL-"))
        XCTAssertNil(SearchPaletteRank.queryNumber("a-b-3"))
        XCTAssertNil(SearchPaletteRank.queryNumber("0"))
        XCTAssertNil(SearchPaletteRank.queryNumber("login"))
    }

    func testDirectHitsAreExemptFromDemotion() {
        XCTAssertTrue(SearchPaletteRank.isIssueDirectHit(title: "x", number: 7, identifier: "MUL-7", query: "7"))
        XCTAssertTrue(SearchPaletteRank.isIssueDirectHit(title: "x", number: nil, identifier: "MUL-7", query: "mul-7"))
        XCTAssertTrue(SearchPaletteRank.isIssueDirectHit(title: " Crash on save ", number: 1, identifier: "MUL-1", query: "crash on save"))
        XCTAssertFalse(SearchPaletteRank.isIssueDirectHit(title: "Crash on save", number: 1, identifier: "MUL-1", query: "crash"))
        XCTAssertTrue(SearchPaletteRank.isProjectDirectHit(title: "Web", query: "web"))
        XCTAssertFalse(SearchPaletteRank.isProjectDirectHit(title: "Web app", query: "web"))
    }

    func testStablePartition() {
        let parts = SearchPaletteRank.partition([1, 2, 3, 4, 5, 6]) { $0 % 2 == 0 }
        XCTAssertEqual(parts.live, [1, 3, 5])
        XCTAssertEqual(parts.cancelled, [2, 4, 6])
    }

    func testRowAndMemberMatching() {
        XCTAssertTrue(SearchPaletteMatch.row(label: "Inbox", keywords: ["notifications"], query: "box"))
        XCTAssertTrue(SearchPaletteMatch.row(label: "Inbox", keywords: ["notifications"], query: "notif"))
        XCTAssertFalse(SearchPaletteMatch.row(label: "Inbox", keywords: ["notifications"], query: "s"), "keywords match by prefix only")
        XCTAssertTrue(SearchPaletteMatch.member(name: "Ada Lovelace", email: "ada@x.io", role: "admin", query: "x.io"))
        XCTAssertTrue(SearchPaletteMatch.member(name: "Ada", email: "a@x", role: "admin", query: "adm"))
        XCTAssertFalse(SearchPaletteMatch.member(name: "Bob", email: "b@x", role: "admin", query: "ad"))
        XCTAssertTrue(SearchPaletteMatch.wantsAllMembers("peo"))
        XCTAssertFalse(SearchPaletteMatch.wantsAllMembers("pe"))
    }

    func testPinyinMatching() {
        let name = ["li", "yun", "long"]
        XCTAssertTrue(SearchPaletteMatch.pinyin(syllables: name, query: "liyunlong"))
        XCTAssertTrue(SearchPaletteMatch.pinyin(syllables: name, query: "liyu"))
        XCTAssertTrue(SearchPaletteMatch.pinyin(syllables: name, query: "lyl"))
        XCTAssertTrue(SearchPaletteMatch.pinyin(syllables: name, query: "liyl"))
        XCTAssertTrue(SearchPaletteMatch.pinyin(syllables: name, query: "LYunL"))
        XCTAssertFalse(SearchPaletteMatch.pinyin(syllables: name, query: "yun"))
        XCTAssertFalse(SearchPaletteMatch.pinyin(syllables: name, query: "lylx"))
    }

    func testPagesAndRecentIssues() {
        XCTAssertEqual(Set(SearchPalettePages.order), Set(WorkspacePage.allCases))
        XCTAssertEqual(SearchPalettePages.order.first, .inbox)
        XCTAssertTrue(SearchPalettePages.keywords(.usage).contains("analytics"))
        let history = [TabLocation(.issue("b")), TabLocation(.projects), TabLocation(.issue("a")), TabLocation(.issue("b")), TabLocation(.issue("c"))]
        XCTAssertEqual(SearchPalettePages.recentIssueIDs(history), ["b", "a", "c"])
        XCTAssertEqual(SearchPalettePages.recentIssueIDs(history, limit: 2), ["b", "a"])
    }
}
