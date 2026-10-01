Pod::Spec.new do |s|
  s.name          = "KYCWidget"
  # The published version, and the git tag consumers resolve. Trunk is
  # append-only, so this must be bumped for every push — re-pushing an
  # existing version is rejected.
  #
  # 1.0.0 aligns iOS with Android: ng.netapps:kyc-insight is on the 1.0 line
  # (1.0.36 at the time of writing) while this pod was still on 0.5.x. Same
  # product, same widget, two version lines that read as unrelated — which
  # made "which version are you on?" ambiguous for anyone supporting both
  # platforms. No API change is implied by the major bump; it is alignment.
  s.version       = "1.0.2"
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
  # A TAG, not a branch. CocoaPods Trunk refuses a branch source — "Git
  # sources should specify either a tag or a commit" — because a branch is
  # mutable and a published pod version must resolve to the same code
  # forever. The tag is pushed to GitLab and the mirror job copies it to
  # GitHub, which is where `pod trunk push` clones from during validation.
  #
  # Consumers need nothing special:  pod 'KYCWidget'
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
