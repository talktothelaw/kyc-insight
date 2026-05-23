#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

@available(iOS 15.0, *)
struct FileFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession

    @State private var showSourceSheet = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var pickedSummary: String?

    var body: some View {
        FieldShell(label: field.label, required: field.required, helper: "PDF, JPG, PNG, or HEIC.", error: session.fieldErrors[field.id]) {
            Button { showSourceSheet = true } label: {
                FieldBox {
                    HStack(spacing: 10) {
                        Image(systemName: pickedSummary != nil ? "doc.fill" : "paperclip")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(pickedSummary != nil ? KYCBrand.primary : .secondary)
                            .frame(width: 28, height: 28)
                            .background((pickedSummary != nil ? KYCBrand.primary : Color.secondary).opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pickedSummary ?? "Upload a file")
                                .font(.system(size: 14, weight: pickedSummary != nil ? .medium : .regular))
                                .foregroundColor(pickedSummary == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if pickedSummary == nil {
                                Text("Tap to choose a photo or document").font(.system(size: 11)).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: pickedSummary != nil ? "checkmark.circle.fill" : "chevron.right")
                            .foregroundColor(pickedSummary != nil ? .green : .secondary)
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
            }
            .buttonStyle(.plain)
            .confirmationDialog("Upload from…", isPresented: $showSourceSheet, titleVisibility: .visible) {
                Button("Photo library") { showPhotoPicker = true }
                Button("Files") { showFilePicker = true }
                Button("Cancel", role: .cancel) { }
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPickerSheet { items in
                if let first = items.first { handlePicked(name: first.name, size: first.data.count) }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf, .jpeg, .png, .heic, .image, .data]
        ) { result in
            if case .success(let url) = result { handleDocumentPicked(url) }
        }
    }

    private func handlePicked(name: String, size: Int) {
        pickedSummary = "\(name) · \(formatBytes(size))"
        session.setValue(.object(["name": .string(name), "size": .number(Double(size))]), for: field.id)
    }
    private func handleDocumentPicked(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        handlePicked(name: url.lastPathComponent, size: size)
    }
    private func formatBytes(_ count: Int) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: Int64(count))
    }
}

@available(iOS 15.0, *)
struct PhotoPickerSheet: UIViewControllerRepresentable {
    let onPicked: ([PickedItem]) -> Void
    @Environment(\.presentationMode) private var presentationMode

    struct PickedItem { let data: Data; let name: String }

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
                    lock.lock(); out.append(PickedItem(data: data, name: name)); lock.unlock()
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
