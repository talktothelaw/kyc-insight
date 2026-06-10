import Foundation

/// Recursive helpers for walking the sysSelect option TREE. A
/// ``SysSelectOption``'s `fields` may include another sysSelect, whose options
/// can themselves carry nested sysSelect fields — real configs run 2–3 levels
/// deep (e.g. `kyc_marketplace` → `corporate_policy_holder` →
/// `cac_business_package`).
///
/// Every consumer that looks up an option by `providerType`, mirrors sub-field
/// values, or flattens a composite value for submission must route through
/// here — never via a flat `options.first(where:)` over a single level of
/// `sysSelectOptions` / `composite["values"]`.
///
/// Mirrors:
///   - `kyc-backend/src/helpers/providerLookup.ts`
///     (`findSysSelectOptionByType`, `hasMatchingSysSelectOption`,
///     `collectFieldsForOptionalType`, …)
///   - `kyc-web-wiget-v2/src/engine/processing/buildSubmission.ts`
///     (`flattenSysSelect`)
///   - `kyc-wiget-android/sdk/.../engine/SysSelectTraversal.kt` (companion)
///
/// The bug class fixed by these helpers: a leaf provider reachable only via
/// 2+ levels of sysSelect was silently dropped from submissions, skipped by
/// validation, and missed by the dedup pass — surfacing as
/// "Provider not configured: <leaf type>" on the backend.
enum SysSelectTraversal {

    /// Real configs stay shallow; cap to fence against cyclic data.
    private static let maxDepth = 6

    /// Depth-first search of `options` for the first ``SysSelectOption`` whose
    /// `providerType` equals `targetType`. Returns nil when no chain matches.
    /// Outer match wins on a tie — callers that need a deeper match should
    /// walk the result themselves.
    static func findSysSelectOptionByType(
        _ options: [SysSelectOption]?,
        targetType: String,
        depth: Int = 0
    ) -> SysSelectOption? {
        guard let options, depth <= maxDepth, !targetType.isEmpty else { return nil }
        for opt in options {
            if opt.providerType == targetType { return opt }
            for sub in opt.fields where sub.kind == .sysSelect {
                if let nested = findSysSelectOptionByType(sub.sysSelectOptions, targetType: targetType, depth: depth + 1) {
                    return nested
                }
            }
        }
        return nil
    }

    /// Walks a (possibly nested) sysSelect composite value to its LEAF (the
    /// deepest composite — its `values` doesn't itself wrap another sysSelect).
    /// Returns the leaf's `(selectedType, values)`. Returns the top composite
    /// unchanged when there is no nesting.
    ///
    /// Used by validation + auto-completion detection: when the user picks a
    /// leaf 2+ levels deep, those callers must reason about the LEAF, not the
    /// top-level wrapper selection.
    static func resolveLeaf(
        _ composite: [String: AnyCodable]?,
        depth: Int = 0
    ) -> (type: String?, values: [String: AnyCodable]?) {
        guard let composite, depth <= maxDepth else { return (nil, nil) }
        let thisType = composite["selectedType"]?.stringValue
        guard let thisValues = composite["values"]?.dictValue else { return (thisType, nil) }
        for (_, value) in thisValues {
            guard let nested = value.dictValue,
                  nested["selectedType"] != nil, nested["values"] != nil else { continue }
            return resolveLeaf(nested, depth: depth + 1)
        }
        return (thisType, thisValues)
    }

    /// Result of ``flattenSysSelect(_:)``.
    struct Flat {
        var leafType: String?
        var entries: [(name: String, value: AnyCodable)]
        var consentAcceptanceId: String?
        var consentReference: String?
        /// `kyc_v2._id` of a self-completing CAC verification reached via this
        /// sysSelect tree (mirrors web `flattenSysSelect.cacKycSubmissionId`).
        /// Lets BuildSubmission route a nested CAC to `finalizeCacRequirement`
        /// exactly like a top-level `cacBusinessLookup`.
        var cacKycSubmissionId: String?
    }

    /// Walks `composite` and flattens it into one record:
    ///   - `leafType`: deepest `selectedType` (= backend `optionalType`)
    ///   - `entries`: ordered `(name, value)` pairs collected from every
    ///     non-special value at every level. A nested sysSelect composite
    ///     is NEVER emitted as an entry — it's recursed into so its leaf
    ///     fields surface as siblings of intermediate-level fields.
    ///   - `consentAcceptanceId` / `consentReference`: surfaced from a
    ///     NIN / DL / passport consent value anywhere in the tree.
    ///
    /// Identical shape to the web's `flattenSysSelect` so all platforms emit
    /// the same `kycPayload` regardless of nesting depth.
    static func flattenSysSelect(_ composite: [String: AnyCodable]?, depth: Int = 0) -> Flat {
        guard let composite, depth <= maxDepth else {
            return Flat(leafType: nil, entries: [], consentAcceptanceId: nil, consentReference: nil, cacKycSubmissionId: nil)
        }
        var leafType: String? = composite["selectedType"]?.stringValue
        var entries: [(String, AnyCodable)] = []
        var cid: String?
        var cref: String?
        var cacId: String?
        let subValues = composite["values"]?.dictValue ?? [:]
        for (name, value) in subValues {
            // Nested sysSelect — detected by the (selectedType, values) pair.
            if let dict = value.dictValue,
               dict["selectedType"] != nil, dict["values"] != nil {
                let nested = flattenSysSelect(dict, depth: depth + 1)
                if let nt = nested.leafType { leafType = nt }
                entries.append(contentsOf: nested.entries)
                if let n = nested.consentAcceptanceId { cid = n }
                if let r = nested.consentReference { cref = r }
                if let k = nested.cacKycSubmissionId { cacId = k }
                continue
            }
            // Consent value (NIN / DL / passport) — surface its references.
            if let dict = value.dictValue,
               let inlineCid = dict["consentAcceptanceId"]?.stringValue {
                cid = inlineCid
                cref = dict["consentReference"]?.stringValue
                continue
            }
            // CAC business-lookup value (web `isCacBusinessLookupValue`) — a
            // self-completing verification; surface its held kyc_v2 id, emit no
            // entry (the row already exists server-side).
            if let dict = value.dictValue,
               dict["verified"]?.boolValue == true,
               let k = dict["kycSubmissionId"]?.stringValue {
                cacId = k
                continue
            }
            entries.append((name, value))
        }
        return Flat(leafType: leafType, entries: entries, consentAcceptanceId: cid, consentReference: cref, cacKycSubmissionId: cacId)
    }
}
