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
    case driversLicenseConsent, passportConsent, cacConsent
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

    /// Mirrored from the backend's `field.alreadySupplied` stamp
    /// (`kyc-backend/src/helpers/fieldSupplyResolver.ts`). True when the
    /// customer's existing approved/pending data satisfies this field
    /// and the user doesn't need to fill it again. nil when the
    /// backend didn't stamp.
    public let alreadySupplied: Bool?

    public init(
        id: String,
        name: String,
        label: String,
        kind: FieldKind,
        required: Bool,
        options: [WidgetOption]? = nil,
        kycType: String? = nil,
        sysSelectOptions: [SysSelectOption]? = nil,
        alreadySupplied: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.label = label
        self.kind = kind
        self.required = required
        self.options = options
        self.kycType = kycType
        self.sysSelectOptions = sysSelectOptions
        self.alreadySupplied = alreadySupplied
    }
}

public enum RequiresUpdateReason: String, Sendable, Codable {
    case pending_placeholder
    case requirements_changed
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
    /// Client-derived from the backend's per-field `alreadySupplied`
    /// stamps. True when ANY required field comes back unsupplied AND
    /// the section's status is approved/pending (user has already
    /// engaged with it). UI keeps the form editable and shows the
    /// LevelUpdateBannerView.
    public let requiresUpdate: Bool
    /// Why `requiresUpdate` fired — drives banner copy.
    public let requiresUpdateReason: RequiresUpdateReason?

    public init(
        id: String, name: String, status: WidgetStatus,
        providerId: String, providerType: String,
        fields: [WidgetField], submittedValues: [String: AnyCodable]? = nil,
        requiresUpdate: Bool = false,
        requiresUpdateReason: RequiresUpdateReason? = nil
    ) {
        self.id = id; self.name = name; self.status = status
        self.providerId = providerId; self.providerType = providerType
        self.fields = fields; self.submittedValues = submittedValues
        self.requiresUpdate = requiresUpdate
        self.requiresUpdateReason = requiresUpdateReason
    }
}

public struct WidgetStep: Identifiable, Sendable, Codable {
    public let id: String
    public let name: String
    public let slug: String
    public let status: WidgetStatus
    public let sections: [WidgetSection]
    /// Roll-up: at least one section needs the user's input. Drives the
    /// tier-level frontier so the user can't skip past it.
    public let requiresUpdate: Bool

    public init(
        id: String, name: String, slug: String, status: WidgetStatus,
        sections: [WidgetSection], requiresUpdate: Bool = false
    ) {
        self.id = id; self.name = name; self.slug = slug
        self.status = status; self.sections = sections
        self.requiresUpdate = requiresUpdate
    }
}

public struct WidgetSchema: Sendable, Codable {
    public let processToken: String
    public let steps: [WidgetStep]
    public init(processToken: String, steps: [WidgetStep]) {
        self.processToken = processToken
        self.steps = steps
    }
}
