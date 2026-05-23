# KYCWidget — iOS SDK

Native iOS host for the **KYC Insight verification widget**. Loads the widget page in a `WKWebView`, bridges lifecycle events back to your host app via Swift closure callbacks, and manages the camera / microphone / photo-library permissions the widget needs for document scan, liveness checks, and document upload.

The widget itself — NIN consent, BVN, CAC business lookup, document upload, liveness checks (NINAuth + internal), sanctions / PEP screening — runs **inside** the WKWebView. This SDK is the transport, permissions, and presentation chrome. Same code that powers the [web embed](../kyc-web-wiget-v2/) powers the iOS app; switching between iOS and web is a transport change, not a protocol change.

---

## Install

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…**

```
https://github.com/netapps/kyc-widget-ios.git
```

Or in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/netapps/kyc-widget-ios.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "KYCWidget", package: "kyc-widget-ios"),
    ]),
]
```

### CocoaPods

```ruby
pod 'KYCWidget', '~> 0.1'
```

Minimum iOS: **14.0**.

---

## Info.plist — required keys

The widget uses the camera (document scan + liveness), microphone (liveness video audio track), and photo library (document upload). Add these to your app's `Info.plist` — iOS will refuse access without them.

```xml
<key>NSCameraUsageDescription</key>
<string>Used to capture documents and complete liveness checks during identity verification.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Used to record short audio during liveness video capture.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Used to upload identity documents from your photo library.</string>
```

Customize the descriptions for your audience — they appear verbatim in the OS prompts the user sees.

---

## Usage — minimum viable integration

```swift
import KYCWidget
import UIKit

class HomeViewController: UIViewController {

    @IBAction func startVerification() {
        let config = KYCWidgetConfig(
            publicKey: "NA_PUB_PROD_xxxxxxxxxxxxxxxxxxxxxxxx",
            userRef:   "user-1234",
            slug:      "supplier_registration",
            name:      "Lawrence Olu",
            levelSlug: "tier_1"
        )

        let widget = KYCWidget(config: config)
        widget.onSuccess = { _ in
            print("Verification complete")
        }
        widget.onError = { error in
            print("Verification error:", error.localizedDescription)
        }
        widget.onClose = {
            print("Widget dismissed")
        }
        widget.present(from: self)
    }
}
```

That's it. The widget handles everything else — the customer's screens, the camera flows, the document upload, the backend round-trips. Your app observes lifecycle events.

---

## Public API

### `KYCWidgetConfig`

Mirrors the web SDK's `KycWidgetConfig` field-for-field. Each field becomes a query param on the URL the widget loads from, so the same backend integration works for both.

| Field | Required | Description |
|---|---|---|
| `publicKey` | yes | Merchant's `NA_PUB_*` key. |
| `userRef` | yes | Stable identifier for the end user. Reusing it returns the same customer record. |
| `slug` | yes | KYC group slug. |
| `name` | yes | End-user display name. |
| `levelSlug` | yes | Starting tier slug (e.g. `tier_1`). |
| `vName` | no | Billing-line alias used by verification-link integrations. |
| `environment` | no | `.test` (default) or `.live`. |
| `display` | no | `.modal` (default) or `.inline`. |
| `gqlEndpoint` | no | Override the backend GraphQL URL. Advanced; defaults to prod. |
| `debug` | no | Verbose console logging inside the widget. |
| `widgetEnvironment` | no | `.production` (default) or `.custom(URL)` to point at staging / a dev server. |

### `KYCWidget`

```swift
public final class KYCWidget {
    public init(config: KYCWidgetConfig)

    // Lifecycle callbacks — all fire on the main thread.
    public var onReady:         (() -> Void)?
    public var onLevelChange:   ((KYCWidgetLevel) -> Void)?
    public var onLevelApproved: ((KYCWidgetLevel) -> Void)?
    public var onSubmit:        ((AnyJSON?) -> Void)?
    public var onSuccess:       ((AnyJSON?) -> Void)?
    public var onError:         ((KYCWidgetError) -> Void)?
    public var onClose:         (() -> Void)?

    // Presentation.
    public func present(from presenter: UIViewController,
                        animated: Bool = true,
                        prewarmPermissions: Bool = true,
                        completion: (() -> Void)? = nil)
    public func makeViewController() throws -> KYCWidgetViewController
    public func destroy()
}
```

### Lifecycle callbacks

| Callback | When it fires | Payload |
|---|---|---|
| `onReady` | Widget mounted, ready for input. | None |
| `onLevelChange` | Customer moved to a new level (tier). | `KYCWidgetLevel { slug, index }` |
| `onLevelApproved` | A level just flipped to fully approved (every requirement inside reached `approved`). Covers both auto-approving levels (NIN / BVN that complete synchronously) and manual approvals. **Always fires before `onLevelChange`** when the approval auto-advances to the next level. | `KYCWidgetLevel { slug, index }` |
| `onSubmit` | A section was successfully submitted to the backend. | Raw `AnyJSON` payload |
| `onSuccess` | Every tier and section is approved or submitted. | Raw `AnyJSON` payload |
| `onError` | Fatal load or submission failure. | `KYCWidgetError` |
| `onClose` | Widget destroyed — either the customer closed it or your app called `destroy()`. | None |

---

## Permissions — pre-warm vs lazy

By default, `present(from:)` pre-warms the camera + microphone OS prompts up front, before the WKWebView loads. This avoids a confusing pause when the customer first hits the document-scan or liveness step. Set `prewarmPermissions: false` to skip the pre-flight — the widget then prompts only when it actually needs the camera, which is fine but adds a delay mid-flow.

You can also pre-warm photo-library access if your flow involves document upload:

```swift
MediaPermissions.prewarmPhotoLibrary { status in
    // optional callback when the user has decided
}
```

---

## Modal vs inline

```swift
// Modal — full-screen overlay. The widget paints its own centered card
// with a dimmed backdrop. This is the default for native iOS hosts.
KYCWidgetConfig(/* … */, display: .modal)

