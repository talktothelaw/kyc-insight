import Foundation

/// A level (tier) the customer is moving through. `slug` matches the
/// merchant's level slug (e.g. `tier_1`); `index` is zero-based.
public struct KYCWidgetLevel: Sendable, Equatable {
    public let slug: String
    public let index: Int

    public init(slug: String, index: Int) {
        self.slug = slug
        self.index = index
    }
}

/// Internal envelope used over the JS↔Swift bridge. Matches the web SDK's
/// `BridgeMessage` (`kyc-web-wiget-v2/src/sdk/iframeLoader.ts`) byte-for-byte
/// so the same widget code talks to both the iframe loader (web) and the
/// WKWebView host (iOS) with no protocol divergence.
struct BridgeMessage: Decodable {
    let source: String
    let type: String
    let payload: AnyJSON?

    static let widgetSource = "kyc-widget-v2"
    static let hostSource = "kyc-widget-v2-host"
}

/// Loose JSON value — used for the polymorphic `payload` field on
/// ``BridgeMessage``. We decode into this and let each event-specific
/// handler pick the shape it needs.
///
/// Public so the ``KYCWidget/onSubmit`` and ``KYCWidget/onSuccess``
/// callbacks can expose the raw payload to the host app without forcing
/// a specific schema. Use the `*Value` accessors or pattern-match the
/// cases directly.
public enum AnyJSON: Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyJSON])
    case array([AnyJSON])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let n = try? container.decode(Double.self) { self = .number(n); return }
        if let arr = try? container.decode([AnyJSON].self) { self = .array(arr); return }
        if let obj = try? container.decode([String: AnyJSON].self) { self = .object(obj); return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unrecognised JSON value"
        )
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var doubleValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var intValue: Int? { if case .number(let n) = self { return Int(n) } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var dictValue: [String: AnyJSON]? { if case .object(let d) = self { return d } else { return nil } }
    public var arrayValue: [AnyJSON]? { if case .array(let a) = self { return a } else { return nil } }
}

extension AnyJSON {
    /// Pull a level out of a `{ slug: String, index: Int }` payload object.
    static func decodeLevel(_ payload: AnyJSON?) -> KYCWidgetLevel? {
        guard let dict = payload?.dictValue,
              let slug = dict["slug"]?.stringValue,
              let index = dict["index"]?.intValue else { return nil }
        return KYCWidgetLevel(slug: slug, index: index)
    }

    /// Pull `{ message: String }` out of an error payload.
    static func decodeMessage(_ payload: AnyJSON?) -> String? {
        payload?.dictValue?["message"]?.stringValue
    }
}
