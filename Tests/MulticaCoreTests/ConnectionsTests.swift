import XCTest
@testable import MulticaCore

final class ConnectionsTests: XCTestCase {
    func testRepositoryIdentity() {
        XCTAssertEqual(ConnectionsRepository.identity("https://github.com/Org/Repo.git"), "github.com/Org/Repo")
        XCTAssertEqual(ConnectionsRepository.identity("git@github.com:Org/Repo.git"), "github.com/Org/Repo")
        XCTAssertEqual(ConnectionsRepository.identity("https://GitHub.com/Org/Repo/"), "github.com/Org/Repo")
        XCTAssertEqual(ConnectionsRepository.identity("ssh://git@host:22/a/b"), "host/a/b")
        XCTAssertEqual(ConnectionsRepository.identity("ssh://git@host:2222/a/b"), "host:2222/a/b")
        XCTAssertEqual(ConnectionsRepository.identity("https://host:443/a"), "host/a")
        XCTAssertNil(ConnectionsRepository.identity(""))
        XCTAssertNil(ConnectionsRepository.identity("not a url"))
        XCTAssertTrue(ConnectionsRepository.isGitHub("git@github.com:a/b"))
    }

    func testGitHubSettingsDefaultsOn() {
        let all = ConnectionsGitHubSettings(settings: [:])
        XCTAssertTrue(all.enabled && all.prSidebar && all.coAuthor && all.autoLinkPRs)
        let paused = ConnectionsGitHubSettings(settings: ["github_enabled": false, "co_authored_by_enabled": true])
        XCTAssertFalse(paused.enabled || paused.coAuthor)
    }

    func testPRMergeStatus() {
        XCTAssertEqual(ConnectionsPRMergeStatus.derive(settings: [:]), "done")
        XCTAssertEqual(ConnectionsPRMergeStatus.derive(settings: ["pr_auto_complete_enabled": false]), "none")
        XCTAssertEqual(ConnectionsPRMergeStatus.derive(settings: ["pr_merge_status": " In_Review "]), "in_review")
        XCTAssertEqual(ConnectionsPRMergeStatus.derive(settings: ["pr_merge_status": 3]), "none")
        let entries = [IssueStatusEntry(id: "1", key: "qa", name: "QA", category: .started, position: 5),
                       IssueStatusEntry(id: "2", key: "in_progress", name: "In progress", category: .started, position: 1),
                       IssueStatusEntry(id: "3", key: "blocked", name: "Blocked", category: .started, position: 2)]
        let groups = ConnectionsPRMergeStatus.groups(entries: entries)
        XCTAssertEqual(groups[0].keys, ["in_review", "in_progress", "qa"])
        XCTAssertEqual(groups[1].keys, ["done"])
    }

    func testMcpFormRoundTrip() {
        var form = ConnectionsMcpForm()
        form.command = " npx "
        form.args = ["-y", "server"]
        form.env = [ConnectionsKeyValue(key: "TOKEN", value: "x"), ConnectionsKeyValue(key: " ", value: "ignored")]
        let config = form.config
        XCTAssertEqual(config["command"], "npx")
        XCTAssertEqual(config["args"], JSONValue(["-y", "server"]))
        XCTAssertEqual(config["env"], ["TOKEN": "x"])
        let back = ConnectionsMcpForm(config: config)
        XCTAssertEqual(back.transport, .stdio)
        XCTAssertEqual(back.args, ["-y", "server"])

        var http = ConnectionsMcpForm(transport: .http)
        XCTAssertEqual(http.problem, .url)
        http.url = "https://mcp.example.com/mcp"
        XCTAssertEqual(http.config["type"], "http")
        XCTAssertTrue(ConnectionsMcp.prettyJSON(http.config).contains("https://mcp.example.com/mcp"))

        let legacy = ConnectionsMcpForm(config: ["command": ["node", "a.js"], "cwd": "/tmp"])
        XCTAssertEqual(legacy.command, "node")
        XCTAssertEqual(legacy.args, ["a.js"])
        XCTAssertEqual(legacy.config["cwd"], "/tmp")
    }

