#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// Native FileField. 1:1 with the web's `FileField.tsx` — same 3-step
/// pipeline: pick file → `FileUploadAPI.upload(...)` (RequestFileUploadTwo
/// → multipart POST → completeFileUploadTwo) → store `{fileId, uploaded,
/// name, mime, size}` so `BuildSubmission` can read `fileId` at submit time.
@available(iOS 15.0, *)
struct FileFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession

    @State private var showSourceSheet = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var phase: Phase = .idle
    @State private var pickedSummary: String?
    @State private var localError: String?

    enum Phase: Equatable { case idle, uploading, uploaded, failed }

    /// Provider type to send to `RequestFileUploadTwo`. Same heuristic as
    /// the web FileField: prefer the field's own `kycType` meta (set during
    /// schema normalization for file-bearing fields), fall back to the
    /// current section's providerType.
    private var fileKycType: String {
        field.kycType ?? session.currentSection?.providerType ?? ""
    }

    var body: some View {
        FieldShell(
            label: field.label, required: field.required,
            helper: phase == .idle ? "PDF, JPG, PNG, or HEIC." : nil,
            error: session.fieldErrors[field.id] ?? localError
        ) {
            Button { if phase != .uploading { showSourceSheet = true } } label: {
                FieldBox {
                    HStack(spacing: 10) {
                        leadingIcon
                        VStack(alignment: .leading, spacing: 2) {
                            Text(primaryLabel)
                                .font(.system(size: 14, weight: phase == .idle ? .regular : .medium))
                                .foregroundColor(phase == .idle ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
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
            .confirmationDialog("Upload from…", isPresented: $showSourceSheet, titleVisibility: .visible) {
                Button("Photo library") { showPhotoPicker = true }
                Button("Files") { showFilePicker = true }
                Button("Cancel", role: .cancel) { }
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerSheet { items in
                if let first = items.first {
                    Task { await runUpload(data: first.data, fileName: first.name, mime: first.mime) }
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf, .jpeg, .png, .heic, .image, .data]
        ) { result in
            if case .success(let url) = result {
                Task { await runDocumentUpload(url) }
            }
        }
    }

    private var leadingIcon: some View {
        Group {
            switch phase {
            case .idle:
                Image(systemName: "paperclip").foregroundColor(.secondary)
            case .uploading:
                ProgressView()
            case .uploaded:
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .frame(width: 28, height: 28)
        .background(iconBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    private var iconBackground: Color {
        switch phase {
        case .idle:      return Color.secondary.opacity(0.12)
        case .uploading: return KYCBrand.primary.opacity(0.12)
        case .uploaded:  return Color.green.opacity(0.12)
        case .failed:    return Color.red.opacity(0.12)
        }
    }
    @ViewBuilder
    private var trailingIndicator: some View {
        switch phase {
        case .uploaded:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 13, weight: .semibold))
        case .failed:
            Image(systemName: "arrow.clockwise").foregroundColor(.red).font(.system(size: 13, weight: .semibold))
        default:
            Image(systemName: "chevron.right").foregroundColor(.secondary).font(.system(size: 13, weight: .semibold))
        }
    }
    private var primaryLabel: String {
        switch phase {
        case .idle:      return "Upload a file"
        case .uploading: return "Uploading…"
        case .uploaded:  return pickedSummary ?? "File uploaded"
        case .failed:    return pickedSummary ?? "Upload failed — tap to retry"
        }
    }
    private var secondaryLabel: String? {
        switch phase {
        case .idle:      return "Tap to choose a photo or document"
        case .uploading: return "Securing your file…"
        case .uploaded:  return nil
        case .failed:    return localError ?? "Tap to try again"
        }
    }

    // MARK: - Upload pipeline

    private func runUpload(data: Data, fileName: String, mime: String?) async {
        phase = .uploading
        pickedSummary = fileName
        localError = nil
        let api = FileUploadAPI(client: GraphQLClient(endpoint: session.config.gqlEndpoint, publicKey: session.config.publicKey))
        do {
            let result = try await api.upload(
                data: data,
                fileName: fileName,
                mimeType: mime,
                processToken: session.schema?.processToken ?? "",
                kycType: fileKycType,
                fieldName: field.name
            )
            // Store the same shape the web's FileFieldValue uses so
            // BuildSubmission.swift can read `fileId` at submit time and
            // validation can check `uploaded == true`.
            session.setValue(.object([
                "fileId":   .string(result.fileId),
                "uploaded": .bool(true),
                "name":     .string(fileName),
                "mime":     .string(mime ?? ""),
                "size":     .number(Double(data.count)),
            ]), for: field.id)
            pickedSummary = "\(fileName) · \(formatBytes(data.count))"
            phase = .uploaded
        } catch {
            phase = .failed
            localError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Clear the value so submission validation flags the field as
            // missing — half-uploaded files would otherwise show as
            // satisfied while having no fileId.
            session.setValue(.string(""), for: field.id)
        }
    }

    private func runDocumentUpload(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            await runUpload(data: data, fileName: url.lastPathComponent, mime: mime)
        } catch {
            phase = .failed
            localError = "Couldn't read the file: \(error.localizedDescription)"
        }
    }

    private func formatBytes(_ count: Int) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: Int64(count))
    }
}

/// Photo picker that returns raw bytes + a derived MIME type so the
/// caller can drive the upload pipeline immediately.
@available(iOS 15.0, *)
struct PhotoPickerSheet: UIViewControllerRepresentable {
    let onPicked: ([PickedItem]) -> Void
    @Environment(\.presentationMode) private var presentationMode

    struct PickedItem { let data: Data; let name: String; let mime: String? }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPickerSheet
        init(_ parent: PhotoPickerSheet) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.presentationMode.wrappedValue.dismiss()
            var out: [PickedItem] = []
            let group = DispatchGroup()
            let lock = NSLock()
            for r in results {
                group.enter()
                let typeId = ["public.jpeg", "public.png", "public.heic", "public.image"]
                    .first { r.itemProvider.hasItemConformingToTypeIdentifier($0) } ?? "public.image"
                r.itemProvider.loadDataRepresentation(forTypeIdentifier: typeId) { data, _ in
                    defer { group.leave() }
                    guard let data else { return }
                    let name = (r.itemProvider.suggestedName ?? "photo") + Self.ext(for: typeId)
                    let mime = UTType(typeId)?.preferredMIMEType
                    lock.lock(); out.append(PickedItem(data: data, name: name, mime: mime)); lock.unlock()
                }
            }
            group.notify(queue: .main) { self.parent.onPicked(out) }
        }
        private static func ext(for utiID: String) -> String {
            UTType(utiID).flatMap { ".\($0.preferredFilenameExtension ?? "jpg")" } ?? ".jpg"
        }
    }
}
#endif
