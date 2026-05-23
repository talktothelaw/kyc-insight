import Foundation

/// Errors surfaced to the host app via the ``KYCWidget/onError`` callback,
/// and thrown synchronously from ``KYCWidgetConfig/buildURL()`` on bad config.
public enum KYCWidgetError: Error, Equatable, Sendable {
    /// A required config field was empty. Payload is the field name.
    case missingRequiredConfig(String)
    /// The widget URL couldn't be constructed (extremely unlikely — happens
    /// only if `widgetEnvironment.baseURL` is invalid after percent-encoding).
    case invalidURL
    /// The widget reported a fatal load or submission error. `message` is
    /// the human-readable description forwarded from the widget itself.
    case widgetError(message: String)
}

extension KYCWidgetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingRequiredConfig(let field):
            return "KYCWidget: missing required config field \"\(field)\"."
        case .invalidURL:
            return "KYCWidget: could not build the widget URL from the supplied environment."
        case .widgetError(let message):
            return message
        }
    }
}
