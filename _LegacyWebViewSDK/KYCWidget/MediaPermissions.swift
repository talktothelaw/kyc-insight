#if canImport(UIKit)
import AVFoundation
import Photos
import UIKit

/// Pre-flight permission helper.
///
/// The widget renders its own permission UX inside the WebView, but iOS
/// requires us to declare usage descriptions in `Info.plist` AND request
/// access via `AVCaptureDevice.requestAccess` before the OS will let
/// WKWebView's `getUserMedia` succeed. Calling
/// ``MediaPermissions/prewarm()`` before presenting the widget cuts
/// out a confusing "Camera access denied" loading flicker for first-time
/// users — the system prompt fires up front instead of after the customer
/// has already navigated to the document-upload step.
public enum MediaPermissions {
    /// Required `Info.plist` keys. Document these in your README + integration
    /// guide; iOS will hard-crash on the first `AVCaptureDevice.requestAccess`
    /// call if any of them are missing.
    public static let infoPlistKeys = [
        "NSCameraUsageDescription":      "The widget uses the camera for document scan + liveness checks.",
        "NSMicrophoneUsageDescription":  "The widget records short audio with liveness video (when required).",
        "NSPhotoLibraryUsageDescription": "The widget lets the customer upload documents from their photo library.",
    ]

    /// Fire the OS prompt for camera + microphone up front, before the
    /// customer interacts with the widget. Both are idempotent — if the
    /// user has already decided, the closure is called immediately with
    /// the current state.
    public static func prewarm(_ completion: (() -> Void)? = nil) {
        let group = DispatchGroup()
        group.enter()
        AVCaptureDevice.requestAccess(for: .video) { _ in group.leave() }
        group.enter()
        AVCaptureDevice.requestAccess(for: .audio) { _ in group.leave() }
        group.notify(queue: .main) { completion?() }
    }

    /// Optionally request photo-library access too. Some integrators want
    /// the OS prompt out of the way before the file-picker step opens.
    public static func prewarmPhotoLibrary(_ completion: ((PHAuthorizationStatus) -> Void)? = nil) {
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                DispatchQueue.main.async { completion?(status) }
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                DispatchQueue.main.async { completion?(status) }
            }
        }
    }

    /// True when every required `Info.plist` key is present in the host
    /// app's bundle. Useful as a precondition assertion in development.
    public static var infoPlistComplete: Bool {
        let bundle = Bundle.main
        return infoPlistKeys.keys.allSatisfy { bundle.object(forInfoDictionaryKey: $0) != nil }
    }
}
#endif
