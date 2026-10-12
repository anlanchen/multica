import XCTest
@testable import MulticaCore

final class SkillsOriginTests: XCTestCase {
    func origin(_ type: String, _ url: String?) -> SkillsOrigin {
        var o: [String: JSONValue] = ["type": .string(type)]
        if let url { o["source_url"] = .string(url) }
        return SkillsOrigin(config: ["origin": .object(o)])
    }

    func testReadsTypesAndFallsBackToManual() {
        XCTAssertEqual(SkillsOrigin(config: [:]).type, .manual)
        XCTAssertEqual(SkillsOrigin(config: ["origin": .object(["type": "weird"])]).type, .manual)
        let local = SkillsOrigin(config: ["origin": .object(["type": "runtime_local", "runtime_id": "r1", "provider": "claude"])])
        XCTAssertEqual(local.type, .runtimeLocal)
        XCTAssertEqual(local.runtimeID, "r1")
        XCTAssertEqual(local.provider, "claude")
    }

    func testLinkAcceptsOwnHostOnly() {
        let url = "https://github.com/anthropics/skills/tree/main/animations"
        XCTAssertEqual(origin("github", url).linkURL, url)
        XCTAssertEqual(origin("skills_sh", "https://skills.sh/a/b/c").linkURL, "https://skills.sh/a/b/c")
        XCTAssertEqual(origin("clawhub", "https://clawhub.ai/owner/slug").linkURL, "https://clawhub.ai/owner/slug")
        XCTAssertEqual(origin("github", "http://www.github.com/a/b").linkURL, "http://www.github.com/a/b")
        XCTAssertEqual(origin("github", "https://WWW.GITHUB.COM/a/b").linkURL, "https://WWW.GITHUB.COM/a/b")
        XCTAssertNil(origin("github", "https://evil.example/anthropics/skills").linkURL)
        XCTAssertNil(origin("github", "https://skills.sh/a/b/c").linkURL)
        XCTAssertNil(origin("clawhub", "https://github.com/a/b").linkURL)
        XCTAssertNil(origin("github", "https://github.com.evil.example/a/b").linkURL)
        XCTAssertNil(origin("github", "https://notgithub.com/a/b").linkURL)
    }

    func testLinkRejectsSchemesAndMalformed() {
        XCTAssertNil(origin("github", "javascript:alert(1)").linkURL)
        XCTAssertNil(origin("github", "ftp://github.com/a/b").linkURL)
        XCTAssertNil(origin("github", "not a url").linkURL)
        XCTAssertNil(origin("github", "github.com/a/b").linkURL)
        XCTAssertNil(origin("clawhub", "my-skill").linkURL)
        XCTAssertNil(origin("manual", "https://github.com/a/b").linkURL)
        XCTAssertNil(origin("runtime_local", "https://github.com/a/b").linkURL)
        XCTAssertNil(origin("github", nil).linkURL)
        XCTAssertNil(origin("github", "").linkURL)
    }

    func testRefreshable() {
        XCTAssertTrue(origin("github", "https://github.com/a/b").isRefreshable)
        XCTAssertTrue(origin("clawhub", "my-skill").isRefreshable)
        XCTAssertFalse(origin("github", nil).isRefreshable)
        XCTAssertFalse(origin("runtime_local", "x").isRefreshable)
    }

    func testPermissionsAndConflictDetection() {
        XCTAssertTrue(SkillsPermissions.canEdit(createdBy: "u2", userID: "u1", role: "admin"))
        XCTAssertTrue(SkillsPermissions.canEdit(createdBy: "u1", userID: "u1", role: "member"))
        XCTAssertFalse(SkillsPermissions.canEdit(createdBy: "u2", userID: "u1", role: "member"))
        XCTAssertFalse(SkillsPermissions.canEdit(createdBy: nil, userID: nil, role: nil))
        XCTAssertTrue(SkillsErrors.isNameConflict("HTTP 409"))
        XCTAssertTrue(SkillsErrors.isNameConflict("a skill with this name Already Exists"))
        XCTAssertFalse(SkillsErrors.isNameConflict("network down"))
        XCTAssertEqual(SkillsErrors.midTruncate("abcdefghij", maxLength: 5), "ab…ij")
    }
}

final class SkillsListTests: XCTestCase {
    func row(_ id: String, name: String = "review-helper", agents: [String] = [], createdBy: String? = nil,
             labels: [String]? = nil, origin: String? = nil, updated: String = "2026-01-01T00:00:00Z") -> SkillsListRow {
        var config: [String: JSONValue] = [:]
        if let origin { config["origin"] = .object(["type": .string(origin)]) }
        let skill = SkillSummary(id: id, name: name, config: config, createdBy: createdBy, createdAt: "2026-01-01T00:00:00Z",
                                 updatedAt: updated, labels: labels?.map { try! label($0) })
        return SkillsListRow(skill: skill, agents: agents.map { AgentRecord(id: $0, name: $0) })
    }

