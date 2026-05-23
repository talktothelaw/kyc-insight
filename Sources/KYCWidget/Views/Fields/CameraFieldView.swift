#if canImport(SwiftUI) && canImport(UIKit) && canImport(AVFoundation)
import SwiftUI
import UIKit
import AVFoundation

/// Camera capture field — used for selfies, liveness, and document scans.
/// The user gets a native full-screen capture sheet with a front/back
/// camera toggle, capture button, and retake/confirm controls.
@available(iOS 15.0, *)
struct CameraFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession
    let preferFrontCamera: Bool

    @State private var showCamera = false
    @State private var captured: UIImage?

    var body: some View {
        FieldShell(
            label: field.label,
            required: field.required,
            helper: preferFrontCamera ? "Centre your face and hold still." : "Lay the document flat, fill the frame.",
            error: session.fieldErrors[field.id]
        ) {
            VStack(spacing: 10) {
                Button { showCamera = true } label: {
                    FieldBox {
                        HStack(spacing: 10) {
                            Image(systemName: preferFrontCamera ? "person.crop.square" : "doc.viewfinder")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(captured != nil ? KYCBrand.primary : .secondary)
                                .frame(width: 28, height: 28)
                                .background((captured != nil ? KYCBrand.primary : Color.secondary).opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(captured == nil ? ("Open camera") : "Retake photo")
                                    .font(.system(size: 14, weight: captured != nil ? .medium : .regular))
                                    .foregroundColor(captured == nil ? .secondary : .primary)
                                if captured == nil {
                                    Text(preferFrontCamera ? "Selfie · front camera" : "Document · back camera")
                                        .font(.system(size: 11)).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: captured != nil ? "checkmark.circle.fill" : "chevron.right")
                                .foregroundColor(captured != nil ? .green : .secondary)
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                }
                .buttonStyle(.plain)
                if let captured {
                    Image(uiImage: captured)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .clipped()
                        .cornerRadius(10)
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureSheet(preferFrontCamera: preferFrontCamera) { image in
                captured = image
                if let data = image.jpegData(compressionQuality: 0.85) {
                    session.setValue(.object([
                        "size": .number(Double(data.count)),
                        "mime": .string("image/jpeg"),
                    ]), for: field.id)
                }
                showCamera = false
            } onCancel: {
                showCamera = false
            }
        }
    }
}

/// Full-screen native camera UI. Live preview, capture button, front/back
/// toggle, cancel button.
@available(iOS 15.0, *)
struct CameraCaptureSheet: View {
    let preferFrontCamera: Bool
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    @StateObject private var controller = CameraController()
    @State private var configureError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let error = configureError {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 36))
                        .foregroundColor(.white)
                    Text(error)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Close") { onCancel() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                CameraPreviewView(session: controller.camera.session)
                    .ignoresSafeArea()
                VStack {
                    HStack {
                        Button(action: onCancel) {
                            Image(systemName: "xmark")
                                .foregroundColor(.white)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 36, height: 36)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        Spacer()
                        Button(action: { controller.switchFacing() }) {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .foregroundColor(.white)
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    Spacer()
                    Button {
                        controller.capture { image in
                            if let image { onCapture(image) }
                        }
                    } label: {
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 4)
                            .frame(width: 72, height: 72)
                            .overlay(
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 60, height: 60)
                            )
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .onAppear {
            MediaPermissions.requestCamera { granted in
                guard granted else {
                    configureError = "Camera access is denied. Enable it in Settings to continue."
                    return
                }
                controller.start(prefersFront: preferFrontCamera) { err in
                    if let err { configureError = err.localizedDescription }
                }
            }
        }
        .onDisappear {
            controller.stop()
        }
    }
}

@available(iOS 15.0, *)
@MainActor
final class CameraController: ObservableObject {
    let camera = CameraSession()

    func start(prefersFront: Bool, completion: @escaping (Error?) -> Void) {
        camera.configure(mode: .photo, facing: prefersFront ? .front : .back, completion: completion)
    }

    func stop() { camera.stop() }

    func switchFacing() {
        camera.switchFacing { _ in }
    }

    func capture(completion: @escaping (UIImage?) -> Void) {
        camera.capturePhoto { result in
            switch result {
            case .success(let data): completion(UIImage(data: data))
            case .failure: completion(nil)
            }
        }
    }
}
#endif
