import XCTest
@testable import MulticaCore

final class ProjectsTests: XCTestCase {
    private func project(_ id: String, title: String, status: String = "planned", priority: String = "none",
                         lead: (String, String)? = nil, issues: Int = 0, done: Int = 0,
                         created: String = "2026-01-01T00:00:00Z") -> Project {
        Project(id: id, title: title, status: status, priority: priority, leadType: lead?.0, leadId: lead?.1,
                createdAt: created, issueCount: issues, doneCount: done)
    }

    func testIssueMetrics() {
        let m = ProjectsIssueMetrics(project("p", title: "A", issues: 3, done: 2))
        XCTAssertEqual(m.totalCount, 3)
        XCTAssertEqual(m.completedCount, 2)
        XCTAssertEqual(m.percent, 67)
        XCTAssertEqual(ProjectsIssueMetrics(totalCount: 8, completedCount: 1).percent, 13)
        XCTAssertEqual(ProjectsIssueMetrics(totalCount: 0, completedCount: 0).percent, 0)
        XCTAssertEqual(ProjectsIssueMetrics(totalCount: 0, completedCount: 0).sortKey, -1)
    }

    func testPatchBodyAndApply() {
        let p = project("p", title: "A", lead: ("member", "u1"))
        let clear = ProjectsPatch(description: .some(nil), lead: .some(nil))
        XCTAssertEqual(clear.body, ["description": .null, "lead_type": .null, "lead_id": .null])
        let cleared = clear.applied(to: p)
        XCTAssertNil(cleared.leadId)
        XCTAssertNil(cleared.leadType)
        let set = ProjectsPatch(status: "paused", lead: ActorRef(type: "agent", id: "a1"), dueDate: "2026-11-01")
        XCTAssertEqual(set.body, ["status": "paused", "lead_type": "agent", "lead_id": "a1", "due_date": "2026-11-01"])
        let applied = set.applied(to: p)
        XCTAssertEqual(applied.status, "paused")
        XCTAssertEqual(applied.leadId, "a1")
        XCTAssertEqual(applied.dueDate, "2026-11-01")
        XCTAssertEqual(applied.title, "A")
        XCTAssertEqual(ProjectsPatch().body, [:])
    }

    func testViewStateDefaultsAndSortToggling() {
        var s = ProjectsViewState()
        XCTAssertEqual(s.viewMode, .compact)
        XCTAssertEqual(s.sortField, .created)
        XCTAssertEqual(s.sortDirection, .desc)
        XCTAssertFalse(s.isVisible(.issues))
        s.toggleSort(.created)
        XCTAssertEqual(s.sortDirection, .asc)
        s.toggleSort(.name)
        XCTAssertEqual(s.sortField, .name)
        XCTAssertEqual(s.sortDirection, .asc)
        s.setSortField(.name)
        XCTAssertEqual(s.sortDirection, .asc)
        s.setSortField(.priority)
        XCTAssertEqual(s.sortDirection, .desc)
        s.toggleColumn(.issues)
        XCTAssertTrue(s.isVisible(.issues))
        s.toggleFilter(\.statuses, "paused")
        s.toggleFilter(\.leads, "agent:a1")
        XCTAssertEqual(s.filters.activeCount, 2)
        s.toggleFilter(\.statuses, "paused")
        XCTAssertEqual(s.filters.activeCount, 1)
        s.clearFilters()
        XCTAssertEqual(s.filters, ProjectsFilters())
    }

