import Foundation

/// 1:1 Swift port of `kyc-web-wiget-v2/src/engine/normalize.ts`.
///
/// Takes the raw `createMerchantCustomer` response from the backend and
/// produces a typed ``WidgetSchema`` the SwiftUI renderer binds to. Every
/// rule the web widget applies — status mapping, field-kind resolution,
/// label formatting, location reordering, submitted-value pre-fill —
/// must be preserved here so the iOS widget renders exactly what the web
/// widget renders for the same backend response.
enum SchemaNormalizer {

    // MARK: - Top-level entry

    static func normalize(_ raw: RawCustomerSession) -> WidgetSchema {
        let steps: [WidgetStep] = raw.levels.map { level in
            let sections: [WidgetSection] = level.providersInfo.map { provider in
                let fields = normalizeProviderFields(provider: provider)
                let submittedValues = extractSubmittedValues(provider: provider, fields: fields)
                let status = normalizeStatus(provider.status)

                // Backend-authoritative "needs update" derivation —
                // 1:1 mirror of `kyc-web-wiget-v2/src/engine/normalize.ts`.
                // Trust `field.alreadySupplied` from the backend
                // (`fieldSupplyResolver.ts`). Three guards before
                // flipping requiresUpdate:
                //
                //   1. Backend must be stamping (some field === true).
                //   2. Status must be approved OR pending (user
                //      engaged).
                //   3. Plain-text evidence: if the section is approved
                //      but ZERO plain-text fields are stamped true
                //      (only opaque kinds like sysSelect / consent
                //      did), that's a backend matching/projection bug
                //      — likely the consent sub-row was matched
                //      instead of the form-fields row. Trust the
                //      `approved` status; suppress requiresUpdate.
                let hasAnyStampedTrue = fields.contains { $0.alreadySupplied == true }
                let hasMissingRequired = fields.contains { $0.required && $0.alreadySupplied != true }
                let isEngagedStatus = status == .approved || status == .pending
                let textKinds: Set<FieldKind> = [
                    .text, .email, .number, .date, .datetime, .time,
                    .url, .password, .select, .radio, .checkbox, .location,
                ]
                let hasPlainTextFields = fields.contains { textKinds.contains($0.kind) }
                let hasAnyPlainTextSupplied = fields.contains {
                    textKinds.contains($0.kind) && $0.alreadySupplied == true
                }
                let looksLikeServerDataGap = status == .approved
                    && hasPlainTextFields
                    && !hasAnyPlainTextSupplied
                let requiresUpdate = !looksLikeServerDataGap
                    && hasAnyStampedTrue
                    && hasMissingRequired
                    && isEngagedStatus
                let reason: RequiresUpdateReason? = requiresUpdate
                    ? (status == .approved ? .requirements_changed : .pending_placeholder)
                    : nil

                return WidgetSection(
                    id: provider._id,
                    name: formatLabel(provider.service),
                    status: status,
                    providerId: provider._id,
                    providerType: provider.type,
                    fields: fields,
                    submittedValues: submittedValues.isEmpty ? nil : submittedValues,
                    requiresUpdate: requiresUpdate,
                    requiresUpdateReason: reason
                )
            }
            // Roll-up: tier needs update if any section does.
            let stepRequiresUpdate = sections.contains { $0.requiresUpdate }
            return WidgetStep(
                id: level.levelSlug,
                name: formatLabel(level.levelName),
                slug: level.levelSlug,
                status: normalizeStatus(level.status),
                sections: sections,
                requiresUpdate: stepRequiresUpdate
            )
        }
        return WidgetSchema(processToken: raw.processToken, steps: steps)
    }

    // MARK: - Status

    static func normalizeStatus(_ raw: String?) -> WidgetStatus {
        switch raw {
        case "approved":  return .approved
        case "pending":   return .pending
        case "rejected":  return .rejected
        case "failed":    return .rejected
        default:          return .initialized
        }
    }

    // MARK: - Field kind resolution

