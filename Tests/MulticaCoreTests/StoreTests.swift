import XCTest
@testable import MulticaCore

final class IssueStoreTests: XCTestCase {
    @MainActor func issue(_ id: String, _ n: Int, _ status: IssueStatusKey = .todo, rev: Int = 1, pos: Double = 0) -> Issue {
        var i = Issue(id: id, number: n, identifier: "MUL-\(n)", title: "Issue \(n)", status: status, position: pos, revision: rev)
        i.updatedAt = "2026-09-01T00:00:0\(rev)Z"
        return i
    }

    @MainActor func testSectionsFollowCatalogOrder() async {
        let s = IssueStore()
        s.merge(page: [issue("a", 1, .done), issue("b", 2, .todo), issue("c", 3, .backlog)], total: 3, replacing: true)
        s.resectionIfNeeded()
        XCTAssertEqual(s.sections.map(\.key), [.backlog, .todo, .inProgress, .inReview, .blocked, .done, .cancelled])
        XCTAssertEqual(s.sections.first { $0.key == .todo }?.items.map(\.id), ["b"])
    }

    @MainActor func testRowUpdateDoesNotResection() async {
        let s = IssueStore()
        s.merge(page: [issue("a", 1)], total: 1, replacing: true)
        s.resectionIfNeeded()
        let before = s.resectionCount
        let model = s.model("a")!
        var renamed = issue("a", 1, rev: 2)
        renamed.priority = .urgent
        s.upsert(renamed)
        s.resectionIfNeeded()
        XCTAssertEqual(s.resectionCount, before, "a field edit must touch only its row")
        XCTAssertTrue(s.model("a") === model)
        XCTAssertEqual(model.issue.priority, .urgent)
    }

    @MainActor func testStatusChangeMovesSectionOnceForABurst() async {
        let s = IssueStore()
        s.merge(page: (1...50).map { issue("i\($0)", $0) }, total: 50, replacing: true)
        s.resectionIfNeeded()
        let before = s.resectionCount
        for n in 1...50 { s.upsert(issue("i\(n)", n, .done, rev: 2)) }
        s.resectionIfNeeded()
        XCTAssertEqual(s.resectionCount, before + 1)
        XCTAssertEqual(s.sections.first { $0.key == .done }?.items.count, 50)
    }

    @MainActor func testStaleRevisionIgnored() async {
        let s = IssueStore()
        s.merge(page: [issue("a", 1, .done, rev: 5)], total: 1, replacing: true)
        s.upsert(issue("a", 1, .todo, rev: 3))
        XCTAssertEqual(s.model("a")?.issue.status, .done)
    }

    @MainActor func testLifecycleTouchesOnlyItsRowAndFeedsRunningFilter() async {
        let s = IssueStore()
        s.merge(page: [issue("a", 1), issue("b", 2)], total: 2, replacing: true)
        s.applyTaskLifecycle(TaskLifecycle(taskID: "t1", agentID: "ag", issueID: "a", status: .running))
        XCTAssertEqual(s.model("a")?.activeRuns, 1)
        XCTAssertEqual(s.model("b")?.activeRuns, 0)
        s.filter = .running
        s.resectionIfNeeded()
        XCTAssertEqual(s.sections.flatMap(\.items).map(\.id), ["a"])
        s.applyTaskLifecycle(TaskLifecycle(taskID: "t1", agentID: "ag", issueID: "a", status: .completed))
        s.resectionIfNeeded()
        XCTAssertEqual(s.sections.flatMap(\.items).count, 0)
    }

    @MainActor func testOptimisticPatchAndRestore() async {
        let s = IssueStore()
        s.merge(page: [issue("a", 1)], total: 1, replacing: true)
        let prev = s.patch("a") { var i = $0; i.status = .done; return i }
        XCTAssertEqual(s.model("a")?.issue.status, .done)
        s.restore(prev!)
        XCTAssertEqual(s.model("a")?.issue.status, .todo)
    }
}

final class InboxStoreTests: XCTestCase {
    @MainActor func item(_ id: String, issue: String?, at: String, read: Bool = false) throws -> InboxItem {
        let issueField = issue.map { #""issue_id":"\#($0)""# } ?? #""issue_id":null"#
        let json = #"{"id":"\#(id)",\#(issueField),"title":"t","read":\#(read),"archived":false,"created_at":"\#(at)","type":"mentioned","severity":"info"}"#
        return try JSONCoders.decoder.decode(InboxItem.self, from: Data(json.utf8))
    }

    @MainActor func testCollapsesToNewestPerIssue() async throws {
        let s = InboxStore()
        s.setItems([try item("1", issue: "i1", at: "2026-01-01"), try item("2", issue: "i1", at: "2026-01-02"),
                    try item("3", issue: nil, at: "2026-01-03"), try item("4", issue: nil, at: "2026-01-00")])
        XCTAssertEqual(s.items.map(\.id), ["3", "2", "4"])
        s.markRead("2")
        XCTAssertEqual(s.items.first { $0.id == "2" }?.read, true)
    }

    @MainActor func testSummaryDrivesBadge() async {
        let s = InboxStore()
        s.setSummary([InboxWorkspaceUnread(workspaceID: "w1", count: 3)])
        XCTAssertEqual(s.unread(in: "w1"), 3)
        XCTAssertEqual(s.unread(in: "w2"), 0)
    }
}

extension InboxWorkspaceUnread {
    init(workspaceID: String, count: Int) {
        let json = #"{"workspace_id":"\#(workspaceID)","count":\#(count)}"#
        self = try! JSONCoders.decoder.decode(InboxWorkspaceUnread.self, from: Data(json.utf8))
    }
}

final class IssueStoreTotalsTests: XCTestCase {
    @MainActor func testOnlyCreationsGrowTheServerTotal() async {
        let s = IssueStore()
        s.merge(page: [Issue(id: "a", number: 1, identifier: "M-1", title: "a")], total: 10, replacing: true)
        s.upsert(Issue(id: "far", number: 99, identifier: "M-99", title: "beyond the loaded page"))
        XCTAssertEqual(s.totalOnServer, 10)
        s.upsert(Issue(id: "new", number: 100, identifier: "M-100", title: "created"), isNew: true)
        XCTAssertEqual(s.totalOnServer, 11)
    }
}
