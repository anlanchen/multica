import Foundation
import XCTest
@testable import MulticaCore

final class AgentsUITests: XCTestCase {
    private func agent(_ id: String = "a1", owner: String? = "u1", mode: String = "public_to",
                       targets: [AgentInvocationTarget] = [AgentInvocationTarget(targetType: "workspace")],
                       runtime: String = "rt1", archived: Bool = false, name: String = "Agent", created: String = "2026-01-01T00:00:00Z") -> AgentRecord {
        AgentRecord(id: id, runtimeId: runtime, name: name, permissionMode: mode, invocationTargets: targets,
                    maxConcurrentTasks: 2, ownerId: owner, createdAt: created, archivedAt: archived ? "2026-02-01T00:00:00Z" : nil)
    }

    private func runtime(_ id: String = "rt1", status: String = "online", lastSeen: String? = nil, owner: String? = "u1",
                         visibility: String = "private", name: String = "Claude (mbp)", custom: String? = nil,
                         daemon: String? = "d1", provider: String = "claude", mode: String = "local") -> RuntimeDeviceRecord {
        RuntimeDeviceRecord(id: id, daemonId: daemon, name: name, customName: custom, runtimeMode: mode, provider: provider,
                            status: status, ownerId: owner, visibility: visibility, lastSeenAt: lastSeen)
    }

    // MARK: Access

    func testAccessScope() {
        XCTAssertEqual(AgentsUI.accessScope(permissionMode: "private", targets: []), .ownerOnly)
        XCTAssertEqual(AgentsUI.accessScope(permissionMode: nil, targets: nil), .ownerOnly)
        XCTAssertEqual(AgentsUI.accessScope(permissionMode: "public_to", targets: [AgentInvocationTarget(targetType: "workspace")]), .workspace)
        XCTAssertEqual(AgentsUI.accessScope(permissionMode: "public_to", targets: [AgentInvocationTarget(targetType: "member", targetId: "u2")]), .specificPeople)
        XCTAssertEqual(AgentsUI.accessScope(permissionMode: "public_to", targets: nil), .specificPeople)
    }

    func testPermissions() {
        let a = agent(owner: "alice")
        XCTAssertTrue(AgentsUI.canEdit(a, userID: "alice", role: "member"))
        XCTAssertTrue(AgentsUI.canEdit(a, userID: "bob", role: "admin"))
        XCTAssertFalse(AgentsUI.canEdit(a, userID: "bob", role: "member"))
        XCTAssertFalse(AgentsUI.canEdit(a, userID: nil, role: nil))

        XCTAssertNil(AgentsUI.assignDenial(a, userID: "bob", role: "member"))
        XCTAssertEqual(AgentsUI.assignDenial(a, userID: "bob", role: nil), .notMember)
        let priv = agent(owner: "alice", mode: "private", targets: [])
        XCTAssertEqual(AgentsUI.assignDenial(priv, userID: "bob", role: "admin"), .privateVisibility)
        XCTAssertNil(AgentsUI.assignDenial(priv, userID: "alice", role: "member"))
        let members = agent(owner: "alice", targets: [AgentInvocationTarget(targetType: "member", targetId: "bob")])
        XCTAssertNil(AgentsUI.assignDenial(members, userID: "bob", role: "member"))
        XCTAssertEqual(AgentsUI.assignDenial(members, userID: "carol", role: "member"), .privateVisibility)
        let team = agent(owner: "alice", targets: [AgentInvocationTarget(targetType: "team", targetId: "t")])
        XCTAssertEqual(AgentsUI.assignDenial(team, userID: "bob", role: "admin"), .privateVisibility)
    }

    func testRuntimeBoundAndUsable() {
        XCTAssertTrue(AgentsUI.isRuntimeBound(agent()))
        XCTAssertFalse(AgentsUI.isRuntimeBound(agent(runtime: "  ")))
        var a = agent()
        a.runtimeBound = false
        XCTAssertFalse(AgentsUI.isRuntimeBound(a))

        XCTAssertTrue(AgentsUI.isRuntimeUsable(runtime(owner: "u1"), userID: "u1"))
        XCTAssertFalse(AgentsUI.isRuntimeUsable(runtime(owner: "u1"), userID: "u2"))
        XCTAssertTrue(AgentsUI.isRuntimeUsable(runtime(owner: "u1", visibility: "public"), userID: "u2"))
        XCTAssertFalse(AgentsUI.isRuntimeUsable(runtime(owner: nil), userID: "u2"))
    }

