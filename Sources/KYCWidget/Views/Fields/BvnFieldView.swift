#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Native BVN field. 1:1 port of
/// `kyc-web-wiget-v2/src/components/fields/BvnField.tsx`.
///
/// Flow:
///   1. User taps **"Start BVN Verification"** → call
///      `RequestBVNVerificationFlow` → open the returned NIBSS URL inside
///      `WebConsentSheet`.
///   2. The i-gree consent-received page broadcasts
///      `BVN_CONSENT_RECEIVED` over the `bvnConsent` script-message
///      handler (registered in `WebConsentSheet`). This event is the
///      **single source of truth** for closing the window and reacting
///      to the consent — it triggers the sheet dismiss AND a confirming
///      `getBvnStatus` call.
///   3. If the user manually dismisses the sheet (swipe or Cancel) the
///      bridge never fires, no status fetch happens, and the user must
///      tap **"Check status"** to recheck. No background polling, no
///      auto-fetch on bare dismiss — explicit user action only.
@available(iOS 15.0, *)
struct BvnFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession

    @State private var phase: Phase = .idle
    @State private var statusMessage: String?
    @State private var redirectURL: URL?
    @State private var showWebSheet = false

    enum Phase: Equatable {
        case idle, requesting, external, checking, completed, failed, error
    }

    var body: some View {
        FieldShell(
            label: field.label, required: field.required,
            helper: helperText,
            error: session.fieldErrors[field.id]
        ) {
            VStack(spacing: 12) {
                phaseView
                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(phase == .failed || phase == .error ? .red : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .sheet(isPresented: $showWebSheet) {
            if let url = redirectURL {
                // The i-gree consent-received page broadcasts
                // `BVN_CONSENT_RECEIVED` via the bridge — that event is
                // the SINGLE source of truth for "consent done, close
                // the window, fetch status." Manual Cancel and
                // swipe-to-dismiss intentionally do NOT auto-fetch;
                // the user must tap "Check status" if they want to
                // recheck after dismissing without completing.
                WebConsentSheet(
                    initialURL: url,
                    successURLPrefixes: [],
                    cancelURLPrefixes:  []
                ) { result in
                    showWebSheet = false
                    if case .success = result {
                        // Bridge fired → confirm with backend. We never
                        // trust the bridge payload for KYC data (contract
                        // §6); always re-fetch.
                        Task { await checkStatus() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch phase {
        case .idle:       idlePanel
        case .requesting: startingPanel
        case .external:   inProgressPanel
        case .checking:   checkingPanel
        case .completed:  completedPanel
        case .failed, .error: errorPanel
        }
    }

    private var helperText: String? {
        phase == .idle
            ? "Verify your BVN to continue. The verification opens in a separate window."
            : nil
    }

    // MARK: - Panels

    private var idlePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 18))
                    .foregroundColor(KYCBrand.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bank verification")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Verify your BVN to continue. The verification opens in a separate window.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            Button { Task { await start() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                    Text("Start BVN Verification")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(KYCBrand.primary)
                .cornerRadius(10)
            }
        }
    }

    private var startingPanel: some View {
        HStack(spacing: 10) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Starting BVN verification…")
                    .font(.system(size: 14, weight: .semibold))
                Text("Preparing your verification link.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
    }

    private var inProgressPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 18))
                    .foregroundColor(KYCBrand.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("BVN verification in progress")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Complete the verification in the window we just opened. We'll detect it automatically once it's done — or tap Check status below.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button { reopen() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.square")
                        Text("Reopen verification")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(KYCBrand.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(KYCBrand.primary.opacity(0.4), lineWidth: 1)
                    )
                }
                .disabled(redirectURL == nil)
                Button { Task { await checkStatus() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("Check status")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(KYCBrand.primary)
                    .cornerRadius(8)
                }
            }
            Button("Restart verification") { restart() }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private var checkingPanel: some View {
        HStack(spacing: 10) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Checking status…")
                    .font(.system(size: 14, weight: .semibold))
                Text("Asking the provider whether your verification has completed.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
    }

    private var completedPanel: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green).font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text("BVN verified")
                    .font(.system(size: 14, weight: .semibold))
                Text("Your bank verification has been confirmed.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
    }

    private var errorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red).font(.system(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text(phase == .failed ? "BVN verification failed" : "Could not start verification")
                        .font(.system(size: 14, weight: .semibold))
                    Text(statusMessage ?? "Please try again.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            Button("Try again") { restart() }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    // MARK: - Actions

    /// `kycType` to send. The web reads `ctx.kycType` which the SchemaRenderer
    /// wires to `section.meta.providerType` — the PARENT section's
    /// providerType, even when BVN is nested inside a sys_select. Backend
    /// uses this only to flag the bvnSession as `direct_bvn` /` sub_bvn`.
    private var bvnKycType: String {
        session.currentSection?.providerType ?? "bvn"
    }

    private func makeAPI() -> BvnAPI {
        BvnAPI(client: GraphQLClient(endpoint: session.config.gqlEndpoint, publicKey: session.config.publicKey))
    }

    private func start() async {
        phase = .requesting
        statusMessage = nil
        print("[KYC BvnField] start → kycType=\(bvnKycType)")
        do {
            // Tier pinning — the webhook's kyc_v2 row lands pinned to this
            // section's provider/level like every other submission.
            let flow = try await makeAPI().requestFlow(
                processToken: session.schema?.processToken ?? "",
                kycType: bvnKycType,
                providerId: session.currentSection?.providerId,
                levelSlug: session.currentStep?.slug
            )
            guard let s = flow.redirectUrl, let url = URL(string: s) else {
                print("[KYC BvnField] start FAILED — no redirectUrl. msg=\(flow.msg)")
                statusMessage = flow.msg.isEmpty
                    ? "Could not start BVN verification. Please try again."
                    : flow.msg
                phase = .error
                return
            }
            print("[KYC BvnField] start OK → redirectUrl=\(s) — opening sheet")
            redirectURL = url
            session.setValue(.string("initiated"), for: field.id)
            phase = .external
            showWebSheet = true
        } catch {
            print("[KYC BvnField] start THREW: \(error)")
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .error
        }
    }

    private func reopen() {
        if redirectURL != nil { showWebSheet = true }
    }

    private func restart() {
        redirectURL = nil
        statusMessage = nil
        session.setValue(.string(""), for: field.id)
        phase = .idle
    }

    /// Hit by the "Check status" button. Always queries `getBvnStatus`.
    /// On in_progress/not_started, leaves the user in the same in-progress
    /// panel with a friendly hint so they can try again.
    private func checkStatus() async {
        phase = .checking
        statusMessage = nil
        print("[KYC BvnField] checkStatus (manual)")
        do {
            let status = try await makeAPI().getStatus(
                processToken: session.schema?.processToken ?? "",
                kycType: bvnKycType
            )
            print("[KYC BvnField] checkStatus → state=\(status.state.rawValue) kycStatus=\(status.kycStatus ?? "-") msg=\(status.message ?? "-")")
            if status.state == .in_progress || status.state == .not_started {
                phase = .external
                statusMessage = "Not validated yet — finish the verification in the open window, then tap Check status again."
                return
            }
            apply(status)
        } catch {
            print("[KYC BvnField] checkStatus THREW: \(error)")
            phase = .external
            statusMessage = "Could not reach the provider. Please try again."
        }
    }

    /// Fired automatically when the sheet dismisses — either via the
    /// i-gree bridge (`BVN_CONSENT_RECEIVED`) or by the user tapping
    /// Cancel. Treats every dismiss as a free "Check status" because the
    /// bridge already told us consent is done, and a manual cancel often
    /// means the user finished anyway.
    private func apply(_ status: BvnStatus) {
        switch status.state {
        case .completed:
            phase = .completed
            statusMessage = nil
            session.setValue(.string("completed"), for: field.id)
        case .failed:
            phase = .failed
            statusMessage = status.message ?? "BVN verification failed."
            session.setValue(.string(""), for: field.id)
        case .expired:
            phase = .failed
            statusMessage = status.message ?? "Your BVN verification session expired. Please restart."
            session.setValue(.string(""), for: field.id)
        case .in_progress, .not_started:
            phase = .external
            statusMessage = status.message
        }
    }
}
#endif
