import XCTest
@testable import KYCWidget

/// Drives the state machine with synthetic `FaceFrameSignals`. Verifies
/// the same thresholds & advancement rules as the web hook
/// (`kyc-web-wiget-v2/src/hooks/useLiveness.ts`).
final class LivenessChallengeStateMachineTests: XCTestCase {

    private final class CapturingDelegate: LivenessStateDelegate, @unchecked Sendable {
        var events: [LivenessStateEvent] = []
        func livenessStateDidChange(_ event: LivenessStateEvent) { events.append(event) }
    }

    private func centeredOkSignals() -> FaceFrameSignals {
        FaceFrameSignals(
            faceDetected: true, earAvg: 0.30, yawRatio: 0.5,
            faceCentered: true, brightness: 180,
            smileScore: 0, mouthOpenRatio: 0
        )
    }

    private func feedFrames(_ machine: LivenessChallengeStateMachine, count: Int, _ s: FaceFrameSignals) {
        for _ in 0..<count { machine.ingest(s) }
    }

    private func warmup(_ machine: LivenessChallengeStateMachine) {
        // First few frames are eaten by the warmup gate.
        feedFrames(machine, count: LivenessChallengeStateMachine.warmupFrames, centeredOkSignals())
    }

    func test_begin_setsStageDetectingAndEmptyHistory() {
        let m = LivenessChallengeStateMachine()
        m.begin(sequence: ["LOOK_STRAIGHT", "TAKE_SELFIE"])
        XCTAssertEqual(m.stage, .detecting)
        XCTAssertEqual(m.completed.count, 0)
        XCTAssertEqual(m.currentIndex, -1)
    }

    func test_detectingAdvancesToReady_afterHoldFrames_ofCenteredFace() {
        let m = LivenessChallengeStateMachine()
        let d = CapturingDelegate()
        m.delegate = d
        m.begin(sequence: ["LOOK_STRAIGHT", "TAKE_SELFIE"])
        warmup(m)
        feedFrames(m, count: LivenessChallengeStateMachine.holdFrames, centeredOkSignals())
        if case .readyFor(let code) = m.stage {
            XCTAssertEqual(code, "LOOK_STRAIGHT")
        } else {
            XCTFail("Expected stage to be .readyFor('LOOK_STRAIGHT'), got \(m.stage)")
        }
    }

    func test_offCenteredFace_doesNotAdvance() {
        let m = LivenessChallengeStateMachine()
        m.begin(sequence: ["LOOK_STRAIGHT", "TAKE_SELFIE"])
        warmup(m)
        let offCenter = FaceFrameSignals(
            faceDetected: true, earAvg: 0.3, yawRatio: 0.5,
            faceCentered: false, brightness: 180,
            smileScore: 0, mouthOpenRatio: 0
        )
        feedFrames(m, count: LivenessChallengeStateMachine.holdFrames * 2, offCenter)
        XCTAssertEqual(m.stage, .detecting)
    }

    func test_lowBrightness_doesNotAdvance() {
        let m = LivenessChallengeStateMachine()
        m.begin(sequence: ["LOOK_STRAIGHT", "TAKE_SELFIE"])
        warmup(m)
        let dark = FaceFrameSignals(
            faceDetected: true, earAvg: 0.3, yawRatio: 0.5,
            faceCentered: true, brightness: 50,
            smileScore: 0, mouthOpenRatio: 0
        )
        feedFrames(m, count: LivenessChallengeStateMachine.holdFrames * 2, dark)
        XCTAssertEqual(m.stage, .detecting)
    }

    func test_turnLeftChallenge_passesOnYawBelowThreshold() {
        let m = LivenessChallengeStateMachine()
        m.begin(sequence: ["TURN_HEAD_LEFT", "TAKE_SELFIE"])
        warmup(m)
        feedFrames(m, count: LivenessChallengeStateMachine.holdFrames, centeredOkSignals())
        m.advanceToActive() // ready → active
        let turnedLeft = FaceFrameSignals(
            faceDetected: true, earAvg: 0.3,
            yawRatio: 0.20, // below threshold (0.30)
            faceCentered: true, brightness: 180,
            smileScore: 0, mouthOpenRatio: 0
        )
        feedFrames(m, count: LivenessChallengeStateMachine.holdFrames, turnedLeft)
        XCTAssertEqual(m.completed.count, 1)
        XCTAssertEqual(m.completed.first?.code, "TURN_HEAD_LEFT")
        XCTAssertTrue(m.completed.first?.clientPassed ?? false)
    }

    func test_blinkChallenge_requiresTwoEyeClosures() {
        let m = LivenessChallengeStateMachine()
        m.begin(sequence: ["BLINK_TWICE", "TAKE_SELFIE"])
        warmup(m)
        feedFrames(m, count: LivenessChallengeStateMachine.holdFrames, centeredOkSignals())
        m.advanceToActive()
        // Open eyes → no progress yet.
        let open = centeredOkSignals()
        feedFrames(m, count: 6, open)
        XCTAssertEqual(m.completed.count, 0)
        // One blink (closed → open transition).
        let closed = FaceFrameSignals(
            faceDetected: true, earAvg: 0.10, yawRatio: 0.5,
            faceCentered: true, brightness: 180,
            smileScore: 0, mouthOpenRatio: 0
        )
        feedFrames(m, count: 3, closed)
        feedFrames(m, count: 3, open)
        XCTAssertEqual(m.completed.count, 0, "One blink should not pass yet")
        // Second blink — should pass.
        feedFrames(m, count: 3, closed)
        feedFrames(m, count: 3, open)
        XCTAssertEqual(m.completed.count, 1)
        XCTAssertEqual(m.completed.first?.code, "BLINK_TWICE")
    }

    func test_completeSequence_emitsReadyForSelfie() {
        let m = LivenessChallengeStateMachine()
        let d = CapturingDelegate()
        m.delegate = d
        m.begin(sequence: ["LOOK_STRAIGHT", "TAKE_SELFIE"])
        warmup(m)
        // Advance from detecting → ready_LOOK_STRAIGHT.
        feedFrames(m, count: LivenessChallengeStateMachine.holdFrames, centeredOkSignals())
        m.advanceToActive()
        // Pass LOOK_STRAIGHT.
        feedFrames(m, count: LivenessChallengeStateMachine.holdFrames, centeredOkSignals())
        // Advance to ready_TAKE_SELFIE.
        m.advanceToActive()
        // Pass TAKE_SELFIE.
        feedFrames(m, count: LivenessChallengeStateMachine.holdFrames, centeredOkSignals())
        // Should have fired readyForSelfie + submitting stage.
        XCTAssertTrue(d.events.contains(where: {
            if case .readyForSelfie = $0 { return true }
            return false
        }))
        XCTAssertEqual(m.stage, .submitting)
    }
}
