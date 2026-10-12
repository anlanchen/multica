import XCTest
@testable import MulticaCore

final class AppRouteTests: XCTestCase {
    func testEveryRouteRoundTripsThroughItsPath() {
        let routes: [AppRoute] = [
            .issues, .issue("a b"), .projects, .project("p"), .autopilots, .autopilot("x"), .myIssues,
            .runtimes, .runtime("m"), .runtimeSettings(machineID: "m", runtimeID: "r"), .skills, .skill("s"),
            .agents, .newAgent, .newAgentManual, .newAgentAI, .newAgentAISession("sess"), .agent("ag"),
            .member("u"), .squads, .squad("q"), .inbox, .chat, .attachmentPreview("f"), .usage, .settings,
        ]
        for r in routes {
            XCTAssertEqual(AppRoute(relativePath: r.relativePath), r, r.relativePath)
            let parsed = AppRoute.parse(path: r.path(workspaceSlug: "acme"))
            XCTAssertEqual(parsed?.slug, "acme")
            XCTAssertEqual(parsed?.route, r)
        }
        XCTAssertEqual(AppRoute.issue("a b").relativePath, "issues/a%20b")
        XCTAssertEqual(AppRoute.parse(path: "/acme")?.route, .issues)
        XCTAssertEqual(AppRoute(relativePath: "chat?session=1"), .chat)
        XCTAssertNil(AppRoute(relativePath: "nope"))
    }

    func testSidebarPagesMatchUpstreamOrderAndIcons() {
        XCTAssertEqual(WorkspacePage.personal + WorkspacePage.work + WorkspacePage.aiTeam + WorkspacePage.utility, WorkspacePage.allCases)
        XCTAssertEqual(WorkspacePage.usage.icon, .barChart3)
        XCTAssertEqual(AppRoute.newAgentAISession("x").page, .agents)
        XCTAssertTrue(AppRoute.projects.isRoot)
        XCTAssertFalse(AppRoute.project("p").isRoot)
        XCTAssertEqual(RouteIconName.forAttachment("a.PNG"), .fileImage)
        XCTAssertEqual(RouteIconName.forAttachment("Makefile"), .file)
    }

    func testTabLocationURL() {
        let loc = TabLocation(.chat, query: ["session": "s 1", "agent": "a"])
        XCTAssertEqual(loc.relativeURL, "chat?agent=a&session=s%201")
        XCTAssertEqual(TabLocation(relativeURL: loc.relativeURL), loc)
    }
}

final class TabStoreTests: XCTestCase {
    @MainActor func makeStore() -> TabStore {
        var n = 0
        return TabStore { n += 1; return "t\(n)" }
    }

    @MainActor func testWorkspaceGroupsAreIndependentAndResume() async {
        let s = makeStore()
        s.switchWorkspace("a")
        XCTAssertEqual(s.tabs.map(\.route), [.issues])
        s.openTab(TabLocation(.inbox))
        s.switchWorkspace("b", open: TabLocation(.agents))
        XCTAssertEqual(s.tabs.map(\.route), [.agents])
        s.switchWorkspace("a")
        XCTAssertEqual(s.activeTab?.route, .inbox, "returns to the tab last used in that workspace")
        XCTAssertEqual(s.tabs.count, 2)
    }

    @MainActor func testOpenDedupesByResourceAndCloseReturnsToMostRecent() async {
        let s = makeStore()
        s.switchWorkspace("a")                       // t1 issues
        let list = s.activeTab!.id
        s.openTab(TabLocation(.projects))            // t2
        s.switchWorkspace("a")
        s.setActiveTab(list)
        let detail = s.openTab(TabLocation(.issue("i1")))!  // t3, opened from the list
        XCTAssertEqual(s.openTab(TabLocation(.issue("i1"), query: ["x": "1"])), detail)
        XCTAssertEqual(s.tabs.count, 3)
        XCTAssertEqual(s.activeLocation?.query, ["x": "1"])
        s.closeTab(detail)
        XCTAssertEqual(s.activeTab?.id, list, "closing goes back to the list, not the positional neighbour")
    }

    @MainActor func testLastTabCloseReseedsDefault() async {
        let s = makeStore()
        s.switchWorkspace("a", open: TabLocation(.usage))
        s.closeActiveTab()
        XCTAssertEqual(s.tabs.map(\.route), [.issues])
    }

    @MainActor func testPerTabHistory() async {
        let s = makeStore()
        s.switchWorkspace("a")
        s.navigate(TabLocation(.issue("1")))
        s.navigate(TabLocation(.issue("2")))
        XCTAssertTrue(s.activeTab!.canGoBack)
        s.goBack()
        XCTAssertEqual(s.activeTab?.route, .issue("1"))
        s.navigate(TabLocation(.projects))
        XCTAssertFalse(s.activeTab!.canGoForward, "a push truncates forward history")
        XCTAssertEqual(s.activeTab?.history.map(\.route), [.issues, .issue("1"), .projects])
        s.setQuery("view", "v1")
        XCTAssertEqual(s.activeTab?.history.count, 3, "query changes replace in place")
        XCTAssertEqual(s.activeGroup?.browsingHistory.first?.route, .projects)
        XCTAssertEqual(s.activeGroup?.browsingHistory.filter { $0.route == .projects }.count, 1)
    }

    @MainActor func testPinnedTabsStayParkedAndFirst() async {
        let s = makeStore()
        s.switchWorkspace("a")
        let first = s.activeTab!.id
        let second = s.openTab(TabLocation(.inbox))!
        s.togglePin(second)
        XCTAssertEqual(s.tabs.map(\.id), [second, first])
        s.setActiveTab(second)
        s.navigate(TabLocation(.issue("9")))
        XCTAssertEqual(s.tabs.first { $0.id == second }?.route, .inbox, "pinned tab did not move")
        XCTAssertEqual(s.activeTab?.route, .issue("9"))
        s.moveTab(from: 2, to: 0)
        XCTAssertEqual(s.tabs.first?.id, second, "unpinned tab cannot cross into the pinned zone")
        s.closeOtherTabs(first)
        XCTAssertEqual(Set(s.tabs.map(\.id)), [second, first])
    }

    @MainActor func testSnapshotRoundTripAndValidation() async {
        let s = makeStore()
        var saved = Data()
        s.onChange = { saved = $0 }
        s.switchWorkspace("a")
        s.navigate(TabLocation(.issue("1")))
        s.setTitle("MUL-1 Fix it", for: s.activeTab!.id)
        s.setViewState("filter", "mine")
        s.switchWorkspace("b")
        let restored = makeStore()
        restored.restore(saved)
        XCTAssertEqual(restored.activeWorkspaceSlug, "b")
        restored.switchWorkspace("a")
        XCTAssertEqual(restored.activeTab?.title, "MUL-1 Fix it")
        XCTAssertEqual(restored.viewState("filter"), "mine")
        restored.validateWorkspaceSlugs(["a"])
        XCTAssertNil(restored.groups["b"])
        XCTAssertEqual(restored.activeWorkspaceSlug, "a")
    }
}
