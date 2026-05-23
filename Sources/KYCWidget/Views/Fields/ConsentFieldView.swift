#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Native consent field for NIN / BVN-consent / DL / Passport. 1:1 port
/// of the state machine in `kyc-web-wiget-v2/src/components/fields/NinConsentField.tsx`.
///
/// Flow:
///   1. **idle**       — "Verify <kind>" button. Tap fires `initConsent`.
///   2. **initiating** — waiting for server.
///   3. Server returns `mode: internal | external`.
///      • **internal** → `nin_input` (or whatever identifier the field
///        config asks for) → `submitting` → `otp_input` → `verifying`.
///      • **external** → `external` (WKWebView opens widgetUrl).
///   4. After identifier/OTP succeeds, or external returns with reference,
///      enters `polling` and hits `getRequirementStatus` every 5s × 6.
///   5. Terminal states: `auto_completed` (✓), `awaiting_final_submission`
///      (✓ — Continue button finalises), `error` (Try again).
@available(iOS 15.0, *)
struct ConsentFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession

    @State private var phase: Phase = .idle
    @State private var errorMsg: String?
    @State private var consentAcceptanceId: String?
    @State private var consentSessionId: String = ""
    @State private var consentReference: String?

    /// External-mode WKWebView sheet.
    @State private var showExternal = false
    @State private var externalURL: URL?
    @State private var externalClientId: String = ""
    @State private var externalUserRef: String = ""
    @State private var externalScope: String = "basic"

    /// Internal-mode form state.
    @State private var identifierFields: [ConsentIdentifierField] = []
    @State private var identifierValues: [String: String] = [:]
    @State private var otpCode: String = ""
    @State private var phoneHint: String?
    @State private var resendMessage: String?
    @State private var resendCooldownEndsAt: Date?

    /// Polling state.
    @State private var pollAttempt: Int = 0
    private let pollMax = 6
    private let pollInterval: TimeInterval = 5

    enum Phase: Equatable {
        case idle
        case initiating
        case internalIdentifier      // collecting NIN / BVN / etc.
        case submitting
        case otpInput
        case verifying
        case external                // WKWebView open
        case polling
        case autoCompleted
        case awaitingFinalSubmission
        case error
    }

    private var consentType: ConsentType {
        switch field.kind {
        case .ninConsent:              return .nin_consent
        case .driversLicenseConsent:   return .drivers_license_consent
        case .passportConsent:         return .passport_consent
        case .bvn:                     return .bvn_consent
        default:                       return .nin_consent
        }
    }

    private var brandName: String {
        switch field.kind {
        case .ninConsent:            return "NIN"
        case .driversLicenseConsent: return "Driver's License"
        case .passportConsent:       return "International Passport"
        case .bvn:                   return "BVN"
        default:                     return "ID"
        }
    }

    var body: some View {
        FieldShell(
            label: field.label, required: field.required,
            helper: helperText,
            error: session.fieldErrors[field.id]
        ) {
            VStack(spacing: 10) {
                phaseView
                if let errorMsg {
                    Text(errorMsg)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .sheet(isPresented: $showExternal) {
            if let url = externalURL {
                // `widgetConfig.widgetUrl` is a JS bundle, NOT a renderable
                // page — exactly what the web injects as a <script> tag.
                // NinAuthWebSheet loads it in an HTML harness that builds
                // the NIN widget instance and bridges callbacks back via
                // webkit.messageHandlers.
                NinAuthWebSheet(
                    widgetUrl: url,
                    clientId:  externalClientId,
                    userRef:   externalUserRef,
                    scope:     externalScope
                ) { result in
                    showExternal = false
                    Task { await handleExternalResult(result) }
                }
            }
        }
    }

    // MARK: - Phase-driven UI

    @ViewBuilder
    private var phaseView: some View {
        switch phase {
        case .idle, .error:
            actionButton(title: phase == .error ? "Try again" : "Verify \(brandName)",
                         loading: false) {
                Task { await start() }
            }
        case .initiating:
            actionButton(title: "Starting…", loading: true) {}
                .disabled(true)
        case .internalIdentifier:
            internalIdentifierForm
        case .submitting:
            actionButton(title: "Sending OTP…", loading: true) {}
                .disabled(true)
        case .otpInput:
            otpForm
        case .verifying:
            actionButton(title: "Verifying…", loading: true) {}
                .disabled(true)
        case .external:
            actionButton(title: "Opening secure window…", loading: true) {}
                .disabled(true)
        case .polling:
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("Finalising verification…").foregroundColor(.white)
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(KYCBrand.primary).cornerRadius(10)
        case .autoCompleted, .awaitingFinalSubmission:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundColor(.white)
                Text(phase == .autoCompleted ? "Verified ✓" : "\(brandName) verified — continue to finalise")
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Color.green).cornerRadius(10)
        }
    }

    private var helperText: String? {
        switch phase {
        case .idle:
            return "We'll start your \(brandName) verification securely. Only a safe reference returns here — never your raw \(brandName)."
        case .internalIdentifier, .otpInput:
            return nil
        case .external:
            return "Complete the provider's secure window."
        default: return nil
        }
    }

    // MARK: - Action button

    private func actionButton(title: String, loading: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading { ProgressView().tint(.white) }
                Image(systemName: "checkmark.shield").foregroundColor(.white)
                Text(title).foregroundColor(.white)
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(KYCBrand.primary).cornerRadius(10)
        }
    }

    // MARK: - Internal identifier form (NIN / BVN input)

    private var internalIdentifierForm: some View {
        VStack(spacing: 10) {
            ForEach(identifierFields) { f in
                VStack(alignment: .leading, spacing: 4) {
                    Text(f.label).font(.system(size: 13, weight: .semibold))
                    FieldBox {
                        TextField(f.placeholder ?? f.label, text: Binding(
                            get: { identifierValues[f.key] ?? "" },
                            set: { identifierValues[f.key] = $0 }
                        ))
                        .keyboardType(f.inputType == "phone" ? .phonePad : .default)
                        .font(.system(size: 15, design: .monospaced))
                    }
                }
            }
            Button { Task { await submitIdentifier() } } label: {
                Text("Submit \(brandName)")
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.vertical, 12)
                    .background(KYCBrand.primary)
                    .cornerRadius(10)
            }
            .disabled(identifierFields.contains { ($0.required) && (identifierValues[$0.key]?.isEmpty ?? true) })
        }
    }

    private var otpForm: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("One-time code").font(.system(size: 13, weight: .semibold))
                if let phoneHint {
                    Text("Sent to \(phoneHint). Enter the 6-digit code below.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                FieldBox {
                    TextField("6-digit code", text: $otpCode)
                        .keyboardType(.numberPad)
                        .font(.system(size: 17, design: .monospaced))
                }
            }
            HStack(spacing: 10) {
                Button { Task { await verifyOtp() } } label: {
                    Text("Verify")
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(KYCBrand.primary)
                        .cornerRadius(10)
                }
                .disabled(otpCode.count < 4)
                Button { Task { await resendOtp() } } label: {
                    Text(resendCooldownLabel ?? "Resend")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(KYCBrand.primary)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .background(KYCBrand.primary.opacity(0.08))
                        .cornerRadius(10)
                }
                .disabled(resendCooldownLabel != nil)
            }
            if let resendMessage {
                Text(resendMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var resendCooldownLabel: String? {
        guard let endsAt = resendCooldownEndsAt else { return nil }
        let remaining = Int(endsAt.timeIntervalSinceNow)
        guard remaining > 0 else { return nil }
        let m = remaining / 60, s = remaining % 60
        return "Resend (\(m):\(String(format: "%02d", s)))"
    }

    // MARK: - API calls

    private var api: ConsentAPI {
        ConsentAPI(client: GraphQLClient(endpoint: session.config.gqlEndpoint, publicKey: session.config.publicKey))
    }

    private func start() async {
        phase = .initiating
        errorMsg = nil
        do {
            let res = try await api.initConsent(
                processToken: session.schema?.processToken ?? "",
                consentType: consentType,
                providerId: session.currentSection?.providerId,
                levelSlug: session.currentStep?.slug
            )
            guard res.success, let cid = res.consentAcceptanceId else {
                errorMsg = res.message ?? "Could not start \(brandName) verification."
                phase = .error
                return
            }
            consentAcceptanceId = cid
            consentSessionId = res.consentSessionId ?? ""
            if res.mode == "internal" {
                identifierFields = res.identifierFields ?? defaultIdentifierFields()
                identifierValues = [:]
                phase = .internalIdentifier
            } else if let cfg = res.widgetConfig, let url = URL(string: cfg.widgetUrl) {
                externalURL = url
                externalClientId = cfg.clientId
                externalUserRef  = cfg.userRef
                externalScope    = cfg.scope ?? "basic"
                phase = .external
                showExternal = true
            } else {
                errorMsg = "Provider configuration is incomplete."
                phase = .error
            }
        } catch {
            errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .error
        }
    }

    private func defaultIdentifierFields() -> [ConsentIdentifierField] {
        // Fallback shape when the backend forgot to declare identifierFields
        // for internal mode — keep the user moving instead of hard-stopping.
        let label = brandName
        return [ConsentIdentifierField(
            key: consentType == .bvn_consent ? "bvn" : "nin",
            label: label,
            inputType: "text",
            placeholder: "Enter your \(label)",
            required: true,
            pattern: nil
        )]
    }

    private func submitIdentifier() async {
        guard let cid = consentAcceptanceId else { return }
        phase = .submitting
        errorMsg = nil
        do {
            let res = try await api.submitConsentIdentifier(
                processToken: session.schema?.processToken ?? "",
                consentAcceptanceId: cid,
                sessionId: consentSessionId,
                identifier: identifierValues
            )
            if !res.success {
                errorMsg = res.message ?? "Could not submit \(brandName)."
                phase = .internalIdentifier
                return
            }
            phoneHint = res.phoneHint
            otpCode = ""
            resendMessage = nil
            startResendCooldown()
            phase = .otpInput
        } catch {
            errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .internalIdentifier
        }
    }

    private func verifyOtp() async {
        guard let cid = consentAcceptanceId else { return }
        phase = .verifying
        errorMsg = nil
        do {
            let res = try await api.verifyConsentIdentifierOtp(
                processToken: session.schema?.processToken ?? "",
                consentAcceptanceId: cid,
                sessionId: consentSessionId,
                otpCode: otpCode
            )
            if !res.success {
                errorMsg = res.message ?? "Invalid OTP. Please try again."
                phase = .otpInput
                return
            }
            // Store the safe reference and start polling for terminal state.
            session.setValue(.object([
                "verified":                .bool(true),
                "consentAcceptanceId":     .string(cid),
                "awaitingFinalSubmission": .bool(false),
                "autoCompleted":           .bool(false),
            ]), for: field.id)
            await poll()
        } catch {
            errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .otpInput
        }
    }

    private func resendOtp() async {
        guard let cid = consentAcceptanceId else { return }
        do {
            let res = try await api.resendConsentIdentifierOtp(
                processToken: session.schema?.processToken ?? "",
                consentAcceptanceId: cid,
                sessionId: consentSessionId
            )
            if res.success {
                resendMessage = "A new code has been sent."
                startResendCooldown()
            } else {
                resendMessage = res.message ?? "Could not resend code."
            }
        } catch {
            resendMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func startResendCooldown() {
        // 5-minute gate, matching the web's `useResendCooldown` hook.
        resendCooldownEndsAt = Date().addingTimeInterval(5 * 60)
    }

    private func handleExternalResult(_ result: Result<String, KYCWidgetError>) async {
        switch result {
        case .success(let ref):
            consentReference = ref
            guard let cid = consentAcceptanceId else {
                phase = .error
                errorMsg = "Lost consent context."
                return
            }
            session.setValue(.object([
                "verified":                .bool(true),
                "consentAcceptanceId":     .string(cid),
                "consentReference":        .string(ref),
                "awaitingFinalSubmission": .bool(false),
                "autoCompleted":           .bool(false),
            ]), for: field.id)
            await poll()
        case .failure(let err):
            errorMsg = err.localizedDescription
            phase = .error
        }
    }

    // MARK: - Polling

    private func poll() async {
        phase = .polling
        pollAttempt = 0
        while pollAttempt < pollMax {
            pollAttempt += 1
            do {
                let s = try await api.getRequirementStatus(
                    processToken: session.schema?.processToken ?? "",
                    providerId: session.currentSection?.providerId,
                    levelSlug: session.currentStep?.slug
                )
                switch s.requirementState.lowercased() {
                case "auto_completed":
                    phase = .autoCompleted
                    updateValueWith(autoCompleted: true, awaiting: false)
                    return
                case "awaiting_final_submission", "ready_for_finalization":
                    phase = .awaitingFinalSubmission
                    updateValueWith(autoCompleted: false, awaiting: true)
                    return
                case "failed", "rejected":
                    phase = .error
                    errorMsg = "Verification failed. Please try again."
                    return
                default:
                    break    // still in progress — sleep and retry
                }
            } catch {
                // Transient error — keep polling unless we've burned the budget.
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        // Out of attempts — gracefully drop into "awaiting" so the user
        // can still tap Continue and let the backend resolve server-side.
        phase = .awaitingFinalSubmission
        updateValueWith(autoCompleted: false, awaiting: true)
    }

    private func updateValueWith(autoCompleted: Bool, awaiting: Bool) {
        guard let cid = consentAcceptanceId else { return }
        var dict: [String: AnyCodable] = [
            "verified":                .bool(true),
            "consentAcceptanceId":     .string(cid),
            "awaitingFinalSubmission": .bool(awaiting),
            "autoCompleted":           .bool(autoCompleted),
        ]
        if let consentReference { dict["consentReference"] = .string(consentReference) }
        session.setValue(.object(dict), for: field.id)
    }
}
#endif
