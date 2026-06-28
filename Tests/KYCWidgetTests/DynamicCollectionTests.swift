import XCTest
@testable import KYCWidget

/// Dynamic Collection (repeatable group) — engine coverage mirroring the web
/// `normalize/buildSubmission/validate.test.ts` dynamicCollection describes and
/// the Android `DynamicCollectionTest`. Asserts the GLUE: backend inputType →
/// kind + meta, the single JSON-stringified wire entry, and min/max + per-row
/// required validation.
final class DynamicCollectionTests: XCTestCase {

    private func provider() -> RawProvider {
        RawProvider(_id: "p1", service: "Company", type: "kyc_custom", shortName: nil, status: nil, fields: [], data: nil)
    }

    // MARK: - normalize

    func test_normalize_resolvesKind_andThreadsChildren() {
        let raw = RawField(
            _id: "col-1", name: "directors", title: "Directors", inputType: "dynamicCollection",
            options: nil, required: true,
            itemFields: [
                RawField(_id: nil, name: "full_name", title: "Full Name", inputType: "textInput", options: nil, required: true, alreadySupplied: nil),
                RawField(_id: nil, name: "role", title: "Role", inputType: "select",
                         options: [.string("ceo"), .string("cfo")], required: false, alreadySupplied: nil),
            ],
            minRows: 1, maxRows: 5, allowReorder: false,
            alreadySupplied: nil
        )
        let f = SchemaNormalizer.normalizeField(raw, provider: provider())
        XCTAssertEqual(f.kind, .dynamicCollection)
        XCTAssertEqual(f.itemFields?.count, 2)
        XCTAssertEqual(f.itemFields?[0].kind, .text)
        XCTAssertEqual(f.itemFields?[0].name, "full_name")
        XCTAssertFalse(f.itemFields?[0].id.isEmpty ?? true)   // synthesised id
        XCTAssertEqual(f.itemFields?[1].kind, .select)
        XCTAssertEqual(f.itemFields?[1].options?.count, 2)
        XCTAssertEqual(f.minRows, 1)
        XCTAssertEqual(f.maxRows, 5)
        XCTAssertEqual(f.allowAdd, true)        // unset → default true
        XCTAssertEqual(f.allowReorder, false)   // explicitly disabled
    }

    // MARK: - buildSubmission

    private func collectionField() -> WidgetField {
        WidgetField(
            id: "col", name: "directors", label: "Directors", kind: .dynamicCollection, required: true,
            itemFields: [WidgetField(id: "c1", name: "full_name", label: "Full Name", kind: .text, required: true)]
        )
    }

    private func section(_ field: WidgetField) -> WidgetSection {
        WidgetSection(id: "sec", name: "co", status: .initialized, providerId: "prov", providerType: "kyc_custom", fields: [field])
    }
    private func step(_ section: WidgetSection) -> WidgetStep {
        WidgetStep(id: "s", name: "T1", slug: "tier-1", status: .initialized, sections: [section])
    }
    private func rows(_ names: [String]) -> AnyCodable {
        .array(names.enumerated().map { i, n in
            .object(["_rowId": .string("r\(i)"), "full_name": .string(n)])
        })
    }

    func test_buildSubmission_emitsOneJsonEntry() {
        let field = collectionField()
        let sec = section(field)
        let built = BuildSubmission.build(processToken: "tok", step: step(sec), section: sec, values: ["col": rows(["Ada", "Obi"])])
        let entry = built.kycPayload.first { $0.field == "directors" }
        XCTAssertNotNil(entry)
        XCTAssertEqual(built.kycPayload.filter { $0.field == "directors" }.count, 1)
        XCTAssertTrue(entry!.value.contains("Ada"))
        XCTAssertTrue(entry!.value.contains("Obi"))
    }

    func test_buildSubmission_dropsEmptyCollection() {
        let field = collectionField()
        let sec = section(field)
        let built = BuildSubmission.build(processToken: "tok", step: step(sec), section: sec, values: ["col": .array([])])
        XCTAssertNil(built.kycPayload.first { $0.field == "directors" })
    }

    // MARK: - validate

    private func colField(min: Int? = nil, max: Int? = nil, required: Bool = true) -> WidgetField {
        WidgetField(
            id: "col", name: "directors", label: "Directors", kind: .dynamicCollection, required: required,
            itemFields: [WidgetField(id: "c1", name: "full_name", label: "Full Name", kind: .text, required: true)],
            minRows: min, maxRows: max
        )
    }

    func test_validate_requiredEmpty_isError() {
        let err = SectionValidator.validate(field: colField(), value: .array([]))
        XCTAssertNotNil(err)
        XCTAssertTrue(err!.contains("Directors"))
    }
    func test_validate_optionalEmpty_isOk() {
        XCTAssertNil(SectionValidator.validate(field: colField(required: false), value: .array([])))
    }
    func test_validate_belowMin() {
        let err = SectionValidator.validate(field: colField(min: 2), value: rows(["Ada"]))
        XCTAssertTrue(err!.contains("at least 2"))
    }
    func test_validate_aboveMax() {
        let err = SectionValidator.validate(field: colField(max: 1), value: rows(["Ada", "Obi"]))
        XCTAssertTrue(err!.contains("no more than 1"))
    }
    func test_validate_rowMissingRequiredChild() {
        let r: AnyCodable = .array([.object(["_rowId": .string("r1"), "full_name": .string("")])])
        let err = SectionValidator.validate(field: colField(), value: r)
        XCTAssertTrue(err!.contains("Full Name"))
    }
    func test_validate_happyPath() {
        XCTAssertNil(SectionValidator.validate(field: colField(min: 1, max: 5), value: rows(["Ada", "Obi"])))
    }
}
