import XCTest
@testable import MulticaCore

final class RuntimesTests: XCTestCase {
    let now = Timestamp.parse("2026-05-17T12:00:00Z")!

    func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: date)
    }

    func runtime(id: String = "runtime-1", daemon: String? = "daemon-1", name: String = "Claude (dev-machine.local)",
                 mode: String = "local", provider: String = "claude", status: String = "online",
                 deviceInfo: String = "dev-machine.local · claude 1.0.0", metadata: [String: JSONValue] = ["cli_version": "0.3.0"],
                 owner: String? = "user-1", visibility: String = "private", customName: String? = nil, profileID: String? = nil,
                 lastSeenAgo: TimeInterval = 10) -> RuntimeDeviceRecord {
        RuntimeDeviceRecord(id: id, workspaceId: "ws-1", daemonId: daemon, name: name, customName: customName, runtimeMode: mode,
                            provider: provider, status: status, deviceInfo: deviceInfo, metadata: metadata, ownerId: owner,
                            visibility: visibility, profileId: profileID, lastSeenAt: iso(now.addingTimeInterval(-lastSeenAgo)),
                            createdAt: "2026-05-17T11:00:00Z", updatedAt: "2026-05-17T11:00:00Z")
    }

    // MARK: Health

    func testHealthBuckets() {
        XCTAssertEqual(RuntimesHealth.of(runtime(status: "online", lastSeenAgo: 99999), now: now), .online)
        XCTAssertEqual(RuntimesHealth.of(runtime(status: "offline", lastSeenAgo: 60), now: now), .recentlyLost)
        XCTAssertEqual(RuntimesHealth.of(runtime(status: "offline", lastSeenAgo: 600), now: now), .offline)
        XCTAssertEqual(RuntimesHealth.of(runtime(status: "offline", lastSeenAgo: 7 * 86400), now: now), .longOffline)
        XCTAssertEqual(RuntimesHealth.derive(status: "offline", lastSeenAt: nil, now: now), .longOffline)
    }

    // MARK: Machines

    func testGroupsProvidersByDaemon() {
        let machines = RuntimesKit.buildMachines([
            runtime(id: "rt-claude", name: "Claude (dev.local)"),
            runtime(id: "rt-codex", provider: "codex"),
        ], options: RuntimesMachineOptions(now: now, localDaemonID: "daemon-1"))
        XCTAssertEqual(machines.count, 1)
        let m = machines[0]
        XCTAssertEqual(m.id, "local:daemon-1")
        XCTAssertEqual(m.title, "dev.local")
        XCTAssertEqual(m.section, .local)
        XCTAssertTrue(m.isCurrent)
        XCTAssertEqual(m.onlineCount, 2)
        XCTAssertEqual(m.issueCount, 0)
        XCTAssertEqual(m.providerNames, ["claude", "codex"])
    }

    func testOnlineCLIVersionWins() {
        let machines = RuntimesKit.buildMachines([
            runtime(id: "rt-online", metadata: ["cli_version": "0.4.0", "launched_by": "desktop"]),
            runtime(id: "rt-stale", provider: "copilot", status: "offline", metadata: ["cli_version": "0.3.17", "launched_by": "desktop"], lastSeenAgo: 4 * 86400),
        ], options: RuntimesMachineOptions(now: now))
        XCTAssertEqual(machines.first?.cliVersion, "0.4.0")
        XCTAssertEqual(machines.first?.launchedBy, "desktop")
    }

    func testSharedCustomNameTitle() {
        let shared = RuntimesKit.buildMachines([
            runtime(id: "a", customName: "Bohan's MacBook"),
            runtime(id: "b", provider: "codex", customName: "Bohan's MacBook"),
        ], options: RuntimesMachineOptions(now: now, localDaemonID: "daemon-1", localMachineName: "dev-machine.local"))
        XCTAssertEqual(shared.first?.title, "Bohan's MacBook")

        let oneOff = RuntimesKit.buildMachines([
            runtime(id: "a", customName: "just this one"),
            runtime(id: "b", provider: "codex"),
        ], options: RuntimesMachineOptions(now: now, localDaemonID: "daemon-1"))
        XCTAssertEqual(oneOff.first?.title, "dev-machine.local")
    }

    func testIssuesAndSeverity() {
        let machines = RuntimesKit.buildMachines([
            runtime(id: "on"),
            runtime(id: "off", provider: "codex", status: "offline", lastSeenAgo: 600),
        ], options: RuntimesMachineOptions(now: now))
        let counts = RuntimesKit.machineCounts(machines)
        XCTAssertEqual(counts.all, 1)
        XCTAssertEqual(counts.online, 1)
        XCTAssertEqual(counts.issues, 1)
        XCTAssertEqual(RuntimesKit.filterMachines(machines, query: "", filter: .issues).count, 1)

        let offline = RuntimesKit.buildMachines([
            runtime(id: "a", status: "offline", lastSeenAgo: 600),
            runtime(id: "b", provider: "codex", status: "offline", lastSeenAgo: 8 * 86400),
        ], options: RuntimesMachineOptions(now: now))
        XCTAssertEqual(offline.first?.health, .longOffline)
    }

    func testLocalNameMatchRequiresOwnership() {
        let other = RuntimesKit.buildMachines([runtime(daemon: "d2", owner: "someone-else")],
                                             options: RuntimesMachineOptions(now: now, localMachineName: "dev-machine.local", currentUserID: "user-1"))
        XCTAssertFalse(other[0].isCurrent)
        let mine = RuntimesKit.buildMachines([runtime(daemon: "d2")],
                                            options: RuntimesMachineOptions(now: now, localMachineName: "DEV-MACHINE.local", currentUserID: "user-1"))
        XCTAssertTrue(mine[0].isCurrent)
        XCTAssertEqual(mine[0].title, "DEV-MACHINE.local")
    }

    func testPlaceholderAndSorting() {
        let machines = RuntimesKit.buildMachines([
            runtime(id: "cloud", daemon: nil, name: "codex", mode: "cloud", provider: "codex", deviceInfo: ""),
            runtime(id: "remote", daemon: "remote-daemon-1234567890", name: "Claude (zeta)", deviceInfo: "zeta · darwin-arm64"),
        ], options: RuntimesMachineOptions(now: now, localMachineName: "My Mac", ensureLocalMachine: true))
        XCTAssertEqual(machines.map(\.section), [.local, .remote, .cloud])
        XCTAssertEqual(machines[0].id, RuntimesKit.placeholderMachineID)
        XCTAssertEqual(machines[0].title, "My Mac")
        XCTAssertEqual(machines[1].subtitle, "arm64 macOS")
        XCTAssertEqual(machines[2].title, "Codex cloud")
        XCTAssertEqual(machines[2].subtitle, "Cloud worker")
        XCTAssertNotNil(RuntimesKit.findMachine(machines, locator: RuntimesKit.placeholderMachineID))
        XCTAssertEqual(RuntimesKit.findMachine(machines, locator: "remote")?.id, machines[1].id)
    }

    func testSubtitleSkipsVersionsAndDaemonFallback() {
        let m = RuntimesKit.buildMachines([runtime(name: "Claude", deviceInfo: "2.1.5 (Claude Code)")],
                                         options: RuntimesMachineOptions(now: now))[0]
        XCTAssertEqual(m.subtitle, "daemon daemon-1")
    }

    func testNamesAndLabels() {
        XCTAssertEqual(RuntimesKit.splitRuntimeName("Claude (host.local)").base, "Claude")
        XCTAssertEqual(RuntimesKit.splitRuntimeName("Claude (host.local)").hostname, "host.local")
        XCTAssertNil(RuntimesKit.splitRuntimeName("Claude").hostname)
        let aliased = runtime(customName: "Mac")
        XCTAssertEqual(RuntimesKit.runtimeRowLabel(aliased, machineTitle: "Mac"), "Claude")
        XCTAssertEqual(RuntimesKit.runtimeRowLabel(aliased, machineTitle: "Other"), "Mac")
        XCTAssertEqual(RuntimesKit.displayLabel(runtime(provider: "traecli", customName: "Mine")), "Mine (Trae)")
        XCTAssertEqual(RuntimesKit.displayLabel(runtime()), "Claude (dev-machine.local)")
        XCTAssertEqual(RuntimesKit.formatDeviceInfo("host · linux-amd64"), "host · Linux (x86_64)")
        XCTAssertEqual(RuntimesKit.compactDaemonID("0123456789abcdef"), "012345··ef")
        XCTAssertEqual(RuntimesKit.shortDaemonID("0123456789abcdef"), "01234567...")
    }

    func testUsability() {
        XCTAssertFalse(RuntimesKit.isUsable(runtime(owner: nil), by: "user-1"))
        XCTAssertTrue(RuntimesKit.isUsable(runtime(), by: nil))
        XCTAssertTrue(RuntimesKit.isUsable(runtime(), by: "user-1"))
        XCTAssertFalse(RuntimesKit.isUsable(runtime(), by: "user-2"))
        XCTAssertTrue(RuntimesKit.isUsable(runtime(visibility: "public"), by: "user-2"))
    }

    func testWorkloadIndex() {
        let agents = [AgentRecord(id: "a1", runtimeId: "r1"), AgentRecord(id: "a2", runtimeId: "r1"),
                      AgentRecord(id: "a3", runtimeId: "r1", archivedAt: "2026-01-01T00:00:00Z")]
        let tasks = [AgentTask(id: "t1", agentID: "a1", issueID: "i", status: .running),
                     AgentTask(id: "t2", agentID: "a2", issueID: "i", status: .dispatched),
                     AgentTask(id: "t3", agentID: "a2", issueID: "i", status: .waitingLocalDirectory),
                     AgentTask(id: "t4", agentID: "a3", issueID: "i", status: .running)]
        let index = RuntimesKit.workloadIndex(agents: agents, tasks: tasks)
        XCTAssertEqual(index["r1"], RuntimesWorkload(agentIDs: ["a1", "a2"], runningCount: 1, queuedCount: 1))
    }

    func testPendingRuntimes() {
        let profile = RuntimeProfile(id: "p1", workspaceId: "ws-1", displayName: "Team Codex", protocolFamily: "codex", commandName: "codex",
                                     createdBy: "user-1", enabled: true, createdAt: "2026-05-17T11:59:30Z")
        let rows = RuntimesKit.withPendingRuntimes([runtime()], profiles: [profile], localDaemonID: "daemon-1", localMachineName: "Mac")
        XCTAssertEqual(rows.count, 2)
        let pending = rows[1]
        XCTAssertTrue(RuntimesKit.isPending(pending))
        XCTAssertFalse(RuntimesKit.isDisabledPending(pending))
        XCTAssertEqual(pending.name, "Team Codex (Mac)")
        XCTAssertEqual(pending.id, "pending-runtime-profile:p1")
        XCTAssertEqual(RuntimesKit.pendingCommandName(pending), "codex")
        XCTAssertFalse(RuntimesKit.isPendingWarning(pending, now: now))
        XCTAssertTrue(RuntimesKit.isPendingWarning(pending, now: now.addingTimeInterval(30)))

        let registered = RuntimesKit.withPendingRuntimes([runtime(profileID: "p1")], profiles: [profile])
        XCTAssertEqual(registered.count, 1)

        var failed = runtime()
        failed.metadata = ["runtime_profile_registration_error": true, "runtime_profile_failure_reason": "not found"]
        XCTAssertEqual(RuntimesKit.registrationFailure(failed), "not found")
    }

    func testMachineUpdateRuntime() {
        let m = RuntimesKit.buildMachines([
            runtime(id: "mine-off", status: "offline", lastSeenAgo: 600),
            runtime(id: "pub", provider: "codex", owner: "other", visibility: "public"),
        ], options: RuntimesMachineOptions(now: now))[0]
        XCTAssertEqual(RuntimesKit.machineUpdateRuntime(m, currentUserID: "user-1", canManagePublicRuntimes: true)?.id, "pub")
        XCTAssertEqual(RuntimesKit.machineUpdateRuntime(m, currentUserID: "user-1", canManagePublicRuntimes: false)?.id, "mine-off")
        XCTAssertNil(RuntimesKit.machineUpdateRuntime(m, currentUserID: nil, canManagePublicRuntimes: true))
    }

    func testResolveSettingsTarget() {
        let rows = [runtime(id: "a"), runtime(id: "b", provider: "codex")]
        XCTAssertEqual(RuntimesKit.resolveSettingsTarget(rows, machineID: "local:daemon-1", runtimeID: "b", now: now)?.runtime.id, "b")
        XCTAssertEqual(RuntimesKit.resolveSettingsTarget(rows, machineID: "a", runtimeID: "b", now: now)?.machine.id, "local:daemon-1")
        XCTAssertNil(RuntimesKit.resolveSettingsTarget(rows, machineID: "local:daemon-1", runtimeID: "zzz", now: now))
    }

    // MARK: Pricing

    func usage(_ date: String = "2026-05-17", model: String = "claude-sonnet-4-5", provider: String = "claude",
               input: Int = 1_000_000, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, ticks: Double? = nil,
               uncostedInput: Int? = nil) -> RuntimeUsage {
        RuntimeUsage(runtimeId: "r", date: date, provider: provider, model: model, inputTokens: input, outputTokens: output,
                     cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, costUsdTicks: ticks, uncostedInputTokens: uncostedInput)
    }

    func testPricingResolution() {
        let p = RuntimesPricer()
        XCTAssertNotNil(p.resolve("claude-opus-4.7", provider: nil))
        XCTAssertNotNil(p.resolve("anthropic/claude-opus-4-7", provider: nil))
        XCTAssertNotNil(p.resolve("claude-sonnet-4-5-20250929", provider: nil))
        XCTAssertNotNil(p.resolve("claude-opus-4-7[1m]", provider: nil))
        XCTAssertNotNil(p.resolve("custom:anthropic/claude-opus-4.7", provider: nil))
        XCTAssertNil(p.resolve("gpt-5.5-mini", provider: nil))
        XCTAssertNil(p.resolve("auto", provider: nil))
        XCTAssertNotNil(p.resolve("auto", provider: "Cursor"))
        XCTAssertEqual(RuntimesPricer.pricingKey("auto", provider: "Cursor"), "cursor/auto")
        XCTAssertEqual(RuntimesPricer.pricingKey("cursor/auto", provider: "cursor"), "cursor/auto")
        XCTAssertEqual(p.modelGroupingKey("claude-opus-4-7", provider: "claude"), "claude-opus-4-7")
        XCTAssertEqual(p.modelGroupingKey("auto", provider: "cursor"), "cursor/auto")
    }

    func testEstimateCost() {
        let p = RuntimesPricer()
        XCTAssertEqual(p.estimateCost(usage(input: 1_000_000, output: 1_000_000)), 18, accuracy: 1e-9)
        XCTAssertEqual(p.estimateCost(usage(model: "unknown-model", ticks: 5_000_000_000)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.estimateCost(usage(input: 1_000_000, ticks: 10_000_000_000)), 1, accuracy: 1e-9)
        XCTAssertEqual(p.estimateCost(usage(input: 2_000_000, ticks: 10_000_000_000, uncostedInput: 1_000_000)), 4, accuracy: 1e-9)
        XCTAssertEqual(p.estimateCacheSavings(usage(input: 0, cacheRead: 1_000_000)), 2.7, accuracy: 1e-9)
        let custom = RuntimesPricer(custom: ["my-model": RuntimesModelPrice(input: 1, output: 2, cacheRead: 0, cacheWrite: 0)])
        XCTAssertEqual(custom.estimateCost(usage(model: "my-model", provider: "")), 1, accuracy: 1e-9)

        let b = p.estimateCostBreakdown(usage(input: 1_000_000, output: 1_000_000, ticks: 10_000_000_000, uncostedInput: 0))
        XCTAssertEqual(b.total, p.estimateCost(usage(input: 1_000_000, output: 1_000_000, ticks: 10_000_000_000, uncostedInput: 0)), accuracy: 1e-9)
    }

    func testSummarizeTaskUsage() {
        let p = RuntimesPricer()
        XCTAssertNil(p.summarizeTaskUsage([RuntimeUsage]()))
        XCTAssertNil(p.summarizeTaskUsage(Optional<[RuntimeUsage]>.none))
        let s = p.summarizeTaskUsage([usage(model: "claude-sonnet-4-5"), usage(model: "claude-opus-4-1"), usage(model: "claude-sonnet-4-5")])
        XCTAssertEqual(s?.models, ["claude-sonnet-4-5", "claude-opus-4-1"])
        XCTAssertEqual(s?.tokens, 3_000_000)
        XCTAssertEqual(s?.cost ?? 0, 21, accuracy: 1e-9)
    }

    func testUnmappedModels() {
        let p = RuntimesPricer()
        let rows = [usage(model: "auto", provider: "x"), usage(model: "mystery", provider: ""), usage(model: "claude-opus-4-7"),
                    usage(model: "paid", provider: "", ticks: 100, uncostedInput: 0)]
        XCTAssertEqual(p.collectUnmappedModels(rows), ["mystery", "x/auto"])
    }

    func testFormatting() {
        XCTAssertEqual(RuntimesFormat.tokens(999, locale: Locale(identifier: "en_US")), "999")
        XCTAssertEqual(RuntimesFormat.tokens(1234), "1.2K")
        XCTAssertEqual(RuntimesFormat.tokens(999_999), "1M")
        XCTAssertEqual(RuntimesFormat.tokens(2_000_000), "2M")
        XCTAssertEqual(RuntimesFormat.usd(12.345), "$12.35")
        XCTAssertEqual(RuntimesFormat.usd(123.4), "$123")
        XCTAssertEqual(RuntimesFormat.cacheHitRatePercent(input: 0, cacheRead: 0, cacheWrite: 0), nil)
        XCTAssertEqual(RuntimesFormat.cacheHitRatePercent(input: 1, cacheRead: 999, cacheWrite: 0), 99)
        XCTAssertEqual(RuntimesFormat.cacheHitRatePercent(input: 0, cacheRead: 5, cacheWrite: 0), 100)
        XCTAssertEqual(RuntimesFormat.pctChange(12, 10), 20)
        XCTAssertNil(RuntimesFormat.pctChange(12, 0))
        XCTAssertEqual(RuntimesFormat.rate(failed: 1, total: 8), "13%")
        XCTAssertEqual(RuntimesFormat.rate(failed: 1, total: 70), "1.4%")
        XCTAssertEqual(RuntimesFormat.rate(failed: 0, total: 0), "—")
        XCTAssertEqual(RuntimesFormat.uptime("1h23m45.6s"), "1h 23m")
        XCTAssertEqual(RuntimesFormat.uptime("5m2s"), "5m")
        XCTAssertEqual(RuntimesFormat.uptime("42s"), "42s")
    }

    // MARK: Usage aggregation

    func testCalendar() {
        XCTAssertEqual(RuntimesCalendar.addDays("2026-03-01", -1), "2026-02-28")
        XCTAssertEqual(RuntimesCalendar.weekStart("2026-05-17"), "2026-05-11")
        XCTAssertEqual(RuntimesCalendar.weekStart("2026-05-11"), "2026-05-11")
        XCTAssertEqual(RuntimesCalendar.weekdayIndex("2026-05-17"), 6)
        XCTAssertEqual(RuntimesCalendar.diffDays("2026-05-11", "2026-05-17"), 6)
        XCTAssertEqual(RuntimesCalendar.shortDate("2026-05-11"), "May 11")
        XCTAssertEqual(RuntimesCalendar.axisLabel("2026-05-01"), "5/1")
        XCTAssertEqual(RuntimesCalendar.today(in: TimeZone(identifier: "Asia/Shanghai")!, now: Timestamp.parse("2026-05-17T20:00:00Z")!), "2026-05-18")
    }

    func testSliceAndWindows() {
        let rows = [usage("2026-05-17"), usage("2026-05-10"), usage("2026-05-03"), usage("2026-04-01")]
        let (cur, prev) = RuntimesUsageMath.sliceWindow(rows, days: 7, today: "2026-05-17")
        XCTAssertEqual(cur.map(\.date), ["2026-05-17", "2026-05-10"])
        XCTAssertEqual(prev.map(\.date), ["2026-05-03"])
        let p = RuntimesPricer()
        XCTAssertEqual(RuntimesUsageMath.costInWindow(rows, days: 7, today: "2026-05-17", pricer: p), 3, accuracy: 1e-9)
        XCTAssertEqual(RuntimesUsageMath.costInWindow(rows, days: 7, today: "2026-05-17", offset: 7, pricer: p), 3, accuracy: 1e-9)
    }

    func testByDateAndWeek() {
        let p = RuntimesPricer()
        let rows = [usage("2026-05-17", output: 100), usage("2026-05-16"), usage("2026-05-17", model: "gpt-5")]
        let daily = RuntimesUsageMath.byDate(rows, pricer: p)
        XCTAssertEqual(daily.tokens.map(\.date), ["2026-05-16", "2026-05-17"])
        XCTAssertEqual(daily.tokens[1].input, 2_000_000)
        XCTAssertEqual(daily.cost[1].total, daily.cost[1].input + daily.cost[1].output + daily.cost[1].cacheRead + daily.cost[1].cacheWrite, accuracy: 0.011)

        let weekly = RuntimesUsageMath.byWeek(rows + [usage("2026-01-01")], today: "2026-05-14", weekCount: 3, pricer: p)
        XCTAssertEqual(weekly.tokens.map(\.week.weekStart), ["2026-04-27", "2026-05-04", "2026-05-11"])
        XCTAssertEqual(weekly.tokens.last?.week.partial, true)
        XCTAssertEqual(weekly.tokens.last?.week.daysCovered, 4)
        XCTAssertEqual(weekly.tokens[0].total, 0)
        XCTAssertEqual(weekly.tokens.last?.week.rangeLabel, "May 11 – May 17")
    }

    func testCostBy() {
        let p = RuntimesPricer()
        let byAgent = RuntimesUsageMath.costByAgent([
            RuntimeUsageByAgent(agentId: "a", provider: "claude", model: "claude-sonnet-4-5", inputTokens: 1_000_000, taskCount: 2),
            RuntimeUsageByAgent(agentId: "b", provider: "claude", model: "claude-opus-4-1", inputTokens: 1_000_000, taskCount: 1),
            RuntimeUsageByAgent(agentId: "a", provider: "claude", model: "claude-sonnet-4-5", inputTokens: 1_000_000, taskCount: 3),
        ], pricer: p)
        XCTAssertEqual(byAgent.map(\.key), ["b", "a"])
        XCTAssertEqual(byAgent[1].taskCount, 5)
        XCTAssertEqual(byAgent[1].tokens, 2_000_000)
        let byModel = RuntimesUsageMath.costByModel([usage(model: "auto", provider: "cursor"), usage(model: "auto", provider: "other")], pricer: p)
        XCTAssertEqual(Set(byModel.map(\.key)), ["cursor/auto", "other/auto"])
    }

    func testHeatmap() {
        let p = RuntimesPricer()
        let rows = [usage("2026-05-17"), usage("2026-05-16", input: 3_000_000), usage("2026-05-11", input: 2_000_000)]
        let h = RuntimesUsageMath.heatmap(rows, today: "2026-05-17", pricer: p)
        XCTAssertEqual(h.cells.count, 25 * 7 + 7)
        XCTAssertEqual(h.cells.last?.date, "2026-05-17")
        XCTAssertEqual(h.cells.first?.dayOfWeek, 0)
        XCTAssertEqual(h.insights.busiestDate, "2026-05-16")
        XCTAssertEqual(h.insights.totalCost, 18, accuracy: 1e-9)
        XCTAssertEqual(h.cells.first { $0.date == "2026-05-16" }?.level, 4)
        XCTAssertEqual(h.cells.first { $0.date == "2026-05-17" }?.level, 1)
        XCTAssertEqual(h.insights.busyWeekday, 5)
        XCTAssertEqual(h.insights.windowDays, h.cells.count)
        XCTAssertFalse(h.months.isEmpty)

        let empty = RuntimesUsageMath.heatmap([RuntimeUsage](), today: "2026-05-17", pricer: p)
        XCTAssertNil(empty.insights.busyWeekday)
        XCTAssertNil(empty.insights.quietWeekday)
    }

    // MARK: Profiles

    func profile(_ id: String, _ name: String, _ updated: String, enabled: Bool = true) -> RuntimeProfile {
        RuntimeProfile(id: id, workspaceId: "ws-1", displayName: name, protocolFamily: "codex", commandName: "codex",
                       visibility: "workspace", createdBy: "user-1", enabled: enabled, createdAt: "2026-01-01T00:00:00Z", updatedAt: updated)
    }

    func testProfileCatalog() {
        let catalog = RuntimesProfileCatalog.build([
            profile("disabled-new", "Disabled New", "2026-01-04T00:00:00Z", enabled: false),
            profile("enabled-old", "Alpha", "2026-01-01T00:00:00Z"),
            profile("enabled-new-a", "Zulu", "2026-01-03T00:00:00Z"),
            profile("enabled-new-b", "Bravo", "2026-01-03T00:00:00Z"),
        ])
        XCTAssertEqual(catalog.customs.map(\.id), ["enabled-new-b", "enabled-new-a", "enabled-old", "disabled-new"])
        XCTAssertEqual(catalog.builtins.count, RuntimesProfileCatalog.runtimeTypes.count)
        XCTAssertEqual(catalog.builtins.first?.id, "builtin:claude")
        XCTAssertEqual(RuntimesProfileCatalog.label("omp"), "Oh-My-Pi")
        XCTAssertEqual(RuntimesProfileCatalog.label("future-runtime"), "future-runtime")
    }

    func testCommandLineParsing() {
        func ok(_ s: String) -> RuntimesParsedCommand? { try? RuntimesProfileCatalog.parse(s).get() }
        func err(_ s: String) -> RuntimesCommandLineError? {
            if case .failure(let e) = RuntimesProfileCatalog.parse(s) { return e }
            return nil
        }
        XCTAssertEqual(ok("agent --model composer-2.5"), RuntimesParsedCommand(commandName: "agent", fixedArgs: ["--model", "composer-2.5"]))
        XCTAssertEqual(ok(#"agent --flag "a b c" path\ with\ spaces"#)?.fixedArgs, ["--flag", "a b c", "path with spaces"])
        XCTAssertEqual(err("agent && rm -rf /"), .shellSyntax)
        XCTAssertEqual(err("agent | tee out"), .shellSyntax)
        XCTAssertEqual(err("agent --path $HOME/bin"), .shellExpansion)
        XCTAssertEqual(err("agent --path $(which foo)"), .shellExpansion)
        XCTAssertEqual(ok("agent --note '$5 reward `literal`'")?.fixedArgs, ["--note", "$5 reward `literal`"])
        XCTAssertEqual(err(#"agent --flag "unterminated"#), .unclosedQuote)
        XCTAssertEqual(err("agent \\"), .trailingEscape)
        XCTAssertEqual(err("   "), .empty)
        XCTAssertEqual(RuntimesProfileCatalog.format(commandName: "agent", fixedArgs: ["--flag", "a b c"]), #"agent --flag "a b c""#)
        XCTAssertEqual(RuntimesProfileCatalog.validate(displayName: " ", commandLine: ""), [.displayName, .commandLine])
    }

    // MARK: Daemon log

    func testLogParsing() {
        let r = RuntimesDaemonLog.parse("17:52:35.587 INF task completed component=daemon task=c45266e5 status=completed", id: 1)
        XCTAssertEqual(r.timestamp, "17:52:35.587")
        XCTAssertEqual(r.level, .info)
        XCTAssertEqual(r.message, "task completed")
        XCTAssertEqual(r.fields.map(\.key), ["component", "task", "status"])
        XCTAssertEqual(RuntimesDaemonLog.parse("17:53:06.644 DBG agent component=daemon", id: 1).level, .debug)
        XCTAssertEqual(RuntimesDaemonLog.parse("07:48:09.391 WRN claim task failed component=daemon", id: 1).level, .warn)
        XCTAssertEqual(RuntimesDaemonLog.parse("12:00:00.000 ERR something bad component=daemon", id: 1).level, .error)
        XCTAssertEqual(RuntimesDaemonLog.parse("12:00:00.000 INF+1 unusual delta component=daemon", id: 1).message, "unusual delta")
        XCTAssertEqual(RuntimesDaemonLog.parse("17:52:54.578 INF tool #1: Skill component=daemon task=8791b717", id: 1).message, "tool #1: Skill")

        let quoted = RuntimesDaemonLog.parse(#"17:53:06.644 DBG agent component=daemon task=8791b717 text="The issue is just \"ping\" with no description.""#, id: 1)
        XCTAssertEqual(quoted.message, "agent")
        XCTAssertEqual(quoted.field("text"), #"The issue is just "ping" with no description."#)
        XCTAssertEqual(quoted.field("task"), "8791b717")

        let url = RuntimesDaemonLog.parse(#"07:48:09.391 WRN claim task failed component=daemon runtime_id=03f8ff17-276d error="Post \"http://localhost:8080/api/x\": dial tcp [::1]:8080: connect: connection refused""#, id: 1)
        XCTAssertEqual(url.field("error"), #"Post "http://localhost:8080/api/x": dial tcp [::1]:8080: connect: connection refused"#)
        XCTAssertEqual(url.field("runtime_id"), "03f8ff17-276d")

        let args = RuntimesDaemonLog.parse(#"17:52:48.757 INF agent command component=daemon exec=claude args="[-p --output-format stream-json --verbose]""#, id: 1)
        XCTAssertEqual(args.field("args"), "[-p --output-format stream-json --verbose]")

        let raw = RuntimesDaemonLog.parse("\tat github.com/multica/foo (line 42)", id: 1)
        XCTAssertNil(raw.timestamp)
        XCTAssertNil(raw.level)
        XCTAssertEqual(raw.message, raw.raw)
        XCTAssertNil(RuntimesDaemonLog.parse("12:00:00.000 TRACE something exotic", id: 1).level)
        XCTAssertTrue(RuntimesDaemonLog.parse("12:00:00.000 INF plain message", id: 3).fields.isEmpty)
    }

    func testLogFoldAndFilter() {
        let lines = ["12:00:00.000 DBG poll: no tasks", "12:00:01.000 DBG poll: no tasks", "12:00:02.000 DBG poll: no tasks", "12:00:03.000 INF hello", "garbage"]
            .enumerated().map { RuntimesDaemonLog.parse($0.element, id: $0.offset + 1) }
        let folded = RuntimesDaemonLog.fold(lines)
        XCTAssertEqual(folded.count, 3)
        if case .group(let first, let rest) = folded[0] {
            XCTAssertEqual(first.id, 1)
            XCTAssertEqual(rest.map(\.id), [2, 3])
        } else {
            XCTFail("expected a group")
        }
        let filtered = RuntimesDaemonLog.filter(lines, levels: [.info, .warn, .error], search: "")
        XCTAssertEqual(filtered.map(\.id), [4, 5])
        XCTAssertEqual(RuntimesDaemonLog.filter(lines, levels: Set(RuntimesDaemonLogLevel.allCases), search: "HELLO").map(\.id), [4])
        XCTAssertEqual(RuntimesDaemonLog.truncate(String(repeating: "a", count: 40)), String(repeating: "a", count: 36) + "…")
        XCTAssertEqual(RuntimesDaemonLog.truncate(String(repeating: "a", count: 37)), String(repeating: "a", count: 37))
    }

    // MARK: Store helpers

    func testConflictParsing() {
        let body = Data(#"{"code":"runtime_has_active_agents","error":"busy","active_agents":[{"id":"a1","name":"Atlas","runtime_id":"r"},{"bogus":1}]}"#.utf8)
        let conflict = RuntimesConflict.runtimeDelete(APIError.from(status: 409, body: body))
        XCTAssertEqual(conflict?.code, .hasActiveAgents)
        XCTAssertEqual(conflict?.agents.map(\.id), ["a1"])
        XCTAssertNil(RuntimesConflict.runtimeDelete(APIError.from(status: 409, body: Data(#"{"code":"other"}"#.utf8))))
        XCTAssertNil(RuntimesConflict.runtimeDelete(APIError.from(status: 500, body: body)))
        let planChanged = RuntimesConflict.runtimeDelete(APIError.from(status: 409, body: Data(#"{"code":"runtime_delete_plan_changed"}"#.utf8)))
        XCTAssertEqual(planChanged?.code, .planChanged)
        XCTAssertEqual(planChanged?.agents.count, 0)

        XCTAssertEqual(RuntimesConflict.profileBound(APIError.from(status: 409, body: Data(#"{"message":"agents bound"}"#.utf8))), "agents bound")
        XCTAssertEqual(RuntimesConflict.profileBound(APIError.from(status: 409, body: Data(#"{"error":"still used"}"#.utf8))), "still used")
        XCTAssertEqual(RuntimesConflict.profileBound(APIError(status: 409, message: "fallback")), "fallback")
        XCTAssertNil(RuntimesConflict.profileBound(APIError(status: 400, message: "x")))
    }

    func testReleaseVersions() {
        XCTAssertEqual(RuntimesRelease.parseReleaseVersion("v0.4.17"), [0, 4, 17])
        XCTAssertNil(RuntimesRelease.parseReleaseVersion("v0.4.17-12-gabc1234"))
        XCTAssertNil(RuntimesRelease.parseReleaseVersion("dev"))
        XCTAssertTrue(RuntimesRelease.isNewer("v0.4.18", than: "0.4.17"))
        XCTAssertFalse(RuntimesRelease.isNewer("v0.4.17", than: "0.4.17"))
        XCTAssertFalse(RuntimesRelease.isNewer("v0.5.0", than: "dev"))
        XCTAssertFalse(RuntimesRelease.isNewer("v0.3.9", than: "0.4.0"))
    }

    func testMikaSetup() {
        XCTAssertTrue(RuntimesKit.memberNeedsMikaSetup(agents: [AgentRecord(id: "a")], sessions: []))
        let mika = AgentRecord(id: "m", systemKey: "mika")
        XCTAssertTrue(RuntimesKit.memberNeedsMikaSetup(agents: [mika], sessions: []))
        XCTAssertTrue(RuntimesKit.memberNeedsMikaSetup(agents: [mika], sessions: [ChatSession(id: "s", agentId: "m")]))
        XCTAssertFalse(RuntimesKit.memberNeedsMikaSetup(agents: [mika], sessions: [ChatSession(id: "s", agentId: "m", lastMessage: ChatLastMessage())]))
        XCTAssertEqual(RuntimesKit.mikaContentLanguage("zh-Hans"), "zh")
        XCTAssertEqual(RuntimesKit.mikaContentLanguage("fr"), "en")
    }

    // MARK: Daemon rules

    func testRecoveryPolicy() {
        var p = RuntimesDaemonRecoveryPolicy()
        var t = now
        func observe(_ state: DaemonState, desired: Bool = true) -> RuntimesDaemonRecoveryPolicy.Decision {
            p.observe(desiredRunning: desired, externallyManaged: false, lifecycleBusy: false, state: state, now: t)
        }
        XCTAssertEqual(observe(.stopped), .none)
        XCTAssertEqual(observe(.stopped), .none)
        XCTAssertEqual(observe(.stopped), .confirm)
        p.recordAttempt(t)
        for _ in 0..<3 { _ = observe(.stopped) }
        XCTAssertEqual(observe(.stopped, desired: false), .none)

        // Backoff 15 s → 30 s → 2 min → 10 min; five starts fit in 30 min.
        for delay in [16.0, 31, 121, 601] {
            t = t.addingTimeInterval(delay)
            _ = observe(.stopped); _ = observe(.stopped)
            XCTAssertEqual(observe(.stopped), .confirm)
            p.recordAttempt(t)
        }
        t = t.addingTimeInterval(601)
        _ = observe(.stopped); _ = observe(.stopped)
        XCTAssertEqual(observe(.stopped), .pause)
        XCTAssertTrue(p.isPaused)
        XCTAssertEqual(observe(.stopped), .pause)

        p.reset()
        XCTAssertFalse(p.isPaused)
        XCTAssertFalse(p.recordPIDDeferral(t))
        XCTAssertFalse(p.recordPIDDeferral(t))
        XCTAssertTrue(p.recordPIDDeferral(t))
    }

    func testRecoveryForgivenessAfterStableRunning() {
        var p = RuntimesDaemonRecoveryPolicy()
        p.recordAttempt(now)
        _ = p.observe(desiredRunning: true, externallyManaged: false, lifecycleBusy: false, state: .running, now: now)
        _ = p.observe(desiredRunning: true, externallyManaged: false, lifecycleBusy: false, state: .running, now: now.addingTimeInterval(61))
        var decisions: [RuntimesDaemonRecoveryPolicy.Decision] = []
        for _ in 0..<3 {
            decisions.append(p.observe(desiredRunning: true, externallyManaged: false, lifecycleBusy: false, state: .stopped, now: now.addingTimeInterval(62)))
        }
        XCTAssertEqual(decisions.last, .confirm)
    }

    func testDaemonRules() {
        XCTAssertEqual(RuntimesDaemonRules.classifyAuthProbe(noToken: true), .authExpired)
        XCTAssertEqual(RuntimesDaemonRules.classifyAuthProbe(networkError: true), .unknown)
        XCTAssertEqual(RuntimesDaemonRules.classifyAuthProbe(status: 401), .authExpired)
        XCTAssertEqual(RuntimesDaemonRules.classifyAuthProbe(status: 200), .ok)
        XCTAssertEqual(RuntimesDaemonRules.classifyAuthProbe(status: 503), .unknown)

        func health(_ json: String) -> DaemonHealth { try! JSONCoders.decoder.decode(DaemonHealth.self, from: Data(json.utf8)) }
        XCTAssertEqual(RuntimesDaemonRules.versionAction(bundled: "0.4.1", health: nil), .notRunning)
        XCTAssertEqual(RuntimesDaemonRules.versionAction(bundled: "0.4.1", health: health(#"{"status":"running","cli_version":"0.4.1"}"#)), .ok)
        XCTAssertEqual(RuntimesDaemonRules.versionAction(bundled: nil, health: health(#"{"status":"running","cli_version":"0.4.0"}"#)), .ok)
        XCTAssertEqual(RuntimesDaemonRules.versionAction(bundled: "0.4.1", health: health(#"{"status":"running","cli_version":"0.4.0","active_task_count":2}"#)), .deferred)
        XCTAssertEqual(RuntimesDaemonRules.versionAction(bundled: "0.4.1", health: health(#"{"status":"running","cli_version":"0.4.0"}"#)), .restart)
        XCTAssertEqual(health(#"{"status":"running","workspaces":[{},{}]}"#).workspaceCount, 2)

        XCTAssertFalse(RuntimesDaemonRules.isExternallyManaged(daemonOS: nil))
        XCTAssertFalse(RuntimesDaemonRules.isExternallyManaged(daemonOS: "darwin"))
        XCTAssertTrue(RuntimesDaemonRules.isExternallyManaged(daemonOS: "linux"))
        XCTAssertEqual(RuntimesDaemonRules.parsePID(" 4242\n"), 4242)
        XCTAssertNil(RuntimesDaemonRules.parsePID("abc"))
        XCTAssertNil(RuntimesDaemonRules.parsePID("0"))
        XCTAssertTrue(RuntimesDaemonRules.urlsMatch("https://API.multica.ai/", "https://api.multica.ai"))
        XCTAssertFalse(RuntimesDaemonRules.urlsMatch("", ""))

        let names = ["multica-cli-0.4.1-darwin-arm64.tar.gz", "multica-cli-0.4.1-linux-amd64.tar.gz", "multica_darwin_amd64.tar.gz"]
        XCTAssertEqual(RuntimesDaemonRules.releaseAssetName(names, arch: "arm64"), "multica-cli-0.4.1-darwin-arm64.tar.gz")
        XCTAssertEqual(RuntimesDaemonRules.releaseAssetName(names, arch: "amd64"), "multica_darwin_amd64.tar.gz")
        XCTAssertNil(RuntimesDaemonRules.releaseAssetName(names, os: "windows", arch: "amd64"))
        let sums = RuntimesDaemonRules.parseChecksums("\(String(repeating: "a", count: 64))  multica.tar.gz\njunk\n")
        XCTAssertEqual(sums["multica.tar.gz"], String(repeating: "a", count: 64))
    }
}
