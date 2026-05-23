import Foundation

/// Configuration accepted by ``KYCWidget`` initializer.
///
/// Field shape matches the web SDK's `KycWidgetConfig`
/// (`kyc-web-wiget-v2/src/types/config.ts`) so the same backend
/// integration works for both. Every field becomes a query param on
/// the URL the widget loads from.
public struct KYCWidgetConfig: Sendable, Equatable {
    /// Required. The merchant's `NA_PUB_*` key.
    public let publicKey: String
    /// Required. Stable identifier for the end user — reusing the same
    /// value across sessions returns the same customer record.
    public let userRef: String
    /// Required. The KYC group slug the customer is verifying against.
    public let slug: String
    /// Required. End user's display name.
    public let name: String
    /// Required. The tier (level) slug the customer starts on, e.g. `tier_1`.
    public let levelSlug: String

    /// Optional billing-line alias used by verification-link integrations.
    public let vName: String?
    /// `"test"` (default) or `"live"`.
    public let environment: APIEnvironment?
    /// Presentation mode forwarded to the widget. `.modal` is the default
    /// for native iOS hosts — the widget renders its own centred card with
    /// backdrop, and the WKWebView fills the screen.
    public let display: Display
    /// Override the GraphQL endpoint (advanced; defaults to the prod URL
    /// baked into the widget bundle).
    public let gqlEndpoint: URL?
    /// Verbose console logging inside the widget.
    public let debug: Bool

    /// Where to load the widget HTML from. ``KYCWidgetEnvironment/production``
    /// by default. Switch to ``KYCWidgetEnvironment/custom(_:)`` while
    /// integrating against staging.
    public let widgetEnvironment: KYCWidgetEnvironment

    public init(
        publicKey: String,
        userRef: String,
        slug: String,
        name: String,
        levelSlug: String,
        vName: String? = nil,
        environment: APIEnvironment? = nil,
        display: Display = .modal,
        gqlEndpoint: URL? = nil,
        debug: Bool = false,
        widgetEnvironment: KYCWidgetEnvironment = .production
    ) {
        self.publicKey = publicKey
        self.userRef = userRef
        self.slug = slug
        self.name = name
        self.levelSlug = levelSlug
        self.vName = vName
        self.environment = environment
        self.display = display
        self.gqlEndpoint = gqlEndpoint
        self.debug = debug
        self.widgetEnvironment = widgetEnvironment
    }

    /// `"test"` vs `"live"` — forwarded as the widget's `environment` query param.
    public enum APIEnvironment: String, Sendable, Equatable {
        case test, live
    }

    /// Widget presentation mode. The native host doesn't change layout based
    /// on this — it just forwards the value to the widget, which paints its
    /// own modal or inline layout accordingly.
    public enum Display: String, Sendable, Equatable {
        case modal, inline
    }

    /// Internal: validate that all required fields are present and non-empty.
    /// Throws ``KYCWidgetError/missingRequiredConfig(_:)`` otherwise.
    func validate() throws {
        let required: [(String, String)] = [
            ("publicKey", publicKey),
            ("userRef", userRef),
            ("slug", slug),
            ("name", name),
            ("levelSlug", levelSlug),
        ]
        for (label, value) in required where value.isEmpty {
            throw KYCWidgetError.missingRequiredConfig(label)
        }
    }

    /// Build the URL the WKWebView loads. Mirrors `buildIframeUrl` in
    /// `iframeLoader.ts` — same field names, same order doesn't matter.
    public func buildURL() throws -> URL {
        try validate()
        var components = URLComponents(
            url: widgetEnvironment.baseURL,
            resolvingAgainstBaseURL: false
        )
        var items: [URLQueryItem] = [
            URLQueryItem(name: "publicKey", value: publicKey),
            URLQueryItem(name: "userRef", value: userRef),
            URLQueryItem(name: "slug", value: slug),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "levelSlug", value: levelSlug),
            URLQueryItem(name: "display", value: display.rawValue),
        ]
        if let vName { items.append(URLQueryItem(name: "vName", value: vName)) }
        if let environment {
            items.append(URLQueryItem(name: "environment", value: environment.rawValue))
        }
        if let gqlEndpoint {
            items.append(URLQueryItem(name: "gqlEndpoint", value: gqlEndpoint.absoluteString))
        }
        if debug { items.append(URLQueryItem(name: "debug", value: "true")) }

        components?.queryItems = items
        components?.path = "/"
        guard let url = components?.url else {
            throw KYCWidgetError.invalidURL
        }
        return url
    }
}