    func testMcpJSONValidation() {
        XCTAssertEqual(ConnectionsMcp.parseServerJSON("[]"), .notObject)
        XCTAssertEqual(ConnectionsMcp.parseServerJSON(#"{"command":""}"#), .missingTarget)
        if case .ok(let o) = ConnectionsMcp.parseServerJSON(#"{"url":"https://x"}"#) {
            XCTAssertEqual(o["url"], "https://x")
        } else {
            XCTFail("expected ok")
        }
        if case .invalid = ConnectionsMcp.parseServerJSON("{") {} else { XCTFail("expected invalid") }
        XCTAssertEqual(ConnectionsMcp.transportLabel("streamable-http"), "Streamable HTTP")
        XCTAssertEqual(ConnectionsMcp.transportLabel(""), "Unknown")
        XCTAssertTrue(ConnectionsMcp.isValidName("my_server-1"))
        XCTAssertFalse(ConnectionsMcp.isValidName("my server"))
    }

    func testPluginScheduleFrequency() {
        XCTAssertEqual(ConnectionsPlugins.frequency("*/15 * * * *"), .minutes(15))
        XCTAssertEqual(ConnectionsPlugins.frequency("5 * * * *"), .hourly(minute: "5"))
        XCTAssertEqual(ConnectionsPlugins.frequency("5 9 * * *"), .daily(hour: "09", minute: "05"))
        XCTAssertEqual(ConnectionsPlugins.frequency("0 9 * * 1"), .custom)
        XCTAssertEqual(ConnectionsPlugins.frequency("bad"), .custom)
        XCTAssertEqual(ConnectionsPlugins.scopeKey("net:api.example.com").args["domain"], "api.example.com")
        XCTAssertEqual(ConnectionsPlugins.scopeKey("weird").key, "unknown")
    }

    func testPluginInvocationSummary() {
        func inv(_ status: String, _ error: String? = nil) -> PluginInvocation {
            PluginInvocation(id: UUID().uuidString, hookKey: "h", trigger: "event", status: status, error: error)
        }
        let s = ConnectionsPlugins.summarize([inv("error", "boom"), inv("error"), inv("ok"), inv("error", "old")])
        XCTAssertEqual(s.failures, 3)
        XCTAssertEqual(s.consecutiveFailures, 2)
        XCTAssertEqual(s.lastError, "boom")
        XCTAssertFalse(s.tripped)
        let tools = [PluginMCPTool(name: "a", approved: true), PluginMCPTool(name: "b", approved: true, drifted: true), PluginMCPTool(name: "c")]
        XCTAssertEqual(ConnectionsPlugins.initialSelection(tools), ["a"])
        let payload = ConnectionsPlugins.configPayload(values: ["x": 1], secrets: ["k": "", "s": "v"])
        XCTAssertNil(payload["k"])
        XCTAssertEqual(payload["s"], "v")
    }

    func testPluginSurfaceBridge() {
        for ok in ["/context", "/issues/abc", "/issues/abc/comments", "/storage/user", "/storage/workspace/key", "/hooks/sync"] {
            XCTAssertTrue(ConnectionsPlugins.isAllowedBridgePath(ok), ok)
        }
        for bad in ["/", "context", "/issues", "/issues/a/b", "/storage/other", "/members", "/hooks/a/b", "/issues//comments"] {
            XCTAssertFalse(ConnectionsPlugins.isAllowedBridgePath(bad), bad)
        }
        XCTAssertNil(ConnectionsPlugins.surfaceDocument(url: "javascript:alert(1)", bridgeToken: "t", theme: [:]))
        XCTAssertNil(ConnectionsPlugins.surfaceDocument(url: "https://plugins.example.com/p", bridgeToken: "", theme: [:]))
        let doc = ConnectionsPlugins.surfaceDocument(url: "https://plugins.example.com:8443/p/index.html", bridgeToken: "tok", theme: ["--background": "#fff"])
        XCTAssertTrue(doc?.contains("frame-src https://plugins.example.com:8443") ?? false)
        XCTAssertFalse(doc?.contains("tok\"") ?? true)
    }

    func testBillingUsageAndFormatting() {
        let limited = WorkspaceSubscriptionEntitlements(limits: ["autopilotRuns": ["mode": "limited", "limit": 100], "issue_count": ["mode": "unlimited"]])
        XCTAssertTrue(limited.connectionsIssueLimit.unlimited)
        XCTAssertEqual(limited.connectionsAutopilotLimit.limit, 100)
        let usage = AutopilotQuotaUsage(action: "block", used: 40, reserved: 10, total: 50, limit: 100, reached: false, resetAt: "2026-11-01T00:00:00Z")
        if case .metered(_, _, let total, _, let progress, _, _) = ConnectionsBilling.autopilotUsage(entitlements: limited, usage: usage, failed: false) {
            XCTAssertEqual(total, 50)
            XCTAssertEqual(progress, 50)
        } else {
            XCTFail("expected metered")
        }
        XCTAssertEqual(ConnectionsBilling.autopilotUsage(entitlements: limited, usage: usage, failed: true), .unavailable)
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(ConnectionsBilling.formatStripeMinorAmount(2000, currency: "usd", locale: en), "$20")
        XCTAssertEqual(ConnectionsBilling.formatStripeMinorAmount(2050, currency: "USD", locale: en), "$20.50")
        XCTAssertEqual(ConnectionsBilling.formatStripeMinorAmount(500, currency: "JPY", locale: en), "¥500")
        XCTAssertNil(ConnectionsBilling.formatStripeMinorAmount(-1, currency: "USD", locale: en))
        XCTAssertNil(ConnectionsBilling.formatStripeMinorAmount(1.5, currency: "USD", locale: en))
        XCTAssertEqual(ConnectionsBilling.parseAdditionalSeats(" 3 "), 3)
        XCTAssertEqual(ConnectionsBilling.parseAdditionalSeats("2.5"), 0)
        XCTAssertEqual(ConnectionsBilling.seatInvitationCapacityFailure("seat_capacity_full"), .full)
        XCTAssertFalse(ConnectionsBilling.seatPurchaseCanRetryWithSameQuote("seat_quote_changed"))
    }

    func testSubscriptionSummaryDecodesSnakeCase() throws {
        let json = #"""
        {"entitlement":{"workspace_id":"w","plan":"pro","status":"active","seats":3,
          "limits":{"issue_count":{"mode":"unlimited","limit":null},"autopilot_runs":{"mode":"limited","limit":50}},
          "current_period_end":"2026-11-01T00:00:00Z","version":2},
         "billing_interval":"month","human_members":3,
         "seat_capacity":{"purchased":5,"used":3,"reserved":1,"available":1,"overcommitted":false,"version":4,"pending_quantity":null},
         "cancel_at_period_end":false,"grace_until":null,"has_stripe_customer":true,
         "available_actions":{"checkout":false,"portal":true,"purchase_seats":true}}
        """#
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let s = try d.decode(WorkspaceSubscriptionSummary.self, from: Data(json.utf8))
        XCTAssertEqual(s.billingInterval, "month")
        XCTAssertEqual(s.humanMembers, 3)
        XCTAssertEqual(s.seatCapacity?.purchased, 5)
        XCTAssertEqual(s.entitlement?.currentPeriodEnd, "2026-11-01T00:00:00Z")
        XCTAssertEqual(s.connectionsActions, ConnectionsBillingActions(checkout: false, portal: true, purchaseSeats: true))
        XCTAssertEqual(s.entitlement?.connectionsAutopilotLimit.limit, 50)
        XCTAssertTrue(s.entitlement?.connectionsIssueLimit.unlimited ?? false)
    }

    func testAPIErrorCarriesCode() {
        let e = APIError.from(status: 409, body: Data(#"{"error":"changed","code":"seat_capacity_changed"}"#.utf8))
        XCTAssertEqual(e.code, "seat_capacity_changed")
        XCTAssertEqual(e.message, "changed")
    }

    func testDingTalkGroups() {
        let bot = { (inst: String, name: String, issue: String, active: String?) in
            DingTalkGroupBot(installationId: inst, botName: name, botIdentityIssue: issue, lastActiveAt: active)
        }
        let groups = [
            DingTalkGroup(conversationId: "c2", conversationTitle: "", bots: [bot("i", "", "missing_qyapi_chat_manage", nil)]),
            DingTalkGroup(conversationId: "c1", conversationTitle: "B", bots: [bot("i", "Robot", "", "2026-10-01T00:00:00Z")]),
            DingTalkGroup(conversationId: "c3", conversationTitle: "A", bots: [bot("i", "", "", nil)]),
        ]
        let identity = ConnectionsChannels.dingTalkBotIdentity(groups: groups, installationID: "i")
        XCTAssertEqual(identity?.botName, "Robot")
        XCTAssertEqual(identity?.botIdentityIssue, "missing_qyapi_chat_manage")
        XCTAssertEqual(ConnectionsChannels.observedGroups(groups, installationID: "i").map(\.group.conversationId), ["c1", "c3", "c2"])
        XCTAssertNil(ConnectionsChannels.installedAt("0001-01-01T00:00:00Z"))
    }

    func testComposioState() {
        let state = ConnectionsComposio.State([
            ComposioConnection(id: "1", toolkitSlug: "gmail", status: "active", lastUsedAt: "2026-10-01T00:00:00Z"),
            ComposioConnection(id: "2", toolkitSlug: "notion", status: "expired"),
        ])
        XCTAssertEqual(state.activeConnectionBySlug["gmail"], "1")
        XCTAssertTrue(state.expiredSlugs.contains("notion"))
        XCTAssertEqual(ConnectionsComposio.logoURLs(slug: "Gmail", fallback: nil, dark: true),
                       ["https://logos.composio.dev/api/gmail?theme=dark", "https://logos.composio.dev/api/gmail"])
        let kits = [ComposioToolkit(slug: "gmail", name: "Gmail", category: "Email"), ComposioToolkit(slug: "x", name: "X")]
        XCTAssertEqual(ConnectionsComposio.filter(kits, query: "email").map(\.slug), ["gmail"])
    }

    func testSVGPathParsing() {
        let cmds = ConnectionsSVGPath.parse("M1 2h3v4l-1-1zm10 10c1 1 2 2 3 3s1 1 2 2a1 1 0 0 1-2 0Q1 1 2 2t3 3")
        XCTAssertEqual(cmds.first, .move(.init(1, 2)))
        XCTAssertEqual(cmds[1], .line(.init(4, 2)))
        XCTAssertEqual(cmds[2], .line(.init(4, 6)))
        XCTAssertEqual(cmds[3], .line(.init(3, 5)))
        XCTAssertEqual(cmds[4], .close)
        XCTAssertEqual(cmds[5], .move(.init(11, 12)))
        if case .cubic(_, _, let end) = cmds.last! {
            XCTAssertEqual(end.x, 5, accuracy: 1e-9)
            XCTAssertEqual(end.y, 5, accuracy: 1e-9)
        } else {
            XCTFail("expected cubic")
        }
        // Compact arc flags and numbers.
        let compact = ConnectionsSVGPath.parse("M0 0a1.685 1.685 0 0 1-1.682-1.68.5.5 0 01.5.5")
        let ends = compact.compactMap { cmd -> ConnectionsSVGPath.Point? in
            if case .cubic(_, _, let end) = cmd { return end }
            return nil
        }
        XCTAssertTrue(ends.contains { abs($0.x + 1.682) < 1e-9 && abs($0.y + 1.68) < 1e-9 })
        XCTAssertEqual(ends.last?.x ?? 0, -1.182, accuracy: 1e-9)
        XCTAssertEqual(ends.last?.y ?? 0, -1.18, accuracy: 1e-9)
    }
}
