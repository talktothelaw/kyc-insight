Pod::Spec.new do |s|
  s.name          = "KYCWidget"
  s.version       = "0.3.0"
  s.summary       = "Native iOS SDK for the KYC Insight verification widget."
  s.description   = <<~DESC
    KYCWidget is the iOS host for the KYC Insight verification widget.
    It loads the widget page in a WKWebView and bridges lifecycle events
    (onReady, onLevelChange, onLevelApproved, onSubmit, onSuccess, onError,
    onClose) back to your host app via Swift closure callbacks.

    All verification UI — NIN consent, BVN, CAC business lookup, document
    upload, liveness checks, sanctions / PEP screening — runs inside the
    widget page. The SDK is transport + permissions + presentation chrome.
    Add NSCameraUsageDescription, NSMicrophoneUsageDescription, and
    NSPhotoLibraryUsageDescription to your Info.plist so the widget can
    request media capture and document upload permissions.
  DESC
  s.homepage      = "https://kyc-verify-v2.netapps.ng"
  s.license       = { :type => "MIT", :file => "LICENSE" }
  s.author        = {
    "Netapps Marketplace Limited" => "support@netapps.com.ng"
  }
  # Must match Package.swift's `platforms: [.iOS(.v15)]`. KYCWidget and
  # LocationLoader use APIs annotated `@available(iOS 15.0, *)` (modern
  # WKWebView media-capture permissions, CoreLocation async helpers);
  # 14.0 here would let Trunk accept the spec but every consumer build
  # would error at compile time.
  s.platform      = :ios, "15.0"
  s.swift_version = "5.9"
  # GitHub mirror populated by the GitLab `mirror_to_talktothelaw` CI job
  # in .gitlab-ci.yml. CocoaPods Trunk fetches tagged sources from this
  # URL during `pod trunk push`, so the value MUST match the CI mirror
  # target (MIRROR_URL). Updating one without the other will break
  # publishing.
  s.source        = {
    :git => "https://github.com/talktothelaw/kyc-insight.git",
    :tag => s.version.to_s
  }

  s.source_files  = "Sources/KYCWidget/**/*.swift"

  # SPM auto-bundles `Sources/KYCWidget/Resources/**` via the `.process`
  # declaration in Package.swift and exposes them through `Bundle.module`.
  # CocoaPods needs an explicit `resource_bundles` to do the same — it
  # generates a `KYCWidget.bundle` next to the framework so the runtime
  # lookup in BrandImages.swift can find the PNGs after `pod install`.
  # Bundle name MUST stay `KYCWidget` — BrandImages.swift looks for that
  # exact filename under the SWIFT_PACKAGE fallback path.
  s.resource_bundles = {
    "KYCWidget" => ["Sources/KYCWidget/Resources/**/*"]
  }

  s.frameworks    = "Foundation", "UIKit", "WebKit", "AVFoundation",
                    "Photos", "PhotosUI", "Combine"
end
