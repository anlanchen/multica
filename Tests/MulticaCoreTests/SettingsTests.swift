import XCTest
@testable import MulticaCore

final class SettingsLocationTests: XCTestCase {
    func testDefaultsToProfileAndKeepsSectionAndIntegration() {
        XCTAssertEqual(SettingsLocation.resolve([:]), SettingsLocation(tab: "profile"))
        XCTAssertEqual(SettingsLocation.resolve(["tab": "members", "section": "links"]), SettingsLocation(tab: "members", section: "links"))
    }

    func testLegacyTabsMapToTheirCurrentPages() {
        XCTAssertEqual(SettingsLocation.resolve(["tab": "issue"]), SettingsLocation(tab: "preferences", section: "issue"))
        XCTAssertEqual(SettingsLocation.resolve(["tab": "chat"]), SettingsLocation(tab: "preferences", section: "chat"))
        XCTAssertEqual(SettingsLocation.resolve(["tab": "labs"]), SettingsLocation(tab: "workspace"))
        XCTAssertEqual(SettingsLocation.resolve(["tab": "github", "section": "x"]), SettingsLocation(tab: "code", section: "x"))
        XCTAssertEqual(SettingsLocation.resolve(["tab": "repositories"]), SettingsLocation(tab: "code", section: "repositories"))
        XCTAssertEqual(SettingsLocation.resolve(["tab": "slack"]), SettingsLocation(tab: "channels", integration: "slack"))
    }

    func testIntegrationsCallbacks() {
        XCTAssertEqual(SettingsLocation.resolve(["tab": "integrations", "connected": "gmail"]).tab, "apps")
        XCTAssertEqual(SettingsLocation.resolve(["tab": "integrations", "error": "composio_connect_failed"]).tab, "apps")
        XCTAssertEqual(SettingsLocation.resolve(["tab": "integrations", "integration": "github"]), SettingsLocation(tab: "code"))
        XCTAssertEqual(SettingsLocation.resolve(["tab": "integrations", "integration": "vcs"]), SettingsLocation(tab: "code", section: "code-hosting"))
        XCTAssertEqual(SettingsLocation.resolve(["tab": "integrations", "integration": "lark"]), SettingsLocation(tab: "channels", integration: "lark"))
        XCTAssertEqual(SettingsLocation.resolve(["tab": "integrations", "integration": "nope"]), SettingsLocation(tab: "channels"))
    }

    func testQueryKeepsUnrelatedParameters() {
        let q = SettingsLocation.query(from: ["tab": "members", "section": "links", "connected": "1"], tab: "labels")
        XCTAssertEqual(q, ["tab": "labels", "connected": "1"])
        XCTAssertEqual(SettingsLocation.query(from: [:], tab: "code", section: "github")["section"], "github")
    }
}

final class SettingsSearchTests: XCTestCase {
    private let entries = [
        SettingsSearchEntry(tab: "profile", title: "Profile"),
        SettingsSearchEntry(tab: "profile", anchor: "name", title: "Name"),
        SettingsSearchEntry(tab: "preferences", anchor: "theme", title: "Theme", description: "Light or dark appearance for this device"),
        SettingsSearchEntry(tab: "workspace", anchor: "name", title: "Workspace name"),
    ]

    func testEmptyQueryFindsNothing() {
        XCTAssertTrue(SettingsSearch.search(entries, query: "  ").isEmpty)
    }

    func testTitleHitsComeBeforeDescriptionHits() {
        let results = SettingsSearch.search(entries + [SettingsSearchEntry(tab: "x", title: "Dark mode")], query: "dark")
        XCTAssertEqual(results.map(\.entry.tab), ["x", "preferences"])
    }

    func testResultsDedupeByLocationAndKeepIndexOrder() {
        let dup = entries + [SettingsSearchEntry(tab: "profile", anchor: "name", title: "Name again")]
        XCTAssertEqual(SettingsSearch.search(dup, query: "name").map(\.entry.key), ["profile#name#", "workspace#name#"])
    }

    func testSnippetKeepsTheMatchVisible() {
        XCTAssertEqual(SettingsSearch.snippet("Light or dark", needle: "dark"), "Light or dark")
        XCTAssertEqual(SettingsSearch.snippet("Light or dark appearance for this device", needle: "device"), "... this device")
        XCTAssertEqual(SettingsSearch.snippet("abc", needle: "zzz"), "abc")
    }

