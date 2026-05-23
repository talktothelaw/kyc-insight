#if canImport(SwiftUI) && canImport(UIKit) && canImport(AVFoundation)
import SwiftUI
import UIKit
import AVFoundation

/// Native LivenessField — records short video while sampling N frames
/// for the backend liveness check. Mirrors `kyc-web-wiget-v2/src/components/
/// fields/LivenessField.tsx`.
///
/// Captured value shape (mirrors `LivenessValue`):
///   ```
///   { selfieImage: base64-jpeg, livelinessImages: [base64-jpeg], duration: secs }
///   ```
@available(iOS 15.0, *)
struct LivenessFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession

    @State private var showCapture = false
    @State private var capturedSelfie: UIImage?
    @State private var capturedFrames: Int = 0

    var body: some View {
        FieldShell(
            label: field.label, required: field.required,
            helper: "Centre your face. We'll record a short clip and sample a few frames for liveness.",
            error: session.fieldErrors[field.id]
        ) {
            VStack(spacing: 10) {
                Button { showCapture = true } label: {
                    FieldBox {
                        HStack(spacing: 10) {
                            Image(systemName: capturedSelfie == nil ? "video.fill" : "checkmark.seal.fill")
                                .foregroundColor(capturedSelfie == nil ? .secondary : .green)
                                .frame(width: 28, height: 28)
                                .background((capturedSelfie == nil ? Color.secondary : Color.green).opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(capturedSelfie == nil ? "Record liveness clip" : "Recapture clip")
                                    .font(.system(size: 14))
                                if let _ = capturedSelfie {
                                    Text("\(capturedFrames) frames sampled · selfie captured")
                                        .font(.system(size: 11)).foregroundColor(.secondary)
                                } else {
                                    Text("~5 seconds · front camera")
                                        .font(.system(size: 11)).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(.secondary).font(.system(size: 13, weight: .semibold))
                        }
                    }
                }
                .buttonStyle(.plain)
                if let selfie = capturedSelfie {
                    Image(uiImage: selfie)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity).frame(height: 180).clipped().cornerRadius(10)
                }
            }
        }
        .fullScreenCover(isPresented: $showCapture) {
            LivenessCaptureSheet { selfie, frames in
                capturedSelfie = selfie
                capturedFrames = frames.count
                if let selfieData = selfie.jpegData(compressionQuality: 0.85) {
                    let framesData = frames.compactMap { $0.jpegData(compressionQuality: 0.6)?.base64EncodedString() }
                    session.setValue(.object([
                        "selfieImage":      .string(selfieData.base64EncodedString()),
                        "livelinessImages": .array(framesData.map { .string($0) }),
                    ]), for: field.id)
                }
                showCapture = false
            } onCancel: { showCapture = false }
        }
    }
}

/// Liveness capture sheet — front-camera preview, prompt overlay, capture
/// button starts a 5-second sequence sampling N frames + a final selfie.
@available(iOS 15.0, *)
struct LivenessCaptureSheet: View {
    let onCapture: (UIImage, [UIImage]) -> Void
    let onCancel: () -> Void

    @StateObject private var controller = CameraController()
    @State private var configureError: String?
    @State private var phase: Phase = .preview
    @State private var prompt: String = "Look straight at the camera"
    @State private var captured: [UIImage] = []

    enum Phase: Equatable { case preview, recording, processing, done }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let error = configureError {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash").font(.system(size: 36)).foregroundColor(.white)
                    Text(error).foregroundColor(.white).multilineTextAlignment(.center).padding(.horizontal, 32)
                    Button("Close") { onCancel() }.buttonStyle(.borderedProminent)
                }
            } else {
                CameraPreviewView(session: controller.camera.session).ignoresSafeArea()
                VStack {
                    HStack {
                        Button(action: onCancel) {
                            Image(systemName: "xmark").foregroundColor(.white)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 36, height: 36).background(Color.black.opacity(0.5)).clipShape(Circle())
                        }
                        Spacer()
                    }.padding(.horizontal, 16).padding(.top, 16)

                    Spacer()

                    Text(prompt)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Color.black.opacity(0.55)).clipShape(Capsule())
                        .padding(.bottom, 20)

                    Button {
                        guard phase == .preview else { return }
                        Task { await runSequence() }
                    } label: {
                        ZStack {
                            Circle().strokeBorder(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                            Circle().fill(phase == .recording ? Color.red : Color.white).frame(width: 64, height: 64)
                        }
                    }
                    .disabled(phase != .preview)
                    .padding(.bottom, 40)
                }
            }
        }
        .onAppear {
            MediaPermissions.requestCamera { granted in
                guard granted else { configureError = "Camera access denied."; return }
                controller.start(prefersFront: true) { err in
                    if let err { configureError = err.localizedDescription }
                }
            }
        }
        .onDisappear { controller.stop() }
    }

    /// Sample 5 frames over ~3 seconds, then capture a final selfie.
    private func runSequence() async {
        phase = .recording
        let promptCycle = ["Hold still", "Smile slightly", "Look left", "Look right", "Look at camera"]
        for (i, p) in promptCycle.enumerated() {
            prompt = p
            try? await Task.sleep(nanoseconds: 700_000_000)
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                controller.capture { image in
                    if let image { captured.append(image) }
                    cont.resume()
                }
            }
            if i < promptCycle.count - 1 { prompt = "…" }
        }
        phase = .processing
        // The last captured image is the canonical selfie.
        let selfie = captured.last ?? UIImage()
        let frames = captured
        phase = .done
        onCapture(selfie, frames)
    }
}
#endif
