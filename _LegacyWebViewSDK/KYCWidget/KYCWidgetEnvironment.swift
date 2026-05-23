import Foundation

/// Which deployment of the KYC Insight widget the SDK should load.
///
/// Mirrors the origin-resolution logic in the web embed loader
/// (`kyc-web-wiget-v2/src/sdk/iframeLoader.ts:widgetOrigin`). Production
/// is the canonical CDN-fronted origin; everything else is per-environment
/// dev / staging URLs you point at while integrating.
public enum KYCWidgetEnvironment: Sendable, Equatable {
    /// `https://kyc-verify-v2.netapps.ng` — the production origin. Default.
    case production
    /// Custom origin (e.g. `https://staging.kyc-verify-v2.netapps.ng` or a
    /// local dev server). Must include scheme; trailing slash is ignored.
    case custom(URL)

    /// The base URL the widget page is served from. `/?<query>` is appended
    /// by `KYCWidgetConfig.buildURL()`.
    public var baseURL: URL {
        switch self {
        case .production:
            // swiftlint:disable:next force_unwrapping
            return URL(string: "https://kyc-verify-v2.netapps.ng")!
        case .custom(let url):
            return url
        }
    }
}