    func testIndexFoldsPageDescriptionsAndDropsHiddenPages() {
        let rows = [
            SettingsSearchEntry(tab: "labels", title: "Labels", description: "Organize issues"),
            SettingsSearchEntry(tab: "labels", anchor: "x", title: "Row"),
            SettingsSearchEntry(tab: "billing", anchor: "y", title: "Hidden"),
        ]
        let index = SettingsSearch.index(pages: [(value: "labels", label: "Labels")], rows: rows)
        XCTAssertEqual(index, [
            SettingsSearchEntry(tab: "labels", title: "Labels", description: "Organize issues"),
            SettingsSearchEntry(tab: "labels", anchor: "x", title: "Row"),
        ])
    }
}

final class SettingsShortcutPolicyTests: XCTestCase {
    typealias C = SettingsShortcutPolicy.Chord

    func testAppOwnedChordsAreReserved() {
        for key in ["W", "R", "Q", "T", ",", "C", "V", "1", "9", "0", "="] {
            XCTAssertTrue(SettingsShortcutPolicy.isReserved(C(key: key, primary: true)), key)
        }
        XCTAssertTrue(SettingsShortcutPolicy.isReserved(C(key: "]", primary: true, shift: true)))
        XCTAssertTrue(SettingsShortcutPolicy.isReserved(C(key: "Space", primary: true)))
        XCTAssertTrue(SettingsShortcutPolicy.isReserved(C(key: "Left", control: true)))
        XCTAssertTrue(SettingsShortcutPolicy.isReserved(C(key: "P", primary: true, shift: true)))
        XCTAssertFalse(SettingsShortcutPolicy.isReserved(C(key: "P", primary: true)))
        XCTAssertFalse(SettingsShortcutPolicy.isReserved(C(key: "K", primary: true)))
        XCTAssertFalse(SettingsShortcutPolicy.isReserved(C(key: "]", primary: true)))
    }

    func testEditorSafeActionsNeedCommand() {
        XCTAssertTrue(SettingsShortcutPolicy.isAllowed(C(key: "K", primary: true), isSend: false, allowInEditable: true))
        XCTAssertFalse(SettingsShortcutPolicy.isAllowed(C(key: "K", shift: true), isSend: false, allowInEditable: true))
        XCTAssertFalse(SettingsShortcutPolicy.isAllowed(C(key: "K"), isSend: false, allowInEditable: true))
    }

    func testPlainKeysAllowedOutsideEditorsExceptNavigationKeys() {
        XCTAssertTrue(SettingsShortcutPolicy.isAllowed(C(key: "G"), isSend: false, allowInEditable: false))
        XCTAssertFalse(SettingsShortcutPolicy.isAllowed(C(key: "Enter"), isSend: false, allowInEditable: false))
        XCTAssertTrue(SettingsShortcutPolicy.isAllowed(C(key: "Enter", shift: true), isSend: false, allowInEditable: false))
        XCTAssertFalse(SettingsShortcutPolicy.isAllowed(C(key: "Tab", alt: true), isSend: false, allowInEditable: false))
    }

    func testSendTakesOnlyEnterOrCommandEnter() {
        XCTAssertTrue(SettingsShortcutPolicy.isAllowed(C(key: "Enter"), isSend: true, allowInEditable: true))
        XCTAssertTrue(SettingsShortcutPolicy.isAllowed(C(key: "Enter", primary: true), isSend: true, allowInEditable: true))
        XCTAssertFalse(SettingsShortcutPolicy.isAllowed(C(key: "Enter", shift: true), isSend: true, allowInEditable: true))
        XCTAssertFalse(SettingsShortcutPolicy.isAllowed(C(key: "S", primary: true), isSend: true, allowInEditable: true))
    }
}

final class SettingsSeatPurchaseTests: XCTestCase {
    private let preview = WorkspaceSeatPurchasePreview(currentSeats: 3, additionalSeats: 1, resultingSeats: 4, purchaseVersion: 7,
                                                       currency: "usd", prorationAmount: 1250, nextInvoiceAmount: 4000, quotedAt: "")

    func testCapacityFailureCodes() {
        XCTAssertEqual(SettingsSeatPurchase.capacityFailure("seat_capacity_full"), .full)
        XCTAssertEqual(SettingsSeatPurchase.capacityFailure("seat_capacity_unavailable"), .unavailable)
        XCTAssertEqual(SettingsSeatPurchase.capacityFailure("seat_capacity_rate_limited"), .rateLimited)
        XCTAssertNil(SettingsSeatPurchase.capacityFailure(nil))
        XCTAssertTrue(SettingsSeatPurchase.canRetryInvitationAfterPurchase("seat_capacity_rate_limited"))
        XCTAssertFalse(SettingsSeatPurchase.canRetryInvitationAfterPurchase("seat_capacity_full"))
    }