    func label(_ id: String) throws -> IssueLabel {
        try JSONCoders.decoder.decode(IssueLabel.self, from: Data(##"{"id":"\##(id)","name":"\##(id)","color":"#3b82f6"}"##.utf8))
    }

    func testLabelsDimension() {
        var f = SkillsListFilters()
        XCTAssertTrue(SkillsList.matches(row("a"), filters: f, query: ""))
        f.labels = ["l1"]
        XCTAssertFalse(SkillsList.matches(row("a"), filters: f, query: ""))
        XCTAssertFalse(SkillsList.matches(row("a", labels: []), filters: f, query: ""))
        XCTAssertTrue(SkillsList.matches(row("a", labels: ["l2", "l1"]), filters: f, query: ""))
        f.labels = ["l3", "l2"]
        XCTAssertTrue(SkillsList.matches(row("a", labels: ["l2"]), filters: f, query: ""), "OR within labels")
    }

    func testOtherDimensionsAndSearch() {
        var f = SkillsListFilters()
        XCTAssertFalse(SkillsList.matches(row("a", name: "Deploy"), filters: f, query: "rev"))
        XCTAssertTrue(SkillsList.matches(row("a", name: "Review"), filters: f, query: " REV "))
        f.toggle(.usage, "used")
        XCTAssertFalse(SkillsList.matches(row("a"), filters: f, query: ""))
        XCTAssertTrue(SkillsList.matches(row("a", agents: ["g"]), filters: f, query: ""))
        f = SkillsListFilters()
        f.toggle(.origins, "github")
        XCTAssertFalse(SkillsList.matches(row("a"), filters: f, query: ""))
        XCTAssertTrue(SkillsList.matches(row("a", origin: "github"), filters: f, query: ""))
        f = SkillsListFilters()
        f.toggle(.creators, "u1")
        XCTAssertFalse(SkillsList.matches(row("a"), filters: f, query: ""))
        XCTAssertTrue(SkillsList.matches(row("a", createdBy: "u1"), filters: f, query: ""))
        f.toggle(.creators, "u1")
        XCTAssertEqual(f.activeDimensionCount, 0)
    }

    func testSortAndViewState() {
        let rows = [row("a", name: "beta", agents: ["x"], updated: "2026-01-02T00:00:00Z"),
                    row("b", name: "Alpha", updated: "2026-01-03T00:00:00Z"),
                    row("c", name: "gamma", agents: ["x", "y"], updated: "2026-01-01T00:00:00Z")]
        XCTAssertEqual(SkillsList.sorted(rows, field: .name, direction: .asc).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(SkillsList.sorted(rows, field: .usedBy, direction: .desc).map(\.id), ["c", "a", "b"])
        XCTAssertEqual(SkillsList.sorted(rows, field: .updated, direction: .desc).map(\.id), ["b", "a", "c"])

        var v = SkillsViewState()
        XCTAssertEqual(v.sortField, .updated)
        XCTAssertFalse(v.isVisible(.source))
        v.toggleSort(.name)
        XCTAssertEqual(v.sortDirection, .asc)
        v.toggleSort(.name)
        XCTAssertEqual(v.sortDirection, .desc)
        v.setSortField(.name)
        XCTAssertEqual(v.sortDirection, .desc, "selecting the active field never flips")
        v.setSortField(.usedBy)
        XCTAssertEqual(v.sortDirection, .desc)
        v.toggleColumn(.source)
        XCTAssertTrue(v.isVisible(.source))
    }

    func testViewStateDecodesOldPayloads() throws {
        let old = Data(#"{"sortField":"name","sortDirection":"asc","filters":{"usage":["used"]}}"#.utf8)
        let v = try JSONCoders.decoder.decode(SkillsViewState.self, from: old)
        XCTAssertEqual(v.sortField, .name)
        XCTAssertEqual(v.hiddenColumns, [.source, .created])
        XCTAssertEqual(v.filters.usage, [.used])
        XCTAssertEqual(v.filters.labels, [])
        let roundTrip = try JSONCoders.decoder.decode(SkillsViewState.self, from: JSONCoders.encoder.encode(v))
        XCTAssertEqual(roundTrip, v)
    }

    func testAssignmentsSkipArchivedAndOptionsCount() {
        let active = AgentRecord(id: "a1", name: "A", skills: [AgentSkillSummary(id: "s1", name: "x", description: "")])
        let archived = AgentRecord(id: "a2", name: "B", skills: [AgentSkillSummary(id: "s1", name: "x", description: "")], archivedAt: "2026-01-01")
        XCTAssertEqual(SkillsList.assignments([active, archived])["s1"]?.map(\.id), ["a1"])
        let rows = SkillsList.buildRows(skills: [SkillSummary(id: "s1", createdBy: "u1"), SkillSummary(id: "s2", createdBy: "u2")],
                                        agents: [active, archived],
                                        members: [MemberWithUserRecord(userId: "u1", role: "member", name: "Me")],
                                        runtimes: [], userID: "u1")
        XCTAssertEqual(rows.map(\.canEdit), [true, false])
        let o = SkillsList.options(rows)
        XCTAssertEqual(o.usedCount, 1)
        XCTAssertEqual(o.unusedCount, 1)
        XCTAssertEqual(o.originCounts[.manual], 2)
        XCTAssertEqual(o.creators.map(\.member.userId), ["u1"])
    }
}

final class SkillsFilesTests: XCTestCase {
    func testTreeOrdering() {
        let tree = SkillsFiles.buildTree(["b.txt", "SKILL.md", "refs/z.md", "refs/a.md", "a.txt", "assets/x/y.json"])
        XCTAssertEqual(tree.map(\.path), ["SKILL.md", "assets", "refs", "a.txt", "b.txt"])
        XCTAssertEqual(tree[2].children.map(\.path), ["refs/a.md", "refs/z.md"])
        XCTAssertEqual(tree[1].children.first?.children.first?.path, "assets/x/y.json")
        XCTAssertTrue(tree[1].isDirectory)
    }

    func testPathValidation() {
        XCTAssertNil(SkillsFiles.validateNewPath("references/api.md", existing: ["notes.txt"]))
        XCTAssertEqual(SkillsFiles.validateNewPath("references", existing: ["references/api.md"]), .isDirectory)
        XCTAssertEqual(SkillsFiles.validateNewPath("notes.txt/extra.md", existing: ["notes.txt"]), .underFile)
        XCTAssertEqual(SkillsFiles.validateNewPath("SKILL.md", existing: []), .reserved)
        XCTAssertEqual(SkillsFiles.validateNewPath("/abs.md", existing: []), .absolute)
        XCTAssertEqual(SkillsFiles.validateNewPath("../escape.md", existing: []), .doubleDot)
        XCTAssertEqual(SkillsFiles.validateNewPath("notes.txt", existing: ["notes.txt"]), .exists)
        XCTAssertEqual(SkillsFiles.validateNewPath("  ", existing: []), .empty)
    }

    func testHighlightLanguage() {
        XCTAssertEqual(SkillsFiles.highlightLanguage(for: "scripts/run.py"), "py")
        XCTAssertEqual(SkillsFiles.highlightLanguage(for: "config.yml"), "yaml")
        XCTAssertEqual(SkillsFiles.highlightLanguage(for: "a/b.ts"), "ts")
        XCTAssertNil(SkillsFiles.highlightLanguage(for: "README.md"))
        XCTAssertNil(SkillsFiles.highlightLanguage(for: "LICENSE"))
        XCTAssertNil(SkillsFiles.highlightLanguage(for: ".env"))
        XCTAssertTrue(SkillsFiles.isMarkdown("a.mdx"))
    }
}

final class SkillsFrontmatterTests: XCTestCase {
    func testParsesScalarsAndStripsBody() {
        let raw = "---\nname: review-helper\ndescription: \"Reviews: code\"\nversion: 2\n---\n# Title\nBody"
        let p = SkillsFrontmatter.parse(raw)
        XCTAssertEqual(p.frontmatter?["name"], "review-helper")
        XCTAssertEqual(p.frontmatter?["description"], "Reviews: code")
        XCTAssertEqual(p.frontmatter?["version"], "2")
        XCTAssertEqual(p.body, "# Title\nBody")
    }

    func testBlockScalarsAndNoFrontmatter() {
        let raw = "---\nname: x\ndescription: |\n  Line one\n  Line two\n---\nbody"
        XCTAssertEqual(SkillsFrontmatter.parse(raw).frontmatter?["description"], "Line one\nLine two\n")
        let folded = "---\ndescription: >-\n  a\n  b\n---\n"
        XCTAssertEqual(SkillsFrontmatter.parse(folded).frontmatter?["description"], "a b")
        XCTAssertNil(SkillsFrontmatter.parse("# no frontmatter").frontmatter)
        XCTAssertEqual(SkillsFrontmatter.parse("# no frontmatter").body, "# no frontmatter")
        XCTAssertEqual(SkillsFrontmatter.parse("---\r\nname: w\r\n---\r\nrest").frontmatter?["name"], "w")
    }
}

final class SkillsArchiveTests: XCTestCase {
    func testSelectsShallowestSkillRootAndAppliesRules() throws {
        let members = [
            SkillsArchive.Member(path: "my-skill/SKILL.md", size: 10),
            SkillsArchive.Member(path: "my-skill/scripts/run.py", size: 5),
            SkillsArchive.Member(path: "my-skill/.git/config", size: 5),
            SkillsArchive.Member(path: "my-skill/LICENSE", size: 5),
            SkillsArchive.Member(path: "my-skill/logo.png", size: 5),
            SkillsArchive.Member(path: "my-skill/nested/SKILL.md", size: 5),
            SkillsArchive.Member(path: "other/readme.md", size: 5),
        ]
        let selection = try SkillsArchive.select(members).get()
        XCTAssertEqual(selection.prefix, "my-skill/")
        XCTAssertEqual(selection.skillMDPath, "my-skill/SKILL.md")
        XCTAssertEqual(selection.selected.map(\.path), ["my-skill/SKILL.md", "my-skill/scripts/run.py", "my-skill/nested/SKILL.md"])
    }

    func testFailures() {
        XCTAssertEqual(SkillsArchive.select([]), .failure(.empty))
        XCTAssertEqual(SkillsArchive.select([.init(path: ".hidden", size: 1)]), .failure(.empty))
        XCTAssertEqual(SkillsArchive.select([.init(path: "a.md", size: 1)]), .failure(.missingSkillMD))
        XCTAssertEqual(SkillsArchive.select([.init(path: "SKILL.md", size: SkillsArchive.maxFileBytes + 1)]), .failure(.tooLarge))
        let many = [SkillsArchive.Member(path: "SKILL.md", size: 1)] + (0...SkillsArchive.maxFileCount).map { .init(path: "f\($0).txt", size: 1) }
        XCTAssertEqual(SkillsArchive.select(many), .failure(.tooManyFiles))
    }

    func testPrepareReadsFrontmatterAndPacksZip() throws {
        let files: [String: Data] = [
            "pkg/SKILL.md": Data("---\nname: packed\ndescription: Does things\n---\nhi".utf8),
            "pkg/a.txt": Data("abc".utf8),
        ]
        let selection = try SkillsArchive.select(files.map { .init(path: $0.key, size: $0.value.count) }).get()
        let prepared = try SkillsArchive.prepare(selection) { files[$0] ?? Data() }.get()
        XCTAssertEqual(prepared.fileName, "packed.skill")
        XCTAssertEqual(prepared.preview.displayName, "pkg")
        XCTAssertEqual(prepared.preview.skillName, "packed")
        XCTAssertEqual(prepared.preview.description, "Does things")
        XCTAssertEqual(prepared.preview.fileCount, 2)
        XCTAssertEqual(Array(prepared.data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(Array(prepared.data.suffix(22).prefix(4)), [0x50, 0x4B, 0x05, 0x06])
        XCTAssertEqual(SkillsArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testWrapExisting() throws {
        let p = try SkillsArchive.wrapExisting(fileName: "/tmp/Tool.SKILL", data: Data([1])).get()
        XCTAssertEqual(p.preview.skillName, "Tool")
        XCTAssertEqual(p.preview.source, .archive)
        XCTAssertNil(p.preview.fileCount)
        XCTAssertTrue(SkillsArchive.isArchiveFilename("x.zip"))
    }
}

final class SkillsDraftTests: XCTestCase {
    func skill(description: String = "Desc\n", files: [SkillFile] = []) -> Skill {
        Skill(id: "s", name: " name ", description: description, content: "body", files: files)
    }

    func testFreshDraftIsCleanEvenWithTrailingNewlines() {
        let base = SkillsDraft(skill: skill())
        XCTAssertFalse(base.hasLocalEdits(against: base))
        XCTAssertFalse(base.dirtySummary(against: base).isDirty)
        XCTAssertEqual(base.name, "name")
    }

    func testRenameCountsOnceAndOrderIsIgnored() {
        let files = [SkillFile(id: "f1", path: "a.md", content: "A"), SkillFile(id: "f2", path: "b.md", content: "B")]
        let base = SkillsDraft(skill: skill(files: files))
        var draft = base
        draft.files.reverse()
        XCTAssertFalse(draft.hasLocalEdits(against: base))
        draft.renameFile("a.md", to: "c.md")
        XCTAssertEqual(draft.dirtySummary(against: base).changedFileCount, 1)
        draft.removeFile("b.md")
        draft.files.append(SkillsDraftFile(path: "new.md", content: ""))
        draft.content = "changed"
        draft.description = "x"
        let summary = draft.dirtySummary(against: base)
        XCTAssertEqual(summary.changedFileCount, 4)
        XCTAssertTrue(summary.descriptionChanged)
        XCTAssertFalse(summary.nameChanged)
    }

    func testUpdateRequestCarriesFiles() throws {
        var draft = SkillsDraft(skill: skill(files: [SkillFile(id: "f1", path: "a.md", content: "A")]))
        draft.files.append(SkillsDraftFile(path: " ", content: "dropped"))
        let req = draft.updateRequest
        XCTAssertEqual(req.files?.count, 1)
        XCTAssertEqual(req.files?.first?["id"]?.stringValue, "f1")
        XCTAssertEqual(draft.filePaths, ["SKILL.md", "a.md"])
        XCTAssertEqual(draft.content(at: "a.md"), "A")
    }
}

final class SkillsRuntimeTests: XCTestCase {
    func testDisplayLabel() {
        XCTAssertEqual(SkillsRuntimeLabels.displayLabel(RuntimeDeviceRecord(name: "Codex (EvaM2.local)", customName: "evam2", provider: "codex")), "evam2 (Codex)")
        XCTAssertEqual(SkillsRuntimeLabels.displayLabel(RuntimeDeviceRecord(name: "Codex (EvaM2.local)", customName: "", provider: "codex")), "Codex (EvaM2.local)")
        XCTAssertEqual(SkillsRuntimeLabels.displayLabel(RuntimeDeviceRecord(name: "host", customName: "evam2", provider: "")), "evam2")
        XCTAssertEqual(SkillsRuntimeLabels.providerDisplayName("qwen"), "Qwen Code")
    }

    func testMachinesGroupByDaemon() {
        let a = RuntimeDeviceRecord(id: "1", daemonId: "d1", name: "Claude (mac)", runtimeMode: "local", provider: "claude", status: "online")
        let b = RuntimeDeviceRecord(id: "2", daemonId: "d1", name: "Codex (mac)", runtimeMode: "local", provider: "codex", status: "offline")
        let c = RuntimeDeviceRecord(id: "3", daemonId: "d2", name: "Claude (box)", runtimeMode: "local", provider: "claude", status: "offline")
        let machines = SkillsRuntimeLabels.machines([c, b, a])
        XCTAssertEqual(machines.map(\.title), ["mac", "box"])
        XCTAssertEqual(machines[0].runtimes.map(\.id), ["1", "2"])
        XCTAssertEqual(SkillsRuntimeLabels.rowLabel(a, machineTitle: "mac"), "Claude")
    }

    func testInventorySearchAndConflictDefaults() {
        let inv = SkillsLocalInventory(skills: [
            RuntimeLocalSkillSummary(key: "k1", name: "pdf", description: "Read PDFs", sourcePath: "~/.claude/skills/pdf", provider: "claude", fileCount: 2),
            RuntimeLocalSkillSummary(key: "k2", name: "xlsx", sourcePath: "/x", provider: "codex", fileCount: 1),
        ], supported: true)
        XCTAssertEqual(inv.filtered("CODEX").map(\.key), ["k2"])
        XCTAssertEqual(inv.filtered("pdfs").map(\.key), ["k1"])
        XCTAssertEqual(inv.filtered(" ").count, 2)
        let r = SkillsConflictResolution.initial(name: "pdf", canOverwrite: false)
        XCTAssertEqual(r.action, .rename)
        XCTAssertEqual(r.renameName, "pdf copy")
        XCTAssertFalse(SkillsConflictResolution(action: .overwrite, renameName: "").isApplicable(canOverwrite: false))
        XCTAssertFalse(SkillsConflictResolution(action: .rename, renameName: " ").isApplicable(canOverwrite: true))
    }

    func testHighlightSegments() {
        let s = SkillsTextHighlight.segments("Read PDF files", query: "pdf")
        XCTAssertEqual(s.map(\.text), ["Read ", "PDF", " files"])
        XCTAssertEqual(s.map(\.highlighted), [false, true, false])
        XCTAssertEqual(SkillsTextHighlight.segments("a b", query: "").count, 1)
        XCTAssertEqual(SkillsTextHighlight.segments("read the files", query: "files read").filter(\.highlighted).map(\.text), ["read", "files"])
    }
}