    // MARK: Presence

    func testPresence() {
        let now = Date()
        let tasks = [
            AgentTaskRecord(id: "t1", agentId: "a1", status: "running"),
            AgentTaskRecord(id: "t2", agentId: "a1", status: "queued"),
            AgentTaskRecord(id: "t3", agentId: "a1", status: "completed"),
            AgentTaskRecord(id: "t4", agentId: "a2", status: "waiting_local_directory"),
        ]
        let map = AgentsUI.presenceMap(agents: [agent("a1"), agent("a2", runtime: "gone"), agent("a3", archived: true)],
                                       runtimes: [runtime()], snapshot: tasks, now: now)
        XCTAssertEqual(map["a1"], AgentsUI.Presence(availability: .online, workload: .working, runningCount: 1, queuedCount: 1, capacity: 2))
        XCTAssertEqual(map["a2"]?.availability, .offline)
        XCTAssertEqual(map["a2"]?.workload, .queued)
        XCTAssertEqual(map["a3"]?.availability, .archived)
    }

    func testRuntimeHealthBuckets() {
        let now = Date()
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(AgentsUI.runtimeHealth(status: "offline", lastSeenAt: iso.string(from: now.addingTimeInterval(-60)), now: now), .recentlyLost)
        XCTAssertEqual(AgentsUI.runtimeHealth(status: "offline", lastSeenAt: iso.string(from: now.addingTimeInterval(-3600)), now: now), .offline)
        XCTAssertEqual(AgentsUI.runtimeHealth(status: "offline", lastSeenAt: nil, now: now), .longOffline)
        XCTAssertEqual(AgentsUI.availability(runtime: runtime(status: "offline", lastSeen: iso.string(from: now.addingTimeInterval(-10))), now: now), .unstable)
    }

    // MARK: Activity

    func testActivityAndSummary() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-03-10T12:00:00Z")!
        let buckets = [
            AgentActivityBucket(agentId: "a1", bucketAt: "2026-03-10T00:00:00Z", taskCount: 3, failedCount: 1, completedCount: 2, cancelledCount: 0, durationMs: 3000, durationCount: 3),
            AgentActivityBucket(agentId: "a1", bucketAt: "2026-03-08T00:00:00Z", taskCount: 2, failedCount: 0, completedCount: 1, cancelledCount: 1),
            AgentActivityBucket(agentId: "a1", bucketAt: "2025-12-01T00:00:00Z", taskCount: 9, failedCount: 0, completedCount: 9, cancelledCount: 0),
        ]
        let a = AgentsUI.activity(buckets: buckets, createdAt: "2026-03-07T12:00:00Z", now: now, calendar: cal)
        XCTAssertEqual(a.buckets.count, 30)
        XCTAssertEqual(a.buckets[29].total, 3)
        XCTAssertEqual(a.buckets[27].cancelled, 1)
        XCTAssertEqual(a.daysSinceCreated, 3)
        XCTAssertEqual(a.avgDurationMs, 1000)
        XCTAssertEqual(AgentsUI.lastActiveDaysAgo(a), 0)

        let s = AgentsUI.summarize(a, windowDays: 30)
        XCTAssertEqual(s.totalRuns, 5)
        XCTAssertEqual(s.totalFailed, 1)
        XCTAssertEqual(s.successRate, 75)
        XCTAssertEqual(AgentsUI.summarize(a, windowDays: 0).buckets.count, 0)

