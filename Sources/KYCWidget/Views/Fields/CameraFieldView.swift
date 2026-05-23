#if canImport(SwiftUI) && canImport(UIKit) && canImport(AVFoundation)
import SwiftUI
import UIKit
import AVFoundation

/// Camera capture field — selfies, liveness, document scans.
///
/// After the user takes a photo, the image bytes are pushed through
/// `FileUploadAPI` (same pipeline as `FileFieldView`) and the resulting
/// `fileId` is stored on the session so `BuildSubmission` can emit it.
@available(iOS 15.0, *)
struct CameraFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession
    let preferFrontCamera: Bool

    @State private var showCamera = false
    @State private var captured: UIImage?
    @State private var phase: Phase = .idle
    @State private var localError: String?

    enum Phase: Equatable { case idle, uploading, uploaded, failed }

    private var fileKycType: String {
        field.kycType ?? session.currentSection?.providerType ?? ""
    }

    var body: some View {
        FieldShell(
            label: field.label,
            required: field.required,
            helper: phase == .idle
                ? (preferFrontCamera ? "Centre your face and hold still." : "Lay the document flat, fill the frame.")
                : nil,
            error: session.fieldErrors[field.id] ?? localError
        ) {
            VStack(spacing: 10) {
                Button { if phase != .uploading { showCamera = true } } label: {
                    FieldBox {
                        HStack(spacing: 10) {
                            leadingIcon
                            VStack(alignment: .leading, spacing: 2) {
                                Text(primaryLabel)
                                    .font(.system(size: 14, weight: phase == .uploaded || captured != nil ? .medium : .regular))
                                    .foregroundColor(phase == .idle && captured == nil ? .secondary : .primary)
                                if let detail = secondaryLabel {
                                    Text(detail).font(.system(size: 11)).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            trailingIndicator
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(phase == .uploading)
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
                showCamera = false
                if let data = image.jpegData(compressionQuality: 0.85) {
                    Task { await runUpload(data: data) }
                }
            } onCancel: {
                showCamera = false
            }
        }
    }

    private var leadingIcon: some View {
        Group {
            switch phase {
            case .uploading: ProgressView()
            case .uploaded:  Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
            case .failed:    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
            case .idle:
                Image(systemName: preferFrontCamera ? "person.crop.square" : "doc.viewfinder")
                    .foregroundColor(captured != nil ? KYCBrand.primary : .secondary)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .frame(width: 28, height: 28)
        .background(iconBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    private var iconBackground: Color {
        switch phase {
        case .uploading: return KYCBrand.primary.opacity(0.12)
        case .uploaded:  return Color.green.opacity(0.12)
        case .failed:    return Color.red.opacity(0.12)
        case .idle:      return (captured != nil ? KYCBrand.primary : Color.secondary).opacity(0.12)
        }
    }
    @ViewBuilder
    private var trailingIndicator: some View {
        switch phase {
        case .uploaded:  Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 13, weight: .semibold))
        case .failed:    Image(systemName: "arrow.clockwise").foregroundColor(.red).font(.system(size: 13, weight: .semibold))
        default:         Image(systemName: "chevron.right").foregroundColor(.secondary).font(.system(size: 13, weight: .semibold))
        }
    }
    private var primaryLabel: String {
        switch phase {
        case .uploading: return "Uploading photo…"
        case .uploaded:  return "Retake photo"
        case .failed:    return "Upload failed — tap to retake"
        case .idle:      return captured == nil ? "Open camera" : "Retake photo"
        }
    }
    private var secondaryLabel: String? {
        switch phase {
        case .uploading: return "Securing your photo…"
        case .uploaded:  return nil
        case .failed:    return localError ?? "Tap to try again"
        case .idle:      return captured == nil
            ? (preferFrontCamera ? "Selfie · front camera" : "Document · back camera")
            : nil
        }
    }

    private func runUpload(data: Data) async {
        phase = .uploading
        localError = nil
        let name = "capture-\(UUID().uuidString.prefix(8)).jpg"
        let api = FileUploadAPI(client: GraphQLClient(endpoint: session.config.gqlEndpoint, publicKey: session.config.publicKey))
        do {
            let result = try await api.upload(
                data: data,
                fileName: String(name),
                mimeType: "image/jpeg",
                processToken: session.schema?.processToken ?? "",
                kycType: fileKycType,
                fieldName: field.name
            )
            session.setValue(.object([
                "fileId":   .string(result.fileId),
                "uploaded": .bool(true),
                "name":     .string(String(name)),
                "mime":     .string("image/jpeg"),
                "size":     .number(Double(data.count)),
            ]), for: field.id)
            phase = .uploaded
        } catch {
            phase = .failed
            localError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            session.setValue(.string(""), for: field.id)
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
