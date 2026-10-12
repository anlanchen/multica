import XCTest
@testable import MulticaCore

final class AttachmentPreviewTests: XCTestCase {
    func testKindDispatch() {
        XCTAssertEqual(AttachmentPreview.kind(contentType: "application/pdf", filename: "a"), .pdf)
        XCTAssertEqual(AttachmentPreview.kind(contentType: "", filename: "clip.MOV"), .video)
        XCTAssertEqual(AttachmentPreview.kind(contentType: "audio/mpeg", filename: "x"), .audio)
        XCTAssertEqual(AttachmentPreview.kind(contentType: "image/svg+xml", filename: "logo.svg"), .image)
        XCTAssertEqual(AttachmentPreview.kind(contentType: "text/plain", filename: "README.md"), .markdown)
        XCTAssertEqual(AttachmentPreview.kind(contentType: "text/html; charset=utf-8", filename: "page"), .html)
        XCTAssertEqual(AttachmentPreview.kind(contentType: "", filename: "data.tsv"), .table)
        XCTAssertEqual(AttachmentPreview.kind(contentType: "text/plain", filename: "events.jsonl"), .structured)
        XCTAssertEqual(AttachmentPreview.kind(contentType: "", filename: "main.go"), .text)
        XCTAssertEqual(AttachmentPreview.kind(contentType: "", filename: "Dockerfile"), .text)
        XCTAssertNil(AttachmentPreview.kind(contentType: "application/zip", filename: "a.zip"))
        XCTAssertEqual(AttachmentPreview.structuredFormat(contentType: "application/json", filename: "x.yaml"), .yaml)
        XCTAssertTrue(AttachmentPreview.isTSV(contentType: "text/tab-separated-values", filename: "x"))
        XCTAssertEqual(AttachmentPreview.typeLabel("photo.jpeg"), "JPEG")
        XCTAssertEqual(AttachmentPreview.language(for: "a.tsx"), "typescript")
        XCTAssertTrue(AttachmentPreview.wrapsByDefault("server.log"))
        XCTAssertFalse(AttachmentPreview.wrapsByDefault("main.swift"))
    }

    func testDelimitedParsing() {
        XCTAssertEqual(AttachmentPreview.sniffDelimiter("a;b;c\n1;2;3"), ";")
        XCTAssertEqual(AttachmentPreview.sniffDelimiter("a,b\n"), ",")
        let rows = AttachmentPreview.parseDelimited("\u{FEFF}name,note\r\n\"Smith, J\",\"say \"\"hi\"\"\nthere\"\n\nx,y,z\n", delimiter: ",")
        XCTAssertEqual(rows, [["name", "note"], ["Smith, J", "say \"hi\"\nthere"], ["x", "y", "z"]])
        let table = AttachmentPreview.table("n,v\n1,a\n10,b\n9,", tsv: false)
        XCTAssertEqual(table.header, ["n", "v"])
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertEqual(table.numericColumns, [0])
        XCTAssertEqual(AttachmentPreview.sortedRows(table, column: 0, ascending: true), [0, 2, 1])
        XCTAssertEqual(AttachmentPreview.sortedRows(table, column: 1, ascending: false), [1, 0, 2])
        XCTAssertEqual(AttachmentPreview.compareCells("2", "abc"), .orderedAscending)
        XCTAssertEqual(AttachmentPreview.compareCells("file9", "file10"), .orderedAscending)
    }

    func testJSONKeepsKeyOrder() {
        guard case .ok(let v) = AttachmentPreview.parseStructured(#"{"z": 1, "a": [true, null, "x\u00e9"], "m": {"k": 2.5}}"#, format: .json) else {
            return XCTFail("parse failed")
        }
        XCTAssertEqual(v.entries.map(\.0), ["z", "a", "m"])
        XCTAssertEqual(v.entries[1].1, .array([.bool(true), .null, .string("xé")]))
        if case .failed(let message) = AttachmentPreview.parseStructured("{\"a\": }", format: .json) {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("expected failure")
        }
        guard case .failed(let line) = AttachmentPreview.parseStructured("{\"a\":1}\n\nnope", format: .jsonl) else { return XCTFail() }
        XCTAssertTrue(line.hasPrefix("Line 3"))
    }

    func testYAMLSubset() {
        let yaml = """
        # config
        name: demo
        version: 2
        tags: [a, "b c"]
        nested:
          enabled: true
          items:
            - one
            - key: v
              other: 3
        script: |
          echo hi
          echo bye
        ---
        second: ~
        """
        guard case .ok(let v) = AttachmentPreview.parseStructured(yaml, format: .yaml) else { return XCTFail("yaml failed") }
        guard case .array(let docs) = v, docs.count == 2 else { return XCTFail("expected two documents") }
        let first = docs[0]
        XCTAssertEqual(first.entries.map(\.0), ["name", "version", "tags", "nested", "script"])
        XCTAssertEqual(first.entries[1].1, .number(2))
        XCTAssertEqual(first.entries[2].1, .array([.string("a"), .string("b c")]))
        let nested = first.entries[3].1
        XCTAssertEqual(nested.entries[0].1, .bool(true))
        XCTAssertEqual(nested.entries[1].1, .array([.string("one"), .object([("key", .string("v")), ("other", .number(3))])]))
        XCTAssertEqual(first.entries[4].1, .string("echo hi\necho bye\n"))
        XCTAssertEqual(docs[1], .object([("second", .null)]))
    }

    func testTreeRowsAndPreview() {
        let root: AttachmentPreviewValue = .object([
            ("small", .object([("a", .number(1))])),
            ("list", .array((0..<150).map { .number(Double($0)) })),
            ("empty", .array([])),
            ("s", .string("hi")),
        ])
        let expanded = AttachmentPreviewTree.defaultExpanded(root)
        XCTAssertEqual(expanded, ["/small"])
        var rows = AttachmentPreviewTree.rows(root, expanded: expanded, shown: [:])
        XCTAssertEqual(rows.map(\.path), ["/small", "/small/a", "/list", "/empty", "/s"])
        rows = AttachmentPreviewTree.rows(root, expanded: ["/list"], shown: [:])
        XCTAssertEqual(rows.count, 4 + 100 + 1)
        if case .showMore(let remaining) = rows[rows.count - 3].kind { XCTAssertEqual(remaining, 50) } else { XCTFail("expected show more") }
        rows = AttachmentPreviewTree.rows(root, expanded: ["/list"], shown: ["/list": 200])
        XCTAssertEqual(rows.count, 4 + 150)
        XCTAssertEqual(AttachmentPreview.previewOf(.object([("a", .number(1)), ("b c", .string("x")), ("o", .object([]))])), #"{ a: 1, "b c": "x", o: {…} }"#)
        XCTAssertEqual(AttachmentPreview.primitiveText(.number(3)), "3")
        XCTAssertEqual(AttachmentPreview.primitiveText(.number(2.5)), "2.5")
    }
}
