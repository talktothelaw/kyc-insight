# KYCWidget — iOS SDK

Drop-in iOS SDK for KYC Insight identity verification. Configure it with your merchant keys, present it from any `UIViewController`, and observe lifecycle callbacks.

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

Add these to your app's `Info.plist`. iOS will deny access without them and the verification flow will stall.

```xml
<key>NSCameraUsageDescription</key>
<string>Used to capture documents and complete liveness checks during identity verification.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Used to record short audio during liveness video capture.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Used to upload identity documents from your photo library.</string>
```

Customize the strings — they appear verbatim in the OS prompts your user sees.

---

## Quick start

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

---

## API reference

### `KYCWidgetConfig`

| Field | Required | Description |
|---|---|---|
| `publicKey` | yes | Merchant's `NA_PUB_*` key. |
| `userRef` | yes | Stable identifier for the end user. Reusing the same value returns the same customer record. |
| `slug` | yes | KYC group slug. |
| `name` | yes | End-user display name. |
| `levelSlug` | yes | Starting tier slug (e.g. `tier_1`). |
| `vName` | no | Billing-line alias for verification-link integrations. |
| `environment` | no | `.test` (default) or `.live`. |
| `display` | no | `.modal` (default) or `.inline`. |
| `gqlEndpoint` | no | Override the backend GraphQL URL. Defaults to production. |
| `debug` | no | Enable verbose console logging. |
| `widgetEnvironment` | no | `.production` (default) or `.custom(URL)` for staging / dev. |

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
| `onReady` | Widget mounted and ready for user input. | None |
| `onLevelChange` | User moved to a new level (tier). | `KYCWidgetLevel { slug, index }` |
| `onLevelApproved` | A level just flipped to fully approved. Always fires before `onLevelChange` when the approval auto-advances to the next level. | `KYCWidgetLevel { slug, index }` |
| `onSubmit` | A section was successfully submitted to the backend. | `AnyJSON` |
| `onSuccess` | Every tier and section is approved or submitted. | `AnyJSON` |
| `onError` | Fatal load or submission failure. | `KYCWidgetError` |
| `onClose` | Widget destroyed — by the user closing it or your app calling `destroy()`. | None |

---

## Permissions

`present(from:)` pre-warms the camera and microphone OS prompts before verification begins, so users don't see a prompt mid-flow. Pass `prewarmPermissions: false` to skip this.

To also pre-warm photo-library access (for document upload):

```swift
MediaPermissions.prewarmPhotoLibrary { status in
    // optional callback once the user decides
}
```

---

## Modal vs inline

**Modal** (default) — full-screen overlay:

```swift
KYCWidgetConfig(/* … */, display: .modal)
widget.present(from: self)
```

**Inline** — embed inside your own view controller:

```swift
KYCWidgetConfig(/* … */, display: .inline)

let vc = try widget.makeViewController()
addChild(vc)
view.addSubview(vc.view)
// …apply your layout constraints…
vc.didMove(toParent: self)
```

The presentation chrome is yours — push onto a nav stack, present as a sheet, embed inside a tab.

---

## Custom environments (staging / dev)

```swift
let config = KYCWidgetConfig(
    /* required fields */,
    widgetEnvironment: .custom(URL(string: "https://staging-kyc.example.com")!)
)
```

To also override the GraphQL endpoint, pass `gqlEndpoint`.

---

## Troubleshooting

**The widget loads but the camera step shows "Allow camera access".**
Add `NSCameraUsageDescription` to your `Info.plist`.

**`onError` fires immediately with `"The Internet connection appears to be offline."`.**
The device couldn't reach the configured widget origin. Check `widgetEnvironment`.

**Widget renders, but lifecycle callbacks never fire.**
If you subclassed `KYCWidgetViewController`, make sure your `viewDidLoad` calls `super.viewDidLoad()`.

---

## Running the example app

```sh
open Example/KYCWidgetExample.xcodeproj
```

Build to a simulator or device. The example shows a form with the widget config fields prefilled and an event log that mirrors every lifecycle callback as it fires.
