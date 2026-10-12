import Foundation

// Code hosts, chat channels, Composio apps, billing and subscriptions.

extension APIClient {
    // MARK: GitHub

    public nonisolated func getGitHubConnectURL(workspaceId: String, returnTo: String? = nil) async throws -> GitHubConnectResponse {
        try await call(.get, "/api/workspaces/\(workspaceId)/github/connect", query: MulticaCore.query(["return_to": returnTo]))
    }

    public nonisolated func listGitHubInstallations(workspaceId: String) async throws -> ListGitHubInstallationsResponse {
        try await call(.get, "/api/workspaces/\(workspaceId)/github/installations")
    }

    public nonisolated func listGitHubInstallationRepositories(workspaceId: String, installationId: String, page: Int? = nil, perPage: Int? = nil) async throws -> ListGitHubRepositoriesResponse {
        try await call(.get, "/api/workspaces/\(workspaceId)/github/installations/\(installationId)/repositories",
                       query: MulticaCore.query(["page": page.map(String.init), "per_page": perPage.map(String.init)]))
    }

    public nonisolated func deleteGitHubInstallation(workspaceId: String, installationId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/github/installations/\(installationId)")
    }

    // MARK: Self-hosted VCS

    public nonisolated func listVCSConnections(workspaceId: String) async throws -> ListVCSConnectionsResponse {
        try await call(.get, "/api/workspaces/\(workspaceId)/vcs/connections")
    }

    public nonisolated func connectVCS(workspaceId: String, _ body: ConnectVCSRequest) async throws -> ConnectVCSResponse {
        try await call(.post, "/api/workspaces/\(workspaceId)/vcs/connections", body: JSONValue(encoding: body))
    }

    public nonisolated func deleteVCSConnection(workspaceId: String, connectionId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/vcs/connections/\(connectionId)")
    }

    public nonisolated func rotateVCSWebhook(workspaceId: String, connectionId: String) async throws -> ConnectVCSResponse {
        try await call(.post, "/api/workspaces/\(workspaceId)/vcs/connections/\(connectionId)/rotate-webhook")
    }

    // MARK: Lark / Feishu

    public nonisolated func listLarkInstallations(workspaceId: String) async throws -> ListLarkInstallationsResponse {
        try await call(.get, "/api/workspaces/\(workspaceId)/lark/installations")
    }

    public nonisolated func beginLarkInstall(workspaceId: String, agentId: String, region: String) async throws -> BeginLarkInstallResponse {
        try await call(.post, "/api/workspaces/\(workspaceId)/lark/install/begin", query: MulticaCore.query(["agent_id": agentId, "region": region]))
    }

    public nonisolated func getLarkInstallStatus(workspaceId: String, sessionId: String) async throws -> LarkInstallStatusResponse {
        try await call(.get, "/api/workspaces/\(workspaceId)/lark/install/\(sessionId)/status")
    }

    public nonisolated func deleteLarkInstallation(workspaceId: String, installationId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/lark/installations/\(installationId)")
    }

    public nonisolated func redeemLarkBindingToken(_ token: String) async throws -> RedeemLarkBindingTokenResponse {
        try await call(.post, "/api/lark/binding/redeem", body: ["token": JSONValue(token)] as JSONValue)
    }

    // MARK: Composio

    public nonisolated func listComposioToolkits() async throws -> [ComposioToolkit] {
        try await list("/api/integrations/composio/toolkits")
    }

    public nonisolated func listComposioConnections() async throws -> [ComposioConnection] {
        try await list("/api/integrations/composio/connections")
    }

    public nonisolated func beginComposioConnect(toolkitSlug: String) async throws -> ComposioConnectInitResponse {
        try await call(.post, "/api/integrations/composio/connect/init", body: ["toolkit_slug": JSONValue(toolkitSlug)] as JSONValue)
    }

    public nonisolated func deleteComposioConnection(_ connectionId: String) async throws {
        try await callVoid(.delete, "/api/integrations/composio/connections/\(connectionId)")
    }

    // MARK: Slack

    public nonisolated func listSlackInstallations(workspaceId: String) async throws -> ListSlackInstallationsResponse {
        try await call(.get, "/api/workspaces/\(workspaceId)/slack/installations")
    }

    public nonisolated func registerSlackBYO(workspaceId: String, agentId: String, _ body: RegisterSlackBYORequest) async throws -> SlackInstallation {
        try await call(.post, "/api/workspaces/\(workspaceId)/slack/install/byo", query: MulticaCore.query(["agent_id": agentId]), body: JSONValue(encoding: body))
    }

    public nonisolated func deleteSlackInstallation(workspaceId: String, installationId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/slack/installations/\(installationId)")
    }

    public nonisolated func redeemSlackBindingToken(_ token: String) async throws -> RedeemSlackBindingTokenResponse {
        try await call(.post, "/api/slack/binding/redeem", body: ["token": JSONValue(token)] as JSONValue)
    }

    // MARK: DingTalk

