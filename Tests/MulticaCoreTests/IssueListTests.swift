import XCTest
@testable import MulticaCore

final class IssueListViewStateTests: XCTestCase {
    func testDefaultsMatchUpstream() {
        let s = IssueListViewState()
        XCTAssertEqual(s.viewMode, .board)
        XCTAssertEqual(s.sortBy, "created_at")
        XCTAssertEqual(s.sortDirection, .desc)
        XCTAssertEqual(s.hiddenStatuses, ["cancelled"])
        XCTAssertTrue(s.cardProperties.project)
        XCTAssertFalse(IssueListViewState.defaults(surfaceKey: "project:p1").cardProperties.project)
        XCTAssertEqual(s.tableColumns.first?.key, "title")
    }

    func testManualSortOnlyUnderStatusGrouping() {
        var s = IssueListViewState()
        s.setSortBy("position")
        XCTAssertEqual(s.sortBy, "position")
        s.setGrouping("assignee")
        XCTAssertEqual(s.sortBy, "created_at")
        XCTAssertEqual(s.sortDirection, .desc)
        XCTAssertEqual(IssueListOptions.sortFields(grouping: "assignee").contains("position"), false)
    }

    func testSortDirectionIsRememberedPerField() {
        var s = IssueListViewState()
        s.setSortBy("priority")
        XCTAssertEqual(s.sortDirection, .asc)
        s.setSortDirection(.desc)
        s.setSortBy("title")
        s.setSortBy("priority")
        XCTAssertEqual(s.sortDirection, .desc)
    }

    func testTogglesAndClearDimension() {
        var s = IssueListViewState()
        s.toggleStatusFilter("todo")
        s.toggleAssigneeFilter(IssueListActorFilter(type: "agent", id: "a1"))
        s.includeNoAssignee = true
        s.togglePropertyFilter("p", "o1")
        s.togglePropertyFilter("p", "o1")
        XCTAssertNil(s.propertyFilters["p"], "an emptied property filter is removed")
        s.clearFilterDimension(.assignee)
        XCTAssertTrue(s.assigneeFilters.isEmpty)
        XCTAssertFalse(s.includeNoAssignee)
        XCTAssertEqual(s.statusFilters, ["todo"])
    }

    func testJSONRoundTripAndLenientMerge() {
        var s = IssueListViewState()
        s.viewMode = .list
        s.statusFilters = ["qa", "todo"]
        s.propertyFilters = ["p": [.equals("x"), .op("gte", "3"), .equals(IssueListPropertyFilterValue.noValue)]]
        s.tableColumns = [IssueListTableColumn(key: "title", width: 300), IssueListTableColumn(key: "property:p")]
        s.dateFilter = IssueListDateFilter(field: "created_at", from: "2026-01-01", to: "2026-01-02")
        s.agentRunningFilter = true
        let back = IssueListViewState(json: s.persistedJSON, defaults: IssueListViewState())
        XCTAssertEqual(back.viewMode, .list)
        XCTAssertEqual(back.statusFilters, ["qa", "todo"], "custom status keys survive")
        XCTAssertEqual(back.propertyFilters, s.propertyFilters)
        XCTAssertEqual(back.tableColumns, s.tableColumns)
        XCTAssertNil(back.dateFilter, "date filter is not persisted")
        XCTAssertFalse(back.agentRunningFilter, "agents-working toggle is not persisted")
    }

