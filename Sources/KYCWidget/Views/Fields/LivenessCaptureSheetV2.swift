#if canImport(SwiftUI) && canImport(UIKit) && canImport(AVFoundation)
import SwiftUI
import UIKit
import AVFoundation

/// V2 liveness capture sheet — drives the active-vision flow via
/// `LivenessCaptureCoordinator`, shows a dashed face-oval guide that turns
/// green when the user is centred + detected, and renders the per-challenge
/// instruction badge with the 3-2-1 countdown.
///
/// Mirrors `kyc-web-wiget-v2/src/components/liveness/LivenessOverlay.tsx` —
/// classes there map onto the same visual elements here: progress bar at
/// the top, instruction badge below it, oval guide over the live preview,
/// quality hints at the bottom, cancel × top-right.
@available(iOS 15.0, *)
struct LivenessCaptureSheetV2: View {
    let challengeSequence: [String]
    let onComplete: ([UIImage], UIImage, [LivenessChallengeProgress]) -> Void
    let onCancel: () -> Void

    @StateObject private var coordinator = LivenessCaptureCoordinator()
    @State private var didStart = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let error = coordinator.errorMessage {
                errorView(error)
            } else {
                CameraPreviewView(session: coordinator.camera.session)
                    .ignoresSafeArea()

                faceOvalOverlay
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    topBar
                    progressBar
                    Spacer()
                    instructionBadge
                    qualityHints
                        .padding(.bottom, 24)
                }
            }
        }
        .onAppear {
            guard !didStart else { return }
            didStart = true
            coordinator.onComplete = onComplete
            coordinator.onCancel = onCancel
            coordinator.start(sequence: challengeSequence)
        }
        .onDisappear { coordinator.stop() }
    }

    // ── pieces ──────────────────────────────────────────────────────────

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("Liveness Check")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.black.opacity(0.55))
                .clipShape(Capsule())
            Spacer()
            // Flip camera — front ↔ back. Most users will stay on the front
            // camera; this is a fallback for the rare case where front-cam
            // hardware is broken or unavailable on the device.
            Button {
                coordinator.flipCamera()
            } label: {
                Image(systemName: coordinator.isUsingBackCamera
                      ? "camera.rotate.fill"
                      : "camera.rotate")
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
            }
            .accessibilityLabel(coordinator.isUsingBackCamera
                ? "Switch to front camera"
                : "Switch to back camera")
            Button {
                coordinator.cancel()
            } label: {
                Image(systemName: "xmark")
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Cancel liveness check")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private var progressBar: some View {
        let pct: Double = {
            guard coordinator.totalChallenges > 0 else { return 0 }
            let done = max(0, coordinator.currentChallengeIndex)
            return min(1.0, Double(done) / Double(coordinator.totalChallenges))
        }()
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.accentColor)
                    .frame(width: geo.size.width * CGFloat(pct))
                    .animation(.easeOut(duration: 0.25), value: pct)
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var faceOvalOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let rx = w * 0.34
            let ry = h * 0.30
            let centerX = w / 2
            let centerY = h * 0.45
            ZStack {
                // Dim the outside via even-odd fill.
                Path { p in
                    p.addRect(CGRect(x: 0, y: 0, width: w, height: h))
                    p.addEllipse(in: CGRect(
                        x: centerX - rx, y: centerY - ry,
                        width: rx * 2, height: ry * 2
                    ))
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

                // The guide ring itself.
                Ellipse()
                    .strokeBorder(
                        coordinator.faceDetected && coordinator.faceCentered
                            ? Color.green
                            : Color.white,
                        style: StrokeStyle(
                            lineWidth: 3,
                            dash: coordinator.stage.isActiveChallenge ? [] : [10, 6]
                        )
                    )
                    .frame(width: rx * 2, height: ry * 2)
                    .position(x: centerX, y: centerY)
                    .animation(.easeInOut(duration: 0.2), value: coordinator.faceCentered)
            }
        }
    }

    @ViewBuilder
    private var instructionBadge: some View {
        VStack(spacing: 10) {
            if let count = coordinator.countdown {
                Text("\(count)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(radius: 4)
            }
            Text(coordinator.instruction)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var qualityHints: some View {
        HStack(spacing: 6) {
            if !coordinator.faceDetected {
                hint("No face detected")
            } else if !coordinator.faceCentered {
                hint("Center your face in the frame")
            }
            if !coordinator.lightingOk {
                hint("Find better lighting")
            }
        }
        .padding(.horizontal, 16)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color(red: 0.85, green: 0.46, blue: 0.04, opacity: 0.85))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 36))
                .foregroundColor(.white)
            Text(msg)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Close") { coordinator.cancel() }
                .buttonStyle(.borderedProminent)
        }
    }
}

private extension LivenessStage {
    var isActiveChallenge: Bool {
        if case .challengeFor = self { return true }
        return false
    }
}
#endif
