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
        case .date:     DateFieldView(field: field, session: session, withTime: false)
        case .datetime: DateFieldView(field: field, session: session, withTime: true)
        case .time:     TimeFieldView(field: field, session: session)

        case .select:   SelectFieldView(field: field, session: session)
        case .radio:    RadioFieldView(field: field, session: session)
        case .checkbox: CheckboxFieldView(field: field, session: session)

        case .file:     FileFieldView(field: field, session: session)
        case .image:    CameraFieldView(field: field, session: session, preferFrontCamera: false)
        case .liveness: LivenessFieldView(field: field, session: session)

        // NIN / DL / Passport / CAC use the V2 initConsent mutation with
        // mode branching (internal OTP vs external WKWebView) + polling.
        // 1:1 with the web's NinConsentField.tsx / InternalConsentField.tsx.
        case .ninConsent, .driversLicenseConsent, .passportConsent, .cacConsent:
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

/// Fallback renderer for any FieldKind the iOS SDK doesn't natively
/// render yet. Critical for a fully dynamic system — merchants can ship
/// new custom providers at any time, and the SDK must surface that
/// gracefully (visible, clear, non-blocking) rather than silently
/// failing or showing a discrete icon the user may miss.
/// Mirrors the web's `FallbackField` in `components/fields/fallback.tsx`.
@available(iOS 15.0, *)
struct PlaceholderFieldView: View {
    let field: WidgetField
    let hint: String
    init(field: WidgetField, hint: String = "") {
        self.field = field
        self.hint = hint
    }
    var body: some View {
        FieldShell(label: field.label, required: field.required, helper: nil, error: nil) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Field type ‘\(field.kind.rawValue)’ is not supported in this app yet.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(hint.isEmpty
                            ? "Please update the app to complete this step, or use the web verification flow."
                            : hint)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            )
            .cornerRadius(8)
        }
    }
}
#endif