    func testMergeDropsUnrepresentableValues() {
        let json: [String: JSONValue] = [
            "priorityFilters": ["high", "nope"],
            "projectStatusFilters": ["in_progress", "backlog"],
            "propertyFilters": ["p": ["keep", ["op": "regex", "value": "x"], 7], "q": [["op": "regex", "value": "x"]]],
            "cardProperties": ["labels": true],
            "tableColumns": [["key": "status"], ["key": "title", "width": 200], ["key": "status"]],
            "grouping": "assignee",
            "sortBy": "position",
            "hiddenStatusCategories": ["started"],
        ]
        let s = IssueListViewState(json: json, defaults: IssueListViewState())
        XCTAssertEqual(s.priorityFilters, ["high"])
        XCTAssertEqual(s.projectStatusFilters, ["in_progress"])
        XCTAssertEqual(s.propertyFilters, ["p": [.equals("keep")]])
        XCTAssertTrue(s.cardProperties.labels)
        XCTAssertTrue(s.cardProperties.priority, "keys missing from an old snapshot keep their default")
        XCTAssertEqual(s.tableColumns.map(\.key), ["title", "status"])
        XCTAssertEqual(s.tableColumns.first?.width, 200)
        XCTAssertEqual(s.sortBy, "created_at", "manual sort is normalized away from a non-status grouping")
        XCTAssertEqual(s.hiddenStatuses, ["in_progress", "in_review", "blocked"], "legacy category names map to keys")
    }

    func testBaselineCountsOnlyAdditions() {
        let baseline = IssueListBaseline(query: ["statusFilters": ["todo"], "includeNoAssignee": true])
        var s = IssueListViewState()
        s.resetFilters(to: baseline.raw)
        XCTAssertEqual(s.activeFilterCount(baseline: baseline, activePropertyIDs: nil, includeDate: true), 0)
        s.toggleStatusFilter("done")
        s.toggleLabelFilter("l1")
        XCTAssertEqual(s.activeFilterCount(baseline: baseline, activePropertyIDs: nil, includeDate: true), 2)
        s.clearFilterDimension(.status, baseline: baseline)
        XCTAssertEqual(s.statusFilters, ["todo"], "removing a chip returns the dimension to the view's values")
        XCTAssertEqual(baseline.lockedDimensions, [.status, .assignee])
    }

    func testViewBarPrefs() {
        let r = IssueListBarPrefs.apply(itemIDs: ["builtin:all", "builtin:members", "view:a", "view:b"],
                                        hidden: ["builtin:all", "view:a", "gone"], order: ["view:b", "gone", "builtin:all"],
                                        anchorID: "builtin:all")
        XCTAssertEqual(r.ordered, ["view:b", "builtin:all", "builtin:members", "view:a"])
        XCTAssertEqual(r.visible, ["view:b", "builtin:all", "builtin:members"], "the anchor built-in is never hidden")
        XCTAssertTrue(IssueListBarPrefs.canManage(ownerID: "u2", visibility: "workspace", userID: "u1", role: "admin"))
        XCTAssertFalse(IssueListBarPrefs.canManage(ownerID: "u2", visibility: "private", userID: "u1", role: "owner"))
    }

    func testSortDirectionLabels() {
        XCTAssertEqual(IssueListOptions.sortDirectionLabelKey(field: "created_at", direction: .desc), "newest_first")
        XCTAssertEqual(IssueListOptions.sortDirectionLabelKey(field: "status", direction: .asc), "workflow_order")
        XCTAssertEqual(IssueListOptions.sortDirectionLabelKey(field: "property:x", direction: .desc), "descending_title")
    }
}

final class IssueListQueryTests: XCTestCase {
    func testScopeKeysAndTableScopes() {
        XCTAssertEqual(IssueListSurfaceScope.workspace(actorKind: "all").key, "workspace:all")
        XCTAssertEqual(IssueListSurfaceScope.project(id: "p", actorKind: "all").key, "project:p")
        XCTAssertEqual(IssueListSurfaceScope.project(id: "p", actorKind: "agents").key, "project:p:agents")
        XCTAssertEqual(IssueListSurfaceScope.my(userID: "u", relation: "all").tableScope["relation"], "any")
        XCTAssertEqual(IssueListSurfaceScope.workspace(actorKind: "agents").tableScope["assignee_types"], ["agent", "squad"])
        XCTAssertEqual(IssueListSurfaceScope.actor(type: "agent", id: "a", relation: "created").tableScope["kind"], "creator")
        XCTAssertEqual(IssueListSurfaceScope.workspace(actorKind: "all").applyingViewVariant("members").key, "workspace:members")
        XCTAssertEqual(IssueListSurfaceScope.my(userID: "u", relation: "assigned").applyingViewVariant(nil).key, "my:u:all")
        XCTAssertEqual(IssueListSurfaceScope.my(userID: "u", relation: "assigned").createDefaults.assignee, ActorRef(type: "member", id: "u"))
    }