    func testViewStateDecodesPartialAndUnknownValues() throws {
        let json = #"{"viewMode":"comfortable","sortField":"bogus","hiddenColumns":["lead","nope"],"filters":{"statuses":["paused"]}}"#
        let s = try JSONDecoder().decode(ProjectsViewState.self, from: Data(json.utf8))
        XCTAssertEqual(s.viewMode, .comfortable)
        XCTAssertEqual(s.sortField, .created)
        XCTAssertEqual(s.hiddenColumns, [.lead])
        XCTAssertEqual(s.filters.statuses, ["paused"])
        XCTAssertEqual(s.filters.leads, [])
        let round = try JSONDecoder().decode(ProjectsViewState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(round, s)
    }

    func testFilteringAndLeadOptions() {
        let list = [
            project("1", title: "Alpha", status: "planned", priority: "high", lead: ("member", "u1")),
            project("2", title: "Beta", status: "paused", priority: "low", lead: ("agent", "a1")),
            project("3", title: "Gamma", status: "paused", lead: ("member", "u1")),
            project("4", title: "Delta"),
        ]
        let opts = ProjectsListQuery.leadOptions(list)
        XCTAssertEqual(opts.map(\.value), ["member:u1", "agent:a1"])
        XCTAssertEqual(opts.map(\.count), [2, 1])

        var f = ProjectsFilters(statuses: ["paused"])
        XCTAssertEqual(ProjectsListQuery.visible(list, search: "", filters: f, sortField: .name, direction: .asc).map(\.id), ["2", "3"])
        f.leads = ["member:u1"]
        XCTAssertEqual(ProjectsListQuery.visible(list, search: "", filters: f, sortField: .name, direction: .asc).map(\.id), ["3"])
        XCTAssertEqual(ProjectsListQuery.visible(list, search: " alp ", filters: ProjectsFilters(), sortField: .name, direction: .asc).map(\.id), ["1"])
        let noLead = ProjectsFilters(leads: ["member:u1"])
        XCTAssertFalse(ProjectsListQuery.visible(list, search: "", filters: noLead, sortField: .name, direction: .asc).contains { $0.id == "4" })
    }

    func testSortingMatchesUpstreamTieBreaks() {
        let list = [
            project("b", title: "Bravo", status: "paused", priority: "high", issues: 4, done: 2, created: "2026-02-01T00:00:00Z"),
            project("a", title: "Alpha", status: "planned", priority: "high", issues: 0, created: "2026-03-01T00:00:00Z"),
            project("c", title: "Charlie", status: "planned", priority: "urgent", issues: 2, done: 2, created: "2026-01-01T00:00:00Z"),
        ]
        func ids(_ f: ProjectsSortField, _ d: ProjectsSortDirection) -> [String] {
            ProjectsListQuery.sorted(list, by: f, direction: d).map(\.id)
        }
        XCTAssertEqual(ids(.name, .asc), ["a", "b", "c"])
        XCTAssertEqual(ids(.name, .desc), ["c", "b", "a"])
        // Ties fall back to ascending title regardless of direction.
        XCTAssertEqual(ids(.priority, .desc), ["c", "a", "b"])
        XCTAssertEqual(ids(.priority, .asc), ["a", "b", "c"])
        XCTAssertEqual(ids(.status, .asc), ["a", "c", "b"])
        XCTAssertEqual(ids(.progress, .desc), ["c", "b", "a"])
        XCTAssertEqual(ids(.created, .desc), ["a", "b", "c"])
        XCTAssertEqual(ids(.created, .asc), ["c", "b", "a"])
    }

    func testRelativeDate() {
        let now = Timestamp.parse("2026-10-12T12:00:00Z")!
        XCTAssertEqual(ProjectsRelativeDate.of("2026-10-12T01:00:00Z", now: now), .today)
        XCTAssertEqual(ProjectsRelativeDate.of("2026-10-13T01:00:00Z", now: now), .today)
        XCTAssertEqual(ProjectsRelativeDate.of("2026-10-11T11:00:00Z", now: now), .oneDay)
        XCTAssertEqual(ProjectsRelativeDate.of("2026-10-02T12:00:00Z", now: now), .days(10))
        XCTAssertEqual(ProjectsRelativeDate.of("2026-08-01T12:00:00Z", now: now), .months(2))
    }

    func testGitRefValidation() {
        for ok in ["", "   ", "main", "release/2026-09", "team/alice/feat/new-thing", "v1.2.3", "a1b2c3d",
                   "5e0b1cfa0a7d6a1a0f4b3f2e1d0c9b8a7f6e5d4c", "release.2026.09", "fix/MUL-7504-pin-ref"] {
            XCTAssertNil(ProjectsGitRef.validate(ok), ok)
        }
        for bad in ["my branch", "main~1", "main^", "origin:main", "main?", "refs/heads/*", "feat\\thing", "ma\nin"] {
            XCTAssertEqual(ProjectsGitRef.validate(bad), .invalidCharacters, bad)
        }
        for bad in ["main..dev", "main@{1}", "@", "/main", "main/", "feat//thing", ".hidden", "main.", "main.lock",
                    "feat.lock/thing", "feat/.hidden"] {
            XCTAssertEqual(ProjectsGitRef.validate(bad), .invalidFormat, bad)
        }
        XCTAssertNil(ProjectsGitRef.validate(String(repeating: "a", count: 255)))
        XCTAssertEqual(ProjectsGitRef.validate(String(repeating: "a", count: 256)), .tooLong)
    }

    func testCommitShaDetection() {
        XCTAssertTrue(ProjectsGitRef.looksLikeCommitSha("5e0b1cfa0a7d6a1a0f4b3f2e1d0c9b8a7f6e5d4c"))
        XCTAssertTrue(ProjectsGitRef.looksLikeCommitSha("5E0B1CFA0A7D6A1A0F4B3F2E1D0C9B8A7F6E5D4C"))
        XCTAssertTrue(ProjectsGitRef.looksLikeCommitSha(String(repeating: "a", count: 64)))
        XCTAssertTrue(ProjectsGitRef.looksLikeCommitSha("  " + String(repeating: "b", count: 40) + "  "))
        for v in ["main", "release/2026-09", "v1.2.3", "a1b2c3d", "deadbeef", String(repeating: "a", count: 39),
                  String(repeating: "a", count: 41), String(repeating: "g", count: 40), ""] {
            XCTAssertFalse(ProjectsGitRef.looksLikeCommitSha(v), v)
        }
        XCTAssertTrue(ProjectsGitRef.hasError("5e0b1cfa0a7d6a1a0f4b3f2e1d0c9b8a7f6e5d4c"))
        XCTAssertFalse(ProjectsGitRef.hasError("main"))
    }

    func testSplitGithubURL() {
        func split(_ s: String) -> [String?] { let r = ProjectsGitRef.splitGithubURL(s); return [r.url, r.ref] }
        XCTAssertEqual(split("https://github.com/multica-ai/multica/tree/main"), ["https://github.com/multica-ai/multica", "main"])
        XCTAssertEqual(split("https://github.com/multica-ai/multica/tree/release/2026-09"), ["https://github.com/multica-ai/multica", "release/2026-09"])
        XCTAssertEqual(split("https://github.com/multica-ai/multica.git/tree/main/"), ["https://github.com/multica-ai/multica", "main"])
        XCTAssertEqual(split("  https://github.com/o/r/tree/dev  "), ["https://github.com/o/r", "dev"])
        for url in ["https://github.com/multica-ai/multica", "https://github.com/multica-ai/multica.git",
                    "git@github.com:multica-ai/multica.git", "https://gitlab.com/owner/repo/tree/main",
                    "https://github.com/multica-ai/multica/blob/main/README.md", "https://github.com/multica-ai/multica/pull/8572",
                    "https://github.com/multica-ai/multica/tree/main..dev"] {
            XCTAssertEqual(split(url), [url, nil], url)
        }
    }

    func testGithubShortLabel() {
        XCTAssertEqual(ProjectsGitRef.githubShortLabel("https://github.com/owner/repo"), "owner/repo")
        XCTAssertEqual(ProjectsGitRef.githubShortLabel("https://www.github.com/owner/repo/tree/x"), "owner/repo")
        XCTAssertEqual(ProjectsGitRef.githubShortLabel("ssh://git@github.com/owner/repo.git"), "owner/repo")
        XCTAssertEqual(ProjectsGitRef.githubShortLabel("git@github.com:owner/repo.git"), "owner/repo")
        XCTAssertEqual(ProjectsGitRef.githubShortLabel("https://gitlab.com/owner/repo"), "https://gitlab.com/owner/repo")
        XCTAssertEqual(ProjectsGitRef.githubShortLabel("not a url"), "not a url")
        let long = "org/" + String(repeating: "x", count: 50) + "-alpha"
        let label = ProjectsGitRef.midTruncate(long)
        XCTAssertEqual(label.count, 40)
        XCTAssertTrue(label.hasSuffix("-alpha"))
        XCTAssertTrue(label.contains("…"))
    }

    func testResourceRefs() {
        let local = ProjectResource(resourceType: "local_directory",
                                    resourceRef: ["local_path": "/Users/me/code", "daemon_id": "d1", "label": "code", "execution_mode": "worktree", "extra": 1])
        XCTAssertEqual(local.projectsLocalRef?.executionMode, .worktree)
        XCTAssertEqual(local.projectsLocalDirectoryLabel, "code")
        XCTAssertNil(local.projectsGithubRef)
        var labelled = local
        labelled.label = "  Mine "
        XCTAssertEqual(labelled.projectsLocalDirectoryLabel, "Mine")
        let bare = ProjectResource(resourceType: "local_directory", resourceRef: ["local_path": "/tmp/x", "daemon_id": "d1", "execution_mode": "future"])
        XCTAssertEqual(bare.projectsLocalDirectoryLabel, "/tmp/x")
        XCTAssertEqual(bare.projectsLocalRef?.executionMode, .inPlace)

        let edited = ProjectsResourceRefs.setting(local.resourceRef, "execution_mode", "in_place")
        XCTAssertEqual(edited["extra"], 1)
        XCTAssertEqual(edited["execution_mode"]?.stringValue, "in_place")
        let gh = ProjectsResourceRefs.github(url: "https://github.com/o/r", ref: "dev")
        XCTAssertEqual(ProjectsResourceRefs.setting(gh, "ref", nil), ["url": "https://github.com/o/r"])
        XCTAssertEqual(ProjectsResourceRefs.github(url: "u", ref: ""), ["url": "u"])
        XCTAssertEqual(ProjectsResourceRefs.localDirectory(localPath: "/p", daemonID: "d", label: nil, mode: .inPlace),
                       ["local_path": "/p", "daemon_id": "d", "execution_mode": "in_place"])
        let ghRes = ProjectResource(resourceType: "github_repo", resourceRef: gh)
        XCTAssertEqual(ghRes.projectsGithubRef, ProjectsGithubRef(url: "https://github.com/o/r", ref: "dev"))
    }

    func testWorktreeCapabilityAndModeSelection() {
        let capable: [String: JSONValue] = ["capabilities": ["skill-bundles-v1", "local-worktree-v1"]]
        let incapable: [String: JSONValue] = ["cli_version": "9.9.9"]
        func row(_ m: [String: JSONValue], _ seen: String?) -> RuntimeDeviceRecord {
            RuntimeDeviceRecord(daemonId: "d1", metadata: m, lastSeenAt: seen)
        }
        XCTAssertTrue(ProjectsResourceRefs.runtimeAdvertisesLocalWorktree([row(capable, "2026-08-13T00:00:00Z")], daemonID: "d1"))
        XCTAssertFalse(ProjectsResourceRefs.runtimeAdvertisesLocalWorktree([row(capable, nil)], daemonID: "d2"))
        XCTAssertFalse(ProjectsResourceRefs.runtimeAdvertisesLocalWorktree([row(capable, nil)], daemonID: nil))
        XCTAssertFalse(ProjectsResourceRefs.runtimeAdvertisesLocalWorktree(
            [row(capable, "2026-08-01T00:00:00Z"), row(incapable, "2026-08-13T00:00:00Z")], daemonID: "d1"))
        XCTAssertTrue(ProjectsResourceRefs.runtimeAdvertisesLocalWorktree(
            [row(incapable, nil), row(capable, "2026-08-13T00:00:00Z")], daemonID: "d1"))
        XCTAssertFalse(ProjectsResourceRefs.runtimeAdvertisesLocalWorktree([row(["capabilities": "local-worktree-v1"], nil)], daemonID: "d1"))

        XCTAssertEqual(ProjectsWorktreeBlocker.reason(isGitRepo: false, serverValidates: true), .notGit)
        XCTAssertEqual(ProjectsWorktreeBlocker.reason(isGitRepo: nil, serverValidates: false), .serverOutdated)
        XCTAssertNil(ProjectsWorktreeBlocker.reason(isGitRepo: nil, serverValidates: true))

        XCTAssertEqual(ProjectsResourceRefs.effectiveMode(chosen: nil, isGitRepo: true, advertises: true, blocker: nil), .worktree)
        XCTAssertEqual(ProjectsResourceRefs.effectiveMode(chosen: nil, isGitRepo: nil, advertises: true, blocker: nil), .inPlace)
        XCTAssertEqual(ProjectsResourceRefs.effectiveMode(chosen: nil, isGitRepo: true, advertises: false, blocker: nil), .inPlace)
        XCTAssertEqual(ProjectsResourceRefs.effectiveMode(chosen: .worktree, isGitRepo: false, advertises: true, blocker: .notGit), .inPlace)
        XCTAssertEqual(ProjectsResourceRefs.effectiveMode(chosen: .inPlace, isGitRepo: true, advertises: true, blocker: nil), .inPlace)
    }

    func testLocalDirectoryValidation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("projects-tests-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo/sub")
        let plain = root.appendingPathComponent("plain")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)
        defer { try? fm.removeItem(at: root) }