    func testPreviewValidation() {
        XCTAssertTrue(SettingsSeatPurchase.isSingleSeatPreview(preview))
        var bad = preview
        bad.resultingSeats = 5
        XCTAssertFalse(SettingsSeatPurchase.isSingleSeatPreview(bad))
        bad = preview
        bad.prorationAmount = 12.5
        XCTAssertFalse(SettingsSeatPurchase.isSingleSeatPreview(bad))
        XCTAssertFalse(SettingsSeatPurchase.isSingleSeatPreview(nil))
    }

    func testPurchaseResponseMustMatchQuote() {
        let ok = PurchaseWorkspaceSeatsResponse(currentSeats: 3, additionalSeats: 1, resultingSeats: 4, currency: "usd")
        XCTAssertTrue(SettingsSeatPurchase.purchaseMatchesPreview(ok, preview))
        XCTAssertFalse(SettingsSeatPurchase.purchaseMatchesPreview(PurchaseWorkspaceSeatsResponse(currentSeats: 3, additionalSeats: 1, resultingSeats: 4, currency: "eur"), preview))
        XCTAssertFalse(SettingsSeatPurchase.canRetryWithSameQuote("seat_quote_changed"))
        XCTAssertTrue(SettingsSeatPurchase.canRetryWithSameQuote(nil))
    }

    func testSeatReadinessNeedsAFreshSummaryWithCapacity() {
        let t0 = Date(timeIntervalSince1970: 100)
        let summary = WorkspaceSubscriptionSummary(seatCapacity: WorkspaceSeatCapacity(purchased: 4, used: 3, available: 1))
        XCTAssertTrue(SettingsSeatPurchase.seatIsReadyForInvitation(summary, preview: preview, submittedAt: t0, summaryFetchedAt: t0.addingTimeInterval(2)))
        XCTAssertFalse(SettingsSeatPurchase.seatIsReadyForInvitation(summary, preview: preview, submittedAt: t0, summaryFetchedAt: t0.addingTimeInterval(-1)))
        let full = WorkspaceSubscriptionSummary(seatCapacity: WorkspaceSeatCapacity(purchased: 4, used: 4, available: 0))
        XCTAssertFalse(SettingsSeatPurchase.seatIsReadyForInvitation(full, preview: preview, submittedAt: t0, summaryFetchedAt: t0))
    }

    func testMinorAmountFormatting() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(SettingsSeatPurchase.formatMinorAmount(1250, currency: "usd", locale: en), "$12.50")
        XCTAssertEqual(SettingsSeatPurchase.formatMinorAmount(4000, currency: "USD", locale: en), "$40")
        XCTAssertEqual(SettingsSeatPurchase.formatMinorAmount(500, currency: "JPY", locale: en), "¥500")
        XCTAssertNil(SettingsSeatPurchase.formatMinorAmount(-1, currency: "USD", locale: en))
        XCTAssertNil(SettingsSeatPurchase.formatMinorAmount(10, currency: " ", locale: en))
    }
}

final class SettingsRulesTests: XCTestCase {
    func testIssuePrefixNormalization() {
        XCTAssertEqual(SettingsRules.normalizeIssuePrefix("mul-1 x"), "MUL1X")
        XCTAssertEqual(SettingsRules.normalizeIssuePrefix("abcdefghijklmn"), "ABCDEFGHIJ")
        XCTAssertEqual(SettingsRules.normalizeIssuePrefix("客户"), "")
    }

    func testTemplateTokenDetection() {
        XCTAssertNil(SettingsRules.quickActionTemplateToken("Summarize the issue"))
        XCTAssertEqual(SettingsRules.quickActionTemplateToken("Fix {{issue.title}} now"), "{{issue.title}}")
        XCTAssertEqual(SettingsRules.quickActionTemplateToken("a {{b} c {{d}}"), "{{d}}")
        XCTAssertNil(SettingsRules.quickActionTemplateToken("{{open"))
        XCTAssertEqual(SettingsRules.quickActionTemplateToken("{{}}"), "{{}}")
    }