    func testSpecCompilesFilters() {
        var s = IssueListViewState()
        s.statusFilters = ["todo"]
        s.projectFilters = ["p1"]
        s.propertyFilters = ["live": [.equals("x")], "archived": [.equals("y")]]
        s.agentRunningFilter = true
        s.showSubIssues = false
        s.setSortBy("property:archived")
        let spec = IssueListQuery.spec(scope: .project(id: "p", actorKind: "all"), state: s, search: "  bug ",
                                       workingIssueIDs: ["i1"], activePropertyIDs: ["live"])
        XCTAssertEqual(spec.filters?.statuses, ["todo"])
        XCTAssertNil(spec.filters?.projectIds, "a project surface ignores project filters")
        XCTAssertEqual(spec.filters?.properties?.keys.sorted(), ["live"], "filters on inactive definitions are stripped")
        XCTAssertEqual(spec.filters?.workingIssueIds, ["i1"])
        XCTAssertEqual(spec.filters?.includeSubIssues, false)
        XCTAssertEqual(spec.search, "bug")
        XCTAssertEqual(spec.sort["field"], "position", "a sort on an inactive property degrades to manual")
        XCTAssertEqual(spec.sort["direction"], "asc")
        let unresolved = IssueListQuery.spec(scope: .workspace(actorKind: "all"), state: s, search: "", workingIssueIDs: nil, activePropertyIDs: nil)
        XCTAssertNil(unresolved.filters?.workingIssueIds, "unknown membership never becomes a match-nothing filter")
        XCTAssertEqual(unresolved.filters?.properties?.count, 2, "an unsettled catalog passes filters through")
    }

    func testMembershipKeyIgnoresSort() {
        var s = IssueListViewState()
        let a = IssueListQuery.spec(scope: .workspace(actorKind: "all"), state: s, search: "", workingIssueIDs: nil, activePropertyIDs: [])
        s.setSortBy("title")
        let b = IssueListQuery.spec(scope: .workspace(actorKind: "all"), state: s, search: "", workingIssueIDs: nil, activePropertyIDs: [])
        XCTAssertNotEqual(IssueListQuery.fingerprint(a), IssueListQuery.fingerprint(b))
        XCTAssertEqual(IssueListQuery.membershipKey(a), IssueListQuery.membershipKey(b))
    }

