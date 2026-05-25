#if canImport(AVFoundation) && canImport(UIKit)
import AVFoundation

/// Web Speech API equivalent for iOS — speaks each challenge instruction
/// aloud as the user advances. Mirrors the voice-prompt UX in
/// `kyc-web-wiget-v2/src/hooks/useLiveness.ts`.
///
/// Best-effort: silently no-ops if the AVAudioSession can't be configured
/// (e.g. Bluetooth output disconnected mid-session). On-screen instruction
/// text is the source of truth — the voice is an accessibility layer on
/// top, not a substitute.
final class LivenessVoicePrompter {

    private let synthesizer = AVSpeechSynthesizer()
    private var enabled = true

    init() {
        configureAudioSession()
    }

    /// Speak `text`, cancelling any in-flight utterance first. Same shape
    /// as the web `speechSynthesis.cancel(); speak(u)` pattern.
    func speak(_ text: String) {
        guard enabled, !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.volume = 0.9
        u.pitchMultiplier = 1.0
        synthesizer.speak(u)
    }

    func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func disable() {
        enabled = false
        cancel()
    }

    /// Canonical instruction copy keyed by challenge code. 1:1 with the
    /// web `ACTIVE_BY_CODE` map (`useLiveness.ts:219`).
    static let instructionsByCode: [String: String] = [
        "LOOK_STRAIGHT":   "Look straight at the camera",
        "BLINK_TWICE":     "Open your eyes wide, then blink",
        "TURN_HEAD_LEFT":  "Slowly turn your head to the left",
        "TURN_HEAD_RIGHT": "Slowly turn your head to the right",
        "SMILE":           "Smile for the camera",
        "OPEN_MOUTH":      "Open your mouth wide",
        "TAKE_SELFIE":     "Hold still — capturing selfie",
    ]

    private func configureAudioSession() {
        do {
            // .ambient + .mixWithOthers: don't interrupt the host app's
            // music / podcasts when the synthesiser talks. .duckOthers
            // would briefly drop the volume — friendly default.
            try AVAudioSession.sharedInstance().setCategory(
                .ambient,
                mode: .spokenAudio,
                options: [.mixWithOthers, .duckOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            // Continue without voice; on-screen captions still work.
            enabled = false
        }
    }
}
#endif
