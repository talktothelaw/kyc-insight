import Foundation

/// Drives one liveness session through its server-issued
/// `challengeSequence`. Pure logic — no UIKit, no AVFoundation, no
/// dispatch — so it's unit-testable with synthetic `FaceFrameSignals`.
///
/// 1:1 with the web `useLiveness` hook state machine
/// (`kyc-web-wiget-v2/src/hooks/useLiveness.ts`). The CHALLENGE codes,
/// HOLD_FRAMES count, thresholds, and pass-condition formulas are all
/// kept identical so a session looks the same from the backend whether
/// it ran on web or iOS.
public enum LivenessStage: Equatable, Sendable, CustomStringConvertible {
    case idle
    case loading
    case detecting
    case readyFor(String)        // ready_<CODE> — 3-2-1 countdown
    case challengeFor(String)    // challenge_<CODE> — active detection
    case submitting
    case complete
    case error

    public var description: String {
        switch self {
        case .idle: return "idle"
        case .loading: return "loading"
        case .detecting: return "detecting"
        case .readyFor(let c): return "ready_\(c)"
        case .challengeFor(let c): return "challenge_\(c)"
        case .submitting: return "submitting"
        case .complete: return "complete"
        case .error: return "error"
        }
    }
}

public struct LivenessChallengeProgress: Equatable, Sendable {
    public let code: String
    public let completedAt: Date
    public let clientPassed: Bool
    public let durationMs: Int
}

public enum LivenessStateEvent: Equatable, Sendable {
    case stageChanged(LivenessStage)
    /// Fires once when a challenge passes — caller should capture a frame.
    case challengePassed(String, durationMs: Int)
    /// Fires when the terminal challenge (TAKE_SELFIE) completes — caller
    /// should snap the final selfie and call `finalize()`.
    case readyForSelfie
    /// Fires when every challenge has been completed and the caller
    /// invoked `finalize()`.
    case allChallengesComplete
}

public protocol LivenessStateDelegate: AnyObject {
    func livenessStateDidChange(_ event: LivenessStateEvent)
}

public final class LivenessChallengeStateMachine {

    // ── thresholds (parity with web `useLiveness.ts`) ───────────────────
    public static let holdFrames = 12
    public static let yawCentreMin = 0.40
    public static let yawCentreMax = 0.60
    public static let yawLeftThreshold = 0.30
    public static let yawRightThreshold = 0.70
    public static let earBlinkThreshold = 0.20
    public static let earOpenThreshold = 0.24
    public static let blinkMinClosedFrames = 2
    public static let minBrightness = 100.0
    public static let smileScoreThreshold = 0.40
    public static let mouthOpenRatioThreshold = 0.05
    public static let warmupFrames = 8

    public weak var delegate: LivenessStateDelegate?

    public private(set) var stage: LivenessStage = .idle
    public private(set) var sequence: [String] = []
    public private(set) var completed: [LivenessChallengeProgress] = []
    public private(set) var currentIndex: Int = -1

    private var holdCounter = 0
    private var blinkState: BlinkState = .open
    private var blinkClosedFrames = 0
    private var blinkCount = 0
    private var challengeStartedAt: Date = .distantPast
    private var warmupRemaining = 0

    private enum BlinkState { case open, closed }

    public init() {}

    /// Begin a new session with the server-issued challenge sequence.
    public func begin(sequence: [String]) {
        self.sequence = sequence
        self.completed = []
        self.currentIndex = -1
        self.holdCounter = 0
        self.blinkState = .open
        self.blinkClosedFrames = 0
        self.blinkCount = 0
        self.warmupRemaining = Self.warmupFrames
        setStage(.detecting)
    }

    /// Forces the machine into the loading stage (caller is initialising
    /// camera / model).
    public func enterLoading() { setStage(.loading) }

    /// Forces the machine into the error stage. Idempotent.
    public func enterError() { setStage(.error) }

    /// Caller has captured the selfie and uploaded evidence; mark the
    /// session as complete.
    public func finalize() {
        delegate?.livenessStateDidChange(.allChallengesComplete)
        setStage(.complete)
    }

    /// Feed one signal sample from the detector. Idempotent — safe to
    /// call at the camera's frame rate.
    public func ingest(_ s: FaceFrameSignals) {
        // Warmup — give the camera/model a few frames to stabilise before
        // we start gating on quality signals. Mirrors web behaviour.
        if warmupRemaining > 0 {
            warmupRemaining -= 1
            return
        }
        switch stage {
        case .idle, .loading, .error, .submitting, .complete:
            return
        case .detecting:
            ingestDuringDetecting(s)
        case .readyFor:
            // The ready stage is timer-driven, not signal-driven; the
            // caller flips us into challengeFor(_) on countdown end.
            return
        case .challengeFor(let code):
            ingestDuringChallenge(code, signals: s)
        }
    }

