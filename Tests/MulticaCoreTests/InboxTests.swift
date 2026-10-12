import XCTest
@testable import MulticaCore

final class InboxTests: XCTestCase {
    private func item(
        _ id: String, issue: String? = nil, type: String = "new_comment", actor: (String, String?)? = ("member", "u1"),
        status: String? = nil, priority: String? = "none", read: Bool = false, archived: Bool = false,
        at createdAt: String = "2026-01-01T00:00:00Z", details: String = "null", title: String = "T", body: String? = nil,
        omitPriority: Bool = false
    ) -> InboxItem {
        var fields: [String] = [
            "\"id\": \"\(id)\"", "\"workspace_id\": \"w\"", "\"recipient_type\": \"member\"", "\"recipient_id\": \"me\"",
            "\"type\": \"\(type)\"", "\"severity\": \"info\"", "\"title\": \(json(title))", "\"read\": \(read)",
            "\"archived\": \(archived)", "\"created_at\": \"\(createdAt)\"", "\"details\": \(details)",
            "\"issue_id\": \(json(issue))", "\"issue_status\": \(json(status))", "\"body\": \(json(body))",
            "\"actor_type\": \(json(actor?.0))", "\"actor_id\": \(json(actor?.1))",
        ]
        if !omitPriority { fields.append("\"issue_priority\": \(json(priority))") }
        let data = Data("{\(fields.joined(separator: ","))}".utf8)
        return try! JSONCoders.decoder.decode(InboxItem.self, from: data)
    }