    func testDateRangeIsInclusiveAndOrdered() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let r = try XCTUnwrap(IssueListQuery.dateRange(IssueListDateFilter(field: "updated_at", from: "2026-03-05", to: "2026-03-01"), calendar: cal))
        XCTAssertEqual(r.field, "updated_at")
        XCTAssertEqual(r.start, "2026-03-01T00:00:00.000Z")
        XCTAssertEqual(r.end, "2026-03-06T00:00:00.000Z")
    }

    func testStatusColumns() {
        let qa = IssueStatusEntry(id: "qa", key: "qa", name: "QA", category: .started, position: 2.5, isSystem: false)
        var old = IssueStatusEntry(id: "old", key: "old", name: "Old", category: .unstarted, position: 9, isSystem: false)
        old.archivedAt = "2026-01-01T00:00:00Z"
        let entries = StatusCatalog.builtIn.entries + [qa, old]
        let columns = IssueListStatusColumns.columnKeys(entries: entries, includeArchived: false)
        XCTAssertEqual(columns, [.backlog, .todo, .inProgress, "qa", .inReview, .blocked, .done, .cancelled])
        XCTAssertEqual(IssueListStatusColumns.visible(statusFilters: [], hidden: ["cancelled"], entries: entries).last, .done)
        XCTAssertEqual(IssueListStatusColumns.visible(statusFilters: ["old", "gone"], hidden: [], entries: entries), ["old"],
                       "an exact filter re-admits archived keys and drops unknown ones")
        XCTAssertEqual(IssueListStatusColumns.hidden(statusFilters: [], hidden: ["cancelled"], entries: entries), [.cancelled])
        XCTAssertTrue(IssueListStatusColumns.isCustom("qa", entry: qa))
        XCTAssertEqual(IssueListStatusColumns.columnKeys(entries: [], includeArchived: false), IssueStatusKey.builtIns.sorted {
            [IssueStatusKey.backlog, .todo, .inProgress, .inReview, .blocked, .done, .cancelled].firstIndex(of: $0)! <
                [IssueStatusKey.backlog, .todo, .inProgress, .inReview, .blocked, .done, .cancelled].firstIndex(of: $1)!
        })
    }

    func testFacetCounts() throws {
        let json = """
        {"query_fingerprint":"f","total":9,"facets":[
          {"kind":"status","values":[{"key":"todo","count":4},{"key":"done","count":5}]},
          {"kind":"assignee","values":[{"key":"__none__","count":2},{"key":"member:u","count":7}]},
          {"kind":"property","property_id":"p","values":[{"key":"o","count":3}]},
          {"kind":"working_agents","values":[{"key":"a1","count":2}]}
        ]}
        """
        let r = try JSONCoders.decoder.decode(IssueTableFacetsResponse.self, from: Data(json.utf8))
        let c = IssueListFacetCounts(r)
        XCTAssertEqual(c.total, 9)
        XCTAssertEqual(c.noAssignee, 2)
        XCTAssertEqual(c.assignee["member:u"], 7)
        XCTAssertEqual(c.property["p"]?["o"], 3)
        XCTAssertEqual(c.workingAgents, [IssueListWorkingAgent(id: "a1", runningTaskCount: 2)])
        XCTAssertEqual(c.statusCounts(selected: ["todo"]), ["todo": 4])
        XCTAssertNil(IssueListFacetCounts().workingAgents, "a missing facet stays indeterminate")
    }

    func testGroupValues() {
        XCTAssertEqual(IssueListGroupValue(["kind": "assignee", "actor": ["type": "agent", "id": "a"]]), .assignee(ActorRef(type: "agent", id: "a")))
        XCTAssertEqual(IssueListGroupValue(["kind": "assignee", "actor": nil]), .assignee(nil))
        XCTAssertEqual(IssueListGroupValue(["kind": "project", "project_id": nil]), .project(nil))
        XCTAssertEqual(IssueListGroupValue(["kind": "property", "property_id": "p", "value_state": "unset"]), .property(propertyID: "p", value: nil, state: "unset"))
    }

    func testDragMath() {
        let positions: [String: Double] = ["a": 1, "b": 2, "c": 3]
        XCTAssertEqual(IssueListDrag.position(of: "x", in: ["x", "a", "b"], positions: positions), 0)
        XCTAssertEqual(IssueListDrag.position(of: "x", in: ["a", "x", "b"], positions: positions), 1.5)
        XCTAssertEqual(IssueListDrag.position(of: "x", in: ["a", "b", "x"], positions: positions), 3)
        XCTAssertEqual(IssueListDrag.anchors(of: "x", in: ["a", "x", "b"]).before, "a")
        XCTAssertEqual(IssueListDrag.anchors(of: "x", in: ["a", "x", "b"]).after, "b")
        XCTAssertEqual(IssueListDrag.insertByPosition(["a", "c"], "x", position: 2.5, positions: positions), ["a", "x", "c"])
        XCTAssertEqual(IssueListDrag.move(["a", "b", "c"], "c", before: "a"), ["c", "a", "b"])
        XCTAssertEqual(IssueListDrag.move(["a", "b", "c"], "a", before: nil), ["b", "c", "a"])
    }

    func testDescriptionPreview() {
        let md = "# Title\n\nSee [docs](https://x.y/a_(b)) and ![img](u.png) **bold** \\[x\\]<!-- multica:channel-media:123e4567-e89b-12d3-a456-426614174000 -->"
        XCTAssertEqual(IssueListText.descriptionPreview(md), "Title See docs and bold [x]")
        XCTAssertEqual(IssueListText.descriptionPreview(String(repeating: "a", count: 400)).count, 300)
    }

    func testRowsDecodeKeepsPropertyBag() throws {
        let json = """
        {"query_fingerprint":"f","group_key":"status:todo","total":1,"branch_total":1,"next_cursor":null,
         "rows":[{"issue":{"id":"i","number":1,"identifier":"MUL-1","title":"T","status":"todo","priority":"high",
           "properties":{"p":"o1"},"duplicate_of":{"id":"d","identifier":"MUL-9"}},"direct_child_count":2}]}
        """
        let page = try JSONCoders.decoder.decode(IssueListRowsPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.rows.first?.issue.priority, .high)
        XCTAssertEqual(page.rows.first?.properties["p"], "o1")
        XCTAssertEqual(page.rows.first?.duplicateOfIdentifier, "MUL-9")
        XCTAssertEqual(page.rows.first?.directChildCount, 2)
        XCTAssertNil(page.nextCursor)
    }
}

