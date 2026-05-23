import Foundation
import WebKit

/// Decodes incoming `WKScriptMessage`s from the bridge JS shim and routes
/// lifecycle events to typed callback closures on ``KYCWidget``.
///
/// Lives on a separate non-`@objc` object so the WebView's
/// `WKUserContentController` can hold a weak reference to it without us
/// having to make ``KYCWidget`` inherit from `NSObject` or import UIKit
/// from the public-API layer.
final class WebViewBridge: NSObject, WKScriptMessageHandler {
    weak var widget: KYCWidget?
    init(widget: KYCWidget) {
        self.widget = widget
    }

    // MARK: - Inbound (widget → native)

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == BridgeUserScript.messageHandlerName else { return }
        guard let widget else { return }

        // The shim forwards the raw JS object; `body` is usually a
        // `[String: Any]`. Round-trip through JSON to decode into our
        // typed `BridgeMessage`.
        guard JSONSerialization.isValidJSONObject(message.body),
              let data = try? JSONSerialization.data(withJSONObject: message.body),
              let envelope = try? JSONDecoder().decode(BridgeMessage.self, from: data),
              envelope.source == BridgeMessage.widgetSource else {
            return
        }

        DispatchQueue.main.async {
            widget.dispatch(envelope)
        }
    }

    // MARK: - Outbound (native → widget)

    /// Post a `{ source: 'kyc-widget-v2-host', type, payload }` message into
    /// the widget. Used for host-initiated commands (e.g. `destroy`).
    static func post(
        type: String,
        payload: [String: Any]? = nil,
        into webView: WKWebView
    ) {
        var dict: [String: Any] = ["source": BridgeMessage.hostSource, "type": type]
        if let payload { dict["payload"] = payload }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        // Use `window.postMessage` so the widget's `onCommand` listener picks it up.
        let js = "window.postMessage(\(json), '*');"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}
