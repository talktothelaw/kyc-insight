Pod::Spec.new do |s|
  s.name          = "KYCWidget"
  s.version       = "0.1.0"
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
  s.platform      = :ios, "14.0"
  s.swift_version = "5.9"
  s.source        = {
    :git => "https://github.com/netapps/kyc-widget-ios.git",
    :tag => s.version.to_s
  }

  s.source_files  = "Sources/KYCWidget/**/*.swift"
  s.frameworks    = "Foundation", "UIKit", "WebKit", "AVFoundation",
                    "Photos", "PhotosUI", "Combine"
end