    public nonisolated func listDingTalkInstallations(workspaceId: String) async throws -> ListDingTalkInstallationsResponse {
        try await call(.get, "/api/workspaces/\(workspaceId)/dingtalk/installations")
    }

    private nonisolated func dingTalkQuery(_ p: ListDingTalkGroupsParams) -> [URLQueryItem] {
        MulticaCore.query(["activity": p.activity, "installation_id": p.installationId,
                           "offset": p.offset.map(String.init), "limit": p.limit.map(String.init)])
    }

    /// 404/403 mean the feature is unavailable to this caller: an empty list.
    public nonisolated func listDingTalkGroups(workspaceId: String, _ params: ListDingTalkGroupsParams = ListDingTalkGroupsParams()) async throws -> ListDingTalkGroupsResponse {
        do {
            return try await call(.get, "/api/workspaces/\(workspaceId)/dingtalk/groups", query: dingTalkQuery(params))
        } catch let e as APIError where e.status == 404 || e.status == 403 {
            return ListDingTalkGroupsResponse()
        }
    }

    public nonisolated func listAgentDingTalkGroups(agentId: String, _ params: ListDingTalkGroupsParams = ListDingTalkGroupsParams()) async throws -> ListDingTalkGroupsResponse {
        do {
            return try await call(.get, "/api/agents/\(agentId)/dingtalk/groups", query: dingTalkQuery(params))
        } catch let e as APIError where e.status == 404 || e.status == 403 {
            return ListDingTalkGroupsResponse()
        }
    }

    public nonisolated func forgetDingTalkGroup(workspaceId: String, installationId: String, conversationId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/dingtalk/installations/\(installationId)/groups/\(conversationId.pathEscaped)")
    }

    public nonisolated func registerDingTalkBYO(workspaceId: String, agentId: String, _ body: RegisterDingTalkBYORequest) async throws -> DingTalkInstallation {
        try await call(.post, "/api/workspaces/\(workspaceId)/dingtalk/install/byo", query: MulticaCore.query(["agent_id": agentId]), body: JSONValue(encoding: body))
    }

    public nonisolated func deleteDingTalkInstallation(workspaceId: String, installationId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/dingtalk/installations/\(installationId)")
    }

    public nonisolated func redeemDingTalkBindingToken(_ token: String) async throws -> RedeemDingTalkBindingTokenResponse {
        try await call(.post, "/api/dingtalk/binding/redeem", body: ["token": JSONValue(token)] as JSONValue)
    }

    // MARK: WeCom

    public nonisolated func listWecomInstallations(workspaceId: String) async throws -> ListWecomInstallationsResponse {
        try await call(.get, "/api/workspaces/\(workspaceId)/wecom/installations")
    }

    public nonisolated func registerWecomBYO(workspaceId: String, agentId: String, _ body: RegisterWecomBYORequest) async throws -> WecomInstallation {
        try await call(.post, "/api/workspaces/\(workspaceId)/wecom/install/byo", query: MulticaCore.query(["agent_id": agentId]), body: JSONValue(encoding: body))
    }

    public nonisolated func deleteWecomInstallation(workspaceId: String, installationId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/wecom/installations/\(installationId)")
    }

    public nonisolated func redeemWecomBindingToken(_ token: String) async throws -> RedeemWecomBindingTokenResponse {
        try await call(.post, "/api/wecom/binding/redeem", body: ["token": JSONValue(token)] as JSONValue)
    }

    // MARK: Telegram

    public nonisolated func listTelegramInstallations(workspaceId: String) async throws -> ListTelegramInstallationsResponse {
        try await call(.get, "/api/workspaces/\(workspaceId)/telegram/installations")
    }

    public nonisolated func registerTelegramBot(workspaceId: String, agentId: String, _ body: RegisterTelegramRequest) async throws -> TelegramInstallation {
        try await call(.post, "/api/workspaces/\(workspaceId)/telegram/install", query: MulticaCore.query(["agent_id": agentId]), body: JSONValue(encoding: body))
    }

    public nonisolated func deleteTelegramInstallation(workspaceId: String, installationId: String) async throws {
        try await callVoid(.delete, "/api/workspaces/\(workspaceId)/telegram/installations/\(installationId)")
    }

    public nonisolated func redeemTelegramBindingToken(_ token: String) async throws -> RedeemTelegramBindingTokenResponse {
        try await call(.post, "/api/telegram/binding/redeem", body: ["token": JSONValue(token)] as JSONValue)
    }

    // MARK: Cloud billing (credits)

    public nonisolated func getCloudBillingBalance() async throws -> BillingBalance {
        try await call(.get, "/api/cloud-billing/balance")
    }

    public nonisolated func listCloudBillingTransactions(page: Int? = nil, pageSize: Int? = nil) async throws -> BillingTransactionsPage {
        try await call(.get, "/api/cloud-billing/transactions", query: MulticaCore.query(["page": page.map(String.init), "page_size": pageSize.map(String.init)]))
    }