    static func resolveFieldKind(_ field: RawField, provider: RawProvider) -> FieldKind {
        switch field.inputType {
        case "select":    return .select
        case "sysSelect": return .sysSelect
        case "file":
            // Liveness override — selfie field on liveness providers becomes
            // a video capture, not a static file upload.
            let livenessProviders: Set<String> = ["face_match_nin", "liveness_check"]
            if field.name == "selfieImage" && livenessProviders.contains(provider.type) {
                return .liveness
            }
            return .file
        case "textInput":
            // Legacy catch-all — name + title heuristics keep older provider
            // configs rendering with the right kind even though they predate
            // the explicit `inputType` semantic tags.
            let name = field.name.lowercased()
            let title = field.title.lowercased()
            if name == "bvn" || title == "bvn" { return .bvn }
            if name.contains("date") { return .date }
            if name.contains("country") || name.contains("state") || name.contains("lga") {
                return .location
            }
            if name.contains("email") || title.contains("email") { return .email }
            return .text
        case "date":     return .date
        case "time":     return .time
        case "email":    return .email
        case "number":   return .number
        case "password": return .password
        case "radio":    return .radio
        case "checkbox": return .checkbox
        case "image":    return .image
        case "url":      return .url
        case "__nin_consent_step__":              return .ninConsent
        case "__drivers_license_consent_step__":  return .driversLicenseConsent
        case "__passport_consent_step__":         return .passportConsent
        case "__cac_consent_step__":              return .cacConsent
        case "__cac_business_package_step__":     return .cacBusinessLookup
        default: return .unknown
        }
    }

    // MARK: - Field

    static func normalizeField(_ raw: RawField, provider: RawProvider) -> WidgetField {
        let kind = resolveFieldKind(raw, provider: provider)

        // Build options from string list for choice-based kinds.
        var options: [WidgetOption]?
        if (kind == .select || kind == .radio || kind == .checkbox),
           let raws = raw.options {
            options = raws.compactMap { opt in
                guard let s = opt.stringValue else { return nil }
                return WidgetOption(label: formatLabel(s), value: s)
            }
        }

        // sysSelect — options is a list of RawProvider sub-options.
        var sysSelectOptions: [SysSelectOption]?
        if kind == .sysSelect, let rawSubs = raw.options {
            let providers: [RawProvider] = rawSubs.compactMap { tryDecodeProvider($0) }
            sysSelectOptions = providers.map { sub in
                SysSelectOption(
                    providerId: sub._id,
                    providerType: sub.type,
                    label: sub.shortName ?? sub.service,
                    fields: normalizeProviderFields(provider: sub)
                )
            }
        }

        // File / liveness fields need their parent provider's kycType so the
        // upload mutation knows which slot to target.
        let kycType: String? = (kind == .file || kind == .liveness) ? provider.type : nil

        return WidgetField(
            id: raw._id,
            name: raw.name,
            label: formatLabel(raw.title.isEmpty ? raw.name : raw.title),
            kind: kind,
            required: raw.required ?? false,
            options: options,
            kycType: kycType,
            sysSelectOptions: sysSelectOptions,
            alreadySupplied: raw.alreadySupplied
        )
    }

    private static func tryDecodeProvider(_ value: AnyCodable) -> RawProvider? {
        guard let obj = value.dictValue else { return nil }
        var asAny: [String: Any] = [:]
        for (k, v) in obj { asAny[k] = v.rawValue }
        guard JSONSerialization.isValidJSONObject(asAny),
              let data = try? JSONSerialization.data(withJSONObject: asAny) else { return nil }
        return try? JSONDecoder().decode(RawProvider.self, from: data)
    }

    // MARK: - Provider fields (with consent / package synthesis)

    static func normalizeProviderFields(provider: RawProvider) -> [WidgetField] {
        let fields = provider.fields.map { normalizeField($0, provider: provider) }

        // Empty-fields synthesis — providers that ship zero fields but the
        // widget is meant to render a packaged flow (NIN consent, DL consent,
        // passport consent, CAC business package). Mirrors the web exactly.
        if fields.isEmpty {
            switch provider.type {
            case "nin_consent":
                return [WidgetField(
                    id: "\(provider._id):nin_consent",
                    name: "nin_consent",
                    label: "NIN Verification",
                    kind: .ninConsent,
                    required: true
                )]
            case "drivers_license_consent":
                return [WidgetField(
                    id: "\(provider._id):drivers_license_consent",
                    name: "drivers_license_consent",
                    label: "Driver's License Verification",
                    kind: .driversLicenseConsent,
                    required: true
                )]
            case "passport_consent":
                return [WidgetField(
                    id: "\(provider._id):passport_consent",
                    name: "passport_consent",
                    label: "International Passport Verification",
                    kind: .passportConsent,
                    required: true
                )]
            case "cac_business_package":
                return [WidgetField(
                    id: "\(provider._id):cac_business_package",
                    name: "cac_business_package",
                    label: "CAC Business Verification",
                    kind: .cacBusinessLookup,
                    required: true
                )]
            default: break
            }
        }

        return reorderLocationFields(fields)
    }

