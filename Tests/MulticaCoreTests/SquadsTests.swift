import XCTest
@testable import MulticaCore

final class SquadsTests: XCTestCase {
    private func squad(_ id: String, name: String, leader: String = "a1", creator: String = "u1",
                       count: Int? = nil, preview: Int = 0, created: String = "2026-01-01T00:00:00Z") -> Squad {
        Squad(id: id, name: name, leaderId: leader, creatorId: creator, createdAt: created, memberCount: count,
              memberPreview: (0..<preview).map { SquadMemberPreview(memberType: "agent", memberId: "m\($0)") })
    }

    func testViewStateDefaultsAndDecoding() throws {
        var s = SquadsViewState()
        XCTAssertEqual(s.scope, .mine)
        XCTAssertEqual(s.sortField, .name)
        XCTAssertEqual(s.sortDirection, .asc)
        XCTAssertFalse(s.isVisible(.created))
        XCTAssertTrue(s.isVisible(.creator))
        s.toggleSort(.members)
        XCTAssertEqual(s.sortDirection, .desc)
        s.toggleSort(.members)
        XCTAssertEqual(s.sortDirection, .asc)
        s.setSortField(.created)
        XCTAssertEqual(s.sortDirection, .desc)
        s.toggleFilter(\.leaders, "a1")
        s.toggleFilter(\.creators, "u1")
        XCTAssertEqual(s.filters.activeCount, 2)

        let decoded = try JSONDecoder().decode(SquadsViewState.self, from: Data(#"{"scope":"all","filters":{"leaders":["x"]}}"#.utf8))
        XCTAssertEqual(decoded.scope, .all)
        XCTAssertEqual(decoded.filters.leaders, ["x"])
        XCTAssertEqual(decoded.hiddenColumns, [.created])
    }

    func testScopeFilterAndSort() {
        let list = [
            squad("1", name: "Bravo", leader: "a1", creator: "me", count: 3, created: "2026-02-01T00:00:00Z"),
            squad("2", name: "alpha", leader: "a2", creator: "other", preview: 3, created: "2026-03-01T00:00:00Z"),
            squad("3", name: "Charlie", leader: "a1", creator: "me", count: 5, created: "2026-01-01T00:00:00Z"),
        ]
        XCTAssertEqual(SquadsListQuery.scopeCounts(list, userID: "me"), [.mine: 2, .all: 3])
        XCTAssertEqual(SquadsListQuery.scopeCounts(list, userID: nil), [.mine: 0, .all: 3])
        XCTAssertEqual(SquadsListQuery.scopeRows(list, scope: .mine, userID: "me").map(\.id), ["1", "3"])
        XCTAssertEqual(SquadsListQuery.scopeRows(list, scope: .mine, userID: nil), [])

        let leaders = SquadsListQuery.options(list, key: \.leaderId) { $0 == "a1" ? "Leader One" : nil }
        XCTAssertEqual(leaders.map(\.name), ["Leader One", "a2"])
        XCTAssertEqual(leaders.map(\.count), [2, 1])

        func ids(_ f: SquadsSortField, _ d: SquadsSortDirection, _ filters: SquadsFilters = SquadsFilters()) -> [String] {
            SquadsListQuery.rows(list, filters: filters, sortField: f, direction: d).map(\.id)
        }
        XCTAssertEqual(ids(.name, .asc), ["2", "1", "3"])
        XCTAssertEqual(ids(.members, .desc), ["3", "2", "1"])
        XCTAssertEqual(ids(.members, .asc), ["2", "1", "3"])
        XCTAssertEqual(ids(.created, .desc), ["2", "1", "3"])
        XCTAssertEqual(ids(.name, .asc, SquadsFilters(leaders: ["a1"])), ["1", "3"])
        XCTAssertEqual(ids(.name, .asc, SquadsFilters(leaders: ["a1"], creators: ["other"])), [])
    }

    func testManagementAndInitials() {
        let s = squad("1", name: "Frontend team", creator: "u1")
        XCTAssertTrue(SquadsListQuery.canManage(s, userID: "u1", isWorkspaceAdmin: false))
        XCTAssertTrue(SquadsListQuery.canManage(s, userID: "u2", isWorkspaceAdmin: true))
        XCTAssertFalse(SquadsListQuery.canManage(s, userID: "u2", isWorkspaceAdmin: false))
        XCTAssertFalse(SquadsListQuery.canManage(s, userID: nil, isWorkspaceAdmin: false))
        XCTAssertEqual(SquadsText.initials("Frontend team"), "FT")
        XCTAssertEqual(SquadsText.initials("a b c"), "AB")
        XCTAssertEqual(SquadsText.initials(""), "")
    }

    func testAvatarCropGeometry() {
        let image = CGSize(width: 1000, height: 500)
        XCTAssertEqual(SquadsAvatarCrop.rotatedSize(image, quarterTurns: 1), CGSize(width: 500, height: 1000))
        XCTAssertEqual(SquadsAvatarCrop.rotatedSize(image, quarterTurns: 2), image)
        XCTAssertEqual(SquadsAvatarCrop.scale(image: image, viewport: 250, zoom: 1), 0.5)
        XCTAssertEqual(SquadsAvatarCrop.scale(image: image, viewport: 250, zoom: 9), 1.5)
        // Centered at zoom 1 the crop is the centered short-side square.
        XCTAssertEqual(SquadsAvatarCrop.cropRect(image: image, viewport: 250, zoom: 1, offset: .zero),
                       CGRect(x: 250, y: 0, width: 500, height: 500))
        // Panning right shows the left part; vertical overhang is zero.
        let clamped = SquadsAvatarCrop.clampOffset(CGSize(width: 1000, height: 40), image: image, viewport: 250, zoom: 1)
        XCTAssertEqual(clamped, CGSize(width: 125, height: 0))
        XCTAssertEqual(SquadsAvatarCrop.cropRect(image: image, viewport: 250, zoom: 1, offset: CGSize(width: 1000, height: 0)),
                       CGRect(x: 0, y: 0, width: 500, height: 500))
        // Zoom 2 halves the visible side.
        XCTAssertEqual(SquadsAvatarCrop.cropRect(image: image, viewport: 250, zoom: 2, offset: .zero),
                       CGRect(x: 375, y: 125, width: 250, height: 250))
    }

    func testCreateSelection() {
        var sel = SquadsCreateSelection()
        let a = SquadsCreateSelection.Pick(type: "agent", id: "a1", name: "A")
        let m = SquadsCreateSelection.Pick(type: "member", id: "a1", name: "M")
        sel.toggle(a)
        sel.toggle(m)
        XCTAssertEqual(sel.members.count, 2)
        sel.setLeader("a1")
        XCTAssertEqual(sel.members, [m])
        sel.setLeader("a2")
        XCTAssertEqual(sel.members, [m])
        sel.toggle(m)
        XCTAssertTrue(sel.members.isEmpty)
    }
}