    private func json(_ s: String?) -> String {
        guard let s else { return "null" }
        return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    func testDecodesDetailsStringifyingNumbers() {
        let i = item("a", type: "children_done", details: #"{"stage": 2, "comment_id": "c1", "flag": true}"#)
        XCTAssertEqual(i.details["stage"], "2")
        XCTAssertEqual(i.details["comment_id"], "c1")
        XCTAssertEqual(i.details["flag"], "true")
        XCTAssertTrue(i.issuePriorityPresent)
        XCTAssertFalse(item("b", omitPriority: true).issuePriorityPresent)
    }

    func testActorKeys() {
        XCTAssertEqual(InboxFiltering.actorKey(item("a", actor: ("agent", "x"))), "agent:x")
        XCTAssertEqual(InboxFiltering.actorKey(item("a", actor: ("system", nil))), "system")
        XCTAssertNil(InboxFiltering.actorKey(item("a", actor: ("member", nil))))
        XCTAssertNil(InboxFiltering.actorKey(item("a", actor: nil)))
        XCTAssertEqual(InboxFiltering.actorKeyParts("agent:x").type, "agent")
        XCTAssertEqual(InboxFiltering.actorKeyParts("agent:x").id, "x")
        XCTAssertEqual(InboxFiltering.actorKeyParts("system").type, "system")
        XCTAssertEqual(InboxFiltering.actorKeyParts("system").id, "")
    }

    func testFilterIsOrWithinAndAcrossDimensions() {
        let rows = [
            item("1", issue: "i1", status: "todo", priority: "high", read: false),
            item("2", issue: "i2", status: "done", priority: "low", read: true),
            item("3", issue: "i3", actor: ("agent", "a"), status: "todo", priority: "low", read: true),
            item("4", status: nil, priority: nil),
        ]
        XCTAssertEqual(InboxFiltering.filter(rows, InboxFilters()).map(\.id), ["1", "2", "3", "4"])
        XCTAssertEqual(InboxFiltering.filter(rows, InboxFilters(statuses: ["todo", "done"])).map(\.id), ["1", "2", "3"])
        XCTAssertEqual(InboxFiltering.filter(rows, InboxFilters(statuses: ["todo"], priorities: ["low"])).map(\.id), ["3"])
        XCTAssertEqual(InboxFiltering.filter(rows, InboxFilters(actors: ["agent:a"])).map(\.id), ["3"])
        XCTAssertEqual(InboxFiltering.filter(rows, InboxFilters(unreadOnly: true)).map(\.id), ["1", "4"])
        XCTAssertEqual(InboxFiltering.count(InboxFilters(statuses: ["a"], priorities: ["b", "c"], unreadOnly: true)), 4)
    }

    func testPrioritySupport() {
        XCTAssertEqual(InboxFiltering.prioritySupport([]), .unknown)
        XCTAssertEqual(InboxFiltering.prioritySupport([item("a"), item("b", priority: nil)]), .supported)
        XCTAssertEqual(InboxFiltering.prioritySupport([item("a"), item("b", omitPriority: true)]), .unsupported)
        let f = InboxFilters(statuses: ["todo"], priorities: ["high"])
        XCTAssertEqual(InboxFiltering.effective(f, support: .supported), f)
        XCTAssertEqual(InboxFiltering.effective(f, support: .unknown).priorities, [])
        XCTAssertEqual(InboxFiltering.effective(f, support: .unsupported).statuses, ["todo"])
    }

    func testFacetsIgnoreTheirOwnDimension() {
        let rows = [
            item("1", status: "todo", priority: "high", read: false),
            item("2", status: "done", priority: "high", read: true),
            item("3", status: "todo", priority: "low", read: false),
        ]
        let facets = InboxFiltering.facets(rows, InboxFilters(statuses: ["todo"]))
        XCTAssertEqual(facets.statuses, ["todo": 2, "done": 1])
        XCTAssertEqual(facets.priorities, ["high": 1, "low": 1])
        XCTAssertEqual(facets.actors, ["member:u1": 2])
        XCTAssertEqual(facets.unreadCount, 2)
    }

    func testGroupKeepsNewestAndCarriesCommentID() {
        let rows = [
            item("old", issue: "i1", at: "2026-01-01T00:00:00Z", details: #"{"comment_id": "c-old"}"#),
            item("new", issue: "i1", at: "2026-01-02T00:00:00Z"),
            item("solo", at: "2026-01-03T00:00:00Z"),
            item("arch", issue: "i2", archived: true),
        ]
        let grouped = InboxFiltering.group(rows, archived: false)
        XCTAssertEqual(grouped.map(\.id), ["solo", "new"])
        XCTAssertEqual(grouped[1].details["comment_id"], "c-old")
        XCTAssertEqual(InboxFiltering.group(rows, archived: true).map(\.id), ["arch"])
    }

    func testSelectionAdvancesPastRemovedRow() {
        let rows = [item("a", issue: "1"), item("b", issue: "2"), item("c")]
        XCTAssertEqual(InboxFiltering.selectionAfterRemoving("a", from: rows, selectedKey: "1"), .some("2"))
        XCTAssertEqual(InboxFiltering.selectionAfterRemoving("c", from: rows, selectedKey: "c"), .some("2"))
        XCTAssertNil(InboxFiltering.selectionAfterRemoving("a", from: rows, selectedKey: "2"))
        let last = InboxFiltering.selectionAfterRemoving("x", from: [item("x")], selectedKey: "x")
        XCTAssertEqual(last, .some(nil))
    }

    func testArrowNavigation() {
        let rows = [item("a"), item("b"), item("c")]
        XCTAssertEqual(InboxFiltering.step(from: "", by: 1, in: rows)?.id, "a")
        XCTAssertEqual(InboxFiltering.step(from: "", by: -1, in: rows)?.id, "c")
        XCTAssertEqual(InboxFiltering.step(from: "b", by: 1, in: rows)?.id, "c")
        XCTAssertNil(InboxFiltering.step(from: "c", by: 1, in: rows))
        XCTAssertNil(InboxFiltering.step(from: "a", by: -1, in: rows))
    }

    func testDisplayTitles() {
        XCTAssertEqual(InboxDisplay.stripQuickCreatePrefix("Created ABC-12: Fix   login", identifier: "ABC-12"), "Fix login")
        XCTAssertEqual(InboxDisplay.stripQuickCreatePrefix("Created XY-3: Thing"), "Thing")
        XCTAssertEqual(InboxDisplay.title(item("a", type: "quick_create_done", details: #"{"identifier": "A-1"}"#, title: "Created A-1: Hello")), "Hello")
        XCTAssertEqual(InboxDisplay.title(item("a", type: "quick_create_failed", details: #"{"original_prompt": "  do\nthis "}"#, title: "x")), "do this")
        XCTAssertEqual(InboxDisplay.title(item("a", type: "status_changed", title: "Plain")), "Plain")
        XCTAssertEqual(InboxDisplay.quickCreateOutcomeDetail(item("a", details: #"{"error": "boom"}"#, body: "b")), "boom")
        XCTAssertEqual(InboxDisplay.quickCreateOutcomeDetail(item("a", body: "the body")), "the body")
    }

    func testAgeBuckets() {
        let now = Timestamp.parse("2026-01-02T00:00:00Z")!
        XCTAssertEqual(InboxDisplay.age(of: "2026-01-01T23:59:30Z", now: now), .justNow)
        XCTAssertEqual(InboxDisplay.age(of: "2026-01-01T23:15:00Z", now: now), .minutes(45))
        XCTAssertEqual(InboxDisplay.age(of: "2026-01-01T19:00:00Z", now: now), .hours(5))
        XCTAssertEqual(InboxDisplay.age(of: "2025-12-29T00:00:00Z", now: now), .days(4))
    }
}
