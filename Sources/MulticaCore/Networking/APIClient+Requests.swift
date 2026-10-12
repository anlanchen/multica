import Foundation

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    public init(nilLiteral: ()) { self = .null }

    public init(_ s: String?) { self = s.map(JSONValue.string) ?? .null }
    public init(_ n: Int?) { self = n.map { .number(Double($0)) } ?? .null }
    public init(_ b: Bool?) { self = b.map(JSONValue.bool) ?? .null }
    public init(_ a: [String]) { self = .array(a.map(JSONValue.string)) }

    /// Re-encodes any Encodable value as JSON.
    public init(encoding value: some Encodable) {
        if let data = try? JSONCoders.encoder.encode(value),
           let v = try? JSONCoders.decoder.decode(JSONValue.self, from: data) {
            self = v
        } else {
            self = .null
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// Builds `URLQueryItem`s, dropping nil values (the TS client only sets the
/// search params it has values for).
public func query(_ pairs: KeyValuePairs<String, String?>) -> [URLQueryItem] {
    pairs.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
}

extension String {
    /// `encodeURIComponent` equivalent for path segments.
    public var pathEscaped: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

extension Bool {
    var queryValue: String { self ? "true" : "false" }
}

/// Decodes a 2xx response that may be empty (204) as `JSONValue.null`.
public struct EmptyOrJSON: Decodable, Sendable {
    public var value: JSONValue
    public init(from decoder: Decoder) throws {
        value = (try? JSONValue(from: decoder)) ?? .null
    }
}

extension APIClient {
    /// Request returning a decoded body. `body` is any Encodable (a generated
    /// request type, or a `JSONValue` literal for ad-hoc bodies).
    public nonisolated func call<T: Decodable & Sendable>(
        _ method: Method, _ path: String, query: [URLQueryItem] = [], body: (any Encodable & Sendable)? = nil,
        slug: String? = nil, headers: [String: String] = [:], as type: T.Type = T.self
    ) async throws -> T {
        let encoded = try body.map { try JSONCoders.encoder.encode($0) }
        let data = try await data(method, path, query: query, body: encoded, slug: slug, headers: headers)
        if data.isEmpty, let empty = JSONValue.null as? T { return empty }
        return try Self.decode(T.self, from: data, path: path)
    }

    /// Request whose response body is ignored.
    public nonisolated func callVoid(
        _ method: Method, _ path: String, query: [URLQueryItem] = [], body: (any Encodable & Sendable)? = nil,
        slug: String? = nil
    ) async throws {
        let encoded = try body.map { try JSONCoders.encoder.encode($0) }
        _ = try await data(method, path, query: query, body: encoded, slug: slug)
    }

    /// List endpoint decoded element-wise (bad elements are dropped).
    public nonisolated func list<T: Decodable & Sendable>(
        _ path: String, query: [URLQueryItem] = [], slug: String? = nil, of type: T.Type = T.self
    ) async throws -> [T] {
        try await call(.get, path, query: query, slug: slug, as: LossyList<T>.self).items
    }

    /// Reads one field of a JSON object response (`{ "issues": [...] }`).
    public nonisolated func field<T: Decodable & Sendable>(
        _ method: Method, _ path: String, _ key: String, query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil, as type: T.Type = T.self
    ) async throws -> T {
        let obj: JSONValue = try await call(method, path, query: query, body: body)
        guard let v = obj[key] else { throw APIError(status: 0, message: "Missing \(key) in \(path)") }
        let data = try JSONCoders.encoder.encode(v)
        return try Self.decode(T.self, from: data, path: path)
    }

    /// Uploads a file as multipart/form-data (`file` field plus extra fields).
    public func upload<T: Decodable & Sendable>(
        _ path: String, fileName: String, mimeType: String, fileData: Data, fields: [String: String] = [:],
        as type: T.Type = T.self
    ) async throws -> T {
        let boundary = "multica-\(UUID().uuidString)"
        var body = Data()
        func line(_ s: String) { body.append(Data((s + "\r\n").utf8)) }
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(k)\"")
            line("")
            line(v)
        }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName.replacingOccurrences(of: "\"", with: "'"))\"")
        line("Content-Type: \(mimeType)")
        line("")
        body.append(fileData)
        line("")
        line("--\(boundary)--")
        var request = makeRequest(.post, path, query: [], body: body, slugOverride: nil)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let response = try await rawPerform(request)
        return try Self.decode(T.self, from: response, path: path)
    }

    /// Downloads a binary body (attachments).
    public func download(_ path: String) async throws -> Data {
        let request = makeRequest(.get, path, query: [], body: nil, slugOverride: nil)
        return try await rawPerform(request)
    }
}
