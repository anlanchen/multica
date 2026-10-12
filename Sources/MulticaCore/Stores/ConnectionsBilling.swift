import Foundation

// Workspace subscription presentation logic (upstream settings/components
// billing-state.ts, billing-format.ts, seat-invite-purchase.ts).

/// One entitlement limit: `{mode: "limited", limit}` or `{mode: "unlimited"}`.
public struct ConnectionsEntitlementLimit: Sendable, Hashable {
    public var unlimited: Bool
    public var limit: Int?

    public init(unlimited: Bool, limit: Int?) {
        self.unlimited = unlimited
        self.limit = limit
    }

    init(_ value: JSONValue?) {
        unlimited = value?["mode"]?.stringValue == "unlimited"
        limit = value?["limit"]?.doubleValue.map { Int($0) }
    }
}

public struct ConnectionsBillingActions: Sendable, Hashable {
    public var checkout = false
    public var portal = false
    public var purchaseSeats = false

    public init(checkout: Bool = false, portal: Bool = false, purchaseSeats: Bool = false) {
        self.checkout = checkout
        self.portal = portal
        self.purchaseSeats = purchaseSeats
    }
}

private func connectionsField(_ value: JSONValue?, _ camel: String, _ snake: String) -> JSONValue? {
    value?[camel] ?? value?[snake]
}

extension WorkspaceSubscriptionEntitlements {
    public var connectionsIssueLimit: ConnectionsEntitlementLimit {
        ConnectionsEntitlementLimit(connectionsField(limits, "issueCount", "issue_count"))
    }

    public var connectionsAutopilotLimit: ConnectionsEntitlementLimit {
        ConnectionsEntitlementLimit(connectionsField(limits, "autopilotRuns", "autopilot_runs"))
    }
}

extension WorkspaceSubscriptionSummary {
    public var connectionsActions: ConnectionsBillingActions {
        ConnectionsBillingActions(
            checkout: availableActions["checkout"]?.boolValue ?? false,
            portal: availableActions["portal"]?.boolValue ?? false,
            purchaseSeats: connectionsField(availableActions, "purchaseSeats", "purchase_seats")?.boolValue ?? false)
    }
}

public enum ConnectionsAutopilotUsage: Sendable, Hashable {
    case unlimited
    case unavailable
    case metered(used: Int, reserved: Int, total: Int, limit: Int, progress: Double, reached: Bool, resetAt: String)
}

public enum ConnectionsBilling {
    /// Quota admission counts completed and reserved runs; limit mode and the
    /// reached decision are server facts.
    public static func autopilotUsage(entitlements: WorkspaceSubscriptionEntitlements, usage: AutopilotQuotaUsage?,
                                      failed: Bool) -> ConnectionsAutopilotUsage {
        if entitlements.connectionsAutopilotLimit.unlimited { return .unlimited }
        guard !failed, let usage, usage.action != "off",
              let used = usage.used, let reserved = usage.reserved, let total = usage.total, let limit = usage.limit,
              let reached = usage.reached, let resetAt = usage.resetAt,
              used >= 0, reserved >= 0, limit >= 0, used.isFinite, reserved.isFinite else {
            return .unavailable
        }
        let progress = limit == 0 ? 100 : min(100, max(0, Double(total) / Double(limit) * 100))
        return .metered(used: Int(used), reserved: Int(reserved), total: total, limit: limit, progress: progress,
                        reached: reached, resetAt: resetAt)
    }

    public static func hasActiveSeatCapacity(_ summary: WorkspaceSubscriptionSummary?) -> Bool {
        summary?.seatCapacity != nil
    }

    private static let zeroDecimal: Set<String> = ["BIF", "CLP", "DJF", "GNF", "JPY", "KMF", "KRW", "MGA", "PYG", "RWF", "VND", "VUV", "XAF", "XOF", "XPF"]
    private static let twoDecimalCompat: Set<String> = ["ISK", "UGX"]
    private static let threeDecimal: Set<String> = ["BHD", "JOD", "KWD", "OMR", "TND"]

