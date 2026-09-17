Pod::Spec.new do |s|
  s.name          = "KYCWidget"
  # Informational only. `main` is the release channel, so this is not used to
  # resolve anything; it exists because CocoaPods requires the field. Bump it
  # when the release line changes, to match Android's `releaseLine`.
  s.version       = "0.5.0"
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
  # in .gitlab-ci.yml; the URL MUST match that job's MIRROR_URL.
  #
  # Tracks `main` rather than a tag: merging to main is the release, and
  # nothing is pushed to CocoaPods Trunk any more. Consumers point at the
  # branch directly:
  #
  #   pod 'KYCWidget', :git => 'https://github.com/talktothelaw/kyc-insight.git',
  #                    :branch => 'main'
  s.source        = {
    :git => "https://github.com/talktothelaw/kyc-insight.git",
    :branch => "main"
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
