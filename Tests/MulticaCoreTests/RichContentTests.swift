import XCTest
@testable import MulticaCore

final class RichContentTests: XCTestCase {
    func testIssueIdentifierAutolink() {
        XCTAssertEqual(MarkdownPreprocess.issueIdentifiers("see MUL-12 now"), "see [MUL-12](mention://issue/MUL-12) now")
        XCTAssertEqual(MarkdownPreprocess.issueIdentifiers("`MUL-12` stays"), "`MUL-12` stays")
        XCTAssertEqual(MarkdownPreprocess.issueIdentifiers("```\nMUL-12\n```"), "```\nMUL-12\n```")
        XCTAssertEqual(MarkdownPreprocess.issueIdentifiers("[MUL-12](https://x.y)"), "[MUL-12](https://x.y)")
        XCTAssertEqual(MarkdownPreprocess.issueIdentifiers("https://x.y/MUL-12"), "https://x.y/MUL-12")
        XCTAssertEqual(MarkdownPreprocess.issueIdentifiers("file MUL-12.md"), "file MUL-12.md")
        XCTAssertEqual(MarkdownPreprocess.issueIdentifiers("UTF-8 and mul-1"), "[UTF-8](mention://issue/UTF-8) and mul-1")
        XCTAssertEqual(MarkdownPreprocess.issueIdentifiers("end MUL-3."), "end [MUL-3](mention://issue/MUL-3).")
        XCTAssertTrue(MarkdownPreprocess.isIssueIdentifier("AB2-10"))
        XCTAssertFalse(MarkdownPreprocess.isIssueIdentifier("2AB-10"))
        XCTAssertFalse(MarkdownPreprocess.isIssueIdentifier("AB-"))
    }

    func testLinkify() {
        XCTAssertEqual(MarkdownPreprocess.links("go to https://a.com/x."), "go to [https://a.com/x](https://a.com/x).")
        XCTAssertEqual(MarkdownPreprocess.links("**https://a.com**"), "**[https://a.com](https://a.com)**")
        XCTAssertEqual(MarkdownPreprocess.links("(see https://a.com/a_(b))"), "(see [https://a.com/a_(b)](https://a.com/a_(b)))")
        XCTAssertEqual(MarkdownPreprocess.links("[x](https://a.com)"), "[x](https://a.com)")
        XCTAssertEqual(MarkdownPreprocess.links("`https://a.com`"), "`https://a.com`")
        XCTAssertEqual(MarkdownPreprocess.links("www.a.com"), "[www.a.com](https://www.a.com)")
        XCTAssertEqual(MarkdownPreprocess.links("mail ada@x.io"), "mail [ada@x.io](mailto:ada@x.io)")
        XCTAssertEqual(MarkdownPreprocess.links("看https://a.com。好"), "看[https://a.com](https://a.com)。好")
    }

    func testShortcodesAndChannelMarkers() {
        XCTAssertEqual(MarkdownPreprocess.mentionShortcodes(#"hi [@ id="u1" label="Ada"]!"#), "hi [@Ada](mention://member/u1)!")
        XCTAssertEqual(MarkdownPreprocess.mentionShortcodes(#"[@ label="Ada"]"#), #"[@ label="Ada"]"#)
        let marker = "<!-- multica:channel-media:123e4567-e89b-12d3-a456-426614174000 -->"
        XCTAssertEqual(MarkdownPreprocess.stripChannelMediaMarkers("a\(marker)b"), "ab")
    }

    func testRichBlocks() {
        let id = "123e4567-e89b-12d3-a456-426614174000"
        let md = """
        intro
        !file[re\\[port\\].pdf](/api/attachments/\(id)/download)
        $$
        x^2
        $$
        ```mermaid title="Flow"
        graph TD; A-->B
        ```
        ```html
        <b>open
        """
        let blocks = MarkdownBlocks.parse(md)
        XCTAssertEqual(blocks[0], .paragraph("intro"))
        XCTAssertEqual(blocks[1], .fileCard(name: "re[port].pdf", url: "/api/attachments/\(id)/download"))
        XCTAssertEqual(blocks[2], .math("x^2"))
        XCTAssertEqual(blocks[3], .richFence(kind: "mermaid", code: "graph TD; A-->B", title: "Flow"))
        XCTAssertEqual(blocks[4], .code(language: "html", code: "<b>open"))
        XCTAssertEqual(MarkdownBlocks.attachmentID(fromDownloadURL: "https://api.x/api/attachments/\(id)/download"), id)
        XCTAssertNil(MarkdownBlocks.attachmentID(fromDownloadURL: "/api/attachments/nope/download"))
        XCTAssertNil(MarkdownBlocks.fileCard("!file[x](javascript:alert(1))"))
    }

    func testRawHTML() {
        XCTAssertEqual(MarkdownPreprocess.rawHTML("a <!-- workflow:start --> b"), "a  b")
        XCTAssertEqual(MarkdownPreprocess.rawHTML("x<br>y<BR/>z"), "x\ny\nz")
        XCTAssertEqual(MarkdownPreprocess.rawHTML("`<!-- kept -->`"), "`<!-- kept -->`")
    }

    func testStatusCategoryNormalization() throws {
        let json = #"[{"key":"in_progress","name":"","category":"in_progress"},{"key":"x","name":"X","category":"completed"},{"key":"y","name":"Y","category":"started"}]"#
        let entries = try JSONCoders.decoder.decode([IssueStatusEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.map(\.category), [.started, .done, .started])
        XCTAssertEqual(StatusCategory.normalized("canceled"), .closed)
        XCTAssertEqual(StatusCategory.normalized("backlog"), .unstarted)
    }

    func testCachedParseAppliesPreprocessing() {
        let blocks = MarkdownBlocks.cachedParse("fix MUL-9 per https://a.com")
        XCTAssertEqual(blocks, [.paragraph("fix [MUL-9](mention://issue/MUL-9) per [https://a.com](https://a.com)")])
    }
}
