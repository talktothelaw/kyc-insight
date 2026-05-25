#if canImport(SwiftUI) && canImport(AVFoundation) && canImport(UIKit)
import SwiftUI
import AVFoundation
import UIKit

/// Wires the camera, face-landmark detector, state machine, and voice
/// prompter into one observable surface that SwiftUI views (the capture
/// sheet) can bind to. Owns the lifetime of those components and tears
/// them down on `stop()`.
///
/// Mirrors the responsibility split between
/// `kyc-web-wiget-v2/src/hooks/useLiveness.ts` and
/// `src/components/liveness/LivenessOverlay.tsx`:
///   • this coordinator = the hook (state + sensors)
///   • `LivenessCaptureSheet` (sibling SwiftUI view) = the overlay
@available(iOS 15.0, *)
@MainActor
final class LivenessCaptureCoordinator: ObservableObject, LivenessStateDelegate {

    // ── observable state ────────────────────────────────────────────────
    @Published var stage: LivenessStage = .idle
    @Published var currentChallenge: String? = nil
    @Published var currentChallengeIndex: Int = -1
    @Published var totalChallenges: Int = 0
    @Published var instruction: String = "Press Start to begin liveness verification"
    @Published var countdown: Int? = nil
    @Published var faceDetected: Bool = false
    @Published var faceCentered: Bool = false
    @Published var lightingOk: Bool = true
    @Published var errorMessage: String? = nil

    /// Final captured frames, ordered by the challengeSequence. Always
    /// includes the selfie as the last entry. Empty until completion.
    @Published var capturedFrames: [UIImage] = []
    @Published var selfieImage: UIImage? = nil

    /// True when the back camera is active. Drives the flip button's icon.
    @Published var isUsingBackCamera: Bool = false

    /// Fired exactly once when the sequence is complete and the selfie
    /// has been captured. The caller (LivenessFieldView) hands off to
    /// `submitLivenessEvidence` from here.
    var onComplete: (([UIImage], UIImage, [LivenessChallengeProgress]) -> Void)?
    var onCancel: (() -> Void)?

    // ── internals ──────────────────────────────────────────────────────
    let camera = LivenessCameraSession()
    private let detector = FaceLandmarkDetector()
    private let machine = LivenessChallengeStateMachine()
    private let voice = LivenessVoicePrompter()
    private var lastFrame: UIImage?
    private var lastSignals: FaceFrameSignals = .empty
    private var readyCountdownTask: Task<Void, Never>?
    private static let readyCountdownSeconds = 3

    init() {
        machine.delegate = self
    }

    /// Begin a session with the server-issued challenge sequence.
    func start(sequence: [String]) {
        totalChallenges = sequence.count
        instruction = "Loading camera…"
        machine.enterLoading()
        camera.onSample = { [weak self] buffer in
            // Hop off the camera queue so the detector + state machine
            // mutate state on the main actor.
            guard let self else { return }
            let facing: FaceLandmarkDetector.CameraFacing = (self.camera.facing == .front) ? .front : .back
            let (signals, image) = self.detector.analyze(sampleBuffer: buffer, facing: facing)
            Task { @MainActor in
                self.lastFrame = image
                self.lastSignals = signals
                self.faceDetected = signals.faceDetected
                self.faceCentered = signals.faceCentered
                self.lightingOk = signals.brightness >= LivenessChallengeStateMachine.minBrightness
                self.machine.ingest(signals)
            }
        }
        camera.start(facing: .front) { [weak self] err in
            guard let self else { return }
            if let err {
                self.errorMessage = err.localizedDescription
                self.machine.enterError()
                return
            }
            self.machine.begin(sequence: sequence)
            // Set the initial instruction the user sees before the model has
            // detected a face. The state-machine delegate updates it from
            // here.
            self.instruction = "Center your face inside the frame"
        }
    }

    /// User tapped the flip-camera button. Re-configures the AVCapture
    /// session to the opposite facing without restarting the entire
    /// liveness flow — the state machine keeps its hold counter through
    /// the swap.
    func flipCamera() {
        camera.switchFacing { [weak self] err in
            guard let self else { return }
            if err == nil {
                self.isUsingBackCamera = (self.camera.facing == .back)
            }
        }
    }

    /// Tear everything down. Idempotent.
    func stop() {
        readyCountdownTask?.cancel()
        readyCountdownTask = nil
        voice.cancel()
        camera.onSample = nil
        camera.stop()
    }

    /// User-cancelled — caller dismisses the sheet.
    func cancel() {
        stop()
        onCancel?()
    }

    // MARK: - LivenessStateDelegate

    nonisolated func livenessStateDidChange(_ event: LivenessStateEvent) {
        Task { @MainActor in
            switch event {
            case .stageChanged(let next):
                self.handleStageChange(next)
            case .challengePassed(let code, _):
                // Snapshot the most recent frame into the captured array.
                if let img = self.lastFrame {
                    self.capturedFrames.append(img)
                }
                // Soft confirmation cue — speak the code's success.
                self.voice.speak("\(code.replacingOccurrences(of: "_", with: " ").lowercased()) — captured")
            case .readyForSelfie:
                self.snapSelfieAndFinish()
            case .allChallengesComplete:
                break
            }
        }
    }

    private func handleStageChange(_ next: LivenessStage) {
        stage = next
        switch next {
        case .idle, .loading, .complete, .submitting, .error:
            currentChallenge = nil
            countdown = nil
        case .detecting:
            instruction = "Center your face inside the frame"
            voice.speak(instruction)
        case .readyFor(let code):
            currentChallenge = code
            currentChallengeIndex = machine.currentIndex
            let copy = LivenessVoicePrompter.instructionsByCode[code]
                ?? "Get ready for the next challenge"
            instruction = "Get ready — \(copy)"
            voice.speak(copy)
            startReadyCountdown()
        case .challengeFor(let code):
            currentChallenge = code
            currentChallengeIndex = machine.currentIndex
            instruction = LivenessVoicePrompter.instructionsByCode[code]
                ?? "Follow the on-screen prompt"
            countdown = nil
        }
    }

    private func startReadyCountdown() {
        readyCountdownTask?.cancel()
        var remaining = Self.readyCountdownSeconds
        countdown = remaining
        readyCountdownTask = Task { @MainActor in
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
                if remaining > 0 {
                    countdown = remaining
                } else {
                    countdown = nil
                    machine.advanceToActive()
                }
            }
        }
    }

    private func snapSelfieAndFinish() {
        // Use the most recent frame as the selfie — same approach the web
        // capture takes (it samples a single Canvas-rendered frame from
        // the live video at the end of TAKE_SELFIE).
        let selfie = lastFrame ?? UIImage()
        selfieImage = selfie
        voice.speak("Liveness verification complete")
        let progress = machine.completed
        camera.onSample = nil
        camera.stop()
        // Hand back the captured frames and the selfie to the field view.
        onComplete?(capturedFrames, selfie, progress)
    }
}
#endif
