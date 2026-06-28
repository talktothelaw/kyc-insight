import Foundation

/// Raw shapes returned by the `createMerchantCustomer` GraphQL query.
/// 1:1 port of `kyc-web-wiget-v2/src/types/backendSchema.ts`.
///
/// These models intentionally mirror the backend exactly — no display
/// formatting, no kind resolution. The widget never consumes them
/// directly; everything goes through ``SchemaNormalizer/normalize(_:)``
/// which produces the typed ``WidgetSchema`` the UI binds to.
struct RawField: Decodable {
    /// Optional because dynamicCollection child fields (`itemFields`) are stored
    /// as Mixed subdocs WITHOUT an `_id` (datasource.normalizeChildFields strips
    /// it) — the normalizer synthesises a stable id for those.
    let _id: String?
    let name: String
    let title: String
    let inputType: String
    /// Backend ships option lists as `[String]` for plain selects/radios,
    /// or as `[RawProvider]` for `sysSelect` (the customer picks a verification
    /// method, each with its own sub-fields). Captured as `AnyCodable` here
    /// so the normalizer can branch on the field's `inputType`.
    let options: [AnyCodable]?
    let required: Bool?
    /// Dynamic Collection (repeatable group): child fields + row config. Present
    /// only when `inputType == "dynamicCollection"`. Recurses the same RawField
    /// (one level — children never carry their own itemFields). Arrives verbatim
    /// via the createMerchantCustomer JSON passthrough.
    // `var … = nil` keeps the synthesised memberwise init source-compatible with
    // existing callers that don't pass these dynamicCollection-only fields, while
    // STILL exposing them as settable init params (a `let … = nil` would be
    // excluded from the memberwise init). Decodable decodes them when present.
    var itemFields: [RawField]? = nil
    var minRows: Int? = nil
    var maxRows: Int? = nil
    var defaultRows: Int? = nil
    var allowAdd: Bool? = nil
    var allowDelete: Bool? = nil
    var allowDuplicate: Bool? = nil
    var allowReorder: Bool? = nil
    /// Server-stamped: does the customer's existing data satisfy this
    /// specific field? Computed by
    /// `kyc-backend/src/helpers/fieldSupplyResolver.ts:stampAlreadySuppliedOnLevel`
    /// from the matching kyc_v2 row's status + kycPayload. Lets the
    /// widget render only what's still missing on a previously-
    /// approved tier without guessing.
    let alreadySupplied: Bool?

    /// Returns a copy with `_id` replaced — used to stamp a synthesised id on a
    /// dynamicCollection child field that arrived without one.
    func withId(_ newId: String) -> RawField {
        RawField(
            _id: newId, name: name, title: title, inputType: inputType,
            options: options, required: required, itemFields: itemFields,
            minRows: minRows, maxRows: maxRows, defaultRows: defaultRows,
            allowAdd: allowAdd, allowDelete: allowDelete, allowDuplicate: allowDuplicate,
            allowReorder: allowReorder, alreadySupplied: alreadySupplied
        )
    }
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
