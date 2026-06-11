import XCTest
@testable import KYCWidget

/// Wire-payload regression tests for BuildSubmission. The sysSelect-wrapped
/// liveness case mirrors the production bug: the backend rejected the section
/// with "Missing required fields: liveliness_images. Error Code: 107" because
/// the nested liveness value was stringified whole instead of lowered into
/// the selfie + synthetic liveliness_images entries. Mirrors the Android
/// `BuildSubmissionTest`.
final class BuildSubmissionTests: XCTestCase {

    private func livenessField(id: String, name: String) -> WidgetField {
        WidgetField(id: id, name: name, label: "Liveness Check", kind: .liveness, required: true)
    }

    private func sysSelectField(id: String, name: String, options: [SysSelectOption]) -> WidgetField {
        WidgetField(id: id, name: name, label: name, kind: .sysSelect, required: true,
                    sysSelectOptions: options)
    }

    private func section(fields: [WidgetField]) -> WidgetSection {
        WidgetSection(id: "sec-1", name: "liveness check", status: .initialized,
                      providerId: "prov-1", providerType: "liveness check", fields: fields)
    }

    private func step(_ section: WidgetSection) -> WidgetStep {
        WidgetStep(id: "step-1", name: "Tier 2", slug: "tier-2", status: .initialized,
                   sections: [section])
    }

    private func livenessValue() -> AnyCodable {
        .object([
            "selfieImage": .string("data:image/jpeg;base64,SELFIE"),
            "livelinessImages": .array([
                .string("data:image/jpeg;base64,F1"),
                .string("data:image/jpeg;base64,F2"),
            ]),
        ])
    }

    func test_topLevelLiveness_emitsSelfieAndLivelinessImages() {
        let field = livenessField(id: "f1", name: "selfieImage")
        let sec = section(fields: [field])
        let built = BuildSubmission.build(
            processToken: "tok", step: step(sec), section: sec,
            values: ["f1": livenessValue()]
        )
        let byName = Dictionary(uniqueKeysWithValues: built.kycPayload.map { ($0.field, $0.value) })
        XCTAssertEqual(byName["selfieImage"], "data:image/jpeg;base64,SELFIE")
        XCTAssertNotNil(byName["liveliness_images"], "expected synthetic liveliness_images entry")
    }

    func test_sysSelectWrappedLiveness_emitsSelfieAndLivelinessImagesWithLeafOptionalType() throws {
        let livenessOpt = SysSelectOption(
            providerId: "p_liveness", providerType: "liveness_check",
            label: "Liveness Check",
            fields: [livenessField(id: "sub-1", name: "selfieImage")]
        )
        let wrapper = sysSelectField(id: "f1", name: "liveness_method", options: [livenessOpt])
        let sec = section(fields: [wrapper])
        // Composite as the session mirrors it: liveness dict under the leaf name.
        let composite: AnyCodable = .object([
            "selectedType": .string("liveness_check"),
            "selectedProviderId": .string("p_liveness"),
            "values": .object(["selfieImage": livenessValue()]),
        ])
        let built = BuildSubmission.build(
            processToken: "tok", step: step(sec), section: sec,
            values: ["f1": composite]
        )
        XCTAssertEqual(built.optionalType, "liveness_check")
        let byName = Dictionary(uniqueKeysWithValues: built.kycPayload.map { ($0.field, $0.value) })
        XCTAssertEqual(byName["selfieImage"], "data:image/jpeg;base64,SELFIE")
        let json = try XCTUnwrap(byName["liveliness_images"],
                                 "expected synthetic liveliness_images entry (Error 107 regression)")
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String])
        XCTAssertEqual(decoded, ["data:image/jpeg;base64,F1", "data:image/jpeg;base64,F2"])
    }
}
