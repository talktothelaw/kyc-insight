import Foundation

/// Permissive JSON value — used wherever the backend returns shapes the
/// SDK doesn't normalize into typed structs. Lets us round-trip arbitrary
/// payloads through `Codable` without forcing a schema.
///
/// Identical conceptually to the web SDK's `AnyJSON`.
public enum AnyCodable: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyCodable])
    case array([AnyCodable])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let arr = try? c.decode([AnyCodable].self) { self = .array(arr); return }
        if let obj = try? c.decode([String: AnyCodable].self) { self = .object(obj); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // Convenience accessors
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var doubleValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var intValue: Int? { if case .number(let n) = self { return Int(n) } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var dictValue: [String: AnyCodable]? { if case .object(let d) = self { return d } else { return nil } }
    public var arrayValue: [AnyCodable]? { if case .array(let a) = self { return a } else { return nil } }

    /// JSON-typed `Any` for use with `JSONSerialization` (e.g. when sending
    /// back through the GraphQL client as a variable).
    public var rawValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .string(let s): return s
        case .number(let n): return n
        case .array(let a): return a.map { $0.rawValue }
        case .object(let o):
            var out: [String: Any] = [:]
            for (k, v) in o { out[k] = v.rawValue }
            return out
        }
    }
}
