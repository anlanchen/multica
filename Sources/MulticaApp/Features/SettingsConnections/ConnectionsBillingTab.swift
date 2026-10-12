import MulticaCore
import SwiftUI

/// Workspace subscription state for Settings › Billing (upstream billing-tab.tsx).
@MainActor
@Observable
final class ConnectionsBillingModel {
    enum Phase { case pending, failed, loaded }

    private(set) var summaryPhase = Phase.pending
    private(set) var summary: WorkspaceSubscriptionSummary?
    private(set) var summaryUpdatedAt: Date?
    private(set) var summaryFetching = false

    private(set) var quotaPhase = Phase.pending
    private(set) var quota: AutopilotQuotaUsage?
    private(set) var quotaFetching = false

    private(set) var issueLimit: IssueLimitUsage?

    private(set) var pricesPhase = Phase.pending
    private(set) var prices: WorkspaceSubscriptionPrices?
    private(set) var pricesFetching = false

    func refreshSummary(_ api: APIClient) async {
        summaryFetching = true
        defer { summaryFetching = false }
        do {
            summary = try await api.getWorkspaceSubscriptionSummary()
            summaryPhase = .loaded
            summaryUpdatedAt = Date()
        } catch {
            if summary == nil { summaryPhase = .failed }
        }
    }

    func refreshQuota(_ api: APIClient) async {
        quotaFetching = true
        defer { quotaFetching = false }
        do {
            quota = try await api.getAutopilotQuotaUsage()
            quotaPhase = .loaded
        } catch {
            quotaPhase = .failed
        }
    }

    func refreshIssueLimit(_ api: APIClient) async {
        guard summary?.entitlement?.connectionsIssueLimit.unlimited == false else { return }
        if let usage = try? await api.getIssueLimitUsage() { issueLimit = usage }
    }

    func refreshPrices(_ api: APIClient) async {
        guard summary?.connectionsActions.checkout == true else { return }
        pricesFetching = true
        defer { pricesFetching = false }
        prices = try? await api.getWorkspaceSubscriptionPrices()
        pricesPhase = .loaded
    }

    func refreshAll(_ api: APIClient) async {
        await refreshSummary(api)
        async let q: Void = refreshQuota(api)
        async let i: Void = refreshIssueLimit(api)
        async let p: Void = refreshPrices(api)
        _ = await (q, i, p)
    }
}

/// A second gate inside the tab keeps direct mounts fail-closed while the
/// workspace-subscriptions flag is off.
struct ConnectionsBillingTab: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if env.appConfig?.featureFlags?["billing_workspace_subscriptions"] == true {
            ConnectionsBillingContent()
        }
    }
}

