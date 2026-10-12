import XCTest
@testable import MulticaCore

final class UsageTests: XCTestCase {
    private func daily(_ date: String, model: String = "claude-sonnet-4-5", input: Int = 0, output: Int = 0,
                       cacheRead: Int = 0, cacheWrite: Int = 0, tasks: Int = 1, ticks: Double? = nil,
                       uncostedInput: Int? = nil) -> DashboardUsageDaily {
        DashboardUsageDaily(date: date, provider: "claude", model: model, inputTokens: input, outputTokens: output,
                            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, costUsdTicks: ticks,
                            uncostedInputTokens: uncostedInput, taskCount: tasks)
    }

    func testCalendarHelpers() {
        XCTAssertEqual(UsageCalendar.addDays("2026-03-01", -1), "2026-02-28")
        XCTAssertEqual(UsageCalendar.addDays("2024-12-31", 1), "2025-01-01")
        XCTAssertEqual(UsageCalendar.weekStart("2026-10-12"), "2026-10-12") // Monday
        XCTAssertEqual(UsageCalendar.weekStart("2026-10-18"), "2026-10-12") // Sunday
        XCTAssertEqual(UsageCalendar.diffDays("2026-10-12", "2026-10-18"), 6)
        XCTAssertEqual(UsageCalendar.shortDate("2026-05-12"), "May 12")
        XCTAssertEqual(UsageCalendar.dayLabel("2026-05-02"), "5/2")
    }

    func testPricingResolvesCanonicalForms() {
        let p = UsagePricing()
        XCTAssertNotNil(p.resolve("claude-opus-4.7"))
        XCTAssertNotNil(p.resolve("anthropic/claude-opus-4.7"))
        XCTAssertNotNil(p.resolve("claude-sonnet-4-5-20250929"))
        XCTAssertNotNil(p.resolve("gpt-5-2025-08-07"))
        XCTAssertNotNil(p.resolve("claude-opus-4-7[1m]"))
        XCTAssertNotNil(p.resolve("auto", provider: "cursor"))
        XCTAssertNil(p.resolve("auto"))
        XCTAssertNil(p.resolve("gpt-5.5-mini"))
        let custom = UsagePricing(custom: ["gpt-5.5-mini": UsageModelPricing(input: 1, output: 2, cacheRead: 0, cacheWrite: 0)])
        XCTAssertNotNil(custom.resolve("gpt-5.5-mini"))
    }

