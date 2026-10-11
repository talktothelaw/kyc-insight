import XCTest
@testable import KYCWidget

final class LivenessWireTests: XCTestCase {
    func test_sendsSelfieFramesAndSession() {
        let value: AnyCodable = .object([
            "selfieImage": .string("s"),
            "livelinessImages": .array([.string("a")]),
            "livenessSessionId": .string("tok"),
        ])
        let entries = livenessWireEntries(name: "selfieImage", value: value)
        XCTAssertEqual(entries.map { $0.0 }, ["selfieImage", "liveliness_images", "livenessSessionId"])
        XCTAssertEqual(entries.map { $0.1 }, ["s", "[\"a\"]", "tok"])
    }

    func test_sendsOnlyTheSkipMarker() {
        let entries = livenessWireEntries(name: "selfieImage", value: .object(["skipped": .bool(true)]))
        XCTAssertEqual(entries.map { $0.0 }, ["liveness_skipped"])
        XCTAssertEqual(entries.map { $0.1 }, ["true"])
    }

    func test_sendsAnEmptySelfieWhenThereIsNoValue() {
        let entries = livenessWireEntries(name: "selfieImage", value: nil)
        XCTAssertEqual(entries.map { $0.0 }, ["selfieImage"])
        XCTAssertEqual(entries.map { $0.1 }, [""])
    }

    func test_skippedSatisfiesRequiredLiveness() {
        let field = WidgetField.makeLivenessForTests(required: true)
        XCTAssertNil(SectionValidator.validate(field: field, value: .object(["skipped": .bool(true)])))
    }

    func test_missingCaptureFailsRequiredLiveness() {
        let field = WidgetField.makeLivenessForTests(required: true)
        XCTAssertEqual(SectionValidator.validate(field: field, value: nil), "Please complete the photo capture.")
        XCTAssertEqual(SectionValidator.validate(field: field, value: .null), "Please complete the photo capture.")
    }
}