    func testQuickActionOrderingAndStaleness() {
        let now = Date(timeIntervalSince1970: 200 * 86_400)
        func iso(_ day: Double) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: day * 86_400)) }
        let a = QuickAction(id: "a", name: "B", status: "active", useCount: 1, createdAt: iso(10))
        let b = QuickAction(id: "b", name: "A", status: "active", useCount: 5, createdAt: iso(10))
        let c = QuickAction(id: "c", name: "C", status: "archived", useCount: 99, createdAt: iso(10))
        let d = QuickAction(id: "d", name: "A2", status: "active", useCount: 1, createdAt: iso(10))
        XCTAssertEqual(SettingsRules.sortQuickActions([c, a, d, b]).map(\.id), ["b", "d", "a", "c"])
        XCTAssertTrue(SettingsRules.isStaleQuickAction(QuickAction(lastUsedAt: iso(100), createdAt: iso(10)), now: now))
        XCTAssertFalse(SettingsRules.isStaleQuickAction(QuickAction(lastUsedAt: iso(150), createdAt: iso(10)), now: now))
        XCTAssertFalse(SettingsRules.isStaleQuickAction(QuickAction(createdAt: iso(150)), now: now))
        XCTAssertTrue(SettingsRules.isStaleQuickAction(QuickAction(createdAt: iso(50)), now: now))
    }

    func testUTCOffsets() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(SettingsRules.utcOffset(TimeZone(identifier: "UTC")!, at: date), "UTC+0")
        XCTAssertEqual(SettingsRules.utcOffset(TimeZone(identifier: "Asia/Shanghai")!, at: date), "UTC+8")
        XCTAssertEqual(SettingsRules.utcOffset(TimeZone(secondsFromGMT: -(3 * 3600 + 1800))!, at: date), "UTC-3:30")
    }

    func testPRMergeStatus() {
        XCTAssertEqual(SettingsRules.prMergeStatus(settings: [:]), "done")
        XCTAssertEqual(SettingsRules.prMergeStatus(settings: ["pr_auto_complete_enabled": .bool(false)]), "none")
        XCTAssertEqual(SettingsRules.prMergeStatus(settings: ["pr_merge_status": .string(" In_Review ")]), "in_review")
        XCTAssertEqual(SettingsRules.prMergeStatus(settings: ["pr_merge_status": .string("")]), "none")
    }

    func testStatusOrdering() {
        var custom = IssueStatusEntry(id: "c", key: "qa", name: "QA", category: .started, position: 0, isSystem: false)
        let todo = IssueStatusEntry(id: "t", key: .todo, name: "Todo", category: .unstarted, position: 0)
        let backlog = IssueStatusEntry(id: "b", key: .backlog, name: "Backlog", category: .unstarted, position: 0)
        let progress = IssueStatusEntry(id: "p", key: .inProgress, name: "In Progress", category: .started, position: 0)
        let done = IssueStatusEntry(id: "d", key: .done, name: "Done", category: StatusCategory(rawValue: "completed"), position: 0)
        let sorted = [done, custom, todo, progress, backlog].sorted(by: SettingsRules.compareStatuses)
        XCTAssertEqual(sorted.map(\.id), ["b", "t", "p", "c", "d"])
        custom.position = -1
        XCTAssertEqual([progress, custom].sorted(by: SettingsRules.compareStatuses).map(\.id), ["c", "p"])
        XCTAssertEqual(SettingsRules.normalizeCategory("canceled"), .closed)
        XCTAssertEqual(SettingsRules.normalizeCategory("in_review"), .started)
        XCTAssertNil(SettingsRules.normalizeCategory("weird"))
    }

    func testColorHelpers() {
        XCTAssertEqual(SettingsColor.normalizeHex(" #ABCDEF "), "#abcdef")
        XCTAssertEqual(SettingsColor.normalizeHex("3b82f6"), "#3b82f6")
        XCTAssertNil(SettingsColor.normalizeHex("#abc"))
        XCTAssertNil(SettingsColor.normalizeHex("#gggggg"))
        XCTAssertEqual(SettingsColor.hue("#ff0000"), 0)
        XCTAssertEqual(SettingsColor.hue("#00ff00"), 120)
        XCTAssertNil(SettingsColor.hue("#808080"))
        XCTAssertEqual(SettingsColor.hslToHex(hue: 0, saturation: 1, lightness: 0.5), "#ff0000")
        XCTAssertEqual(SettingsColor.hslToHex(hue: 240, saturation: 1, lightness: 0.5), "#0000ff")
        for _ in 0..<50 {
            let c = SettingsColor.random(avoiding: "#ff0000")
            XCTAssertNotNil(SettingsColor.normalizeHex(c))
            let h = SettingsColor.hue(c) ?? 0
            XCTAssertGreaterThanOrEqual(min(h, 360 - h), 38, c)
        }
    }

    func testSettingsAPIErrorReadsCodeAndIssueCount() {
        let body = Data(#"{"error":"in use","code":"status_in_use","issue_count":3}"#.utf8)
        let e = SettingsAPIError.from(status: 409, data: body)
        XCTAssertEqual(e.message, "in use")
        XCTAssertEqual(e.code, "status_in_use")
        XCTAssertEqual(e.issueCount, 3)
        XCTAssertNil(SettingsAPIError.from(status: 400, data: body).issueCount)
        XCTAssertEqual(SettingsAPIError.from(status: 500, data: Data()).message, "Request failed with status 500")
    }
}
