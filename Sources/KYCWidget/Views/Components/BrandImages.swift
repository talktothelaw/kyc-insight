#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Bundle-resource accessors for the brand PNGs the package ships. Same
/// files the web widget uses (`kyc-web-wiget-v2/src/assets/`).
@available(iOS 15.0, *)
enum BrandImages {

    /// `kyc_insight_logo.png` — the small cube + wordmark used in the
    /// widget footer.
    static var kycInsightLogo: Image? {
        loadImage(named: "kyc_insight_logo")
    }

    /// `netapps_logo.png` — Netapps Marketplace wordmark, used in
    /// "Powered by" attribution when the host needs the full brand.
    static var netappsLogo: Image? {
        loadImage(named: "netapps_logo")
    }

    private static func loadImage(named name: String) -> Image? {
        // Order of lookups: the build's dedicated resource bundle first,
        // then the main app bundle as a last resort so integrators
        // dropping the PNGs into their own asset catalog still see them.
        if let ui = UIImage(named: name, in: resourceBundle, with: nil) {
            return Image(uiImage: ui)
        }
        if let ui = UIImage(named: name) {
            return Image(uiImage: ui)
        }
        return nil
    }

    /// Resource bundle that holds the brand PNGs.
    ///
    /// SPM defines `SWIFT_PACKAGE` and synthesises `Bundle.module` from
    /// the `resources:` block in `Package.swift`. CocoaPods does neither,
    /// so referencing `Bundle.module` unconditionally is a compile error
    /// for pod consumers. Under CocoaPods the podspec's
    /// `resource_bundles = { "KYCWidget" => ... }` produces a sibling
    /// `KYCWidget.bundle` next to the framework binary — `Bundle(for:
    /// ResourceMarker.self)` locates that framework bundle, and the
    /// `url(forResource:)` lookup walks into the nested resource bundle.
    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        let frameworkBundle = Bundle(for: ResourceMarker.self)
        if let nestedURL = frameworkBundle.url(forResource: "KYCWidget", withExtension: "bundle"),
           let nested = Bundle(url: nestedURL) {
            return nested
        }
        return frameworkBundle
        #endif
    }
}

#if !SWIFT_PACKAGE
// Empty marker class used solely as a Bundle anchor in the CocoaPods
// build (`Bundle(for: AnyClass)` requires a type the framework owns).
// Internal — never instantiated.
private final class ResourceMarker {}
#endif
#endif