        XCTAssertEqual(ProjectsLocalDirectory.validate("relative/path"), .failed(.notAbsolute))
        XCTAssertEqual(ProjectsLocalDirectory.validate(""), .failed(.notAbsolute))
        XCTAssertEqual(ProjectsLocalDirectory.validate(root.appendingPathComponent("missing").path), .failed(.notFound))
        XCTAssertEqual(ProjectsLocalDirectory.validate(file.path), .failed(.notADirectory))
        XCTAssertEqual(ProjectsLocalDirectory.validate(repo.path), .ok(isGitRepo: true))
        XCTAssertEqual(ProjectsLocalDirectory.validate(plain.path), .ok(isGitRepo: false))
    }

    func testPinyinMatching() {
        let s = ["li", "yun", "long"]
        XCTAssertTrue(ProjectsPinyin.matches(syllables: s, query: "liyunlong"))
        XCTAssertTrue(ProjectsPinyin.matches(syllables: s, query: "liyu"))
        XCTAssertTrue(ProjectsPinyin.matches(syllables: s, query: "lyl"))
        XCTAssertTrue(ProjectsPinyin.matches(syllables: s, query: "liyl"))
        XCTAssertTrue(ProjectsPinyin.matches(syllables: s, query: "liyunl"))
        XCTAssertFalse(ProjectsPinyin.matches(syllables: s, query: "yun"))
        XCTAssertFalse(ProjectsPinyin.matches(syllables: s, query: "lylx"))
        XCTAssertFalse(ProjectsPinyin.matches("Alpha", "alp"))
        XCTAssertTrue(ProjectsPinyin.matches("Alpha", ""))
        #if canImport(Darwin)
        XCTAssertTrue(ProjectsPinyin.matches("数据透明化", "sjtmh"))
        XCTAssertTrue(ProjectsPinyin.matches("李云龙", "liyl"))
        XCTAssertEqual(ProjectsPinyin.syllables(of: "绿"), ["lv"])
        #endif
    }
}
