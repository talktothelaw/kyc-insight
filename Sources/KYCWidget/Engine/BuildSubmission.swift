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

        for field in section.fields {
            let raw = values[field.id]
            switch field.kind {
            case .sysSelect:
                if let dict = raw?.dictValue,
                   let selectedType = dict["selectedType"]?.stringValue {
                    optionalType = selectedType
                    if let subValues = dict["values"]?.dictValue {
                        for (name, val) in subValues {
                            if let consentDict = val.dictValue,
                               let cid = consentDict["consentAcceptanceId"]?.stringValue {
                                // Inner nin_consent — surface only the safe ref.
                                consentAcceptanceId = cid
                                consentReference = consentDict["consentReference"]?.stringValue
                            } else {
                                items.append(.init(field: name, value: stringify(val)))
                            }
                        }
                    }
                }
            case .ninConsent, .driversLicenseConsent, .passportConsent:
                if let dict = raw?.dictValue,
                   let cid = dict["consentAcceptanceId"]?.stringValue {
                    consentAcceptanceId = cid
                    consentReference = dict["consentReference"]?.stringValue
                }
            case .cacBusinessLookup:
                if let dict = raw?.dictValue,
                   let id = dict["kycSubmissionId"]?.stringValue {
                    items.append(.init(field: field.name, value: id, type: "ref"))
                }
            case .file, .liveness, .image:
                // The widget stored the uploaded file's id under `fileId`.
                // Real upload pipeline writes that key after RequestFileUploadTwo.
                if let dict = raw?.dictValue,
                   let fileId = dict["fileId"]?.stringValue {
                    items.append(.init(field: field.name, value: fileId, type: "file"))
                }
            case .location:
                if let dict = raw?.dictValue,
                   let id = dict["_id"]?.stringValue {
                    items.append(.init(field: field.name, value: id))
                }
            default:
                items.append(.init(field: field.name, value: stringify(raw)))
            }
        }

        return BuiltPayload(
            processToken: processToken,
            providerId: section.providerId,
            kycType: section.providerType,
            levelSlug: step.slug,
            optionalType: optionalType,
            kycPayload: items,
            consentAcceptanceId: consentAcceptanceId,
            consentReference: consentReference
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
