#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Switches on the normalised ``FieldKind`` enum and routes to the
/// matching native renderer. 1:1 with the web widget's
/// `registry/registerFields.tsx` registry.
@available(iOS 15.0, *)
struct FieldRenderer: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession

    var body: some View {
        switch field.kind {
        case .text:    TextFieldView(field: field, session: session, keyboard: .default)
        case .email:   TextFieldView(field: field, session: session, keyboard: .emailAddress)
        case .number:  TextFieldView(field: field, session: session, keyboard: .numberPad)
        case .url:     TextFieldView(field: field, session: session, keyboard: .URL)
        case .password: TextFieldView(field: field, session: session, keyboard: .default, secure: true)
        case .date, .datetime: DateFieldView(field: field, session: session)
        case .time:    TextFieldView(field: field, session: session, keyboard: .numbersAndPunctuation)

        case .select:   SelectFieldView(field: field, session: session)
        case .radio:    RadioFieldView(field: field, session: session)
        case .checkbox: CheckboxFieldView(field: field, session: session)

        case .file:     FileFieldView(field: field, session: session)
        case .image:    CameraFieldView(field: field, session: session, preferFrontCamera: false)
        case .liveness: LivenessFieldView(field: field, session: session)

        // NIN / DL / Passport use the V2 initConsent mutation with mode
        // branching (internal OTP vs external WKWebView) + polling. 1:1
        // with the web's NinConsentField.tsx.
        case .ninConsent, .driversLicenseConsent, .passportConsent:
            ConsentFieldView(field: field, session: session)
        // BVN uses RequestBVNVerificationFlow → NIBSS-hosted page in
        // WebConsentSheet → getBvnStatus polling. Mirrors the web's
        // BvnField.tsx (`services/bvnApi.ts:requestBvnVerificationFlow`).
        case .bvn:                BvnFieldView(field: field, session: session)
        case .cacBusinessLookup:  CacBusinessLookupFieldView(field: field, session: session)
        case .sysSelect:          SysSelectFieldView(field: field, session: session)
        case .location:           LocationFieldView(field: field, session: session)
        case .unknown:            PlaceholderFieldView(field: field, hint: "Unknown field kind from backend")
        }
    }
}

@available(iOS 15.0, *)
struct PlaceholderFieldView: View {
    let field: WidgetField
    let hint: String
    init(field: WidgetField, hint: String = "") {
        self.field = field
        self.hint = hint
    }
    var body: some View {
        FieldShell(label: field.label, required: field.required, helper: hint, error: nil) {
            FieldBox {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.adjustable")
                        .foregroundColor(.secondary)
                    Text("\(field.kind.rawValue) — native renderer pending")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
#endif