final class IssueListStoreRevisionTests: XCTestCase {
    @MainActor func testChangeRevisionOnlyMovesOnRealChanges() {
        let s = IssueStore()
        var a = Issue(id: "a", number: 1, identifier: "MUL-1", title: "A", revision: 1)
        s.upsert(a)
        let afterInsert = s.changeRevision
        s.upsert(a)
        XCTAssertEqual(s.changeRevision, afterInsert, "re-absorbing an identical row must not look like a change")
        a.title = "A2"
        a.revision = 2
        s.upsert(a)
        XCTAssertEqual(s.changeRevision, afterInsert + 1)
        s.setLabels("a", [])
        s.remove("a")
        XCTAssertEqual(s.changeRevision, afterInsert + 3)
        let activity = s.activityRevision
        s.applyTaskLifecycle(TaskLifecycle(taskID: "t", agentID: "g", issueID: "a", status: .running))
        XCTAssertEqual(s.activityRevision, activity + 1)
    }
}

final class IssueListClientFilterTests: XCTestCase {
    private func item(_ id: String, status: IssueStatusKey = .todo, priority: IssuePriority = .none, assignee: ActorRef? = nil,
                      project: String? = nil, start: String? = nil, due: String? = nil, props: [String: JSONValue] = [:]) -> IssueListClientFilter.Item {
        var i = Issue(id: id, number: 1, identifier: id, title: id, status: status, priority: priority, assignee: assignee)
        i.projectID = project
        i.startDate = start
        i.dueDate = due
        return IssueListClientFilter.Item(issue: i, properties: props)
    }

