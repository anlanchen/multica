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

    /// Decodes an array, skipping elements that fail to decode instead of
    /// discarding the whole array.
    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
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
