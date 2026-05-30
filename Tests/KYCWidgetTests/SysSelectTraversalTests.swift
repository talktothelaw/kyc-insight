import XCTest
@testable import KYCWidget

/// Regression guard for the nested-sysSelect bug class. A leaf provider
/// reachable through 2+ levels of sysSelect (e.g. select_legacy_policy_choice
/// → corporate_policy_holder → cac_business_package) was silently dropped by
/// the one-level lookups in SectionValidator, BuildSubmission, and the session
/// sub-value mirror.
///
/// Mirrors the backend's `kyc-backend/src/helpers/__tests__/providerLookup.test.ts`,
/// the web `buildSubmission.test.ts` "nested sysSelect" describes, and the
/// Android `SysSelectTraversalTest`.
final class SysSelectTraversalTests: XCTestCase {

    // MARK: - Factories

    private func textField(id: String, name: String, required: Bool = true) -> WidgetField {
        WidgetField(id: id, name: name, label: name, kind: .text, required: required)
    }

    private func sysSelectField(id: String, name: String, options: [SysSelectOption]) -> WidgetField {
        WidgetField(id: id, name: name, label: name, kind: .sysSelect, required: true,
                    sysSelectOptions: options)
    }

    private func opt(_ providerType: String, fields: [WidgetField]) -> SysSelectOption {
        SysSelectOption(providerId: "p_\(providerType)", providerType: providerType,
                        label: providerType, fields: fields)
    }

    // MARK: - findSysSelectOptionByType

    func test_findSysSelectOptionByType_matchesAtLevel1() {
        let target = opt("cac_business_package", fields: [textField(id: "c", name: "company_name")])
        let options = [opt("cac_profile", fields: []), target]
        let found = SysSelectTraversal.findSysSelectOptionByType(options, targetType: "cac_business_package")
        XCTAssertEqual(found?.providerType, "cac_business_package")
    }

    func test_findSysSelectOptionByType_recursesThroughNestedSysSelect() {
        let leaf = opt("cac_business_package", fields: [textField(id: "c", name: "company_name")])
        let wrapper = opt("corporate_policy_holder", fields: [
            sysSelectField(id: "inner", name: "cac_identity_mode", options: [leaf])
        ])
        let found = SysSelectTraversal.findSysSelectOptionByType([wrapper], targetType: "cac_business_package")
        XCTAssertEqual(found?.providerType, "cac_business_package")
    }

    func test_findSysSelectOptionByType_returnsNilWhenUnreachable() {
        let options = [opt("individual_policy_holder", fields: [
            sysSelectField(id: "inner", name: "nin_method", options: [opt("nin_consent", fields: [])])
        ])]
        XCTAssertNil(SysSelectTraversal.findSysSelectOptionByType(options, targetType: "cac_business_package"))
    }

    func test_findSysSelectOptionByType_outerWinsOnTie() {
        let outer = opt("shared", fields: [
            sysSelectField(id: "inner", name: "x", options: [opt("shared", fields: [])])
        ])
        let found = SysSelectTraversal.findSysSelectOptionByType([outer], targetType: "shared")
        // Outer match wins — providerId differs between outer and inner.
        XCTAssertEqual(found?.providerId, "p_shared")
        XCTAssertTrue(!(found?.fields.isEmpty ?? true))
    }

    func test_findSysSelectOptionByType_handlesNilAndEmpty() {
        XCTAssertNil(SysSelectTraversal.findSysSelectOptionByType(nil, targetType: "x"))
        XCTAssertNil(SysSelectTraversal.findSysSelectOptionByType([], targetType: "x"))
        XCTAssertNil(SysSelectTraversal.findSysSelectOptionByType([opt("a", fields: [])], targetType: ""))
    }

    // MARK: - resolveLeaf

    func test_resolveLeaf_returnsTopWhenNoNesting() {
        let composite: [String: AnyCodable] = [
            "selectedType": .string("nin_consent"),
            "values": .object(["x": .string("y")]),
        ]
        let (type, values) = SysSelectTraversal.resolveLeaf(composite)
        XCTAssertEqual(type, "nin_consent")
        XCTAssertEqual(values?["x"]?.stringValue, "y")
    }

