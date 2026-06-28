import Foundation

/// Port of `kyc-web-wiget-v2/src/engine/processing/buildSubmission.ts`.
/// Assembles the `KycPayloadV2` the backend's `KycSubmission` mutation
/// expects from one section's field values.
enum BuildSubmission {

    struct BuiltPayload {
        var processToken: String
        var providerId: String
        var kycType: String
        var levelSlug: String?
        var optionalType: String?
        var kycPayload: [KycPayloadItem]
        var consentAcceptanceId: String?
        var consentReference: String?
        /// `kyc_v2._id` of a self-completing CAC verification (held by
        /// executeCacBusinessChecks). When set, the session finalizes via
        /// `finalizeCacRequirement` so this section's OTHER fields merge into
        /// the SAME CAC submission instead of a separate, disconnected row.
        /// Routing-only — NOT included in the GraphQL variables (mirrors web,
        /// where buildSubmission surfaces it but submitKyc never sends it).
        var cacKycSubmissionId: String?

        /// Convert to the dictionary the GraphQL `data` variable expects.
        func toVariable() -> [String: Any] {
            var dict: [String: Any] = [
                "processToken": processToken,
                "providerId":   providerId,
                "kycType":      kycType,
                "kycPayload":   kycPayload.map { $0.toDictionary() },
            ]
            if let levelSlug { dict["levelSlug"] = levelSlug }
            if let optionalType { dict["optionalType"] = optionalType }
            if let consentAcceptanceId { dict["consentAcceptanceId"] = consentAcceptanceId }
            if let consentReference { dict["consentReference"] = consentReference }
            return dict
        }
    }

    struct KycPayloadItem {
        var field: String
        var value: String
        var type: String?
        func toDictionary() -> [String: Any] {
            var d: [String: Any] = ["field": field, "value": value]
            if let type { d["type"] = type }
            return d
        }
    }

    /// Build a submission for one section. Mirrors the web's branch table.
    static func build(
        processToken: String,
        step: WidgetStep,
        section: WidgetSection,
        values: [String: AnyCodable]
    ) -> BuiltPayload {
        var items: [KycPayloadItem] = []
        var optionalType: String?
        var consentAcceptanceId: String?
        var consentReference: String?
        var cacKycSubmissionId: String?

        for field in section.fields {
            let raw = values[field.id]
            switch field.kind {
            case .sysSelect:
                // sysSelect composite values may be NESTED — the leaf option
                // the user picked can sit 2+ levels deep. flatten walks the
                // chain, sets optionalType to the LEAF type, surfaces a leaf
                // consent / CAC reference, and emits payload entries for every
                // non-special value at every level.
                let flat = SysSelectTraversal.flattenSysSelect(raw?.dictValue)
                if let leaf = flat.leafType { optionalType = leaf }
                if let cid = flat.consentAcceptanceId {
                    consentAcceptanceId = cid
                    if let ref = flat.consentReference { consentReference = ref }
                }
                if let cacId = flat.cacKycSubmissionId { cacKycSubmissionId = cacId }
                for entry in flat.entries {
                    items.append(.init(field: entry.name, value: stringify(entry.value)))
                }
            case .ninConsent, .driversLicenseConsent, .passportConsent, .cacConsent:
                if let dict = raw?.dictValue,
                   let cid = dict["consentAcceptanceId"]?.stringValue {
                    consentAcceptanceId = cid
                    consentReference = dict["consentReference"]?.stringValue
                }
            case .cacBusinessLookup:
                // CAC package is "self-completing": by the time the user
                // taps Continue, executeCacBusinessChecks already HELD a
                // kyc_v2 row server-side. Emit no kycPayload entry; surface
                // its reference so the session can finalize — merging any
                // sibling fields into the SAME submission. A CAC-only section
                // still short-circuits before any network call. Mirrors web
                // buildSubmission.ts.
                if let cac = raw?.dictValue, cac["verified"]?.boolValue == true {
                    cacKycSubmissionId = cac["kycSubmissionId"]?.stringValue
                }
            case .liveness:
                // Liveness emits TWO entries on the wire: the selfie
                // (named after the field) and a synthetic
                // `liveliness_images` entry that's a JSON-stringified
                // array of frames. Mirrors buildSubmission.ts:87-96.
                if let dict = raw?.dictValue {
                    let selfie = dict["selfieImage"]?.stringValue ?? dict["fileId"]?.stringValue ?? ""
                    items.append(.init(field: field.name, value: selfie))
                    if let frames = dict["livelinessImages"]?.arrayValue {
                        let arr = frames.compactMap { $0.stringValue }
                        if let data = try? JSONSerialization.data(withJSONObject: arr),
                           let json = String(data: data, encoding: .utf8) {
                            items.append(.init(field: "liveliness_images", value: json))
                        }
                    }
                } else {
                    items.append(.init(field: field.name, value: ""))
                }
            case .file, .image:
                // FileFieldValue stores `fileId` after upload. Pre-upload
                // the field is empty — emit '' so validation flags it as
                // missing. NOTE: NO `type` key — the backend's kycPayload
                // schema has no such field; sending it produced spurious
                // strict-mode warnings server-side.
                let fileId = raw?.dictValue?["fileId"]?.stringValue ?? ""
                items.append(.init(field: field.name, value: fileId))
            case .location:
                // LocationFieldView stores `{ _id, name }`; the wire shape
                // is just the _id string.
                if let dict = raw?.dictValue,
                   let id = dict["_id"]?.stringValue {
                    items.append(.init(field: field.name, value: id))
                }
            case .dynamicCollection:
                // The whole repeatable group collapses to ONE entry: the
                // JSON-stringified rows array (each row = child values keyed by
                // name + a permanent _rowId). Empty → "" so it's dropped below.
                // Reuses the checkbox array-stringify precedent.
                let rows = raw?.arrayValue ?? []
                items.append(.init(field: field.name, value: rows.isEmpty ? "" : stringify(raw)))
            default:
                items.append(.init(field: field.name, value: stringify(raw)))
            }
        }

        // Drop kycPayload entries whose value is empty — kyc_v2.kycPayload
        // schema has `value: { type: String, required: true }`, and
        // Mongoose treats empty strings as missing-required. Required
        // fields are already caught by `validateCurrentSection`; remaining
        // empties are optional-and-unfilled and safe to drop. Mirrors the
        // web's `filteredKycPayload` filter (buildSubmission.ts:120).
        let filtered = items.filter { !$0.value.isEmpty }

        return BuiltPayload(
            processToken: processToken,
            providerId: section.providerId,
            kycType: section.providerType,
            levelSlug: step.slug,
            optionalType: optionalType,
            kycPayload: filtered,
            consentAcceptanceId: consentAcceptanceId,
            consentReference: consentReference,
            cacKycSubmissionId: cacKycSubmissionId
        )
    }

    /// Mirrors the web's `stringifyValue` — collapses any value into the
    /// string the backend expects in `kycPayload.value`.
    private static func stringify(_ value: AnyCodable?) -> String {
        guard let value else { return "" }
        switch value {
        case .null: return ""
        case .string(let s): return s
        case .number(let n):
            if n.truncatingRemainder(dividingBy: 1) == 0 { return String(Int(n)) }
            return String(n)
        case .bool(let b): return String(b)
        case .object, .array:
            if let data = try? JSONSerialization.data(withJSONObject: value.rawValue),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return ""
        }
    }
}
