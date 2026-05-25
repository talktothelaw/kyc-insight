import XCTest
@testable import KYCWidget

/// 1:1 parity tests against the web widget's `normalize.ts`. If the web
/// widget produces `kind: 'email'` for a given backend field, this iOS
/// normaliser must produce `.email` for the same field — anything else
/// is a regression in the port.
final class SchemaNormalizerTests: XCTestCase {

    // MARK: - Status mapping (matches web normalizeStatus)

    func test_statusMapping() {
        XCTAssertEqual(SchemaNormalizer.normalizeStatus("approved"), .approved)
        XCTAssertEqual(SchemaNormalizer.normalizeStatus("pending"),  .pending)
        XCTAssertEqual(SchemaNormalizer.normalizeStatus("rejected"), .rejected)
        XCTAssertEqual(SchemaNormalizer.normalizeStatus("failed"),   .rejected)
        XCTAssertEqual(SchemaNormalizer.normalizeStatus(nil),        .initialized)
        XCTAssertEqual(SchemaNormalizer.normalizeStatus("nothing"),  .initialized)
    }

    // MARK: - Field kind resolution

    private func mkField(name: String = "x", title: String = "X", inputType: String,
                         options: [AnyCodable]? = nil, required: Bool? = nil) -> RawField {
        RawField(_id: "f1", name: name, title: title, inputType: inputType,
                 options: options, required: required, alreadySupplied: nil)
    }

    private func mkProvider(type: String = "p_default", fields: [RawField] = []) -> RawProvider {
        RawProvider(_id: "p1", service: "Service", type: type, shortName: nil,
                    status: nil, fields: fields, data: nil)
    }

