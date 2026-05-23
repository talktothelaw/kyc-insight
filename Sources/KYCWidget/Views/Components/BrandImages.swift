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
        // `Bundle.module` resolves to the SwiftPM resource bundle the
        // `.process("Resources")` declaration in `Package.swift` produces.
        // For .xcframework / Cocoapods builds, fall back to the main bundle
        // search so integrators dropping the PNGs into their own asset
        // catalog still see them.
        if let ui = UIImage(named: name, in: .module, with: nil) {
            return Image(uiImage: ui)
        }
        if let ui = UIImage(named: name) {
            return Image(uiImage: ui)
        }
        return nil
    }
}
#endif
