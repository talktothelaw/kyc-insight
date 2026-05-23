import Foundation

/// JavaScript injected into the widget WebView at document start.
///
/// The widget posts lifecycle events to `window.parent` via
/// `window.parent.postMessage({ source:'kyc-widget-v2', type, payload }, '*')`
/// (see `kyc-web-wiget-v2/src/main.tsx:useParentBridge`). In a web iframe
/// the parent is the loader page; in our WKWebView there's no parent frame,
/// so we rewrite `window.parent.postMessage` to forward directly to the
/// native side via `window.webkit.messageHandlers.kycBridge.postMessage(...)`.
///
/// The same script also installs a listener on `window` so the native side
/// can send commands back by calling `webView.evaluateJavaScript("window.postMessage({source:'kyc-widget-v2-host',type:'destroy'}, '*')")`.
enum BridgeUserScript {
    static let messageHandlerName = "kycBridge"

    /// The JS source. Injected at `.atDocumentStart` so the widget's bridge
    /// code, which runs in a React `useEffect`, sees the shim already in place.
    static let source: String = """
    (function() {
      'use strict';
      if (window.__kycBridgeInstalled) return;
      window.__kycBridgeInstalled = true;

      var nativeHandler = function(msg) {
        try {
          window.webkit.messageHandlers.\(messageHandlerName).postMessage(msg);
        } catch (e) {
          // No native handler — running standalone (e.g. dev server in
          // Mobile Safari). Silently no-op.
        }
      };

      // Forward window.parent.postMessage(...) → native. The widget thinks
      // it's posting to a parent iframe; we capture it here.
      try {
        if (window.parent && window.parent !== window) {
          var originalParentPost = window.parent.postMessage.bind(window.parent);
          window.parent.postMessage = function(message, targetOrigin, transfer) {
            nativeHandler(message);
            try { originalParentPost(message, targetOrigin, transfer); } catch (_) {}
          };
        }
      } catch (_) {}

      // Always also forward direct window.parent === window posts. This
      // covers the "no real iframe parent" case — useParentBridge() checks
      // `window.parent !== window` and bails when they're equal, but if the
      // widget ever posts to window itself (or via dispatchEvent) we still
      // see it.
      var originalWindowPost = window.postMessage.bind(window);
      window.postMessage = function(message, targetOrigin, transfer) {
        // Only mirror widget-sourced messages — don't echo our own host
        // commands back to native.
        try {
          if (message && message.source === 'kyc-widget-v2') {
            nativeHandler(message);
          }
        } catch (_) {}
        try { originalWindowPost(message, targetOrigin, transfer); } catch (_) {}
      };

      // Pretend we have a parent so `window.parent !== window` is truthy
      // inside the widget's `isInsideParent()` check. WKWebView always has
      // `window.parent === window` for top-level loads, which would otherwise
      // make the widget skip the bridge entirely. The widget's own bridge
      // code uses this signal to decide whether to post lifecycle events.
      try {
        if (window.parent === window) {
          Object.defineProperty(window, 'parent', {
            configurable: true,
            get: function() { return { postMessage: window.postMessage }; }
          });
        }
      } catch (_) {}
    })();
    """
}