    public nonisolated func listCloudBillingBatches(page: Int? = nil, pageSize: Int? = nil) async throws -> BillingBatchesPage {
        try await call(.get, "/api/cloud-billing/batches", query: MulticaCore.query(["page": page.map(String.init), "page_size": pageSize.map(String.init)]))
    }

    public nonisolated func listCloudBillingTopups(page: Int? = nil, pageSize: Int? = nil) async throws -> BillingTopupsPage {
        try await call(.get, "/api/cloud-billing/topups", query: MulticaCore.query(["page": page.map(String.init), "page_size": pageSize.map(String.init)]))
    }

    public nonisolated func listCloudBillingPriceTiers() async throws -> [BillingPriceTier] {
        try await list("/api/cloud-billing/price-tiers")
    }

    public nonisolated func createCloudBillingCheckoutSession(_ data: CreateBillingCheckoutSessionRequest) async throws -> CreateBillingCheckoutSessionResponse {
        try await call(.post, "/api/cloud-billing/checkout-sessions", body: JSONValue(encoding: data))
    }

    public nonisolated func getCloudBillingCheckoutSession(_ sessionId: String) async throws -> BillingCheckoutSessionStatus {
        try await call(.get, "/api/cloud-billing/checkout-sessions/\(sessionId.pathEscaped)")
    }

    public nonisolated func createCloudBillingPortalSession() async throws -> CreateBillingPortalSessionResponse {
        try await call(.post, "/api/cloud-billing/portal-sessions")
    }

    // MARK: Workspace subscriptions (seats)

    /// The subscription types are upstream's zod-transformed camelCase shapes;
    /// the wire is snake_case.
    private nonisolated func optional<T: Decodable & Sendable>(_ method: Method, _ path: String, body: JSONValue? = nil,
                                                               headers: [String: String] = [:], as type: T.Type) async throws -> T? {
        let v: JSONValue = try await call(method, path, body: body, headers: headers)
        guard !v.isNull else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: JSONCoders.encoder.encode(v))
    }

    public nonisolated func getWorkspaceSubscriptionSummary() async throws -> WorkspaceSubscriptionSummary? {
        try await optional(.get, "/api/cloud-subscriptions/summary", as: WorkspaceSubscriptionSummary.self)
    }

    public nonisolated func getWorkspaceSubscriptionPrices() async throws -> WorkspaceSubscriptionPrices? {
        try await optional(.get, "/api/cloud-subscriptions/prices", as: WorkspaceSubscriptionPrices.self)
    }

    public nonisolated func createWorkspaceSubscriptionCheckout(interval: String, idempotencyKey: String) async throws -> CreateWorkspaceSubscriptionCheckoutResponse? {
        try await optional(.post, "/api/cloud-subscriptions/checkout-sessions",
                           body: ["interval": JSONValue(interval), "idempotency_key": JSONValue(idempotencyKey)],
                           headers: ["Idempotency-Key": idempotencyKey],
                           as: CreateWorkspaceSubscriptionCheckoutResponse.self)
    }

    public nonisolated func reconcileWorkspaceSubscriptionSeats() async throws -> WorkspaceSubscriptionSeatReconcileResult? {
        try await optional(.post, "/api/cloud-subscriptions/seats/reconcile", as: WorkspaceSubscriptionSeatReconcileResult.self)
    }

    public nonisolated func previewWorkspaceSeatPurchase(additionalSeats: Int) async throws -> WorkspaceSeatPurchasePreview? {
        try await optional(.post, "/api/cloud-subscriptions/seats/purchase-preview",
                           body: ["additional_seats": JSONValue(additionalSeats)], as: WorkspaceSeatPurchasePreview.self)
    }

    public nonisolated func purchaseWorkspaceSeats(additionalSeats: Int, expectedCurrentSeats: Int, expectedPurchaseVersion: Int,
                                                   acceptedProrationAmount: Int, currency: String, idempotencyKey: String) async throws -> PurchaseWorkspaceSeatsResponse? {
        try await optional(.post, "/api/cloud-subscriptions/seats/purchases", body: [
            "additional_seats": JSONValue(additionalSeats), "expected_current_seats": JSONValue(expectedCurrentSeats),
            "expected_purchase_version": JSONValue(expectedPurchaseVersion), "accepted_proration_amount": JSONValue(acceptedProrationAmount),
            "currency": JSONValue(currency), "idempotency_key": JSONValue(idempotencyKey),
        ], headers: ["Idempotency-Key": idempotencyKey], as: PurchaseWorkspaceSeatsResponse.self)
    }

    public nonisolated func createWorkspaceSubscriptionPortal(idempotencyKey: String) async throws -> CreateWorkspaceSubscriptionPortalResponse? {
        try await optional(.post, "/api/cloud-subscriptions/portal-sessions", headers: ["Idempotency-Key": idempotencyKey],
                           as: CreateWorkspaceSubscriptionPortalResponse.self)
    }
}