    /// Caller has finished the 3-2-1 ready countdown; flip into the
    /// challenge stage. Resets the per-challenge counters.
    public func advanceToActive() {
        guard case .readyFor(let code) = stage else { return }
        holdCounter = 0
        blinkState = .open
        blinkClosedFrames = 0
        blinkCount = 0
        challengeStartedAt = Date()
        setStage(.challengeFor(code))
    }

    private func ingestDuringDetecting(_ s: FaceFrameSignals) {
        guard s.faceDetected, s.faceCentered, s.brightness >= Self.minBrightness else {
            holdCounter = 0
            return
        }
        holdCounter += 1
        if holdCounter >= Self.holdFrames {
            advanceToReadyForNext()
        }
    }

    private func ingestDuringChallenge(_ code: String, signals s: FaceFrameSignals) {
        guard s.faceDetected, s.brightness >= Self.minBrightness else {
            holdCounter = 0
            return
        }
        let passed = passesCondition(code: code, signals: s)
        if passed {
            holdCounter += 1
        } else {
            holdCounter = 0
        }
        let requiredHold = code == "BLINK_TWICE" ? 1 : Self.holdFrames
        if holdCounter >= requiredHold {
            recordPass(code: code)
            advanceToReadyForNext()
        }
    }

    private func passesCondition(code: String, signals s: FaceFrameSignals) -> Bool {
        switch code {
        case "LOOK_STRAIGHT":
            return s.yawRatio >= Self.yawCentreMin && s.yawRatio <= Self.yawCentreMax && s.faceCentered
        case "TURN_HEAD_LEFT":
            return s.yawRatio < Self.yawLeftThreshold
        case "TURN_HEAD_RIGHT":
            return s.yawRatio > Self.yawRightThreshold
        case "BLINK_TWICE":
            return updateBlinkAndCheck(ear: s.earAvg)
        case "SMILE":
            return s.smileScore >= Self.smileScoreThreshold
        case "OPEN_MOUTH":
            return s.mouthOpenRatio >= Self.mouthOpenRatioThreshold
        case "TAKE_SELFIE":
            // Final challenge — pass once the user is centred + still + lit.
            return s.faceCentered && s.yawRatio >= Self.yawCentreMin && s.yawRatio <= Self.yawCentreMax
        default:
            // Unknown code — auto-advance so the session can finish.
            return true
        }
    }

    /// Two-blink detector. EAR drops sharply when eyes close; we count an
    /// edge `open → closed` of at least `blinkMinClosedFrames` as one
    /// blink. Two blinks → BLINK_TWICE passes.
    private func updateBlinkAndCheck(ear: Double) -> Bool {
        switch blinkState {
        case .open:
            if ear < Self.earBlinkThreshold {
                blinkState = .closed
                blinkClosedFrames = 1
            }
        case .closed:
            if ear < Self.earBlinkThreshold {
                blinkClosedFrames += 1
            } else if ear > Self.earOpenThreshold {
                if blinkClosedFrames >= Self.blinkMinClosedFrames {
                    blinkCount += 1
                }
                blinkState = .open
                blinkClosedFrames = 0
            }
        }
        return blinkCount >= 2
    }

    private func recordPass(code: String) {
        let durationMs = Int(Date().timeIntervalSince(challengeStartedAt) * 1000)
        completed.append(
            LivenessChallengeProgress(
                code: code,
                completedAt: Date(),
                clientPassed: true,
                durationMs: durationMs
            )
        )
        delegate?.livenessStateDidChange(.challengePassed(code, durationMs: durationMs))
    }

    private func advanceToReadyForNext() {
        currentIndex += 1
        if currentIndex >= sequence.count {
            // Sequence exhausted — the final challenge has already been
            // recorded. Let the caller know it's time to snap + submit.
            delegate?.livenessStateDidChange(.readyForSelfie)
            setStage(.submitting)
            return
        }
        let next = sequence[currentIndex]
        holdCounter = 0
        challengeStartedAt = Date()
        setStage(.readyFor(next))
    }

    private func setStage(_ next: LivenessStage) {
        if next == stage { return }
        stage = next
        delegate?.livenessStateDidChange(.stageChanged(next))
    }
}
