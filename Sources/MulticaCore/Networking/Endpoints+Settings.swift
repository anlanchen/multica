import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An API failure that keeps the server's error body. Settings flows branch
/// on its machine-readable parts (`code`, `issue_count`) the way upstream
/// reads `ApiError.body`.
public struct SettingsAPIError: Error, LocalizedError, Sendable {
    public var status: Int
    public var message: String
    public var code: String?
    public var body: JSONValue

    public init(status: Int, message: String, code: String? = nil, body: JSONValue = .null) {
        self.status = status
        self.message = message
        self.code = code
        self.body = body
    }

    public var errorDescription: String? { message }

    /// Issues still on a status the server refused to archive (409).
    public var issueCount: Int? {
        guard status == 409, let n = body["issue_count"]?.doubleValue else { return nil }
        return Int(n)
    }

    static func from(status: Int, data: Data) -> SettingsAPIError {
        let body = (try? JSONCoders.decoder.decode(JSONValue.self, from: data)) ?? .null
        let code = body["code"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return SettingsAPIError(status: status, message: body["error"]?.stringValue ?? "Request failed with status \(status)", code: code, body: body)
    }
}

extension APIClient {
    private static let settingsTransport = URLSessionTransport()

    /// Label catalog of one resource type with usage counts and timestamps
    /// (the shared `listLabels` keeps only id, name and color).
    public nonisolated func settingsListLabelRecords(resourceType: String) async throws -> [LabelRecord] {
        let v: JSONValue = try await call(.get, "/api/labels", query: [URLQueryItem(name: "resource_type", value: resourceType)])
        guard let list = v["labels"], !list.isNull else { return [] }
        return try JSONCoders.decoder.decode(LossyList<LabelRecord>.self, from: JSONCoders.encoder.encode(list)).items
    }

    /// Like `call`, but a failure throws `SettingsAPIError` with the body.
    func settingsStructuredCall<T: Decodable & Sendable>(_ method: Method, _ path: String, body: JSONValue? = nil, as type: T.Type = T.self) async throws -> T? {
        let encoded = try body.map { try JSONCoders.encoder.encode($0) }
        let request = makeRequest(method, path, query: [], body: encoded, slugOverride: nil)
        let response = try await Self.settingsTransport.perform(request)
        guard (200..<300).contains(response.status) else { throw SettingsAPIError.from(status: response.status, data: response.body) }
        guard !response.body.isEmpty else { return nil }
        let value = try JSONCoders.decoder.decode(JSONValue.self, from: response.body)
        guard !value.isNull else { return nil }
        return try JSONCoders.decoder.decode(T.self, from: JSONCoders.encoder.encode(value))
    }

    /// `createMember` (invite by email); seat-capacity refusals carry a code.
    public func settingsInviteMember(workspaceId: String, email: String, role: String) async throws {
        let _: JSONValue? = try await settingsStructuredCall(.post, "/api/workspaces/\(workspaceId)/members",
                                                             body: ["email": JSONValue(email), "role": JSONValue(role)])
    }

    public func settingsPreviewSeatPurchase(additionalSeats: Int) async throws -> WorkspaceSeatPurchasePreview? {
        try await settingsStructuredCall(.post, "/api/cloud-subscriptions/seats/purchase-preview",
                                         body: ["additional_seats": JSONValue(additionalSeats)])
    }

    public func settingsPurchaseSeats(_ preview: WorkspaceSeatPurchasePreview, idempotencyKey: String) async throws -> PurchaseWorkspaceSeatsResponse? {
        try await settingsStructuredCall(.post, "/api/cloud-subscriptions/seats/purchases", body: [
            "additional_seats": JSONValue(Int(preview.additionalSeats)),
            "expected_current_seats": JSONValue(Int(preview.currentSeats)),
            "expected_purchase_version": JSONValue(Int(preview.purchaseVersion)),
            "accepted_proration_amount": JSONValue(Int(preview.prorationAmount)),
            "currency": JSONValue(preview.currency),
            "idempotency_key": JSONValue(idempotencyKey),
        ])
    }

    /// `archiveIssueStatus`; a status still in use answers 409 with `issue_count`.
    public func settingsArchiveIssueStatus(_ id: String) async throws {
        let _: JSONValue? = try await settingsStructuredCall(.delete, "/api/issue-statuses/\(id)")
    }
}