    // MARK: - Location reordering

    /// Within each "location group" (fields sharing a prefix like
    /// `head_office_`), reorder location-kind fields into the canonical
    /// sequence country → state → lga so the user is asked the parent
    /// before its child dropdown.
    static func reorderLocationFields(_ fields: [WidgetField]) -> [WidgetField] {
        let locationIndices = fields.enumerated()
            .filter { tierRank($0.element.name) < 99 }
            .map { $0.offset }
        guard locationIndices.count >= 2 else { return fields }

        var result = fields

        // Group by prefix.
        var groups: [String: [Int]] = [:]
        for i in locationIndices {
            let prefix = locationPrefix(result[i].name)
            groups[prefix, default: []].append(i)
        }
        for (_, slots) in groups where slots.count >= 2 {
            let slotsAsc = slots.sorted()
            let tiered = slotsAsc.map { result[$0] }.sorted { tierRank($0.name) < tierRank($1.name) }
            for (idx, slot) in slotsAsc.enumerated() { result[slot] = tiered[idx] }
        }
        return result
    }

    private static func tierRank(_ name: String) -> Int {
        let n = name.lowercased()
        if n.contains("country") { return 0 }
        if n.contains("state") || n.contains("region") || n.contains("province") { return 1 }
        if n.contains("lga") || n.contains("city") { return 2 }
        return 99
    }

    static func locationPrefix(_ name: String) -> String {
        var s = name.lowercased()
        s = s.replacingOccurrences(of: "_*region[_a-z]*$", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "_*state[_a-z]*$", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "_*province[_a-z]*$", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "_*country[_a-z]*$", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "_*lga[_a-z]*$", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "_*city[_a-z]*$", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "_+$", with: "", options: .regularExpression)
        return s
    }

    // MARK: - Label formatter

    /// camelCase / snake_case / kebab-case → "Title Case", preserving
    /// already-formatted phrases verbatim.
    static func formatLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        // Already-formatted: contains whitespace.
        if trimmed.rangeOfCharacter(from: .whitespaces) != nil { return trimmed }

        // camelCase split: lowercase letter followed by uppercase.
        var s = trimmed.replacingOccurrences(
            of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression
        )
        // snake_case / kebab-case separators.
        s = s.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
        // Capitalise the first letter of every space-delimited word; keep
        // the rest of the word so ALL-CAPS runs (BVN, TIN, URL) survive.
        s = s.replacingOccurrences(
            of: "(^|\\s)([a-z])",
            with: "$1$2",
            options: .regularExpression
        )
        // Manually uppercase first letters because regex back-ref isn't
        // available for `\U` style transforms in NSRegular.
        let words = s.split(separator: " ", omittingEmptySubsequences: true).map { word -> String in
            guard let first = word.first else { return String(word) }
            return first.uppercased() + word.dropFirst()
        }
        return words.joined(separator: " ")
    }

    // MARK: - Submitted-values pre-fill

    static func extractSubmittedValues(
        provider: RawProvider,
        fields: [WidgetField]
    ) -> [String: AnyCodable] {
        guard let kycPayload = provider.data?.kycPayload, !kycPayload.isEmpty else { return [:] }
        let byName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })
        var out: [String: AnyCodable] = [:]
        for entry in kycPayload {
            guard let field = byName[entry.field] else { continue }
            // Skip file/liveness — stored S3 key doesn't restore cleanly,
            // safer to make the user re-pick.
            if entry.type == "file" || field.kind == .file || field.kind == .liveness {
                continue
            }
            // Skip location — values are server-keyed by ObjectId, can't
            // round-trip without the populated dropdown.
            if field.kind == .location { continue }
            out[field.id] = entry.value ?? .null
        }
        return out
    }
}
