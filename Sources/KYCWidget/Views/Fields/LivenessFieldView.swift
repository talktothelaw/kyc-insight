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
    @StateObject private var flow: LivenessFlow

    @State private var capturedPreview: UIImage?
    @State private var retrySecondsRemaining: Int? = nil

    init(field: WidgetField, session: KYCWidgetSession) {
        self.field = field
        self.session = session
        // face_match_nin: NINAuth requires EXACTLY 4 frames; inperson_nin:
        // selfie-only (0) when the business config allows it.
        let challengesPerSession: Int?
        switch field.kycType {
        case "face_match_nin": challengesPerSession = 4
        case "inperson_score": challengesPerSession = 4
        case "inperson_nin": challengesPerSession = 0
        default: challengesPerSession = nil
        }
        let fieldID = field.id
        _flow = StateObject(wrappedValue: LivenessFlow(
            api: session.makeLivenessAPI(),
            createInput: LivenessAPI.CreateInput(
                userRef: session.config.userRef,
                levelSlug: Self.levelSlug(step: session.currentStep, config: session.config),
                deviceMeta: LivenessDeviceMetaInput(
                    userAgent: "KYCWidget-iOS",
                    platform: UIDevice.current.systemName + " " + UIDevice.current.systemVersion,
                    cameraLabel: "front"
                ),
                challengesPerSession: challengesPerSession,
                kycType: field.kycType
            ),
            commit: { [weak session] value in session?.setValue(value ?? .null, for: fieldID) },
            onVerdict: { [weak session] result in
                session?.dispatchLivenessSubmitted(
                    sessionToken: result.sessionToken,
                    status: result.status,
                    riskScore: result.riskScore,
                    failureReason: result.failureReason
                )
            }
        ))
    }

    static func levelSlug(step: WidgetStep?, config: KYCWidgetConfig) -> String {
        step?.slug ?? config.levelSlug
    }

    private var isSkipped: Bool {
        session.values[field.id]?.dictValue?["skipped"]?.boolValue == true
    }

    var body: some View {
        FieldShell(
            label: field.label,
            required: field.required,
            helper: nil,
            error: session.fieldErrors[field.id]
        ) {
            switch flow.shell {
            case .idle:
                if isSkipped { skippedCard } else { idleCard }
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
            case .done:
                doneCard(flow.verdict)
            case .error(let msg):
                errorCard(msg)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { flow.shell == .running },
            set: { open in if !open && flow.shell == .running { flow.cancel() } }
        )) {
            if let seq = flow.session?.challengeSequence {
                LivenessCaptureSheetV2(
                    challengeSequence: seq,
                    recordVideo: flow.session?.requireVideo == true,
                    onComplete: { frames, selfie, progress, clip in
                        capturedPreview = selfie
                        Task { await submit(frames: frames, selfie: selfie, progress: progress, clip: clip) }
                    },
                    onCancel: { flow.cancel() }
                )
            }
        }
        .task {
            await flow.loadSettings(
                levelSlug: Self.levelSlug(step: session.currentStep, config: session.config),
                kycType: field.kycType,
                currentValue: session.values[field.id]
            )
        }
        .onChange(of: flow.shell) { shell in
            // Surface the rate-limit countdown as a separate retry timer
            // when the server replies with "Try again in Ns".
            if case .error(let message) = shell, let seconds = parseRetrySeconds(message) {
                startRetryCountdown(initial: seconds)
            } else {
                retrySecondsRemaining = nil
            }
        }
    }

    // ── action handlers ────────────────────────────────────────────────

    private func submit(frames: [UIImage], selfie: UIImage, progress: [LivenessChallengeProgress], clip: RecordedClip?) async {
        let selfieDataURL = selfie.jpegData(compressionQuality: 0.92).map { "data:image/jpeg;base64,\($0.base64EncodedString())" }
        let frameDataURLs = frames.compactMap { $0.jpegData(compressionQuality: 0.85).map { "data:image/jpeg;base64,\($0.base64EncodedString())" } }
        let isoFmt = ISO8601DateFormatter()
        let completed: [LivenessCompletedChallengeInput] = progress.map {
            LivenessCompletedChallengeInput(
                code: $0.code,
                completedAt: isoFmt.string(from: $0.completedAt),
                clientPassed: $0.clientPassed,
                durationMs: $0.durationMs
            )
        }
        await flow.submit(selfie: selfieDataURL, frames: frameDataURLs, completed: completed, clip: clip)
    }

    private func tryAgain() {
        capturedPreview = nil
        flow.tryAgain()
    }

    private func resubmit() {
        Task { await flow.resubmit() }
    }

    private func backToIdle() {
        capturedPreview = nil
        flow.cancel()
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
            action: { flow.start() },
            secondaryCta: flow.skipMode == "OPTIONAL" ? "Skip" : nil,
            secondaryAction: flow.skip
        )
    }

    private var skippedCard: some View {
        introCard(
            icon: "checkmark.circle.fill",
            iconTint: .green,
            title: "Liveness check not required",
            body: "This step does not need a liveness check."
        )
    }

    @ViewBuilder
    private func doneCard(_ v: LivenessSessionDTO?) -> some View {
        // Verdict nil means we never got a backend response (submission failed
        // but the inline value was committed) — fall back to a neutral
        // "submitted" tone, exactly like web's `verdict?.status ?? 'submitted'`.
        let status = v?.status ?? "submitted"
        let isApproved = status == "passed"
        let isManualReview = status == "requires_manual_review"
        let isFailed = flow.isNotAccepted
        let outOfAttempts = flow.outOfAttempts
        let iconName: String = isApproved
            ? "checkmark.seal.fill"
            : isFailed
                ? "exclamationmark.triangle.fill"
                : "clock.fill"
        let iconTint: Color = isApproved ? .green : isFailed ? .red : .orange
        let title: String = outOfAttempts
            ? "No attempts left"
            : isApproved
            ? "Identity verified"
            : isManualReview
                ? "Submitted for review"
                : isFailed
                    ? "Liveness check didn't pass"
                    : "Liveness submitted"
        let scoreSuffix: String = (isApproved && v?.riskScore != nil)
            ? " (score \(Int(v!.riskScore!.rounded()))/100)" : ""
        let body: String = outOfAttempts
            ? "You have used all your attempts. Please contact the business that sent you this link."
            : isApproved
            ? "Your liveness check was approved automatically\(scoreSuffix)."
            : isManualReview
                ? "A reviewer will confirm your verification shortly. You don't need to do anything else."
                : isFailed
                    ? (v?.failureReason ?? "Please retake the check. Make sure your face is well lit and follow each prompt.")
                    : "Your selfie and challenge frames were captured."
        let canTryAgain = flow.canTryAgain
        introCard(
            icon: iconName,
            iconTint: iconTint,
            title: title,
            body: body,
            thumb: capturedPreview,
            cta: canTryAgain ? "Try again" : nil,
            ctaStyle: .primary,
            action: canTryAgain ? tryAgain : nil,
            ctaHint: canTryAgain ? flow.session.map { "Attempts left: \($0.retriesRemaining)" } : nil
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
            action: flow.canResubmit ? resubmit : (flow.verdict != nil ? tryAgain : backToIdle)
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
        action: (() -> Void)? = nil,
        ctaHint: String? = nil,
        secondaryCta: String? = nil,
        secondaryAction: (() -> Void)? = nil
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
                VStack(spacing: 6) {
                    Button(action: action) {
                        Text(cta)
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ctaDisabled)
                    if let ctaHint {
                        Text(ctaHint)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    if let secondaryCta, let secondaryAction {
                        Button(action: secondaryAction) {
                            Text(secondaryCta)
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                    }
                }
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

@MainActor
final class LivenessFlow: ObservableObject {
    enum Shell: Equatable {
        case idle
        case preparing      // creating session + asking camera
        case running        // capture sheet showing
        case submitting     // POST evidence in flight
        case done
        case error(String)
    }

    static let acceptedStatuses: Set<String> = ["passed", "requires_manual_review"]

    @Published private(set) var shell: Shell = .idle
    @Published private(set) var session: LivenessSessionDTO?
    @Published private(set) var verdict: LivenessSessionDTO?
    @Published private(set) var skipMode = "NONE"
    @Published private var pendingEvidence: LivenessAPI.SubmitInput?
    @Published private var pendingClip: RecordedClip?

    static let videoUploadFailed = "Video upload failed. Please try again."
    static let cannotRecord = "This device cannot record the liveness video."

    private let api: LivenessAPI
    private let createInput: LivenessAPI.CreateInput
    private let commit: (AnyCodable?) -> Void
    private let onVerdict: (LivenessSessionDTO) -> Void

    init(
        api: LivenessAPI,
        createInput: LivenessAPI.CreateInput,
        commit: @escaping (AnyCodable?) -> Void,
        onVerdict: @escaping (LivenessSessionDTO) -> Void = { _ in }
    ) {
        self.api = api
        self.createInput = createInput
        self.commit = commit
        self.onVerdict = onVerdict
    }

    var isNotAccepted: Bool { verdict.map { !Self.acceptedStatuses.contains($0.status) } ?? false }
    var outOfAttempts: Bool { isNotAccepted && session?.retriesRemaining == 0 }
    var canTryAgain: Bool { isNotAccepted && !outOfAttempts }
    var canResubmit: Bool { pendingEvidence != nil && session.map { !Self.isExpired($0) } == true }

    func loadSettings(levelSlug: String?, kycType: String?, currentValue: AnyCodable? = nil) async {
        skipMode = (try? await api.clientSettings(levelSlug: levelSlug, kycType: kycType))?.skipMode ?? "NONE"
        if skipMode == "AUTO" && shell == .idle && session == nil && (currentValue ?? .null) == .null { skip() }
    }

    func skip() {
        commit(.object(["skipped": .bool(true)]))
    }

    func cancel() {
        shell = .idle
    }

    @discardableResult
    func start() -> Task<Void, Never> {
        verdict = nil
        pendingEvidence = nil
        discardClip()
        shell = .preparing
        return Task {
            do {
                if session.map(Self.isExpired) ?? true {
                    session = try await api.createSession(createInput)
                }
                shell = .running
            } catch {
                shell = .error(error.localizedDescription)
            }
        }
    }

    func submit(selfie: String?, frames: [String], completed: [LivenessCompletedChallengeInput], clip: RecordedClip? = nil) async {
        guard let active = session else { return }
        guard let selfie else {
            shell = .error("The captured photo could not be processed. Please try again.")
            return
        }
        await submitEvidence(LivenessAPI.SubmitInput(
            sessionToken: active.sessionToken,
            selfieImage: selfie,
            livelinessImages: frames,
            completedChallenges: completed
        ), clip: clip)
    }

    func resubmit() async {
        guard let pendingEvidence else { return }
        await submitEvidence(pendingEvidence, clip: pendingClip)
    }

    private func submitEvidence(_ input: LivenessAPI.SubmitInput, clip: RecordedClip?) async {
        shell = .submitting
        if session?.requireVideo == true {
            guard let clip else {
                pendingEvidence = nil
                discardClip()
                shell = .error(Self.cannotRecord)
                return
            }
            do {
                let upload = try await api.requestVideoUpload(token: input.sessionToken, contentType: clip.contentType, sizeBytes: clip.sizeBytes)
                try await api.uploadVideo(upload, clip: clip)
            } catch {
                pendingEvidence = input
                pendingClip = clip
                shell = .error(Self.videoUploadFailed)
                return
            }
        }
        let result: LivenessSessionDTO
        do {
            result = try await api.submitEvidence(input)
        } catch {
            let message = error.localizedDescription
            guard message.range(of: "not in a submittable state", options: .caseInsensitive) != nil,
                  let recovered = try? await api.getSession(token: input.sessionToken) else {
                pendingEvidence = input
                pendingClip = clip
                shell = .error(message)
                return
            }
            result = recovered
        }
        pendingEvidence = nil
        pendingClip = nil
        if let clip { try? FileManager.default.removeItem(at: clip.url) }
        session = result
        verdict = result
        commit(Self.acceptedStatuses.contains(result.status) ? .object([
            "selfieImage": .string(input.selfieImage ?? ""),
            "livelinessImages": .array(input.livelinessImages.map { .string($0) }),
            "livenessSessionId": .string(input.sessionToken),
        ]) : nil)
        shell = .done
        onVerdict(result)
    }

    @discardableResult
    func tryAgain() -> Task<Void, Never> {
        discardClip()
        guard let active = session, !Self.isExpired(active) else { return start() }
        guard active.retriesRemaining > 0 else {
            shell = .done
            return Task {}
        }
        shell = .preparing
        return Task {
            do {
                session = try await api.retrySession(token: active.sessionToken)
                verdict = nil
                shell = .running
            } catch {
                let message = error.localizedDescription
                if message.range(of: "Retry limit exceeded|already complete", options: [.regularExpression, .caseInsensitive]) != nil {
                    session?.retriesRemaining = 0
                    shell = .done
                } else {
                    shell = .error(message)
                }
            }
        }
    }

    private func discardClip() {
        if let pendingClip { try? FileManager.default.removeItem(at: pendingClip.url) }
        pendingClip = nil
    }

    private static func isExpired(_ session: LivenessSessionDTO) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let expiry = formatter.date(from: session.expiresAt) ?? ISO8601DateFormatter().date(from: session.expiresAt) else {
            return false
        }
        return expiry < Date()
    }
}

private extension String {
    /// Returns `nil` when the string is empty — used to gate fallback copy.
    var nonEmpty: String? { isEmpty ? nil : self }
}

#endif
