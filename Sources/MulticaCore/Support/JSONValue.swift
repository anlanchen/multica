import Foundation

/// Arbitrary JSON, used for server fields whose shape is open (issue metadata,
/// activity details, tool input). Kept as a value so it is `Sendable` and cheap
/// to copy; rendering code reads only what it needs and clips the rest.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n):
            return n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// Compact single-line rendering, clipped to `limit` characters. Tool
    /// inputs are unbounded on the wire (a Write tool ships the whole file), so
    /// list rows must never stringify the full value.
    public func preview(limit: Int = 200) -> String {
        var out = ""
        out.reserveCapacity(min(limit, 256))
        appendPreview(into: &out, limit: limit)
        if out.count > limit { return String(out.prefix(limit)) + "…" }
        return out
    }

    private func appendPreview(into out: inout String, limit: Int) {
        if out.count > limit { return }
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number: out += stringValue ?? ""
        case .string(let s):
            out += "\""
            out += s.count > limit ? String(s.prefix(limit)) : s
            out += "\""
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if out.count > limit { break }
                if i > 0 { out += ", " }
                v.appendPreview(into: &out, limit: limit)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, k) in o.keys.sorted().enumerated() {
                if out.count > limit { break }
                if i > 0 { out += ", " }
                out += k
                out += ": "
                o[k]!.appendPreview(into: &out, limit: limit)
            }
            out += "}"
        }
    }
}