private struct ConnectionsBillingContent: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(\.openURL) private var openURL
    @State private var model = ConnectionsBillingModel()
    @State private var interval = "month"
    @State private var checkoutConfirm: ConnectionsConfirm?
    @State private var checkoutRan = false
    @State private var seatPurchaseOpen = false
    @State private var actionError: String?
    @State private var portalUnavailable = false
    @State private var seatPurchaseMessage: String?
    @State private var seatPollingTimedOut = false
    @State private var returnResult: String?
    @State private var returnObservedAt: Date?
    @State private var syncing = false
    @State private var syncTimedOut = false
    @State private var checkoutKey: (interval: String, key: String)?
    @State private var portalKey: String?
    @State private var checkoutPending = false
    @State private var portalPending = false
    @State private var purchasePending = false
    /// Survives closing the dialog so a retry reuses the same idempotency key.
    @State private var seatIntent: ConnectionsSeatIntent?

    private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
        tr("billing", "workspace.\(key)", args)
    }

    private var locale: Locale { Locale(identifier: L10n.shared.language) }
    private var api: APIClient { session.api }
    private var isMutating: Bool { checkoutPending || portalPending || purchasePending }

    private var checkoutConfirmed: Bool {
        guard returnResult == "success", let observed = returnObservedAt, let updated = model.summaryUpdatedAt else { return false }
        return model.summary?.connectionsActions.checkout == false && updated >= observed
    }

    private var pollKey: String {
        "\(syncing)|\(model.summary?.seatCapacity?.activePurchase?.requestId ?? "")|\(seatPollingTimedOut)"
    }

    var body: some View {
        Group {
            switch model.summaryPhase {
            case .pending:
                ConnectionsSettingsPage(title: t("title"), scope: .workspace) {
                    ConnectionsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)).frame(width: 160, height: 18)
                            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)).frame(height: 14)
                            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)).frame(width: 300, height: 14)
                        }
                        .padding(16)
                        .accessibilityLabel(t("loading"))
                    }
                }
            case .failed:
                failurePage
            case .loaded:
                if let summary = model.summary, let entitlements = summary.entitlement {
                    loadedPage(summary, entitlements)
                } else {
                    failurePage
                }
            }
        }
        .task {
            consumeReturn()
            await model.refreshAll(api)
        }
        .task(id: nav.query("result") ?? "") { consumeReturn() }
        .task(id: pollKey) {
            // Checkout activation and seat additions land via a Stripe webhook.
            let active = model.summary?.seatCapacity?.activePurchase != nil
            guard syncing || (active && !seatPollingTimedOut) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await model.refreshSummary(api)
                if checkoutConfirmed {
                    syncing = false
                    syncTimedOut = false
                    checkoutKey = nil
                }
            }
        }
        .task(id: returnResult == "success" ? returnObservedAt : nil) {
            guard returnResult == "success" else { return }
            syncing = true
            syncTimedOut = false
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, syncing else { return }
            syncing = false
            syncTimedOut = true
        }
        .task(id: model.summary?.seatCapacity?.activePurchase?.requestId) {
            seatPollingTimedOut = false
            guard model.summary?.seatCapacity?.activePurchase != nil else { return }
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            seatPollingTimedOut = true
        }
        .connectionsOnAppActive { Task { await model.refreshAll(api) } }
    }

    /// Stripe returns carry `?result=success|cancel|portal`; consumed once.
    private func consumeReturn() {
        guard let raw = nav.query("result") else { return }
        let result = ["success", "cancel", "portal"].contains(raw) ? raw : nil
        returnResult = result
        returnObservedAt = result == "success" ? Date() : nil
        if result == "cancel" { checkoutKey = nil }
        nav.setQuery("result", nil)
        nav.setQuery("session_id", nil)
    }

    private var failurePage: some View {
        ConnectionsSettingsPage(title: t("title"), scope: .workspace) {
            ConnectionsAlert(tone: .destructive, title: t("load_failed.title"), message: t("load_failed.description")) {
                Button { Task { await model.refreshSummary(api) } } label: { Label(t("actions.retry"), systemImage: "arrow.clockwise") }
                    .padding(.top, 8)
            }
        }
    }

    private func formatDate(_ s: String?) -> String? {
        guard let s, let d = Timestamp.parse(s) else { return nil }
        return d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale))
    }

    private func formatDateTime(_ s: String?) -> String? {
        guard let s, let d = Timestamp.parse(s) else { return nil }
        return d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
    }

    private func number(_ n: Int) -> String { n.formatted(.number.locale(locale)) }

    private func planLabel(_ plan: String) -> String {
        ["free", "pro"].contains(plan) ? t("plan.\(plan)") : t("plan.unknown")
    }

    private func statusLabel(_ status: String) -> String {
        ["inactive", "active", "trialing", "past_due", "canceled", "incomplete", "incomplete_expired", "paused", "unpaid"].contains(status)
            ? t("status.\(status)") : t("status.unknown")
    }

    @ViewBuilder
    private func loadedPage(_ summary: WorkspaceSubscriptionSummary, _ entitlements: WorkspaceSubscriptionEntitlements) -> some View {
        let actions = summary.connectionsActions
        let periodEnd = formatDate(entitlements.currentPeriodEnd)
        let graceUntil = formatDate(summary.graceUntil)
        ConnectionsSettingsPage(title: t("title"), scope: .workspace) {
            notices(summary, entitlements, periodEnd: periodEnd, graceUntil: graceUntil)
            currentPlan(summary, entitlements, periodEnd: periodEnd)
            if actions.checkout { upgradeSection(summary) }
            if actions.portal { managementSection }
            limitsSection(entitlements)
            if ConnectionsBilling.hasActiveSeatCapacity(summary) {
                seatsSection(summary, periodEnd: periodEnd)
            }
        }
        .sheet(isPresented: $seatPurchaseOpen) {
            ConnectionsSeatPurchaseSheet(model: model, intent: $seatIntent, purchasePending: $purchasePending,
                                         onSubmitted: { count in
                                             seatPurchaseMessage = t("seat_purchase.submitted", ["count": count])
                                         },
                                         onPermissionError: { error in reportActionError(error, fallback: t("seat_purchase.purchase_failed")) })
        }
        .connectionsConfirm($checkoutConfirm)
        .onChange(of: checkoutConfirm == nil) { _, closed in
            if closed && !checkoutRan { checkoutKey = nil }
        }
    }

    @ViewBuilder
    private func notices(_ s: WorkspaceSubscriptionSummary, _ e: WorkspaceSubscriptionEntitlements, periodEnd: String?, graceUntil: String?) -> some View {
        if returnResult == "cancel" {
            ConnectionsAlert(title: t("return.cancel_title"), message: t("return.cancel_description"))
        }
        if returnResult == "portal" {
            ConnectionsAlert(tone: .success, title: t("return.portal_title"))
        }
        if returnResult == "success" {
            ConnectionsAlert(tone: checkoutConfirmed ? .success : (syncing ? .pending : .info),
                             title: checkoutConfirmed ? t("return.active_title") : t("return.syncing_title"),
                             message: checkoutConfirmed ? t("return.active_description")
                                 : syncTimedOut ? t("return.timeout_description") : t("return.syncing_description"))
        }
        if s.cancelAtPeriodEnd {
            ConnectionsAlert(title: t("subscription_notice.canceling_title"),
                             message: periodEnd.map { t("subscription_notice.canceling_description", ["date": $0]) }
                                 ?? t("subscription_notice.canceling_description_without_date"))
        }
        switch e.status {
        case "past_due":
            ConnectionsAlert(tone: .destructive, title: t("past_due.title"),
                             message: graceUntil.map { t("past_due.grace_description", ["date": $0]) } ?? t("past_due.description"))
        case "incomplete":
            ConnectionsAlert(tone: .destructive, title: t("subscription_notice.incomplete_title"), message: t("subscription_notice.incomplete_description"))
        case "incomplete_expired":
            ConnectionsAlert(tone: .destructive, title: t("subscription_notice.incomplete_expired_title"),
                             message: t("subscription_notice.incomplete_expired_description"))
        case "paused":
            ConnectionsAlert(title: t("subscription_notice.paused_title"), message: t("subscription_notice.paused_description"))
        case "unpaid":
            ConnectionsAlert(tone: .destructive, title: t("subscription_notice.unpaid_title"), message: t("subscription_notice.unpaid_description"))
        case "canceled":
            ConnectionsAlert(title: t("subscription_notice.canceled_title"))
        default:
            EmptyView()
        }
        if let actionError {
            ConnectionsAlert(tone: .destructive, title: t("errors.action_title"), message: actionError)
        }
    }

    private func currentPlan(_ s: WorkspaceSubscriptionSummary, _ e: WorkspaceSubscriptionEntitlements, periodEnd: String?) -> some View {
        let members = Int(s.humanMembers)
        return ConnectionsSection(title: t("current.title")) {
            ConnectionsCard {
                ConnectionsRow(t("current.plan")) {
                    HStack(spacing: 8) {
                        ConnectionsBillingBadge(text: planLabel(e.plan), style: e.plan == "pro" ? .filled : e.plan == "free" ? .secondary : .outline)
                        ConnectionsBillingBadge(text: statusLabel(e.status), style: ConnectionsBillingBadge.style(forStatus: e.status))
                    }
                }
                Divider()
                ConnectionsRow(t("current.members"), description: t("current.members_description")) {
                    Text(t("current.member_count", ["count": members])).monospacedDigit()
                }
                if let billing = s.billingInterval {
                    Divider()
                    ConnectionsRow(t("current.billing_interval")) {
                        Text(billing == "month" ? t("upgrade.monthly") : t("upgrade.yearly"))
                    }
                }
                if let periodEnd {
                    Divider()
                    ConnectionsRow(t("current.period_end")) { Text(periodEnd).monospacedDigit() }
                }
            }
        }
    }

    private func upgradeSection(_ s: WorkspaceSubscriptionSummary) -> some View {
        let price = interval == "month" ? model.prices?.month : model.prices?.year
        let formatted = price.flatMap { ConnectionsBilling.formatStripeMinorAmount($0.unitAmount, currency: $0.currency, locale: locale) }
        let displayable = price?.intervalCount == 1 && formatted != nil
        let pricesLoading = model.pricesPhase == .pending
        let canRetry = !pricesLoading && price == nil
        return ConnectionsSection(title: t("upgrade.title"), description: t("upgrade.description")) {
            ConnectionsCard {
                VStack(alignment: .leading, spacing: 20) {
                    Picker(t("upgrade.interval_label"), selection: Binding(get: { interval }, set: { interval = $0; checkoutKey = nil })) {
                        Text(t("upgrade.monthly")).tag("month")
                        Text(t("upgrade.yearly")).tag("year")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(t("upgrade.pro_for_team", ["count": Int(s.humanMembers)])).font(Theme.Font.bodyMedium)
                        if pricesLoading {
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)).frame(width: 192, height: 18)
                                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)).frame(width: 256, height: 14)
                            }
                            .accessibilityLabel(t("upgrade.price_loading"))
                        } else if displayable, let formatted {
                            Text(t("upgrade.unit_price", ["price": formatted])).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        }
                        Text(t("upgrade.price_at_checkout")).font(Theme.Font.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: 520, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        if canRetry {
                            Button { Task { await model.refreshPrices(api) } } label: {
                                HStack(spacing: 6) {
                                    if model.pricesFetching { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                                    Text(t("actions.retry"))
                                }
                            }
                            .controlSize(.small)
                            .disabled(model.pricesFetching)
                        }
                    }
                    Button {
                        checkoutRan = false
                        checkoutConfirm = makeCheckoutConfirm(s)
                    } label: { Label(t("actions.upgrade"), systemImage: "creditcard") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isMutating)
                }
                .padding(20)
            }
        }
    }

    private var managementSection: some View {
        ConnectionsSection(title: t("management.title"), description: t("management.description")) {
            ConnectionsCard {
                ConnectionsRow(t("management.portal"), description: portalUnavailable ? t("management.portal_unavailable") : nil) {
                    if !portalUnavailable {
                        Button { Task { await openPortal() } } label: {
                            HStack(spacing: 6) {
                                if portalPending { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.up.right.square") }
                                Text(t("actions.manage"))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isMutating)
                    }
                }
            }
        }
    }

    private func limitsSection(_ e: WorkspaceSubscriptionEntitlements) -> some View {
        let issueLimit = e.connectionsIssueLimit
        let issueValue: String = {
            if issueLimit.unlimited { return t("limits.unlimited") }
            if let usage = model.issueLimit, usage.limit == issueLimit.limit {
                return "\(number(Int(usage.used))) / \(number(usage.limit))"
            }
            return number(issueLimit.limit ?? 0)
        }()
        let usage = ConnectionsBilling.autopilotUsage(entitlements: e, usage: model.quota, failed: model.quotaPhase == .failed)
        return ConnectionsSection(title: t("limits.title")) {
            ConnectionsCard {
                ConnectionsRow(t("limits.issues")) { Text(issueValue).monospacedDigit() }
                Divider()
                ConnectionsRow(t("limits.autopilots"), alignTop: true) {
                    autopilotUsage(usage, e)
                }
            }
        }
    }

    @ViewBuilder
    private func autopilotUsage(_ usage: ConnectionsAutopilotUsage, _ e: WorkspaceSubscriptionEntitlements) -> some View {
        switch usage {
        case .unlimited:
            Text(t("limits.unlimited")).monospacedDigit()
        case _ where model.quotaPhase == .pending:
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)).frame(width: 288, height: 18)
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)).frame(width: 192, height: 14)
            }
            .accessibilityLabel(t("limits.usage_loading"))
        case .metered(let used, let reserved, let total, let limit, let progress, let reached, let resetAt):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(reached ? t("limits.reached") : t("limits.current_usage")).font(Theme.Font.bodyMedium)
                    Spacer()
                    Text(t("limits.usage_total", ["total": number(total), "limit": number(limit)])).monospacedDigit()
                }
                ProgressView(value: progress, total: 100)
                    .tint(reached ? Theme.destructive : Theme.brand)
                    .accessibilityLabel(t("limits.usage_label"))
                Text(t("limits.usage_breakdown", ["used": number(used), "reserved": number(reserved)]))
                    .font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                if let reset = formatDateTime(resetAt) {
                    Text(t("limits.resets_at", ["date": reset])).font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(width: 288)
        case .unavailable:
            VStack(alignment: .trailing, spacing: 8) {
                let limit = e.connectionsAutopilotLimit
                if !limit.unlimited, let n = limit.limit {
                    Text(t("limits.per_month", ["count": n])).monospacedDigit()
                }
                Text(t("limits.usage_unavailable")).font(Theme.Font.caption).foregroundStyle(.secondary)
                Button { Task { await model.refreshQuota(api) } } label: {
                    HStack(spacing: 6) {
                        if model.quotaFetching { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                        Text(t("actions.retry"))
                    }
                }
                .controlSize(.small)
                .disabled(model.quotaFetching)
                .accessibilityLabel(t("actions.retry_autopilots"))
            }
        }
    }

    private func seatsSection(_ s: WorkspaceSubscriptionSummary, periodEnd: String?) -> some View {
        let capacity = s.seatCapacity
        let actual = Int(s.humanMembers)
        let canAddSeats = s.connectionsActions.purchaseSeats
        let activePurchase = capacity?.activePurchase
        return ConnectionsSection(title: t("seats.title"), description: t("seats.description")) {
            VStack(alignment: .leading, spacing: 12) {
                if let seatPurchaseMessage {
                    ConnectionsAlert(tone: .success, title: t("seats.updated"), message: seatPurchaseMessage)
                }
                if capacity?.overcommitted == true {
                    ConnectionsAlert(title: t("seats.members_over_capacity_title"),
                                     message: t("seats.members_over_capacity_description", ["actual": actual, "purchased": Int(capacity?.purchased ?? 0)])) {
                        if canAddSeats {
                            Button { openSeatPurchase() } label: { Label(t("actions.add_seats"), systemImage: "plus") }
                                .controlSize(.small)
                                .disabled(isMutating)
                                .padding(.top, 8)
                        }
                    }
                }
                if let activePurchase {
                    ConnectionsAlert(tone: seatPollingTimedOut ? .info : .pending,
                                     title: seatPollingTimedOut ? t("seat_purchase.delayed_title") : t("seat_purchase.pending_title"),
                                     message: seatPollingTimedOut
                                         ? (formatDateTime(activePurchase.expiresAt).map { t("seat_purchase.delayed_description_with_expiry", ["date": $0]) }
                                             ?? t("seat_purchase.delayed_description"))
                                         : t("seat_purchase.pending_description", ["count": Int(activePurchase.targetSeats)]))
                }
                ConnectionsCard {
                    ConnectionsRow(t("seats.human_members")) {
                        Text(t("seats.seat_count", ["count": Int(capacity?.used ?? Double(actual))])).monospacedDigit()
                    }
                    Divider()
                    ConnectionsRow(t("seats.billed"), alignTop: true) {
                        if let purchased = capacity?.purchased {
                            VStack(alignment: .trailing, spacing: 8) {
                                Text(t("seats.seat_count", ["count": Int(purchased)])).monospacedDigit()
                                if canAddSeats {
                                    Button { openSeatPurchase() } label: { Label(t("actions.add_seats"), systemImage: "plus") }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(isMutating)
                                }
                            }
                        } else {
                            Text(t("seats.not_subscribed")).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    ConnectionsRow(t("seats.pending_invitations"), description: t("seats.pending_invitations_description")) {
                        Text(t("seats.seat_count", ["count": Int(capacity?.reserved ?? 0)])).monospacedDigit()
                    }
                    Divider()
                    ConnectionsRow(label: {
                        HStack(spacing: 6) {
                            Text(t("seats.available"))
                            ConnectionsInfoPopover(text: t("seats.available_description"), label: t("seats.available_help"))
                        }
                    }) {
                        if let available = capacity?.available {
                            Text(t("seats.seat_count", ["count": Int(available)])).monospacedDigit()
                        } else {
                            Text(t("seats.unavailable")).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    ConnectionsRow(t("seats.pending"), description: t("seats.pending_description")) {
                        if let pending = capacity?.pendingQuantity {
                            Text(periodEnd.map { t("seats.pending_with_date", ["count": Int(pending), "date": $0]) }
                                 ?? t("seats.seat_count", ["count": Int(pending)])).monospacedDigit()
                        } else {
                            Text(t("seats.none_pending")).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func openSeatPurchase() {
        guard !purchasePending else { return }
        seatPurchaseOpen = true
    }

    private func makeCheckoutConfirm(_ s: WorkspaceSubscriptionSummary) -> ConnectionsConfirm {
        ConnectionsConfirm(
            title: t("confirm.title"),
            message: t("confirm.description", ["interval": interval == "month" ? t("upgrade.monthly") : t("upgrade.yearly"),
                                               "count": Int(s.humanMembers)]),
            cancel: t("actions.cancel"),
            confirm: t("actions.continue_to_stripe")) {
                checkoutRan = true
                await checkout()
                return true
            }
    }

    private func reportActionError(_ error: Error, fallback: String) {
        let e = error as? APIError
        if e?.code == "workspace_subscriptions_disabled" || e?.code == "cloud_runtime_not_configured" {
            actionError = t("errors.not_enabled")
        } else if e?.status == 503 {
            actionError = t("errors.temporarily_unavailable")
        } else if e?.status == 403 {
            actionError = t("errors.permission_changed")
        } else {
            actionError = fallback
        }
    }

    private func checkout() async {
        actionError = nil
        let wsID = session.workspace.id
        let key = checkoutKey?.interval == interval ? checkoutKey!.key : ConnectionsBilling.idempotencyKey("workspace-checkout", workspaceID: wsID)
        checkoutKey = (interval, key)
        checkoutPending = true
        defer { checkoutPending = false }
        do {
            let response = try await api.createWorkspaceSubscriptionCheckout(interval: interval, idempotencyKey: key)
            await model.refreshSummary(api)
            guard let raw = response?.url, !raw.isEmpty, let url = URL(string: raw) else {
                actionError = t("errors.checkout_response")
                return
            }
            openURL(url)
        } catch {
            if (error as? APIError)?.status == 409 {
                checkoutKey = nil
                actionError = t("errors.already_subscribed")
                await model.refreshSummary(api)
                return
            }
            reportActionError(error, fallback: t("errors.checkout_failed"))
        }
    }

    private func openPortal() async {
        actionError = nil
        let key = portalKey ?? ConnectionsBilling.idempotencyKey("workspace-portal", workspaceID: session.workspace.id)
        portalKey = key
        portalPending = true
        defer { portalPending = false }
        do {
            let response = try await api.createWorkspaceSubscriptionPortal(idempotencyKey: key)
            guard let raw = response?.url, !raw.isEmpty, let url = URL(string: raw) else {
                actionError = t("errors.portal_response")
                return
            }
            openURL(url)
            // A Portal URL is single-use; a network failure above keeps the key for retry.
            portalKey = nil
        } catch {
            if (error as? APIError)?.status == 404 {
                portalKey = nil
                portalUnavailable = true
                actionError = t("errors.portal_unavailable")
                await model.refreshSummary(api)
                return
            }
            reportActionError(error, fallback: t("errors.portal_failed"))
        }
    }
}

struct ConnectionsSeatIntent {
    var key: String
    var preview: WorkspaceSeatPurchasePreview
}

/// Add seats: a debounced Stripe estimate, then a confirmed purchase that
/// reuses its idempotency key on retry.
private struct ConnectionsSeatPurchaseSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let model: ConnectionsBillingModel
    @Binding var intent: ConnectionsSeatIntent?
    @Binding var purchasePending: Bool
    let onSubmitted: (Int) -> Void
    let onPermissionError: (Error) -> Void

    @State private var input = "1"
    @State private var preview: WorkspaceSeatPurchasePreview?
    @State private var previewLoading = false
    @State private var refreshing = false
    @State private var error: String?
    @State private var revision = 0
    @State private var capacityRetries: (key: String, attempts: Int)?

    private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
        tr("billing", "workspace.\(key)", args)
    }

    private var locale: Locale { Locale(identifier: L10n.shared.language) }
    private var currentSeats: Int? { model.summary?.seatCapacity.map { Int($0.purchased) } }
    private var version: Int? { model.summary?.seatCapacity?.version }
    private var previewKey: String { "\(input)|\(currentSeats ?? -1)|\(version ?? -1)|\(revision)" }

    var body: some View {
        let proration = preview.flatMap { ConnectionsBilling.formatStripeMinorAmount($0.prorationAmount, currency: $0.currency, locale: locale) }
        let nextInvoice = preview.flatMap { ConnectionsBilling.formatStripeMinorAmount($0.nextInvoiceAmount, currency: $0.currency, locale: locale) }
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("seat_purchase.title")).font(.system(size: 15, weight: .semibold))
                Text(t("seat_purchase.description")).font(Theme.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ConnectionsField(label: t("seat_purchase.additional_label"), hint: t("seat_purchase.additional_hint")) {
                TextField("", text: Binding(get: { input }, set: { input = $0; capacityRetries = nil; refreshing = false; error = nil }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .disabled(purchasePending)
            }
            if previewLoading || refreshing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(t("seat_purchase.preview_loading"))
                }
                .font(Theme.Font.body).foregroundStyle(.secondary)
            }
            if let error {
                ConnectionsAlert(tone: .destructive, title: t("seat_purchase.error_title"), message: error)
            }
            if let preview, let proration, let nextInvoice {
                VStack(alignment: .leading, spacing: 10) {
                    line(t("seat_purchase.seats_after"), t("seats.seat_count", ["count": Int(preview.resultingSeats)]))
                    line(t("seat_purchase.charge_today"), proration)
                    line(t("seat_purchase.next_invoice"), nextInvoice)
                    Text(t("seat_purchase.tax_notice")).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }
            HStack {
                Spacer()
                Button(t("actions.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(purchasePending)
                Button {
                    Task { await purchase() }
                } label: {
                    HStack(spacing: 6) {
                        if purchasePending { ProgressView().controlSize(.small) } else { Image(systemName: "plus") }
                        Text(preview.map { t("seat_purchase.confirm", ["count": Int($0.additionalSeats)]) } ?? t("actions.add_seats"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(preview == nil || proration == nil || nextInvoice == nil || previewLoading || refreshing || purchasePending)
            }
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(purchasePending)
        .onAppear {
            if let intent {
                input = String(Int(intent.preview.additionalSeats))
                preview = intent.preview
            }
        }
        .task(id: previewKey) { await updatePreview() }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(Theme.Font.bodyMedium).monospacedDigit()
        }
        .font(Theme.Font.body)
    }

    private func updatePreview() async {
        let additional = ConnectionsBilling.parseAdditionalSeats(input)
        let retryKey = "\(session.workspace.id):\(input.trimmingCharacters(in: .whitespaces))"
        if capacityRetries?.key != retryKey { capacityRetries = (retryKey, 0) }
        if let intent, let seats = currentSeats, let version,
           ConnectionsBilling.previewMatches(intent.preview, additionalSeats: additional, currentSeats: seats, version: version) {
            preview = intent.preview
            refreshing = false
            error = nil
            return
        }
        intent = nil
        preview = nil
        guard additional >= 1, let seats = currentSeats, let version else {
            if (capacityRetries?.attempts ?? 0) > 0 { error = t("seat_purchase.preview_failed") }
            refreshing = false
            return
        }
        try? await Task.sleep(for: .milliseconds(800))
        guard !Task.isCancelled else { return }
        previewLoading = true
        defer { previewLoading = false }
        do {
            let p = try await session.api.previewWorkspaceSeatPurchase(additionalSeats: additional)
            guard !Task.isCancelled else { return }
            refreshing = false
            guard ConnectionsBilling.previewMatches(p, additionalSeats: additional, currentSeats: seats, version: version) else {
                error = t("seat_purchase.preview_unreadable")
                return
            }
            preview = p
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            let e = error as? APIError
            let code = e?.status == 409 ? e?.code : nil
            if code == "seat_capacity_changed" {
                guard let retry = capacityRetries, retry.key == retryKey, retry.attempts < 1 else {
                    refreshing = false
                    self.error = t("seat_purchase.capacity_out_of_sync")
                    return
                }
                capacityRetries = (retryKey, retry.attempts + 1)
                refreshing = true
                self.error = nil
                await model.refreshSummary(session.api)
                if model.summaryPhase == .failed {
                    refreshing = false
                    self.error = t("seat_purchase.preview_failed")
                    return
                }
                if currentSeats == seats && self.version == version {
                    refreshing = false
                    self.error = t("seat_purchase.capacity_out_of_sync")
                    return
                }
                revision += 1
                return
            }
            refreshing = false
            self.error = code == "seat_purchase_in_progress" ? t("seat_purchase.in_progress") : t("seat_purchase.preview_failed")
        }
    }

    private func purchase() async {
        guard let confirmed = preview else { return }
        error = nil
        let key = intent.map { $0.key } ?? String(ConnectionsBilling.idempotencyKey("workspace-seat-purchase", workspaceID: session.workspace.id).prefix(200))
        intent = ConnectionsSeatIntent(key: key, preview: confirmed)
        purchasePending = true
        defer { purchasePending = false }
        do {
            let response = try await session.api.purchaseWorkspaceSeats(
                additionalSeats: Int(confirmed.additionalSeats), expectedCurrentSeats: Int(confirmed.currentSeats),
                expectedPurchaseVersion: Int(confirmed.purchaseVersion), acceptedProrationAmount: Int(confirmed.prorationAmount),
                currency: confirmed.currency, idempotencyKey: key)
            guard ConnectionsBilling.seatPurchaseMatchesPreview(response, confirmed), let response else {
                error = t("seat_purchase.purchase_unreadable")
                return
            }
            intent = nil
            onSubmitted(Int(response.resultingSeats))
            await model.refreshSummary(session.api)
            dismiss()
        } catch {
            let e = error as? APIError
            switch e?.status {
            case 409:
                intent = nil
                preview = nil
                if e?.code == "seat_purchase_in_progress" {
                    self.error = t("seat_purchase.in_progress")
                    await model.refreshSummary(session.api)
                    return
                }
                self.error = t("seat_purchase.quote_changed")
                await model.refreshSummary(session.api)
                revision += 1
            case 402:
                intent = nil
                preview = nil
                self.error = t("seat_purchase.payment_failed")
            case 403:
                intent = nil
                onPermissionError(error)
            default:
                self.error = t("seat_purchase.purchase_failed")
            }
        }
    }
}

struct ConnectionsBillingBadge: View {
    enum Style { case filled, secondary, destructive, outline }
    let text: String
    let style: Style

    static func style(forStatus status: String) -> Style {
        switch status {
        case "active", "trialing": return .filled
        case "past_due", "incomplete", "unpaid": return .destructive
        case "inactive", "canceled", "incomplete_expired", "paused": return .secondary
        default: return .outline
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(style == .filled ? Color.white : style == .destructive ? Theme.destructive : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(style == .outline ? Theme.border : .clear))
    }

    private var fill: Color {
        switch style {
        case .filled: return Theme.brand
        case .secondary: return Color.primary.opacity(0.07)
        case .destructive: return Theme.destructive.opacity(0.12)
        case .outline: return .clear
        }
    }
}

/// Small ⓘ button that explains a value in a popover.
struct ConnectionsInfoPopover: View {
    let text: String
    let label: String
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 11)) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(label)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                Text(text).font(Theme.Font.caption).frame(width: 260, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(12)
            }
    }
}