    func test_resolveLeaf_walksDownToDeepestComposite() {
        let leaf: AnyCodable = .object([
            "selectedType": .string("cac_business_package"),
            "values": .object(["company_name": .string("Acme")]),
        ])
        let outer: [String: AnyCodable] = [
            "selectedType": .string("corporate_policy_holder"),
            "values": .object([
                "cac_identity_mode": leaf,
                "company_name": .string("Acme"),
            ]),
        ]
        let (type, values) = SysSelectTraversal.resolveLeaf(outer)
        XCTAssertEqual(type, "cac_business_package")
        XCTAssertEqual(values?["company_name"]?.stringValue, "Acme")
        // The wrapper's `company_name` sibling must not appear at the leaf.
        XCTAssertNil(values?["cac_identity_mode"])
    }

    func test_resolveLeaf_handlesNilAndMissing() {
        let (t1, v1) = SysSelectTraversal.resolveLeaf(nil)
        XCTAssertNil(t1); XCTAssertNil(v1)
        let (t2, v2) = SysSelectTraversal.resolveLeaf(["selectedType": .string("x")])
        XCTAssertEqual(t2, "x"); XCTAssertNil(v2)
    }

    // MARK: - flattenSysSelect

    func test_flattenSysSelect_emitsLeafTypeAndEntriesForOneLevel() {
        let composite: [String: AnyCodable] = [
            "selectedType": .string("cac_business_package"),
            "values": .object([
                "company_name": .string("Acme"),
                "rc_number": .string("RC123"),
            ]),
        ]
        let flat = SysSelectTraversal.flattenSysSelect(composite)
        XCTAssertEqual(flat.leafType, "cac_business_package")
        XCTAssertEqual(flat.entries.count, 2)
        XCTAssertTrue(flat.entries.contains(where: { $0.name == "company_name" && $0.value.stringValue == "Acme" }))
        XCTAssertTrue(flat.entries.contains(where: { $0.name == "rc_number" }))
        XCTAssertNil(flat.consentAcceptanceId)
    }

    func test_flattenSysSelect_usesLeafTypeWhenNested() {
        let leaf: AnyCodable = .object([
            "selectedType": .string("cac_business_package"),
            "values": .object(["company_name": .string("Acme")]),
        ])
        let outer: [String: AnyCodable] = [
            "selectedType": .string("corporate_policy_holder"),
            "values": .object(["cac_identity_mode": leaf]),
        ]
        let flat = SysSelectTraversal.flattenSysSelect(outer)
        XCTAssertEqual(flat.leafType, "cac_business_package")
    }

    func test_flattenSysSelect_emitsIntermediateAndLeafEntriesWithoutStringifiedComposites() {
        let leaf: AnyCodable = .object([
            "selectedType": .string("cac_business_package"),
            "values": .object(["leaf_field": .string("deep")]),
        ])
        let outer: [String: AnyCodable] = [
            "selectedType": .string("corporate_policy_holder"),
            "values": .object([
                "cac_identity_mode": leaf,
                "company_name": .string("Acme"),
            ]),
        ]
        let flat = SysSelectTraversal.flattenSysSelect(outer)
        let names = flat.entries.map { $0.name }
        XCTAssertTrue(names.contains("company_name"), "expected company_name, got \(names)")
        XCTAssertTrue(names.contains("leaf_field"), "expected leaf_field, got \(names)")
        XCTAssertFalse(names.contains("cac_identity_mode"), "did not expect nested composite as entry, got \(names)")
    }

    func test_flattenSysSelect_surfacesConsentAcceptanceIdFromNested() {
        let consent: AnyCodable = .object([
            "consentAcceptanceId": .string("cae-deep"),
            "consentReference": .string("ref-deep"),
        ])
        let leaf: AnyCodable = .object([
            "selectedType": .string("nin_consent"),
            "values": .object(["nin_consent": consent]),
        ])
        let outer: [String: AnyCodable] = [
            "selectedType": .string("individual_policy_holder"),
            "values": .object(["nin_method": leaf]),
        ]
        let flat = SysSelectTraversal.flattenSysSelect(outer)
        XCTAssertEqual(flat.consentAcceptanceId, "cae-deep")
        XCTAssertEqual(flat.consentReference, "ref-deep")
        XCTAssertEqual(flat.leafType, "nin_consent")
    }

    func test_flattenSysSelect_handlesNilAndEmpty() {
        let flat = SysSelectTraversal.flattenSysSelect(nil)
        XCTAssertNil(flat.leafType)
        XCTAssertTrue(flat.entries.isEmpty)
    }
}
