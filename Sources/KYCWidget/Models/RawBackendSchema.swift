import Foundation

/// Raw shapes returned by the `createMerchantCustomer` GraphQL query.
/// 1:1 port of `kyc-web-wiget-v2/src/types/backendSchema.ts`.
///
/// These models intentionally mirror the backend exactly — no display
/// formatting, no kind resolution. The widget never consumes them
/// directly; everything goes through ``SchemaNormalizer/normalize(_:)``
/// which produces the typed ``WidgetSchema`` the UI binds to.
struct RawField: Decodable {
    let _id: String
    let name: String
    let title: String
    let inputType: String
    /// Backend ships option lists as `[String]` for plain selects/radios,
    /// or as `[RawProvider]` for `sysSelect` (the customer picks a verification
    /// method, each with its own sub-fields). Captured as `AnyCodable` here
    /// so the normalizer can branch on the field's `inputType`.
    let options: [AnyCodable]?
    let required: Bool?
}

struct RawProviderData: Decodable {
    /// Previously-submitted payload from kyc_v2, used to pre-fill rejected
    /// sections. Each entry: `{ field: String, value: AnyCodable, type?: String }`.
    let kycPayload: [RawSubmittedField]?
}

struct RawSubmittedField: Decodable {
    let field: String
    let value: AnyCodable?
    let type: String?
}

struct RawProvider: Decodable {
    let _id: String
    let service: String
    let type: String
    let shortName: String?
    let status: String?
    let fields: [RawField]
    /// Attached by the backend when a matching kyc_v2 row exists.
    let data: RawProviderData?
}

struct RawLevel: Decodable {
    let levelName: String
    let levelSlug: String
    let status: String
    let providersInfo: [RawProvider]
}

struct RawCustomerSession: Decodable {
    let processToken: String
    let merchantId: String?
    let status: String?
    let userRef: String?
    let slug: String?
    let name: String?
    let levels: [RawLevel]
}

/// `createMerchantCustomer` returns a JSON-scalar envelope of the form
/// `{ message: String, data: RawCustomerSession }`. Captured here so the
/// network layer can pull the session out cleanly.
struct RawCreateCustomerResponse: Decodable {
    let message: String?
    let data: RawCustomerSession
}