        let cancelledOnly = AgentsUI.Activity(buckets: [AgentsUI.ActivityBucket(total: 1, cancelled: 1)], daysSinceCreated: 1, avgDurationMs: 0)
        XCTAssertNil(AgentsUI.summarize(cancelledOnly, windowDays: 7).successRate)
    }

    func testFormatDuration() {
        XCTAssertEqual(AgentsUI.formatDuration(ms: 0), "—")
        XCTAssertEqual(AgentsUI.formatDuration(ms: 400), "1s")
        XCTAssertEqual(AgentsUI.formatDuration(ms: 12_000), "12s")
        XCTAssertEqual(AgentsUI.formatDuration(ms: 124_000), "2m 04s")
        XCTAssertEqual(AgentsUI.formatDuration(ms: 5_400_000), "1h 30m")
    }

    // MARK: List

    func testViewStateRules() {
        var v = AgentsUI.ViewState()
        XCTAssertEqual(v.scope, .mine)
        v.toggleFilter(.owners, "bob")
        XCTAssertEqual(v.scope, .all)
        XCTAssertEqual(v.filters.owners, ["bob"])
        v.setScope(.mine)
        XCTAssertEqual(v.filters.activeDimensionCount, 0)
        v.toggleSort(.name)
        XCTAssertEqual(v.sortDirection, .asc)
        v.toggleSort(.name)
        XCTAssertEqual(v.sortDirection, .desc)
        v.setSortField(.runs)
        XCTAssertEqual(v.sortDirection, .desc)
        XCTAssertFalse(v.isVisible(.model))
        v.toggleColumn(.model)
        XCTAssertTrue(v.isVisible(.model))

        let data = try! JSONEncoder().encode(v)
        XCTAssertEqual(try! JSONDecoder().decode(AgentsUI.ViewState.self, from: data), v)
        let legacy = #"{"scope":"all","filters":{"availability":["online"]}}"#.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(AgentsUI.ViewState.self, from: legacy)
        XCTAssertEqual(decoded.filters.availability, ["online"])
        XCTAssertEqual(decoded.filters.owners, [])
    }

    func testRowFiltersAndSort() {
        func row(_ a: AgentRecord, runs: Int, last: Int?, presence: AgentsUI.Availability = .online) -> AgentsUI.ListRow {
            AgentsUI.ListRow(agent: a, runtime: nil,
                             presence: AgentsUI.Presence(availability: presence, workload: .idle, runningCount: 0, queuedCount: 0, capacity: 1),
                             activity: nil, runCount: runs, lastActiveDays: last, isOwnedByMe: false, canManage: false)
        }
        var b = agent("b", name: "Beta", created: "2026-01-02T00:00:00Z")
        b.description = "Reviews pull requests"
        let rows = [row(agent("a", name: "alpha"), runs: 5, last: 2), row(b, runs: 9, last: nil, presence: .offline),
                    row(agent("c", mode: "private", targets: [], name: "Gamma"), runs: 1, last: 0)]

        var f = AgentsUI.ListFilters()
        XCTAssertEqual(rows.filter { AgentsUI.rowMatches($0, filters: f, query: "pull") }.map(\.id), ["b"])
        f.availability = ["online"]
        XCTAssertEqual(rows.filter { AgentsUI.rowMatches($0, filters: f, query: "") }.map(\.id), ["a", "c"])
        f = AgentsUI.ListFilters()
        f.access = ["owner-only"]
        XCTAssertEqual(rows.filter { AgentsUI.rowMatches($0, filters: f, query: "") }.map(\.id), ["c"])

        XCTAssertEqual(AgentsUI.sortRows(rows, field: .lastActive, direction: .desc).map(\.id), ["c", "a", "b"])
        XCTAssertEqual(AgentsUI.sortRows(rows, field: .lastActive, direction: .asc).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(AgentsUI.sortRows(rows, field: .runs, direction: .desc).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(AgentsUI.sortRows(rows, field: .name, direction: .asc).map(\.id), ["a", "b", "c"])
    }

    func testScopeCounts() {
        let c = AgentsUI.scopeCounts([agent("a", owner: "u1"), agent("b", owner: "u2"), agent("c", owner: "u1", archived: true)], userID: "u1")
        XCTAssertEqual(c, AgentsUI.ScopeCounts(mine: 1, all: 2, archived: 1))
    }

    func testLatinizedSearch() {
        let a = agent(name: "研究助手")
        let pinyin: (String) -> String = { _ in "yan jiu zhu shou" }
        XCTAssertTrue(AgentsUI.matchesSearch(a, query: "yanjiu", latinize: pinyin))
        XCTAssertTrue(AgentsUI.matchesSearch(a, query: "yjzs", latinize: pinyin))
        XCTAssertFalse(AgentsUI.matchesSearch(a, query: "xyz", latinize: pinyin))
    }

    // MARK: Runtimes

    func testRuntimeLabels() {
        XCTAssertEqual(AgentsUI.splitRuntimeName("Claude (mbp)").base, "Claude")
        XCTAssertEqual(AgentsUI.splitRuntimeName("Claude (mbp)").hostname, "mbp")
        XCTAssertNil(AgentsUI.splitRuntimeName("Claude").hostname)
        XCTAssertEqual(AgentsUI.runtimeDisplayLabel(runtime(custom: "Work box")), "Work box (Claude)")
        XCTAssertEqual(AgentsUI.runtimeDisplayLabel(runtime()), "Claude (mbp)")
        XCTAssertEqual(AgentsUI.providerDisplayName("qoderclicn"), "Qoder CN")
        XCTAssertEqual(AgentsUI.runtimeRowLabel(runtime(custom: "Box"), machineTitle: "Box"), "Claude")
    }

    func testRuntimeMachines() {
        let machines = AgentsUI.runtimeMachines([
            runtime("r1", name: "Claude (mbp)", daemon: "d1", provider: "claude"),
            runtime("r2", status: "offline", name: "Codex (mbp)", daemon: "d1", provider: "codex"),
            runtime("r3", name: "Claude", daemon: nil, provider: "claude", mode: "cloud"),
        ], now: Date())
        XCTAssertEqual(machines.count, 2)
        XCTAssertEqual(machines[0].title, "mbp")
        XCTAssertEqual(machines[0].onlineCount, 1)
        XCTAssertEqual(machines[0].providerNames, ["claude", "codex"])
        XCTAssertEqual(machines[1].section, .cloud)
    }

    // MARK: Models

    func testModelCapability() {
        XCTAssertEqual(AgentsUI.modelIDForCapabilityLookup(provider: "claude", model: "claude-opus-5[1m]"), "claude-opus-5")
        XCTAssertEqual(AgentsUI.modelIDForCapabilityLookup(provider: "claude", model: "x[beta]"), "x[beta]")
        XCTAssertEqual(AgentsUI.modelIDForCapabilityLookup(provider: "codex", model: "m[1m]"), "m[1m]")

        let catalog = [
            RuntimeModel(id: "a", label: "A", thinking: RuntimeModelThinking(supportedLevels: [RuntimeModelThinkingLevel(value: "high", label: "High")]),
                         serviceTiers: [RuntimeModelServiceTier(id: "fast", name: "Fast")]),
            RuntimeModel(id: "b", label: "B"),
        ]
        XCTAssertEqual(AgentsUI.modelChange(provider: "codex", model: "b", thinkingLevel: "high", serviceTier: "fast", catalog: catalog).patch,
                       ["model": "b", "thinking_level": "", "service_tier": ""])
        XCTAssertEqual(AgentsUI.modelChange(provider: "codex", model: "a", thinkingLevel: "high", serviceTier: "fast", catalog: catalog).patch, ["model": "a"])
        XCTAssertEqual(AgentsUI.modelChange(provider: "codex", model: "b", thinkingLevel: "high", serviceTier: "", catalog: nil).patch, ["model": "b"])
        XCTAssertEqual(AgentsUI.thinkingModelEntry(catalog, model: "", provider: "claude")?.id, "a")
        XCTAssertNil(AgentsUI.thinkingModelEntry(catalog, model: "", provider: "codex"))
    }

    func testFailureLabels() {
        XCTAssertEqual(AgentsUI.failureLabel("agent_error.provider_network"), .key("agent_error_provider_network"))
        XCTAssertEqual(AgentsUI.failureLabel("brand_new_reason"), .raw("brand_new_reason"))
        XCTAssertNil(AgentsUI.failureLabel(""))
    }

    // MARK: Env file

    func testEnvParse() {
        let text = "# comment\nexport FOO=bar\nBAZ = \"quoted # not comment\" # trailing\nQUX='single'\nEMPTY=\nURL=http://x#frag # c\n"
        guard case .success(let list) = AgentsUI.parseEnvFileResult(text) else { return XCTFail() }
        XCTAssertEqual(list, [
            .init(key: "FOO", value: "bar"), .init(key: "BAZ", value: "quoted # not comment"),
            .init(key: "QUX", value: "single"), .init(key: "EMPTY", value: ""), .init(key: "URL", value: "http://x#frag"),
        ])
        XCTAssertEqual(AgentsUI.parseEnvFileResult("A=1\nnot valid"), .failure(.malformed(line: 2)))
        XCTAssertEqual(AgentsUI.parseEnvFileResult("A=1\n\nA=2"), .failure(.duplicate(line: 3, key: "A")))
        XCTAssertEqual(AgentsUI.parseEnvFileResult("A=\"unterminated"), .failure(.malformed(line: 1)))
        XCTAssertEqual(AgentsUI.parseEnvFileResult("export=1"), .success([.init(key: "export", value: "1")]))
        XCTAssertNil(AgentsUI.parseEnvFile("   \n# only comments"))
        XCTAssertTrue(AgentsUI.isEnvFilePaste("hello\nKEY=value"))
        XCTAssertFalse(AgentsUI.isEnvFilePaste("just a value"))
    }

    func testEnvFormatRoundTrip() {
        let entries: [AgentsUI.EnvAssignment] = [
            .init(key: "A", value: "plain"), .init(key: "B", value: "has #hash"), .init(key: "C", value: "foo\" #bar"), .init(key: "D", value: " lead"),
        ]
        guard case .success(let text) = AgentsUI.formatEnvFile(entries) else { return XCTFail() }
        XCTAssertEqual(AgentsUI.parseEnvFileResult(text), .success(entries))
        XCTAssertEqual(AgentsUI.formatEnvFile([.init(key: "A", value: "a\nb")]), .failure(.unrepresentable(key: "A")))
        XCTAssertEqual(AgentsUI.formatEnvFile([.init(key: "A", value: "1"), .init(key: "A", value: "2")]), .failure(.duplicate(key: "A")))
        XCTAssertEqual(AgentsUI.formatEnvFile([.init(key: "1A", value: "1")]), .failure(.unrepresentable(key: "1A")))
    }

    // MARK: MCP config

    func testMcpConfigModel() {
        let doc: JSONValue = [
            "mcpServers": ["b": ["command": "npx", "args": ["x"]], "a": ["url": "https://x", "enabled": false]],
            "mcp": ["b": ["type": "local", "command": ["run"]], "c": ["type": "sse", "url": "https://s"]],
        ]
        let list = AgentsUI.listManagedMcpServers(doc)
        XCTAssertEqual(list.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(list.map(\.transport), ["http", "stdio", "sse"])
        XCTAssertEqual(list[0].enabled, false)
        XCTAssertEqual(list[2].container, .mcp)

        let renamed = AgentsUI.upsertManagedMcpServer(doc, previous: list[1], name: "b2", config: list[1].config)
        XCTAssertNil(renamed["mcpServers"]?["b"])
        XCTAssertNotNil(renamed["mcpServers"]?["b2"])
        let removed = AgentsUI.removeManagedMcpServer(.object(["mcp": ["c": ["url": "u"]]]), server: list[2])
        XCTAssertNil(removed)
        XCTAssertEqual(AgentsUI.mcpTransportLabel("streamable-http"), "Streamable HTTP")
        XCTAssertTrue(AgentsUI.isValidMcpServerName("my_server-1"))
        XCTAssertFalse(AgentsUI.isValidMcpServerName("bad name"))
    }

    func testMcpForm() {
        let cfg: [String: JSONValue] = ["command": "npx", "args": ["-y", "pkg"], "env": ["K": "v"], "timeout": 30]
        var form = AgentsUI.mcpForm(from: cfg)
        XCTAssertEqual(form.transport, .stdio)
        XCTAssertEqual(form.args, ["-y", "pkg"])
        XCTAssertEqual(form.env, [AgentsUI.KeyValue(key: "K", value: "v")])
        XCTAssertEqual(AgentsUI.mcpConfig(from: form), cfg)
        form.transport = .http
        form.url = " https://x "
        XCTAssertEqual(AgentsUI.mcpConfig(from: form)["type"], "http")
        XCTAssertEqual(AgentsUI.mcpConfig(from: form)["url"], "https://x")

        XCTAssertFalse(AgentsUI.mcpFormCanExpress(["type": "websocket", "url": "wss://x"]))
        XCTAssertTrue(AgentsUI.mcpFormCanExpress(["url": "https://x"]))
        XCTAssertFalse(AgentsUI.mcpFormCanExpress(["foo": 1]))
        XCTAssertEqual(AgentsUI.parseMcpServerJSON("[]"), .failure(.notObject))
        XCTAssertEqual(AgentsUI.parseMcpServerJSON("{\"a\":1}"), .failure(.missingTarget))
        if case .failure(.invalid) = AgentsUI.parseMcpServerJSON("{") {} else { XCTFail() }
        XCTAssertEqual(try? AgentsUI.parseMcpServerJSON("{\"url\":\"u\"}").get(), ["url": "u"])
    }

    // MARK: Drafts & builder

    func testDuplicateDraftAndRequest() {
        var src = agent(owner: "u1", targets: [AgentInvocationTarget(targetType: "member", targetId: "u2")])
        src.name = "Bot"
        src.model = "opus"
        src.thinkingLevel = "high"
        src.customArgs = ["--x"]
        src.skills = [AgentSkillSummary(id: "s1", name: "S")]
        let kept = AgentsUI.duplicateDraft(src, runtimes: [runtime()], userID: "u1", fallbackRuntimeID: "rt2", nameSuffix: " (Copy)")
        XCTAssertEqual(kept.name, "Bot (Copy)")
        XCTAssertEqual(kept.runtimeId, "rt1")
        XCTAssertEqual(kept.model, "opus")
        XCTAssertEqual(kept.permissionScope, .members)
        XCTAssertEqual(kept.memberIds, ["u2"])
        let reset = AgentsUI.duplicateDraft(src, runtimes: [runtime(owner: "other")], userID: "u1", fallbackRuntimeID: "rt2", nameSuffix: "")
        XCTAssertEqual(reset.runtimeId, "rt2")
        XCTAssertEqual(reset.model, "")
        XCTAssertEqual(reset.thinkingLevel, "")

        let req = AgentsUI.createRequest(kept, runtimeID: "rt1", template: nil, duplicateSource: src)
        XCTAssertEqual(req.permissionMode, "public_to")
        XCTAssertEqual(req.invocationTargets?.map(\.targetId), ["u2"])
        XCTAssertEqual(req.customArgs, ["--x"])
        XCTAssertEqual(req.maxConcurrentTasks, 2)
        XCTAssertEqual(req.skillIds, ["s1"])
        XCTAssertNil(AgentsUI.createRequest(AgentsUI.Draft(), runtimeID: "r").model)

        var d = AgentsUI.Draft()
        d.model = "m"
        d.thinkingLevel = "low"
        XCTAssertEqual(d.withModel("n").thinkingLevel, "")
        XCTAssertEqual(d.withRuntime("x").model, "")
    }

    func testStoredDraftAndManualDrafts() {
        var d = AgentsUI.Draft()
        d.name = "X"
        d.skillIds = ["b", "a"]
        let stored = AgentsUI.StoredDraft(d, appliedMessageID: "m1")
        XCTAssertEqual(stored.skillIds, ["a", "b"])
        XCTAssertEqual(stored.json["applied_message_id"], "m1")
        XCTAssertEqual(stored.draft(runtimeID: "r").skillIds, ["a", "b"])

        var drafts = AgentsUI.ManualDrafts()
        let owner = AgentsUI.ManualDrafts.owner(duplicateID: nil)
        drafts.set(owner, .init(runtimeId: "r", draft: AgentsUI.StoredDraft(AgentsUI.Draft(), appliedMessageID: nil)))
        XCTAssertTrue(drafts.byOwner.isEmpty)
        drafts.set(owner, .init(runtimeId: "r", draft: stored))
        XCTAssertNotNil(drafts.byOwner["blank"])
        XCTAssertEqual(AgentsUI.ManualDrafts.owner(duplicateID: "a1"), "duplicate:a1")
    }

    func testBuilderProtocol() {
        let reply = "Here you go.\n\n<agent_draft>{\"name\":\"Reviewer\",\"instructions\":\"line1\nline2\",\"skill_ids\":[\"s1\",\"bogus\"],\"permission_scope\":\"members\",\"member_ids\":[\"u2\"],\"model\":\"m2\"}</agent_draft>"
        let payload = AgentsUI.parseBuilderDraft(reply)
        XCTAssertEqual(payload?["name"], "Reviewer")
        XCTAssertEqual(payload?["instructions"], "line1\nline2")
        XCTAssertEqual(AgentsUI.stripBuilderDraft(reply), "Here you go.")
        XCTAssertEqual(AgentsUI.stripBuilderDraft("Thinking…  <agent_draft>{\"na"), "Thinking…")

        var current = AgentsUI.Draft()
        current.model = "m1"
        current.thinkingLevel = "high"
        let merged = AgentsUI.mergeBuilderDraft(current, payload: payload!, validSkillIDs: ["s1"], validMemberIDs: ["u2"], validModelIDs: ["m1", "m2"])
        XCTAssertEqual(merged.name, "Reviewer")
        XCTAssertEqual(merged.skillIds, ["s1"])
        XCTAssertEqual(merged.permissionScope, .members)
        XCTAssertEqual(merged.memberIds, ["u2"])
        XCTAssertEqual(merged.model, "m2")
        XCTAssertEqual(merged.thinkingLevel, "")
        let unknownCatalog = AgentsUI.mergeBuilderDraft(current, payload: payload!, validSkillIDs: [], validMemberIDs: [], validModelIDs: nil)
        XCTAssertEqual(unknownCatalog.model, "m1")

        let encoded = AgentsUI.encodeBuilderInput("Make a \"reviewer\"", draft: current, catalog: AgentsUI.BuilderCatalog(
            skills: [(id: "s1", name: "S", description: "")], members: [(id: "u2", name: "Bob")], runtime: nil, models: nil))
        XCTAssertTrue(encoded.hasPrefix("MULTICA_AGENT_BUILDER_INPUT\n{\n  \"user_request\""))
        XCTAssertEqual(AgentsUI.decodeBuilderInput(encoded), "Make a \"reviewer\"")
        XCTAssertEqual(AgentsUI.decodeBuilderInput("plain"), "plain")
    }

    func testOpenclawConfig() {
        let cfg = AgentsUI.OpenclawConfig(["mode": "gateway", "gateway": ["host": "gw", "port": 18789, "token": "***", "tls": true]])
        var form = AgentsUI.OpenclawForm(cfg)
        XCTAssertTrue(form.tokenWasMasked)
        XCTAssertEqual(form.token, "")
        XCTAssertEqual(form.config.token, "***")
        XCTAssertTrue(form.config.semanticallyEquals(cfg))
        form.port = "12a"
        XCTAssertFalse(form.portValid)
        form = AgentsUI.OpenclawForm()
        XCTAssertEqual(form.config.json, ["mode": "local"])
        XCTAssertTrue(AgentsUI.OpenclawConfig([:]).semanticallyEquals(AgentsUI.OpenclawConfig(mode: "local")))
    }

    func testConversationStarters() {
        let fallback = [AgentConversationStarter(label: "F", prompt: "f")]
        XCTAssertTrue(AgentsUI.selectConversationStarters([AgentConversationStarter(label: "x", prompt: " ")], fallback: fallback).isFallback)
        XCTAssertFalse(AgentsUI.selectConversationStarters([AgentConversationStarter(label: "x", prompt: "y")], fallback: fallback).isFallback)
    }
}