// Inline — widget renders flat to fill its container. Use this when
// embedding inside your own custom UIViewController.
KYCWidgetConfig(/* … */, display: .inline)
let vc = try widget.makeViewController()
addChild(vc)
view.addSubview(vc.view)
// …layout constraints…
vc.didMove(toParent: self)
```

The presentation chrome is your app's — push onto a nav stack, present as a sheet, embed inside a tab. The SDK never adds its own modal backdrop or close button at the iOS layer; all visual chrome comes from inside the widget WebView.

---

## Custom environments (staging / dev)

```swift
let config = KYCWidgetConfig(
    /* required fields */,
    widgetEnvironment: .custom(URL(string: "https://staging-kyc.example.com")!)
)
```

The `widgetEnvironment` controls only where the WebView loads the widget HTML from. The backend API URL is baked into the widget bundle; if you need to override the GraphQL endpoint too, pass `gqlEndpoint`.

---

## Architecture

```
┌─ iOS host app ─────────────────────────────────────────┐
│                                                        │
│  let widget = KYCWidget(config: KYCWidgetConfig(…))    │
│  widget.onLevelApproved = { … }                        │
│  widget.present(from: viewController)                  │
│                                                        │
│  ┌─ KYCWidgetViewController ────────────────────────┐  │
│  │  WKWebView                                       │  │
│  │  src = "https://kyc-verify-v2.netapps.ng/        │  │
│  │         ?publicKey=…&slug=…&userRef=…&           │  │
│  │          name=…&levelSlug=…&display=modal"       │  │
│  │                                                  │  │
│  │  ◄── webkit.messageHandlers.kycBridge.postMessage│  │
│  │      forwards { source:'kyc-widget-v2',          │  │
│  │                 type,payload } envelopes         │  │
│  │  ──► evaluateJavaScript posts                    │  │
│  │      { source:'kyc-widget-v2-host',type:'destroy'│  │
│  │  }                                               │  │
│  └──────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────┘
```

The bridge envelope matches the [web embed loader](../kyc-web-wiget-v2/src/sdk/iframeLoader.ts) byte-for-byte. Same lifecycle events, same payload shapes, same backend.

---

## Troubleshooting

**The widget loads but the camera flow shows "Allow camera access".**
Add `NSCameraUsageDescription` to `Info.plist`. iOS will refuse to surface the camera prompt without it, and the widget will sit on the "checking permissions" step until the OS times out.

**`onError` fires immediately with `"The Internet connection appears to be offline."`.**
The WKWebView couldn't reach the widget origin. Check your `widgetEnvironment` — `.production` requires real internet; `.custom(URL)` requires the URL to be reachable from the device / simulator.

**Widget renders, but lifecycle callbacks never fire.**
The bridge shim couldn't install. This usually means the user content controller didn't get the user script — verify you haven't subclassed `KYCWidgetViewController` and overridden `viewDidLoad` without calling `super`.

**iOS 14 hits a permission prompt on every camera step.**
iOS 14 lacks `WKUIDelegate.requestMediaCapturePermissionFor`, so WKWebView falls back to per-page prompting. iOS 15+ uses the single delegate callback and gets one prompt per origin. Pre-warming via `MediaPermissions.prewarm()` reduces this further.

**Example app target name in Xcode still says `LiveAndAiChatExample`.**
Open `Example/LiveAndAiChatExample.xcodeproj` and rename the target — the Swift code already uses `KYCWidgetExampleApp` and imports `KYCWidget`, but the Xcode project file isn't auto-rewritten. The package dependency in the project also needs to point at the `KYCWidget` product (was `LiveAndAiChat` in the legacy scaffold).

---

## Running the example app

```sh
open Example/LiveAndAiChatExample.xcodeproj
```

1. Xcode will offer to re-resolve the local package dependency — point it at the repo root.
2. In **General → Frameworks, Libraries, and Embedded Content**, remove `LiveAndAiChat` and add `KYCWidget` from the local package.
3. Build to a simulator or device. The example shows a form with the widget config fields prefilled and an event log that mirrors every lifecycle callback as it fires.

---

## What's NOT in this SDK (and where it lives instead)

| Concern | Lives in |
|---|---|
| Verification UI (forms, NIN/BVN consent, document upload, liveness, sanctions screening) | The widget page itself, served from the widget origin. |
| Backend API (GraphQL, billing, approval workflow) | [`kyc-backend`](../kyc-backend) |
| Merchant dashboard (configure flows, review submissions) | [`kyc-frontend`](../kyc-frontend) |
| Web embed loader (same architecture, browser host) | [`kyc-web-wiget-v2`](../kyc-web-wiget-v2) |

Anything you can't fix from the iOS side, you can fix in the widget itself — same code, same backend.
