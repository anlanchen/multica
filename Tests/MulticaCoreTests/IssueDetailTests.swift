import XCTest
@testable import MulticaCore

final class IssueDetailTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        try! JSONCoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    private func comment(_ id: String, at: String, parent: String? = nil, actor: String = "member", actorID: String = "u1",
                         source: String? = nil, type: String = "comment", resolvedAt: String? = nil, deleted: Bool = false) -> TimelineEntry {
        var fields = [
            "\"type\":\"comment\"", "\"id\":\"\(id)\"", "\"actor_type\":\"\(actor)\"", "\"actor_id\":\"\(actorID)\"",
            "\"created_at\":\"\(at)\"", "\"content\":\"body \(id)\"", "\"comment_type\":\"\(type)\"",
        ]
        if let parent { fields.append("\"parent_id\":\"\(parent)\"") }
        if let source { fields.append("\"source_task_id\":\"\(source)\"") }
        if let resolvedAt { fields.append("\"resolved_at\":\"\(resolvedAt)\"") }
        if deleted { fields.append("\"deleted_at\":\"\(at)\"") }
        return decode(TimelineEntry.self, "{\(fields.joined(separator: ","))}")
    }

    private func activity(_ id: String, at: String, action: String, actorID: String = "u1", details: String = "{}") -> TimelineEntry {
        decode(TimelineEntry.self, """
        {"type":"activity","id":"\(id)","actor_type":"member","actor_id":"\(actorID)","created_at":"\(at)","action":"\(action)","details":\(details)}
        """)
    }

    private func task(_ id: String, status: String, created: String, trigger: String? = nil, completed: String? = nil,
                      kind: String? = nil) -> AgentTaskRecord {
        AgentTaskRecord(id: id, agentId: "a1", issueId: "i1", status: status, completedAt: completed, createdAt: created,
                        triggerCommentId: trigger, kind: kind)
    }

    func testThreadsCollectNestedRepliesChronologically() {
        let entries = [
            comment("c1", at: "2026-01-01T10:00:00Z"),
            comment("r2", at: "2026-01-01T10:05:00Z", parent: "r1"),
            comment("r1", at: "2026-01-01T10:01:00Z", parent: "c1"),
            comment("r3", at: "2026-01-01T10:03:00Z", parent: "c1"),
        ]
        let layout = IssueDetailTimelineLayout.build(entries: entries, tasks: [])
        XCTAssertEqual(layout.items.count, 1)
        XCTAssertEqual(layout.items[0].thread?.replies.map(\.id), ["r1", "r3", "r2"])
        XCTAssertEqual(layout.replyToRoot["r2"], "c1")
    }

    func testActivitiesCoalesceWithinWindowAndGroup() {
        let entries = [
            activity("a1", at: "2026-01-01T10:00:00Z", action: "priority_changed"),
            activity("a2", at: "2026-01-01T10:01:00Z", action: "priority_changed"),
            activity("a3", at: "2026-01-01T10:10:00Z", action: "priority_changed"),
            activity("a4", at: "2026-01-01T10:11:00Z", action: "duplicate_marked"),
            activity("a5", at: "2026-01-01T10:11:30Z", action: "duplicate_marked"),
            comment("c1", at: "2026-01-01T10:20:00Z"),
            activity("a6", at: "2026-01-01T10:30:00Z", action: "task_completed"),
            activity("a7", at: "2026-01-02T10:30:00Z", action: "task_completed"),
        ]
        let layout = IssueDetailTimelineLayout.build(entries: entries, tasks: [])
        XCTAssertEqual(layout.items.count, 3)
        guard case .activities(let id, let first) = layout.items[0] else { return XCTFail() }
        XCTAssertEqual(id, "a2")
        XCTAssertEqual(first.map(\.id), ["a2", "a3", "a4", "a5"])
        XCTAssertEqual(first[0].coalescedCount, 2)
        guard case .activities(let lastID, let last) = layout.items[2] else { return XCTFail() }
        XCTAssertEqual(last.count, 1)
        XCTAssertEqual(last[0].coalescedCount, 2)
        XCTAssertEqual(layout.lastActivityGroupID, lastID)
    }

    func testRunAnchorsOnTriggerAndReplyIsReparented() {
        let entries = [
            comment("c1", at: "2026-01-01T10:00:00Z"),
            comment("reply", at: "2026-01-01T10:05:00Z", actor: "agent", actorID: "a1", source: "t1"),
        ]
        let tasks = [task("t1", status: "completed", created: "2026-01-01T10:00:01Z", trigger: "c1", completed: "2026-01-01T10:06:00Z")]
        let layout = IssueDetailTimelineLayout.build(entries: entries, tasks: tasks)
        XCTAssertEqual(layout.items.count, 1)
        let thread = layout.items[0].thread
        XCTAssertEqual(thread?.root.id, "c1")
        XCTAssertEqual(thread?.replies.map(\.id), ["reply"])
        XCTAssertEqual(thread?.runs.first?.hasReply, true)
        let rows = thread.map { $0.rows(replies: $0.replies, runs: $0.runs) } ?? []
        guard case .run(let run, let reply, let replyTo)? = rows.first else { return XCTFail() }
        XCTAssertEqual(run.id, "t1")
        XCTAssertEqual(reply?.id, "reply")
        XCTAssertNil(replyTo)
    }

    func testStandaloneRunWithoutReplyOrdersByEnqueueTime() {
        let entries = [
            comment("c1", at: "2026-01-01T10:00:00Z"),
            comment("c2", at: "2026-01-01T10:10:00Z"),
        ]
        let tasks = [task("t1", status: "running", created: "2026-01-01T10:05:00Z")]
        let layout = IssueDetailTimelineLayout.build(entries: entries, tasks: tasks)
        XCTAssertEqual(layout.items.map(\.id), ["c1", "run:t1", "c2"])
    }

    func testWorkingRunInThreadSitsAfterItsInput() {
        let entries = [
            comment("c1", at: "2026-01-01T10:00:00Z"),
            comment("r1", at: "2026-01-01T10:01:00Z", parent: "c1"),
            comment("r2", at: "2026-01-01T10:09:00Z", parent: "c1"),
        ]
        let tasks = [task("t1", status: "running", created: "2026-01-01T10:02:00Z", trigger: "r1")]
        let layout = IssueDetailTimelineLayout.build(entries: entries, tasks: tasks)
        guard let thread = layout.items.first?.thread else { return XCTFail() }
        let rows = thread.rows(replies: thread.replies, runs: thread.runs)
        XCTAssertEqual(rows.map(\.id), ["r1", "run:t1", "r2"])
    }

    func testQuickCreateAndObsoleteRunsAreHidden() {
        let entries = [comment("c1", at: "2026-01-01T10:00:00Z")]
        var obsolete = task("t2", status: "cancelled", created: "2026-01-01T10:01:00Z", trigger: "c1")
        obsolete.cancelledByCommentChange = true
        let tasks = [task("t1", status: "completed", created: "2026-01-01T09:00:00Z", kind: "quick_create"), obsolete]
        let layout = IssueDetailTimelineLayout.build(entries: entries, tasks: tasks)
        XCTAssertTrue(layout.runsByTask.isEmpty)
        XCTAssertEqual(layout.items.map(\.id), ["c1"])
    }

    func testResolutionPrefersRootThenLatestReply() {
        let root = comment("c1", at: "2026-01-01T10:00:00Z")
        let a = comment("r1", at: "2026-01-01T10:01:00Z", parent: "c1", resolvedAt: "2026-01-01T11:00:00Z")
        let b = comment("r2", at: "2026-01-01T10:02:00Z", parent: "c1", resolvedAt: "2026-01-01T12:00:00Z")
        XCTAssertEqual(IssueDetailResolution(root: root, replies: [a, b]), .reply("r2"))
        let resolvedRoot = comment("c1", at: "2026-01-01T10:00:00Z", resolvedAt: "2026-01-01T13:00:00Z")
        XCTAssertEqual(IssueDetailResolution(root: resolvedRoot, replies: [a, b]), .root)
        XCTAssertEqual(IssueDetailResolution(root: root, replies: []), .none)
    }

    func testActivityTextAndLinkTarget() {
        let names = IssueDetailNames(actor: { _, id in id == "u2" ? "Bob" : "Alice" }, status: { $0.uppercased() },
                                     priority: { $0 }, date: { $0 }, time: { $0 })
        let status = activity("a1", at: "2026-01-01T10:00:00Z", action: "status_changed", details: #"{"from":"todo","to":"done"}"#)
        XCTAssertTrue(IssueDetailActivityText.format(status, names).contains("DONE"))
        let selfAssign = activity("a2", at: "2026-01-01T10:00:00Z", action: "assignee_changed",
                                  details: #"{"to_type":"member","to_id":"u1"}"#)
        XCTAssertEqual(IssueDetailActivityText.format(selfAssign, names), tr("issues", "activity.self_assigned"))
        let dup = activity("a3", at: "2026-01-01T10:00:00Z", action: "duplicate_marked",
                           details: #"{"original_id":"x","original_identifier":"MUL-9"}"#)
        XCTAssertEqual(IssueDetailActivityText.linkTarget(dup)?.identifier, "MUL-9")
    }

    func testPlainTriggerSummary() {
        let raw = "Hi [@Bob](mention://member/u2) see ![shot](https://x/y.png) and [docs](https://d) &amp; more"
        XCTAssertEqual(IssueDetailFormat.plainTriggerSummary(raw, imageLabel: "[Image]"), "Hi @Bob see [Image] and docs & more")
    }

    func testOccurrencesAndStageGrouping() {
        XCTAssertEqual(IssueDetailFormat.occurrences(of: "ab", in: "AB ab xab"), 3)
        let groups = IssueDetailFormat.groupByStage([("a", 2), ("b", nil), ("c", 1), ("d", 2)]) { $0.1 }
        XCTAssertEqual(groups.map(\.stage), [1, 2, nil])
        XCTAssertEqual(groups[1].items.map(\.0), ["a", "d"])
    }

    func testWorkdirTargetPrefersDurableDirectoryOnceEnded() {
        var running = AgentTaskRecord(id: "t1", status: "running", createdAt: "2026-01-01T10:00:00Z")
        running.workDir = "/tmp/run"
        var done = AgentTaskRecord(id: "t2", status: "completed", createdAt: "2026-01-02T10:00:00Z")
        done.durableWorkDir = "/repo"
        done.branchName = "feat"
        let target = IssueDetailFormat.workdirTarget([running, done])
        XCTAssertEqual(target?.path, "/repo")
        XCTAssertEqual(target?.isProjectDirectory, true)
        XCTAssertEqual(IssueDetailFormat.workdirTarget([running])?.path, "/tmp/run")
    }

    @MainActor
    func testReactionEventsRespectCommentRevision() {
        let model = IssueDetailModel(issueID: "i1")
        var c = comment("c1", at: "2026-01-01T10:00:00Z")
        c.revision = 3
        model.setTimeline([c])
        model.applyReactionEvent(added: true, payload: [
            "issue_id": "i1", "comment_revision": 2,
            "reaction": ["id": "r1", "comment_id": "c1", "actor_type": "member", "actor_id": "u1", "emoji": "👍"],
        ])
        XCTAssertTrue(model.entries[0].reactions.isEmpty)
        model.applyReactionEvent(added: true, payload: [
            "issue_id": "i1", "comment_revision": 4,
            "reaction": ["id": "r1", "comment_id": "c1", "actor_type": "member", "actor_id": "u1", "emoji": "👍"],
        ])
        XCTAssertEqual(model.entries[0].reactions.map(\.emoji), ["👍"])
        model.applyReactionEvent(added: false, payload: [
            "issue_id": "i1", "comment_revision": 5, "comment_id": "c1", "emoji": "👍", "actor_type": "member", "actor_id": "u1",
        ])
        XCTAssertTrue(model.entries[0].reactions.isEmpty)
        XCTAssertEqual(model.entries[0].revision, 5)
    }

    @MainActor
    func testRemoveSubtreeDropsDescendants() {
        let model = IssueDetailModel(issueID: "i1")
        model.setTimeline([
            comment("c1", at: "2026-01-01T10:00:00Z"),
            comment("r1", at: "2026-01-01T10:01:00Z", parent: "c1"),
            comment("r2", at: "2026-01-01T10:02:00Z", parent: "r1"),
            comment("c2", at: "2026-01-01T10:03:00Z"),
        ])
        model.issueDetailRemoveSubtree("c1")
        XCTAssertEqual(model.entries.map(\.id), ["c2"])
    }
}
