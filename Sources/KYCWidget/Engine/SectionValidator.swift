import Foundation

/// 1:1 port of `kyc-web-wiget-v2/src/engine/processing/validate.ts`.
///
/// Per-field-kind validation. Pure — takes a field + value, returns an
/// error message or nil. Mirror the web's behaviour exactly so iOS and
/// web behave identically when the same backend schema is rendered.
enum SectionValidator {

    static let emailRegex = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
    static let timeRegex  = #"^([01]\d|2[0-3]):[0-5]\d$"#

    /// Validate one field's value. Returns an error message, or nil if
    /// the value is acceptable.
    static func validate(field: WidgetField, value: AnyCodable?) -> String? {
        switch field.kind {
        case .liveness:
            let selfie = value?.dictValue?["selfieImage"]?.stringValue ?? ""
            if selfie.isEmpty && field.required {
                return "Please complete the photo capture."
            }
            return nil

        case .file, .image:
            // Satisfied only when the upload pipeline has stored a
            // `fileId`. A picked-but-unuploaded file (legacy shape with
            // `{name, size}` and no fileId) is treated as empty.
            let uploaded = (value?.dictValue?["fileId"]?.stringValue ?? "").isEmpty == false
            if !uploaded && field.required {
                return "\(field.label) is required."
            }
            return nil

        case .ninConsent:
            let cid = value?.dictValue?["consentAcceptanceId"]?.stringValue ?? ""
            if cid.isEmpty && field.required {
                return "Please complete NIN verification."
            }
            return nil

        case .driversLicenseConsent:
            let cid = value?.dictValue?["consentAcceptanceId"]?.stringValue ?? ""
            if cid.isEmpty && field.required {
                return "Please complete Driver's License verification."
            }
            return nil

        case .passportConsent:
            let cid = value?.dictValue?["consentAcceptanceId"]?.stringValue ?? ""
            if cid.isEmpty && field.required {
                return "Please complete International Passport verification."
            }
            return nil

        case .cacBusinessLookup:
            let id = value?.dictValue?["kycSubmissionId"]?.stringValue
                ?? value?.dictValue?["_id"]?.stringValue ?? ""
            if id.isEmpty && field.required {
                return "Please complete the CAC business verification."
            }
            return nil

        case .sysSelect:
            let composite = value?.dictValue
            let selectedType = composite?["selectedType"]?.stringValue ?? ""
            if selectedType.isEmpty {
                return field.required ? "\(field.label) is required." : nil
            }
            // Recurse into the chosen sub-option's required sub-fields —
            // an unfilled required sub-field invalidates the whole select.
            // BVN-style sub-fields write under a `values` dict keyed by
            // field NAME (not id), mirroring the web.
            guard let options = field.sysSelectOptions,
                  let option = options.first(where: { $0.providerType == selectedType }) else {
                return nil
            }
            let subValues = composite?["values"]?.dictValue ?? [:]
            for sub in option.fields where sub.required {
                let raw = subValues[sub.name]
                if isEmpty(raw) {
                    return "Please complete all fields for \(option.label)."
                }
                // For sub-fields that themselves carry kind-specific
                // semantics (a nested ninConsent inside a sysSelect, for
                // example), recurse. The web validates sub-fields with the
                // SAME validator, so any custom-provider type bolted onto
                // a sub-option still gets its kind check.
                if let err = validate(field: sub, value: raw) {
                    return err
                }
            }
            return nil

        default:
            // Plain inputs — required check, then format check.
            let empty = isEmpty(value)
            if field.required && empty { return "\(field.label) is required." }
            if empty { return nil }
            let str = value?.stringValue ?? ""
            switch field.kind {
            case .email:
                if str.range(of: emailRegex, options: .regularExpression) == nil {
                    return "Enter a valid email address."
                }
            case .number:
                if Double(str) == nil {
                    return "Enter a valid number."
                }
            case .url:
                if URL(string: str) == nil || !str.contains("://") {
                    return "Enter a valid URL (e.g. https://example.com)."
                }
            case .time:
                if str.range(of: timeRegex, options: .regularExpression) == nil {
                    return "Enter a valid time (HH:MM, 24-hour)."
                }
            default:
                break
            }
            return nil
        }
    }

    /// Validate every field in the section. Returns a `{fieldId: error}`
    /// map containing only failing fields. Skips fields the backend
    /// stamped `alreadySupplied: true` on a `requiresUpdate` section —
    /// they're hidden in the UI and the backend already has the value
    /// on the kyc_v2 row, so demanding them again would fight the
    /// "don't make the user retype" rule.
    static func validate(section: WidgetSection, values: [String: AnyCodable]) -> [String: String] {
        var errors: [String: String] = [:]
        for field in section.fields {
            if section.requiresUpdate && field.alreadySupplied == true { continue }
            if let err = validate(field: field, value: values[field.id]) {
                errors[field.id] = err
            }
        }
        return errors
    }

    /// Web's `isEmpty` — empty arrays, empty strings, false, and nil all
    /// count as empty. Matters most for `.checkbox` group-mode where
    /// nothing-selected is `[]`, not `nil`.
    static func isEmpty(_ value: AnyCodable?) -> Bool {
        switch value {
        case .none, .some(.null): return true
        case .some(.string(let s)): return s.trimmingCharacters(in: .whitespaces).isEmpty
        case .some(.array(let a)): return a.isEmpty
        case .some(.object(let o)): return o.isEmpty
        case .some(.bool(let b)): return b == false
        default: return false
        }
    }
}
