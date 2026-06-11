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
                // WYSIWYG camera box — pinned to the sensor's 4:3 aspect so
                // the user sees the FULL analysis frame. A full-screen
                // aspect-fill crop hid ~40% of the sensor width: faces
                // overflowed the oval at selfie distance and users backed
                // away until detection lost them.
                GeometryReader { geo in
                    ZStack {
                        CameraPreviewView(session: coordinator.camera.session)
                        faceOvalOverlay
                    }
                    .frame(width: geo.size.width, height: geo.size.width * 4.0 / 3.0)
                    .clipped()
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    topBar
                    progressBar
                    // Persistent target-zone label — sits between the
                    // progress bar and the oval so the user always sees
                    // where to put their face.
                    targetZoneLabel
                        .padding(.top, 16)
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
            // Geometry == the 4:3 camera box. Oval centred on the FRAME
            // centre so it matches the detector's ±15%/±20% centering gate;
            // 66% of frame width fits a face at normal selfie distance.
            let w = geo.size.width
            let h = geo.size.height
            let rx = w * 0.33
            let ry = h * 0.345
            let centerX = w / 2
            let centerY = h * 0.5
            let armLen = min(rx, ry) * 0.28
            let acquired = coordinator.faceDetected && coordinator.faceCentered
            let ringColor: Color = acquired ? .green : .white
            let cornerColor: Color = acquired ? .green : Color(red: 0.99, green: 0.83, blue: 0.30)
            ZStack {
                // Dim the outside via even-odd fill — heavier dim so the
                // cut-out reads as a clear target zone.
                Path { p in
                    p.addRect(CGRect(x: 0, y: 0, width: w, height: h))
                    p.addEllipse(in: CGRect(
                        x: centerX - rx, y: centerY - ry,
                        width: rx * 2, height: ry * 2
                    ))
                }
                .fill(Color.black.opacity(0.65), style: FillStyle(eoFill: true))

                // The guide ring — thicker so it reads at a glance.
                Ellipse()
                    .strokeBorder(
                        ringColor,
                        style: StrokeStyle(
                            lineWidth: 4,
                            dash: coordinator.stage.isActiveChallenge ? [] : [12, 7]
                        )
                    )
                    .frame(width: rx * 2, height: ry * 2)
                    .position(x: centerX, y: centerY)
                    .animation(.easeInOut(duration: 0.2), value: acquired)

                // Scan-style L-shaped corner brackets at the oval's
                // bounding rect — gives the user an explicit "viewfinder
                // box" so the centring intent is obvious.
                Path { p in
                    let left = centerX - rx
                    let right = centerX + rx
                    let top = centerY - ry
                    let bot = centerY + ry
                    // top-left
                    p.move(to: CGPoint(x: left, y: top))
                    p.addLine(to: CGPoint(x: left + armLen, y: top))
                    p.move(to: CGPoint(x: left, y: top))
                    p.addLine(to: CGPoint(x: left, y: top + armLen))
                    // top-right
                    p.move(to: CGPoint(x: right, y: top))
                    p.addLine(to: CGPoint(x: right - armLen, y: top))
                    p.move(to: CGPoint(x: right, y: top))
                    p.addLine(to: CGPoint(x: right, y: top + armLen))
                    // bottom-left
                    p.move(to: CGPoint(x: left, y: bot))
                    p.addLine(to: CGPoint(x: left + armLen, y: bot))
                    p.move(to: CGPoint(x: left, y: bot))
                    p.addLine(to: CGPoint(x: left, y: bot - armLen))
                    // bottom-right
                    p.move(to: CGPoint(x: right, y: bot))
                    p.addLine(to: CGPoint(x: right - armLen, y: bot))
                    p.move(to: CGPoint(x: right, y: bot))
                    p.addLine(to: CGPoint(x: right, y: bot - armLen))
                }
                .stroke(cornerColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .animation(.easeInOut(duration: 0.2), value: acquired)
            }
        }
    }

    // Persistent label sitting between the top bar and the oval's top
    // edge so the user always knows the oval is the target zone — even
    // before the detector has acquired a centred face. Goes amber-on-dark
    // until centring is confirmed, then flips to green.
    private var targetZoneLabel: some View {
        let acquired = coordinator.faceDetected && coordinator.faceCentered
        let text: String = {
            if !coordinator.faceDetected { return "Position your face inside the frame" }
            if !coordinator.faceCentered { return "Centre your face in the oval" }
            switch coordinator.stage {
            case .detecting: return "Hold still…"
            default:         return "Stay centred"
            }
        }()
        return Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background((acquired ? Color(red: 0.02, green: 0.59, blue: 0.41) : Color.black).opacity(0.85))
            .clipShape(Capsule())
            .animation(.easeInOut(duration: 0.2), value: acquired)
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
