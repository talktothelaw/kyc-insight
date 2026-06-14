#if canImport(SwiftUI) && canImport(UIKit) && canImport(AVFoundation)
import SwiftUI
import UIKit
import AVFoundation

/// Native LivenessField — full V2 active-vision flow on iOS, 1:1 with
/// `kyc-web-wiget-v2/src/components/fields/LivenessField.tsx`.
///
/// Idle → user taps "Start camera" → `LivenessAPI.createSession` issues a
/// server-randomised `challengeSequence` → presents `LivenessCaptureSheetV2`
/// which drives the active-vision state machine → on completion,
/// `LivenessAPI.submitEvidence` returns the verdict (`passed` /
/// `requires_manual_review` / `failed`) → the field renders verdict-aware
/// done copy AND the host's `onLivenessSubmitted` callback fires.
///
/// Captured value shape (mirrors web `LivenessValue`):
///   ```
///   { selfieImage: base64-jpeg,
///     livelinessImages: [base64-jpeg],
///     livenessSessionId: String? }
///   ```
@available(iOS 15.0, *)
struct LivenessFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession

    private enum Shell: Equatable {
        case idle
        case preparing      // creating session + asking camera
        case running        // capture sheet showing
        case submitting     // POST evidence in flight
        case done(Verdict?) // verdict nil when evidence submission failed but
                            // the inline value was committed anyway (non-blocking)
        case error(String)
    }

    private struct Verdict: Equatable {
        let status: String          // 'passed' | 'failed' | 'requires_manual_review' | …
        let riskScore: Double?
        let failureReason: String?
    }

    @State private var shell: Shell = .idle
    @State private var session_: LivenessSessionDTO?
    @State private var capturedPreview: UIImage?
    @State private var retrySecondsRemaining: Int? = nil
    /// Non-blocking warning surfaced in the done card when evidence submission
    /// failed but we committed the inline value anyway (web's `shellError`
    /// note inside the done state). Lets the legacy submission path keep the
    /// user moving instead of hard-blocking on a network / rate-limit error.
    @State private var submitNote: String? = nil

    var body: some View {
        FieldShell(
            label: field.label,
            required: field.required,
            helper: nil,
            error: session.fieldErrors[field.id]
        ) {
            switch shell {
            case .idle:
                idleCard
            case .preparing:
                statusCard(
                    icon: "arrow.triangle.2.circlepath",
                    iconTint: .secondary,
                    title: "Preparing liveness session…",
                    body: "Setting up the camera and challenge sequence. This only takes a second."
                )
            case .running:
                statusCard(
                    icon: "video.fill",
                    iconTint: .accentColor,
                    title: "Verification in progress",
                    body: "Follow the on-screen prompts."
                )
            case .submitting:
                statusCard(
                    icon: "arrow.triangle.2.circlepath",
                    iconTint: .secondary,
                    title: "Submitting evidence…",
                    body: "Hold tight while we verify the captured frames."
                )
            case .done(let v):
                doneCard(v)
            case .error(let msg):
                errorCard(msg)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { shell == .running },
            set: { open in if !open && shell == .running { shell = .idle } }
        )) {
            if let seq = session_?.challengeSequence {
                LivenessCaptureSheetV2(
                    challengeSequence: seq,
                    onComplete: { frames, selfie, progress in
                        capturedPreview = selfie
                        Task { await submit(frames: frames, selfie: selfie, progress: progress) }
                    },
                    onCancel: { shell = .idle }
                )
            }
        }
    }

    // ── action handlers ────────────────────────────────────────────────

    private func startFlow() {
        shell = .preparing
        Task {
            do {
                let api = session.makeLivenessAPI()
                // face_match_nin: NINAuth requires EXACTLY 4 frames; inperson_nin:
                // selfie-only (0) when the business config allows it.
                let challengesPerSession: Int?
                switch field.kycType {
                case "face_match_nin": challengesPerSession = 4
                case "inperson_score": challengesPerSession = 4
                case "inperson_nin": challengesPerSession = 0
                default: challengesPerSession = nil
                }
                let input = LivenessAPI.CreateInput(
                    userRef: session.config.userRef,
                    levelSlug: session.config.levelSlug,
                    deviceMeta: LivenessDeviceMetaInput(
                        userAgent: "KYCWidget-iOS",
                        platform: UIDevice.current.systemName + " " + UIDevice.current.systemVersion,
                        cameraLabel: "front"
                    ),
                    challengesPerSession: challengesPerSession
                )
                let dto = try await api.createSession(input)
                await MainActor.run {
                    session_ = dto
                    shell = .running
                }
            } catch let err as GraphQLClientError {
                await MainActor.run { handleCreateError(err) }
            } catch {
                await MainActor.run { shell = .error(error.localizedDescription) }
            }
        }
    }

    private func handleCreateError(_ err: GraphQLClientError) {
        switch err {
        case .server(let message, _):
            // Surface the rate-limit countdown as a separate retry timer
            // when the server replies with "Try again in Ns".
            if let seconds = parseRetrySeconds(message) {
                startRetryCountdown(initial: seconds)
                shell = .error(message)
                return
            }
            shell = .error(message)
        default:
            shell = .error(err.errorDescription ?? "Liveness session could not be started.")
        }
    }

    private func submit(frames: [UIImage], selfie: UIImage, progress: [LivenessChallengeProgress]) async {
        guard let dto = session_ else { return }
        await MainActor.run {
            shell = .submitting
            submitNote = nil
        }
        let selfieB64 = selfie.jpegData(compressionQuality: 0.92)?.base64EncodedString() ?? ""
        let frameB64 = frames.compactMap { $0.jpegData(compressionQuality: 0.85)?.base64EncodedString() }
        let selfieDataURL = "data:image/jpeg;base64,\(selfieB64)"
        let frameDataURLs = frameB64.map { "data:image/jpeg;base64,\($0)" }
        let isoFmt = ISO8601DateFormatter()
        let completed: [LivenessCompletedChallengeInput] = progress.map {
            LivenessCompletedChallengeInput(
                code: $0.code,
                completedAt: isoFmt.string(from: $0.completedAt),
                clientPassed: $0.clientPassed,
                durationMs: $0.durationMs
            )
        }

        // Non-blocking submission — exactly like web `LivenessField.handleComplete`.
        // If `submitEvidence` throws (network / rate-limit), we DO NOT block the
        // user: we surface a warning note and still commit the inline value so
        // the legacy section-submit path keeps them moving. Only on success do
        // we capture the verdict + fire `onLivenessSubmitted` with the server's
        // session token.
        var verdict: Verdict?
        var sessionId: String?
        do {
            let api = session.makeLivenessAPI()
            let result = try await api.submitEvidence(LivenessAPI.SubmitInput(
                sessionToken: dto.sessionToken,
                selfieImage: selfieDataURL,
                livelinessImages: frameDataURLs,
                completedChallenges: completed
            ))
            verdict = Verdict(
                status: result.status,
                riskScore: result.riskScore,
                failureReason: result.failureReason
            )
            sessionId = result.sessionToken
            await MainActor.run {
                session.dispatchLivenessSubmitted(
                    sessionToken: result.sessionToken,
                    status: result.status,
                    riskScore: result.riskScore,
                    failureReason: result.failureReason
                )
            }
        } catch {
            // Non-blocking: surface the warning but still commit the inline
            // value so the legacy submission path keeps the user moving.
            await MainActor.run {
                submitNote = "Liveness session submission failed: \(error.localizedDescription). Continuing with inline submission."
            }
        }

        // Snapshot into immutable copies for the final main-actor hop.
        let finalVerdict = verdict
        let finalSessionId = sessionId
        await MainActor.run {
            // Commit the value into the widget so section submit picks it up —
            // committed in BOTH the success and failure paths (web parity).
            var value: [String: AnyCodable] = [
                "selfieImage":      .string(selfieDataURL),
                "livelinessImages": .array(frameDataURLs.map { .string($0) }),
            ]
            if let finalSessionId { value["livenessSessionId"] = .string(finalSessionId) }
            session.setValue(.object(value), for: field.id)
            shell = .done(finalVerdict)
        }
    }

    private func retake() {
        session_ = nil
        capturedPreview = nil
        shell = .idle
        retrySecondsRemaining = nil
        submitNote = nil
    }

    // ── retry countdown ────────────────────────────────────────────────

    private func parseRetrySeconds(_ msg: String) -> Int? {
        // "Too many liveness sessions. Try again in 2956s."
        let pattern = #"Try again in\s+(\d+)\s*s"#
        guard let range = msg.range(of: pattern, options: .regularExpression) else { return nil }
        let digits = msg[range].filter { $0.isNumber }
        return Int(digits)
    }

    private func startRetryCountdown(initial: Int) {
        retrySecondsRemaining = initial
        Task { @MainActor in
            while let r = retrySecondsRemaining, r > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if retrySecondsRemaining == nil { return }
                retrySecondsRemaining = (retrySecondsRemaining ?? 0) - 1
            }
        }
    }

    private func formatCountdown(_ totalSeconds: Int) -> String {
        let s = max(0, totalSeconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return "\(sec)s"
    }

    // ── card builders (mirror the web NinConsent intro pattern) ────────

    private var idleCard: some View {
        introCard(
            icon: "video.fill",
            iconTint: .accentColor,
            title: "Liveness verification",
            body: "We'll guide you through a few quick face actions. Make sure your face is well-lit and visible to the camera.",
            cta: "Start camera",
            ctaStyle: .primary,
            action: startFlow
        )
    }

    @ViewBuilder
    private func doneCard(_ v: Verdict?) -> some View {
        // Verdict nil means we never got a backend response (submission failed
        // but the inline value was committed) — fall back to a neutral
        // "submitted" tone, exactly like web's `verdict?.status ?? 'submitted'`.
        let status = v?.status ?? "submitted"
        let isApproved = status == "passed"
        let isManualReview = status == "requires_manual_review"
        let isFailed = status == "failed" || status == "expired"
        let iconName: String = isApproved
            ? "checkmark.seal.fill"
            : isFailed
                ? "exclamationmark.triangle.fill"
                : "clock.fill"
        let iconTint: Color = isApproved ? .green : isFailed ? .red : .orange
        let title: String = isApproved
            ? "Identity verified"
            : isManualReview
                ? "Submitted for review"
                : isFailed
                    ? "Liveness check didn't pass"
                    : "Liveness submitted"
        let scoreSuffix: String = (isApproved && v?.riskScore != nil)
            ? " (score \(Int(v!.riskScore!.rounded()))/100)" : ""
        let body: String = isApproved
            ? "Your liveness check was approved automatically\(scoreSuffix)."
            : isManualReview
                ? "A reviewer will confirm your verification shortly. You don't need to do anything else."
                : isFailed
                    ? (v?.failureReason ?? "Please retake the check — make sure your face is well-lit and follow each prompt.")
                    : "Your selfie and challenge frames were captured."
        let showRetake = isFailed
        introCard(
            icon: iconName,
            iconTint: iconTint,
            title: title,
            body: body,
            thumb: capturedPreview,
            note: submitNote,
            cta: showRetake ? "Try again" : nil,
            ctaStyle: .primary,
            action: showRetake ? retake : nil
        )
    }

    @ViewBuilder
    private func errorCard(_ msg: String) -> some View {
        let isRateLimited = retrySecondsRemaining != nil && (retrySecondsRemaining ?? 0) > 0
        let texts = errorTexts(msg: msg, isRateLimited: isRateLimited)
        introCard(
            icon: "exclamationmark.triangle.fill",
            iconTint: .red,
            title: texts.title,
            body: texts.body,
            cta: "Try again",
            ctaStyle: .primary,
            ctaDisabled: isRateLimited,
            action: retake
        )
    }

    /// Splits the "Too many liveness sessions. Try again in 2956s." backend
    /// payload into a clean title (everything before the retry phrase) and
    /// a live, human-readable countdown body. Kept out of `errorCard` so the
    /// `@ViewBuilder` context above doesn't see a statement-level if/else,
    /// which it can't synthesise into a View.
    private func errorTexts(msg: String, isRateLimited: Bool) -> (title: String, body: String) {
        if isRateLimited, let r = retrySecondsRemaining {
            let cleaned = msg
                .replacingOccurrences(of: #"Try again in\s+\d+\s*s\.?"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
                .nonEmpty ?? "Too many liveness sessions."
            return (cleaned, "Try again in \(formatCountdown(r)).")
        }
        return (msg, "Please check your camera and lighting, then try again.")
    }

    // ── intro-card primitive ───────────────────────────────────────────
    // Matches `kyc-nin-intro` from the web widget: bordered card with
    // tinted icon chip + title/text block + right-aligned CTA.

    private enum CTAStyle { case primary, secondary }

    @ViewBuilder
    private func introCard(
        icon: String,
        iconTint: Color,
        title: String,
        body: String,
        thumb: UIImage? = nil,
        note: String? = nil,
        cta: String? = nil,
        ctaStyle: CTAStyle = .primary,
        ctaDisabled: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(iconTint)
                .frame(width: 32, height: 32)
                .background(iconTint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(body)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let thumb {
                    Image(uiImage: thumb)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 96).clipped().cornerRadius(8)
                        .padding(.top, 8)
                }
                // Non-blocking warning note (web's `kyc-liveness-intro-note`).
                if let note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            if let cta, let action {
                Button(action: action) {
                    Text(cta)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(ctaDisabled)
            }
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
    }

    @ViewBuilder
    private func statusCard(icon: String, iconTint: Color, title: String, body: String) -> some View {
        introCard(icon: icon, iconTint: iconTint, title: title, body: body)
    }

    private static func defaultStatusCard(title: String) -> some View {
        Text(title).font(.system(size: 13)).foregroundColor(.secondary)
    }
}

private extension String {
    /// Returns `nil` when the string is empty — used to gate fallback copy.
    var nonEmpty: String? { isEmpty ? nil : self }
}

#endif