    func testCostEstimateAndAuthoritativeSplit() {
        let p = UsagePricing()
        let row = daily("2026-10-01", input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(p.estimateCost(row), 18, accuracy: 1e-9)
        // Fully provider-priced row without the uncosted split: authoritative only.
        let priced = daily("2026-10-01", input: 1_000_000, ticks: 5 * 10_000_000_000)
        XCTAssertEqual(p.estimateCost(priced), 5, accuracy: 1e-9)
        XCTAssertEqual(p.estimateCostBreakdown(priced).total, 5, accuracy: 1e-9)
        // Unpriced model with authoritative cost lands whole in input.
        let unknown = daily("2026-10-01", model: "mystery", input: 10, ticks: 2 * 10_000_000_000)
        XCTAssertEqual(p.estimateCostBreakdown(unknown).input, 2, accuracy: 1e-9)
    }

    func testCustomPricingDecodesZustandEnvelope() {
        let json = #"{"state":{"pricings":{"x/y":{"input":1,"output":2,"cacheRead":0.1,"cacheWrite":0}}},"version":0}"#
        let map = UsagePricing.decodeCustomPricing(Data(json.utf8))
        XCTAssertEqual(map["x/y"]?.output, 2)
    }

    func testDailyAggregationsSortAndSplitTasks() {
        let rows = [daily("2026-10-02", input: 10, output: 5), daily("2026-10-01", input: 1), daily("2026-10-02", input: 3)]
        let tokens = UsageDashboard.dailyTokens(rows)
        XCTAssertEqual(tokens.map(\.key), ["2026-10-01", "2026-10-02"])
        XCTAssertEqual(tokens[1].value.input, 13)
        let runTime = [DashboardRunTimeDaily(date: "2026-10-01", totalSeconds: 60, taskCount: 10, failedCount: 2, cancelledCount: 3)]
        XCTAssertEqual(UsageDashboard.dailyTasks(runTime)[0].value, UsageTaskStack(completed: 5, failed: 2, cancelled: 3))
    }

    func testWeeklyShellsArePreZeroedAndPartial() {
        // Wednesday.
        let weeks = UsageDashboard.weeks(today: "2026-10-14", count: 2)
        XCTAssertEqual(weeks.map(\.weekStart), ["2026-10-05", "2026-10-12"])
        XCTAssertFalse(weeks[0].partial)
        XCTAssertTrue(weeks[1].partial)
        XCTAssertEqual(weeks[1].daysCovered, 3)
        let runTime = [DashboardRunTimeDaily(date: "2026-10-13", totalSeconds: 30), DashboardRunTimeDaily(date: "2026-09-01", totalSeconds: 99)]
        let time = UsageDashboard.weeklyTime(runTime, today: "2026-10-14", weekCount: 2)
        XCTAssertEqual(time.map(\.value), [0, 30])
    }

    func testAgentMergeAndDeletedBucket() {
        let tokens = [UsageAgentCostRow(agentID: "a", tokens: 100, cost: 2, taskCount: 4),
                      UsageAgentCostRow(agentID: "gone", tokens: 50, cost: 1, taskCount: 1)]
        let runTime = [DashboardAgentRunTime(agentId: "a", totalSeconds: 60, taskCount: 3, meteredTaskCount: 2),
                       DashboardAgentRunTime(agentId: "b", totalSeconds: 120, taskCount: 2, meteredTaskCount: 0)]
        let merged = UsageDashboard.mergeAgentRows(tokens, runTime)
        XCTAssertEqual(merged.map(\.agentID), ["a", "gone", "b"])
        XCTAssertEqual(merged[0].taskCount, 3)
        XCTAssertEqual(merged[0].unreportedTaskCount, 1)
        XCTAssertFalse(merged[2].hasUsageTotals)
        XCTAssertEqual(merged[2].unreportedTaskCount, 2)

        let visible = UsageDashboard.bucketUnknownAgents(merged, known: ["a", "b"])
        XCTAssertEqual(visible.map(\.agentID), ["a", "b", UsageDashboard.deletedAgentsRowID])
        XCTAssertEqual(visible.last?.cost, 1)
        XCTAssertEqual(UsageDashboard.deletedAgentCount(merged, known: ["a", "b"]), 1)
        XCTAssertEqual(UsageDashboard.bucketUnknownAgents(merged, known: nil).count, 3)
    }

    func testFailureClassificationAndRates() {
        XCTAssertEqual(UsageFailureClass(reason: "agent_error.provider_quota_limit"), .rateLimit)
        XCTAssertEqual(UsageFailureClass(reason: "environment_prepare_failed"), .runtime)
        XCTAssertEqual(UsageFailureClass(reason: "agent_error.something_new"), .other)
        let rows = [DashboardFailureDaily(date: "2026-10-01", failureReason: "", taskCount: 8),
                    DashboardFailureDaily(date: "2026-10-01", failureReason: "timeout", taskCount: 1),
                    DashboardFailureDaily(date: "2026-10-02", failureReason: "runtime_offline", taskCount: 1)]
        let totals = UsageDashboard.failureTotals(rows)
        XCTAssertEqual(totals.failed, 2)
        XCTAssertEqual(totals.total, 10)
        XCTAssertEqual(UsageFormat.rate(failed: 2, total: 10), "20%")
        XCTAssertEqual(UsageFormat.rate(failed: 1, total: 70), "1.4%")
        XCTAssertEqual(UsageFormat.rate(failed: 0, total: 0), "—")
        XCTAssertEqual(UsageDashboard.failureClasses(rows).map(\.failureClass), [.timeout, .runtime])
        let errors = UsageDashboard.dailyErrors(rows)
        XCTAssertEqual(errors[0].value.total, 9)
        XCTAssertEqual(errors[0].value[.timeout], 1)
        XCTAssertEqual(UsageDashboard.activeClasses(errors), [.timeout, .runtime])
    }

    func testOffenderSortingDemotesSmallSamples() {
        let byAgent = [DashboardFailureByAgent(agentId: "big", failureReason: "timeout", taskCount: 5),
                       DashboardFailureByAgent(agentId: "big", failureReason: "", taskCount: 15),
                       DashboardFailureByAgent(agentId: "tiny", failureReason: "timeout", taskCount: 1),
                       DashboardFailureByAgent(agentId: "hidden", failureReason: "timeout", taskCount: 2)]
        let anonymized = UsageDashboard.anonymizeUnresolved(byAgent, known: ["big", "tiny"])
        let rows = UsageDashboard.agentFailures(anonymized)
        XCTAssertEqual(rows.map(\.agentID), ["big", UsageDashboard.unresolvedAgentsRowID, "tiny"])
        let byRate = UsageDashboard.sortAgentFailures(rows, by: .rate)
        XCTAssertEqual(byRate.first?.agentID, "big")
    }

    func testFormatting() {
        XCTAssertEqual(UsageFormat.duration(0.5, lessThanMinute: "<1m"), "<1m")
        XCTAssertEqual(UsageFormat.duration(45, lessThanMinute: "<1m"), "45s")
        XCTAssertEqual(UsageFormat.duration(750, lessThanMinute: "<1m"), "12m 30s")
        XCTAssertEqual(UsageFormat.duration(5_000, lessThanMinute: "<1m"), "1h 23m")
        XCTAssertEqual(UsageFormat.duration(90_000, lessThanMinute: "<1m"), "1d 1h")
        XCTAssertEqual(UsageFormat.tokens(999), "999")
        XCTAssertEqual(UsageFormat.tokens(1_500), "1.5K")
        XCTAssertEqual(UsageFormat.tokens(999_999), "1M")
        XCTAssertEqual(UsageFormat.tokens(2_000_000), "2M")
    }

    func testSnapshotTrimsDailyButNotWeekly() {
        var input = UsageDashboardInput(days: 7, today: "2026-10-14")
        input.daily = [daily("2026-10-14", input: 10), daily("2026-10-01", input: 5)]
        input.knownAgentIDs = []
        let snapshot = UsageDashboardSnapshot(input)
        XCTAssertEqual(snapshot.totals.input, 10)
        XCTAssertEqual(snapshot.dailyTokens.count, 1)
        XCTAssertEqual(snapshot.weeklyTokens.map(\.value.input).reduce(0, +), 10)
        XCTAssertEqual(UsageDashboardInput.chartFetchDays(30), 35)
        XCTAssertFalse(snapshot.usageHasNoData)
    }
}
