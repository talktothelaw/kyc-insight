import Foundation

/// Configuration accepted by ``KYCWidget``. Mirrors the web widget's config
/// field-for-field so the same backend integration parameters work for
/// both — but the native iOS SDK actually USES these values to drive its
/// own GraphQL calls and SwiftUI rendering, rather than passing them as
/// query params to a WKWebView.
public struct KYCWidgetConfig: Sendable, Equatable {
    public let publicKey: String
    public let userRef: String
    public let slug: String
    public let name: String
    public let levelSlug: String
    public let vName: String?
    public let apiEnvironment: APIEnvironment
    public let display: Display
    /// Override the GraphQL endpoint. Defaults to the production URL.
    public let gqlEndpoint: URL
    public let debug: Bool

    /// Opt into the bundled offline demo schema instead of calling the
    /// backend. Use this when integrating the SDK against a publicKey that
    /// can't be reached from the device (e.g. while iterating on UI in the
    /// simulator). The default is `false` — production hosts always hit
    /// the real GraphQL endpoint and surface errors loudly.
    public let demoMode: Bool

    public init(
        publicKey: String,
        userRef: String,
        slug: String,
        name: String,
        levelSlug: String,
        vName: String? = nil,
        apiEnvironment: APIEnvironment = .live,
        display: Display = .modal,
        gqlEndpoint: URL = KYCWidgetConfig.defaultGQLEndpoint,
        debug: Bool = false,
        demoMode: Bool = false
    ) {
        self.publicKey = publicKey
        self.userRef = userRef
        self.slug = slug
        self.name = name
        self.levelSlug = levelSlug
        self.vName = vName
        self.apiEnvironment = apiEnvironment
        self.display = display
        self.gqlEndpoint = gqlEndpoint
        self.debug = debug
        self.demoMode = demoMode
    }

    public static let defaultGQLEndpoint: URL = URL(string: "https://kyc-api.netapps.ng/graphql")!

    public enum APIEnvironment: String, Sendable, Equatable {
        case test, live
    }

    /// Native presentation mode. `.modal` presents over the host's view
    /// hierarchy as a full-screen sheet. `.embed` returns a UIViewController
    /// the host can place anywhere (push, container, tab, etc.).
    public enum Display: String, Sendable, Equatable {
        case modal, embed
    }

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
}
