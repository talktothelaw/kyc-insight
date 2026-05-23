import Foundation

/// Errors surfaced via ``KYCWidget/onError``.
public enum KYCWidgetError: Error, Equatable, Sendable {
    case missingRequiredConfig(String)
    case loadFailed(message: String)
    case submissionFailed(message: String)
    case cameraUnavailable
    case permissionDenied(String)
    case externalConsentFailed(message: String)
    case unknown(message: String)
}

extension KYCWidgetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingRequiredConfig(let field):
            return "KYCWidget: missing required config field \"\(field)\"."
        case .loadFailed(let message):
            return "Could not load verification: \(message)"
        case .submissionFailed(let message):
            return "Submission failed: \(message)"
        case .cameraUnavailable:
            return "Camera is not available on this device."
        case .permissionDenied(let kind):
            return "\(kind) permission was denied. Enable it in Settings to continue."
        case .externalConsentFailed(let message):
            return "External consent failed: \(message)"
        case .unknown(let message):
            return message
        }
    }
}
