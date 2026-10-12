import Foundation

// Installed desktop clients talk to newer backends, so every UI-consumed
// payload decodes leniently: a missing or mistyped optional field falls back to
// its default instead of failing the whole response (the upstream web client
// does the same with zod + parseWithFallback).

extension KeyedDecodingContainer {
    @inline(__always)
    func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    @inline(__always)
    func lossy<T: Decodable>(_ type: T.Type, _ key: Key, default value: T) -> T {
        lossy(type, key) ?? value
    }

    /// Lenient scalar/struct decode used by generated models: a missing,
    /// null or mistyped value yields nil, and numbers convert between Int,
    /// Double and String the way JavaScript would read them.
    public func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        if let v = try? decodeIfPresent(T.self, forKey: key) { return v }
        if T.self == Int.self, let d = try? decodeIfPresent(Double.self, forKey: key), d.isFinite {
            return Int(d) as? T
        }
        if T.self == String.self {
            if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) as? T }
            if let b = try? decodeIfPresent(Bool.self, forKey: key) { return String(b) as? T }
        }
        if T.self == Bool.self, let s = try? decodeIfPresent(String.self, forKey: key) {
            return (s == "true") as? T
        }
        return nil
    }

    /// Decodes an array, skipping elements that fail to decode instead of
    /// discarding the whole array.
    public func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        guard var nested = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var out: [T] = []
        if let count = nested.count { out.reserveCapacity(count) }
        while !nested.isAtEnd {
            if let value = try? nested.decode(T.self) {
                out.append(value)
            } else {
                _ = try? nested.decode(Skip.self)
            }
        }
        return out
    }
}

/// Consumes one JSON value of any shape.
struct Skip: Decodable {
    init(from decoder: Decoder) throws {}
}

/// Top-level array decoding that drops malformed elements.
public struct LossyList<Element: Decodable>: Decodable {
    public var items: [Element]

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Element] = []
        if let count = c.count { out.reserveCapacity(count) }
        while !c.isAtEnd {
            if let v = try? c.decode(Element.self) {
                out.append(v)
            } else {
                _ = try? c.decode(Skip.self)
            }
        }
        items = out
    }
}

/// String-backed open enum. The server keeps adding statuses, failure reasons
/// and inbox types; an installed client must carry unknown values through
/// instead of failing to decode them.
public protocol OpenEnum: RawRepresentable, Codable, Hashable, Sendable where RawValue == String {
    init(rawValue: String)
}

extension OpenEnum {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.init(rawValue: (try? c.decode(String.self)) ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Shared JSON coders. `JSONDecoder` is safe to reuse across threads once
/// configured; allocating one per frame shows up in WebSocket profiles.
public enum JSONCoders {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

extension LossyList: Sendable where Element: Sendable {}