    func test_fieldKind_explicitInputTypes() {
        let p = mkProvider()
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "email"),    provider: p), .email)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "number"),   provider: p), .number)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "date"),     provider: p), .date)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "time"),     provider: p), .time)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "password"), provider: p), .password)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "url"),      provider: p), .url)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "radio"),    provider: p), .radio)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "checkbox"), provider: p), .checkbox)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "image"),    provider: p), .image)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "select"),   provider: p), .select)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "sysSelect"),provider: p), .sysSelect)
    }

    func test_fieldKind_fileVsLiveness() {
        let plain = mkProvider(type: "passport_upload")
        let liveness = mkProvider(type: "liveness_check")
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(name: "selfieImage", inputType: "file"), provider: plain),    .file)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(name: "selfieImage", inputType: "file"), provider: liveness), .liveness)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(name: "frontImage",  inputType: "file"), provider: liveness), .file)
    }

    func test_fieldKind_textInputHeuristics() {
        let p = mkProvider()
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(name: "bvn", inputType: "textInput"),       provider: p), .bvn)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(name: "dateOfBirth", inputType: "textInput"),provider: p), .date)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(name: "country", inputType: "textInput"),    provider: p), .location)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(name: "state", inputType: "textInput"),      provider: p), .location)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(name: "lga", inputType: "textInput"),        provider: p), .location)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(name: "email", inputType: "textInput"),      provider: p), .email)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(name: "firstName", inputType: "textInput"),  provider: p), .text)
    }

    func test_fieldKind_consentStepTokens() {
        let p = mkProvider()
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "__nin_consent_step__"),             provider: p), .ninConsent)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "__drivers_license_consent_step__"), provider: p), .driversLicenseConsent)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "__passport_consent_step__"),        provider: p), .passportConsent)
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "__cac_business_package_step__"),    provider: p), .cacBusinessLookup)
    }

    func test_fieldKind_unknown() {
        XCTAssertEqual(SchemaNormalizer.resolveFieldKind(mkField(inputType: "alien"), provider: mkProvider()), .unknown)
    }

    // MARK: - Provider field synthesis (consent providers with zero fields)

    func test_emptyProvider_synthesizesConsentFields() {
        for (type, expectedKind, expectedNameSuffix) in [
            ("nin_consent",              FieldKind.ninConsent,            "nin_consent"),
            ("drivers_license_consent",  FieldKind.driversLicenseConsent, "drivers_license_consent"),
            ("passport_consent",         FieldKind.passportConsent,       "passport_consent"),
            ("cac_business_package",     FieldKind.cacBusinessLookup,     "cac_business_package"),
        ] {
            let provider = mkProvider(type: type, fields: [])
            let fields = SchemaNormalizer.normalizeProviderFields(provider: provider)
            XCTAssertEqual(fields.count, 1, "\(type) should synthesise a single field")
            XCTAssertEqual(fields.first?.kind, expectedKind)
            XCTAssertEqual(fields.first?.required, true)
            XCTAssertEqual(fields.first?.name, expectedNameSuffix)
        }
    }

    // MARK: - Label formatter (matches web formatLabel)

    func test_formatLabel() {
        XCTAssertEqual(SchemaNormalizer.formatLabel("corporateTin"), "Corporate Tin")
        XCTAssertEqual(SchemaNormalizer.formatLabel("first_name"),   "First Name")
        XCTAssertEqual(SchemaNormalizer.formatLabel("head-office-region"), "Head Office Region")
        XCTAssertEqual(SchemaNormalizer.formatLabel("Head Office Region | State"), "Head Office Region | State")
        XCTAssertEqual(SchemaNormalizer.formatLabel("BVN Number"),   "BVN Number")
        XCTAssertEqual(SchemaNormalizer.formatLabel(""), "")
    }

    // MARK: - Location reordering

    func test_locationReorder_groupsByPrefix() {
        let order = ["head_office_state", "head_office_country", "head_office_lga", "telephone"]
        let fields = order.map { name in
            WidgetField(id: name, name: name, label: name, kind: .location, required: false)
        }
        // Replace `telephone` with a non-location field
        var raw = fields
        raw[3] = WidgetField(id: "telephone", name: "telephone", label: "tel", kind: .text, required: false)
        let result = SchemaNormalizer.reorderLocationFields(raw)
        XCTAssertEqual(result.map(\.name), ["head_office_country", "head_office_state", "head_office_lga", "telephone"])
    }

    // MARK: - End-to-end normalisation

    func test_normalizeSchema_endToEnd() throws {
        // A minimal real-shaped raw response.
        let rawJSON = """
        {
          "processToken": "tok",
          "merchantId": "m1",
          "levels": [
            {
              "levelName": "tier_one",
              "levelSlug": "tier_1",
              "status": "initialized",
              "providersInfo": [
                {
                  "_id": "p1",
                  "service": "company_profile",
                  "type": "company_info",
                  "fields": [
                    { "_id": "f1", "name": "companyName", "title": "Company Name", "inputType": "textInput", "required": true },
                    { "_id": "f2", "name": "country",     "title": "Country",      "inputType": "textInput" },
                    { "_id": "f3", "name": "state",       "title": "State",        "inputType": "textInput" }
                  ]
                }
              ]
            }
          ]
        }
        """
        let raw = try JSONDecoder().decode(RawCustomerSession.self, from: Data(rawJSON.utf8))
        let schema = SchemaNormalizer.normalize(raw)
        XCTAssertEqual(schema.processToken, "tok")
        XCTAssertEqual(schema.steps.count, 1)
        let step = schema.steps[0]
        XCTAssertEqual(step.name, "Tier One") // formatLabel applied
        XCTAssertEqual(step.slug, "tier_1")
        XCTAssertEqual(step.sections.count, 1)
        let section = step.sections[0]
        XCTAssertEqual(section.name, "Company Profile")
        XCTAssertEqual(section.providerType, "company_info")
        XCTAssertEqual(section.fields.count, 3)
        // country must come before state (location reorder)
        let names = section.fields.map(\.name)
        XCTAssertEqual(names, ["companyName", "country", "state"])
        XCTAssertEqual(section.fields[1].kind, .location)
        XCTAssertEqual(section.fields[2].kind, .location)
        XCTAssertEqual(section.fields[0].kind, .text)
        XCTAssertTrue(section.fields[0].required)
    }
}
