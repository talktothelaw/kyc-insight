#if canImport(UIKit)
import AVFoundation
import Photos
import UIKit

/// Pre-flight permissions for the camera, microphone, and photo library.
///
/// The native SDK manages these directly (no WKWebView passthrough), so
/// the prompts fire from native code at the right moment in the flow.
public enum MediaPermissions {
    public static let infoPlistKeys: [String: String] = [
        "NSCameraUsageDescription":      "The widget uses the camera for document scan + liveness checks.",
        "NSMicrophoneUsageDescription":  "The widget records short audio with liveness video (when required).",
        "NSPhotoLibraryUsageDescription": "The widget lets the customer upload documents from their photo library.",
    ]

    public static var infoPlistComplete: Bool {
        infoPlistKeys.keys.allSatisfy { Bundle.main.object(forInfoDictionaryKey: $0) != nil }
    }

    public enum Kind { case camera, microphone, photoLibrary }

    public static func authorizationStatus(_ kind: Kind) -> AVAuthorizationStatus {
        switch kind {
        case .camera:     return AVCaptureDevice.authorizationStatus(for: .video)
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio)
        case .photoLibrary:
            let raw = PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue
            return AVAuthorizationStatus(rawValue: raw) ?? .notDetermined
        }
    }

    public static func requestCamera(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    public static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    public static func requestPhotoLibrary(_ completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                completion(status == .authorized || status == .limited)
            }
        }
    }
}
#endif
