// swift-tools-version: 5.9
//
// KYC Insight Widget — iOS Swift Package.
//
// A thin native host that loads the KYC Insight verification widget in a
// WKWebView and bridges its lifecycle events back to host-app callbacks.
// The widget itself (the entire verification UI, all field kinds, NIN /
// BVN / CAC flows, document upload, sanctions screening, etc.) lives at
// the widget origin — this SDK is the transport + permissions +
// presentation chrome.
//
// Architecture mirrors the web embed loader (`kyc-web-wiget-v2/src/sdk/
// iframeLoader.ts`): same query-param URL shape, same postMessage envelope,
// same lifecycle events. Switching between iOS and web SDKs is a transport
// change, not a protocol change.
import PackageDescription

let package = Package(
    name: "KYCWidget",
    platforms: [
        // iOS 14 baseline gives us SwiftUI presentation helpers and modern
        // WKWebView APIs. iOS 15 unlocks `requestMediaCapturePermissionFor`
        // which removes the camera/mic prompt double-tap on first use — we
        // detect at runtime so iOS 14 still works (just with the legacy
        // AVCaptureDevice.requestAccess pre-flight).
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "KYCWidget",
            targets: ["KYCWidget"]
        ),
    ],
    targets: [
        .target(
            name: "KYCWidget",
            path: "Sources/KYCWidget",
            resources: [
                // The brand logos shipped in the package bundle — same PNGs
                // the web widget ships in `kyc-web-wiget-v2/src/assets/`.
                // Accessed via `Bundle.module` (see `BrandImages.swift`).
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "KYCWidgetTests",
            dependencies: ["KYCWidget"],
            path: "Tests/KYCWidgetTests"
        ),
    ]
)
