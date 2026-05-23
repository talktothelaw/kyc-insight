import Foundation

/// Field kinds the widget knows how to render natively. 1:1 with
/// `FIELD_KINDS` in `kyc-web-wiget-v2/src/types/schema.ts`. Anything the
/// backend emits that doesn't map here resolves to ``unknown`` and the
/// renderer surfaces a placeholder.
public enum FieldKind: String, Sendable, Codable {
    case text, email, number, date, datetime, time
    case url, password
    case select, checkbox, radio, file, image
    case sysSelect, bvn, ninConsent
    case driversLicenseConsent, passportConsent
    case cacBusinessLookup
    case liveness, location
    case unknown
}

/// Section / step submission status. 1:1 with the web's `Status` union.
public enum WidgetStatus: String, Sendable, Codable {
    case initialized, pending, approved, rejected
}

public struct WidgetOption: Sendable, Hashable, Codable {
    public let label: String
    public let value: String
    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// A SysSelect sub-option — the customer picks a verification method,
/// each carrying its own sub-fields. Lives in ``WidgetField/sysSelectOptions``.
public struct SysSelectOption: Sendable, Codable {
    public let providerId: String
    public let providerType: String
    public let label: String
    public let fields: [WidgetField]
}

/// A normalised field — what every native renderer binds to. Field-kind-
/// specific extras (sysSelect options, file kycType, etc.) live in their
/// own optional properties rather than a generic `meta` dictionary so the
/// Swift type system catches mismatches at compile time.
public struct WidgetField: Identifiable, Sendable, Codable {
    public let id: String
    public let name: String
    public let label: String
    public let kind: FieldKind
    public let required: Bool
    public let options: [WidgetOption]?

    /// Provider's `kycType` — propagated to file + liveness fields so
    /// `RequestFileUploadTwo` knows which slot to upload into.
    public let kycType: String?

    /// Sub-options for `sysSelect`. Empty for other kinds.
    public let sysSelectOptions: [SysSelectOption]?

    public init(
        id: String,
        name: String,
        label: String,
        kind: FieldKind,
        required: Bool,
        options: [WidgetOption]? = nil,
        kycType: String? = nil,
        sysSelectOptions: [SysSelectOption]? = nil
    ) {
        self.id = id
        self.name = name
        self.label = label
        self.kind = kind
        self.required = required
        self.options = options
        self.kycType = kycType
        self.sysSelectOptions = sysSelectOptions
    }
}

public struct WidgetSection: Identifiable, Sendable, Codable {
    public let id: String
    public let name: String
    public let status: WidgetStatus
    public let providerId: String
    public let providerType: String
    public let fields: [WidgetField]
    /// Values pre-filled from a prior submission (kyc_v2.kycPayload). Keyed
    /// by field id. Used to seed the widget's `values` so rejected sections
    /// come up with the user's prior data already in place.
    public let submittedValues: [String: AnyCodable]?

    public init(
        id: String, name: String, status: WidgetStatus,
        providerId: String, providerType: String,
        fields: [WidgetField], submittedValues: [String: AnyCodable]? = nil
    ) {
        self.id = id; self.name = name; self.status = status
        self.providerId = providerId; self.providerType = providerType
        self.fields = fields; self.submittedValues = submittedValues
    }
}

public struct WidgetStep: Identifiable, Sendable, Codable {
    public let id: String
    public let name: String
    public let slug: String
    public let status: WidgetStatus
    public let sections: [WidgetSection]
}

public struct WidgetSchema: Sendable, Codable {
    public let processToken: String
    public let steps: [WidgetStep]
    public init(processToken: String, steps: [WidgetStep]) {
        self.processToken = processToken
        self.steps = steps
    }
}