    /// Formats a Stripe minor-unit amount without guessing currency precision;
    /// nil for amounts that are not safe non-negative integers.
    public static func formatStripeMinorAmount(_ amount: Double, currency: String, locale: Locale) -> String? {
        guard amount >= 0, amount == amount.rounded(), amount <= 9_007_199_254_740_991 else { return nil }
        let code = currency.trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { return nil }
        let digits = twoDecimalCompat.contains(code) ? 2 : zeroDecimal.contains(code) ? 0 : threeDecimal.contains(code) ? 3 : 2
        var divisor = 1.0
        for _ in 0..<digits { divisor *= 10 }
        let major = amount / divisor
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = locale
        f.currencyCode = code
        if major == major.rounded() {
            f.minimumFractionDigits = 0
            f.maximumFractionDigits = 0
        } else {
            f.minimumFractionDigits = digits
            f.maximumFractionDigits = digits
        }
        return f.string(from: NSNumber(value: major))
    }

    public static func idempotencyKey(_ prefix: String, workspaceID: String, limit: Int = 255) -> String {
        String("\(prefix)-\(workspaceID)-\(UUID().uuidString.lowercased())".prefix(limit))
    }

    // MARK: Seat invitations (members tab)

    public enum SeatCapacityFailure: String, Sendable {
        case full, unavailable, rateLimited = "rate_limited"
    }

    public static func seatInvitationCapacityFailure(_ code: String?) -> SeatCapacityFailure? {
        switch code {
        case "seat_capacity_full": return .full
        case "seat_capacity_unavailable": return .unavailable
        case "seat_capacity_rate_limited": return .rateLimited
        default: return nil
        }
    }

    public static func seatInvitationCanRetryAfterPurchase(_ code: String?) -> Bool {
        let f = seatInvitationCapacityFailure(code)
        return f == .unavailable || f == .rateLimited
    }

    public static func isSingleSeatInvitePreview(_ p: WorkspaceSeatPurchasePreview?) -> Bool {
        guard let p else { return false }
        return p.additionalSeats == 1 && p.resultingSeats == p.currentSeats + 1
            && p.prorationAmount >= 0 && p.prorationAmount == p.prorationAmount.rounded()
            && p.nextInvoiceAmount >= 0 && p.nextInvoiceAmount == p.nextInvoiceAmount.rounded()
    }

    public static func seatPurchaseMatchesPreview(_ r: PurchaseWorkspaceSeatsResponse?, _ p: WorkspaceSeatPurchasePreview) -> Bool {
        guard let r else { return false }
        return r.currentSeats == p.currentSeats && r.additionalSeats == p.additionalSeats
            && r.resultingSeats == p.resultingSeats && r.currency == p.currency
    }

    public static func seatPurchaseCanRetryWithSameQuote(_ code: String?) -> Bool {
        !["seat_purchase_payment_failed", "seat_purchase_in_progress", "seat_quote_changed", "seat_capacity_changed"].contains(code ?? "")
    }

    public static func purchasedSeatIsReadyForInvitation(_ summary: WorkspaceSubscriptionSummary?, preview: WorkspaceSeatPurchasePreview,
                                                         submittedAt: Date, summaryUpdatedAt: Date) -> Bool {
        guard summaryUpdatedAt >= submittedAt, let c = summary?.seatCapacity else { return false }
        return c.purchased >= preview.resultingSeats && c.available >= 1
    }

    /// Parses the add-seats input: digits only, else 0.
    public static func parseAdditionalSeats(_ input: String) -> Int {
        let v = input.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v.allSatisfy(\.isASCII), v.allSatisfy(\.isNumber) else { return 0 }
        return Int(v) ?? 0
    }

    /// A preview answers the request only when every echoed number matches.
    public static func previewMatches(_ p: WorkspaceSeatPurchasePreview?, additionalSeats: Int, currentSeats: Int, version: Int) -> Bool {
        guard let p else { return false }
        return Int(p.additionalSeats) == additionalSeats && Int(p.currentSeats) == currentSeats
            && Int(p.purchaseVersion) == version && Int(p.resultingSeats) == currentSeats + additionalSeats
    }
}
