import XCTest
@testable import KYCWidget

/// Regression guard: validation must walk a nested sysSelect tree down to
/// the LEAF before checking required sub-fields. Previously the one-level
/// `options.first(where: ...)` returned nil for nested leaves and silently
/// skipped all required-field validation.
///
/// Companion to the Android SectionValidatorTest cases that cover the same
/// bug class.
final class SectionValidatorNestedSysSelectTests: XCTestCase {

    private func textField(id: String, name: String, label: String, required: Bool = true) -> WidgetField {
        WidgetField(id: id, name: name, label: label, kind: .text, required: required)
    }

    private func sysSelectField(id: String, name: String, label: String, options: [SysSelectOption]) -> WidgetField {
        WidgetField(id: id, name: name, label: label, kind: .sysSelect, required: true,
                    sysSelectOptions: options)
    }

    func test_nested_leaf_missing_required_field_returns_error() {
        let leaf = SysSelectOption(providerId: "p_cac", providerType: "cac_business_package",
                                   label: "CAC", fields: [
            textField(id: "f_company", name: "company_name", label: "Company Name")
        ])
        let outer = SysSelectOption(providerId: "p_corp", providerType: "corporate_policy_holder",
                                    label: "Corporate", fields: [
            sysSelectField(id: "f_inner", name: "cac_identity_mode", label: "Inner", options: [leaf])
        ])
        let field = sysSelectField(id: "f_outer", name: "policy_holder_type",
                                   label: "Policy Holder", options: [outer])
        // Outer selected corporate, inner selected cac_business_package, leaf values empty.
        let nested: AnyCodable = .object([
            "selectedType": .string("cac_business_package"),
            "values": .object([:]),
        ])
        let composite: AnyCodable = .object([
            "selectedType": .string("corporate_policy_holder"),
            "values": .object(["cac_identity_mode": nested]),
        ])
        XCTAssertEqual(SectionValidator.validate(field: field, value: composite),
                       "Company Name is required.")
    }

    func test_nested_leaf_filled_returns_nil() {
        let leaf = SysSelectOption(providerId: "p_cac", providerType: "cac_business_package",
                                   label: "CAC", fields: [
            textField(id: "f_company", name: "company_name", label: "Company Name")
        ])
        let outer = SysSelectOption(providerId: "p_corp", providerType: "corporate_policy_holder",
                                    label: "Corporate", fields: [
            sysSelectField(id: "f_inner", name: "cac_identity_mode", label: "Inner", options: [leaf])
        ])
        let field = sysSelectField(id: "f_outer", name: "policy_holder_type",
                                   label: "Policy Holder", options: [outer])
        let nested: AnyCodable = .object([
            "selectedType": .string("cac_business_package"),
            "values": .object(["company_name": .string("Acme Ltd")]),
        ])
        let composite: AnyCodable = .object([
            "selectedType": .string("corporate_policy_holder"),
            "values": .object(["cac_identity_mode": nested]),
        ])
        XCTAssertNil(SectionValidator.validate(field: field, value: composite))
    }
}