    func testAssigneeAndProjectSemantics() {
        let items = [item("a", assignee: ActorRef(type: "agent", id: "x"), project: "p"), item("b"), item("c", assignee: ActorRef(type: "member", id: "m"))]
        var s = IssueListViewState()
        s.includeNoAssignee = true
        XCTAssertEqual(IssueListClientFilter.apply(items, state: s, ignoreProjects: false, runningIssueIDs: nil, projectStatusByID: nil).map(\.issue.id), ["b"])
        s.toggleAssigneeFilter(IssueListActorFilter(type: "agent", id: "x"))
        XCTAssertEqual(IssueListClientFilter.apply(items, state: s, ignoreProjects: false, runningIssueIDs: nil, projectStatusByID: nil).map(\.issue.id), ["a", "b"])
        var p = IssueListViewState()
        p.includeNoProject = true
        XCTAssertEqual(IssueListClientFilter.apply(items, state: p, ignoreProjects: false, runningIssueIDs: nil, projectStatusByID: nil).map(\.issue.id), ["b", "c"])
        XCTAssertEqual(IssueListClientFilter.apply(items, state: p, ignoreProjects: true, runningIssueIDs: nil, projectStatusByID: nil).count, 3)
        var ps = IssueListViewState()
        ps.projectStatusFilters = ["completed"]
        XCTAssertEqual(IssueListClientFilter.apply(items, state: ps, ignoreProjects: false, runningIssueIDs: nil, projectStatusByID: nil).count, 3,
                       "without the project catalog the predicate is a no-op")
        XCTAssertEqual(IssueListClientFilter.apply(items, state: ps, ignoreProjects: false, runningIssueIDs: nil, projectStatusByID: ["p": "completed"]).map(\.issue.id), ["a"])
        var w = IssueListViewState()
        w.agentRunningFilter = true
        XCTAssertEqual(IssueListClientFilter.apply(items, state: w, ignoreProjects: false, runningIssueIDs: ["c"], projectStatusByID: nil).map(\.issue.id), ["c"])
    }

    func testPropertyMatching() {
        XCTAssertTrue(IssueListClientFilter.matchesProperties(["n": 3.5], ["n": [.equals("3.50")]]))
        XCTAssertTrue(IssueListClientFilter.matchesProperties(["m": ["a", "b"]], ["m": [.equals("b")]]))
        XCTAssertTrue(IssueListClientFilter.matchesProperties(["c": true], ["c": [.equals("true")]]))
        XCTAssertTrue(IssueListClientFilter.matchesProperties([:], ["x": [.equals(IssueListPropertyFilterValue.noValue)]]))
        XCTAssertFalse(IssueListClientFilter.matchesProperties(["x": "__none__"], ["x": [.equals(IssueListPropertyFilterValue.noValue)]]),
                       "the sentinel never matches a set value")
        XCTAssertTrue(IssueListClientFilter.matchesOperator("Hello", op: "contains", operand: "ELL"))
        XCTAssertFalse(IssueListClientFilter.matchesOperator("Hello", op: "contains", operand: ""))
        XCTAssertFalse(IssueListClientFilter.matchesOperator("5", op: "gt", operand: "3"), "numeric ops only match numbers")
        XCTAssertTrue(IssueListClientFilter.matchesOperator(5, op: "gte", operand: "5"))
        XCTAssertTrue(IssueListClientFilter.matchesOperator("2026-01-01", op: "before", operand: "2026-02-01"))
    }

    func testGanttRowsAndSort() {
        let items = [
            item("late", due: "2026-05-01"), item("none"), item("early", start: "2026-01-01", due: "2026-01-10"),
            item("done", status: .done, start: "2026-02-01"),
        ]
        let canvas = IssueListClientFilter.ganttRows(items, showCompleted: false, catalog: .builtIn)
        XCTAssertEqual(canvas.map(\.issue.id), ["late", "early"])
        XCTAssertEqual(IssueListClientFilter.ganttRows(items, showCompleted: true, catalog: .builtIn).count, 3)
        let byStart = IssueListClientFilter.sort(canvas, field: "start_date", direction: .asc, statusOrder: nil)
        XCTAssertEqual(byStart.map(\.issue.id), ["early", "late"], "missing dates sort last")
        let byPriority = IssueListClientFilter.sort([item("l", priority: .low), item("u", priority: .urgent), item("n")], field: "priority",
                                                    direction: .asc, statusOrder: nil)
        XCTAssertEqual(byPriority.map(\.issue.id), ["u", "l", "n"])
        let byProp = IssueListClientFilter.sort([item("x", props: ["e": 2]), item("y"), item("z", props: ["e": 5])], field: "property:e",
                                                direction: .desc, statusOrder: nil)
        XCTAssertEqual(byProp.map(\.issue.id), ["z", "x", "y"], "missing values sort last in both directions")
    }
}
