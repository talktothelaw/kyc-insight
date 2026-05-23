#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Native BVN field. 1:1 port of
/// `kyc-web-wiget-v2/src/components/fields/BvnField.tsx`.
///
/// The user never types their BVN inline — they hit "Start BVN
/// Verification", we call `RequestBVNVerificationFlow`, open the returned
/// NIBSS URL in `WebConsentSheet`, and poll `getBvnStatus` every 10s for
/// up to 30 minutes (matching the web's `POLL_INTERVAL_MS` /
/// `POLL_TIMEOUT_MS`).
///
/// Phases mirror the web's exactly:
///   idle → requesting → external → polling → (completed | failed |
///   pollingExhausted) — and a discrete `error` phase for init failures.
@available(iOS 15.0, *)
struct BvnFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession

    @State private var phase: Phase = .idle
    @State private var statusMessage: String?
    @State private var redirectURL: URL?
    @State private var showWebSheet = false
    @State private var pollTask: Task<Void, Never>?
    @State private var startedAt: Date?

    private let pollInterval: TimeInterval = 10
    private let pollTimeout: TimeInterval = 30 * 60

    enum Phase: Equatable {
        case idle, requesting, external, polling, pollingExhausted, completed, failed, error
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
                // NIBSS hosts the BVN entry page; it has no fixed
                // completion redirect we can intercept, so the user
                // dismisses the sheet manually. The background poll is
                // what actually detects completion.
                WebConsentSheet(
                    initialURL: url,
                    successURLPrefixes: [],
                    cancelURLPrefixes:  []
                ) { _ in
                    showWebSheet = false
                }
            }
        }
        .onDisappear { pollTask?.cancel() }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch phase {
        case .idle:               idlePanel
        case .requesting:         startingPanel
        case .external, .polling: inProgressPanel
        case .pollingExhausted:   exhaustedPanel
        case .completed:          completedPanel
        case .failed, .error:     errorPanel
        }
    }

    private var helperText: String? {
        phase == .idle
            ? "Verify your BVN to continue. The verification opens in a window — return here once it's done."
            : nil
    }

    // MARK: - Panels (mirror web layout)

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
                    Text("Complete the verification in the window we just opened. We'll detect it automatically — usually within a minute or two.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            Button { reopen() } label: {
                HStack {
                    Image(systemName: "arrow.up.forward.square")
                    Text("Reopen verification")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(KYCBrand.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(KYCBrand.primary.opacity(0.4), lineWidth: 1)
                )
            }
            .disabled(redirectURL == nil)
        }
    }

    private var exhaustedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Still waiting on the provider")
                .font(.system(size: 14, weight: .semibold))
            Text("We didn't get a result after 30 minutes of automatic checks. Try Recheck or Restart.")
                .font(.system(size: 12)).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Button("Reopen") { reopen() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(redirectURL == nil)
                Button("Recheck") { Task { await recheck() } }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("Restart") { restart() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
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

    /// `kycType` to send. The web's BvnField reads `ctx.kycType`, which the
    /// SchemaRenderer wires to `section.meta.providerType` — the PARENT
    /// section's providerType, even when BVN is nested inside a sys_select.
    /// Backend uses this only to flag the bvnSession as `direct_bvn` (when
    /// kycType==="bvn") or `sub_bvn` (anything else); see
    /// `kyc-backend/src/services/kyc/bvnService.ts:11`.
    private var bvnKycType: String {
        session.currentSection?.providerType ?? "bvn"
    }

    private func start() async {
        phase = .requesting
        statusMessage = nil
        let api = BvnAPI(client: GraphQLClient(endpoint: session.config.gqlEndpoint, publicKey: session.config.publicKey))
        do {
            let flow = try await api.requestFlow(
                processToken: session.schema?.processToken ?? "",
                kycType: bvnKycType
            )
            guard let s = flow.redirectUrl, let url = URL(string: s) else {
                statusMessage = flow.msg.isEmpty
                    ? "Could not start BVN verification. Please try again."
                    : flow.msg
                phase = .error
                return
            }
            redirectURL = url
            session.setValue(.string("initiated"), for: field.id)
            startedAt = Date()
            phase = .external
            showWebSheet = true
            startPolling()
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .error
        }
    }

    private func reopen() {
        if redirectURL != nil { showWebSheet = true }
    }

    private func restart() {
        pollTask?.cancel()
        pollTask = nil
        redirectURL = nil
        statusMessage = nil
        startedAt = nil
        session.setValue(.string(""), for: field.id)
        phase = .idle
    }

    private func startPolling() {
        pollTask?.cancel()
        phase = .polling
        let api = BvnAPI(client: GraphQLClient(endpoint: session.config.gqlEndpoint, publicKey: session.config.publicKey))
        let token = session.schema?.processToken ?? ""
        let kycType = bvnKycType
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                if let s = startedAt, Date().timeIntervalSince(s) > pollTimeout {
                    phase = .pollingExhausted
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                if Task.isCancelled { return }
                do {
                    let status = try await api.getStatus(processToken: token, kycType: kycType)
                    if Task.isCancelled { return }
                    if apply(status) { return }
                } catch {
                    // transient — keep polling
                }
            }
        }
    }

    @discardableResult
    private func apply(_ status: BvnStatus) -> Bool {
        switch status.state {
        case .completed:
            phase = .completed
            statusMessage = nil
            session.setValue(.string("completed"), for: field.id)
            return true
        case .failed:
            phase = .failed
            statusMessage = status.message ?? "BVN verification failed."
            session.setValue(.string(""), for: field.id)
            return true
        case .expired:
            phase = .pollingExhausted
            return true
        case .in_progress, .not_started:
            statusMessage = status.message
            return false
        }
    }

    private func recheck() async {
        let api = BvnAPI(client: GraphQLClient(endpoint: session.config.gqlEndpoint, publicKey: session.config.publicKey))
        do {
            let status = try await api.getStatus(
                processToken: session.schema?.processToken ?? "",
                kycType: bvnKycType
            )
            if status.state == .in_progress || status.state == .not_started {
                statusMessage = "Not validated yet — please complete the verification in the open window."
                return
            }
            apply(status)
        } catch {
            statusMessage = "Could not reach the provider. Please try again."
        }
    }
}
#endif
