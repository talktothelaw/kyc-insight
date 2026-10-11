@testable import KYCWidget

extension WidgetField {
    static func makeLivenessForTests(required: Bool) -> WidgetField {
        WidgetField(id: "selfieImage", name: "selfieImage", label: "Liveness Check", kind: .liveness,
                    required: required, kycType: "liveness_check")
    }
}
