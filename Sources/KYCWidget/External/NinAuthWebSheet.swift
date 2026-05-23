#if canImport(SwiftUI) && canImport(UIKit) && canImport(WebKit)
import SwiftUI
import UIKit
import WebKit

/// External NIN / DL / Passport verification sheet.
///
/// The backend hands back `widgetConfig.widgetUrl` — but that URL is a
/// JavaScript file (the NetApps NINAuth SDK), NOT a renderable page.
/// The web widget injects it as a `<script>` tag and then calls
/// `new window.InitNetAppsNinVerification(clientId, userRef, scope, …)`
/// followed by `instance.verify({ onSuccess, onError, … })`. Opening the
/// raw `widgetUrl` in WKWebView shows nothing useful.
///
/// This sheet renders an HTML harness inline that:
///   1. Loads the SDK script from `widgetConfig.widgetUrl`.
///   2. Constructs the verification instance with the same positional
///      args as the web (`clientId`, `userRef`, `scope`, `'true'`,
///      `'false'`, `'false'`, logo URL).
///   3. Calls `instance.verify(...)` and bridges every callback through
///      `window.webkit.messageHandlers.ninauth.postMessage(...)` back to
///      Swift so the parent field gets `reference` on success or a
///      typed error on failure.
@available(iOS 15.0, *)
struct NinAuthWebSheet: View {
    let widgetUrl: URL
    let clientId: String
    let userRef: String
    let scope: String
    let onResult: (Result<String, KYCWidgetError>) -> Void

    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            NinAuthWebView(
                widgetUrl: widgetUrl,
                clientId: clientId,
                userRef: userRef,
                scope: scope,
                onResult: { result in
                    presentationMode.wrappedValue.dismiss()
                    onResult(result)
                }
            )
            .navigationBarTitle("Identity verification", displayMode: .inline)
            .navigationBarItems(
                trailing: Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                    onResult(.failure(.externalConsentFailed(message: "User cancelled.")))
                }
            )
        }
    }
}

@available(iOS 15.0, *)
struct NinAuthWebView: UIViewRepresentable {
    let widgetUrl: URL
    let clientId: String
    let userRef: String
    let scope: String
    let onResult: (Result<String, KYCWidgetError>) -> Void

    /// Logo shown inside the SDK dialog. Matches the web's
    /// `NIN_WIDGET_LOGO_URL` in `NinConsentField.tsx`.
    private static let logoUrl = "https://kyc.netapps.ng/netappsLogo.png"

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "ninauth")

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // The HTML harness needs a non-`about:blank` baseURL so the SDK
        // script can issue cross-origin requests back to its own host.
        // Using the widget URL's origin as the baseURL keeps the browser
        // happy and matches how the web evaluates the script in-page.
        let baseURL = widgetUrl.deletingLastPathComponent()
        webView.loadHTMLString(html(), baseURL: baseURL)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func html() -> String {
        // Escape only what's necessary — these values come from the
        // backend's initConsent response, which we already trust.
        let widget = widgetUrl.absoluteString
        return """
        <!DOCTYPE html>
        <html><head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
          <title>Verification</title>
          <style>
            html, body { margin: 0; padding: 0; height: 100%; background: #f8fafc; -webkit-text-size-adjust: 100%; }
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; color: #1f2937; }
            .wrap { display: flex; align-items: center; justify-content: center; height: 100%; padding: 16px; box-sizing: border-box; }
            .card { background: #fff; border-radius: 12px; padding: 20px; box-shadow: 0 2px 10px rgba(15,23,42,0.06); text-align: center; max-width: 420px; }
            .title { font-weight: 600; font-size: 15px; margin: 0 0 6px; }
            .sub { font-size: 13px; color: #64748b; margin: 0; line-height: 1.5; }
            .spinner { width: 22px; height: 22px; border-radius: 50%; border: 2px solid #e2e8f0; border-top-color: #1E3A8A; animation: spin 0.8s linear infinite; margin: 0 auto 12px; }
            @keyframes spin { to { transform: rotate(360deg); } }
          </style>
        </head><body>
          <div class="wrap"><div class="card" id="status">
            <div class="spinner"></div>
            <p class="title">Loading verification…</p>
            <p class="sub">Please wait — opening the provider's secure window.</p>
          </div></div>
          <script src="\(widget)"></script>
          <script>
          (function() {
            var post = function(msg) {
              try { window.webkit.messageHandlers.ninauth.postMessage(msg); } catch (e) {}
            };
            var statusEl = document.getElementById('status');
            var updateStatus = function(title, sub) {
              if (!statusEl) return;
              statusEl.innerHTML = '<p class="title">' + title + '</p>' +
                                   '<p class="sub">' + (sub || '') + '</p>';
            };
            var launch = function() {
              var Ctor = window.InitNetAppsNinVerification;
              if (!Ctor) {
                updateStatus('Verification unavailable', 'The provider SDK did not load. Please try again.');
                post({ type: 'error', message: 'NIN widget SDK did not register.' });
                return;
              }
              try {
                var inst = new Ctor(
                  \(jsString(clientId)),
                  \(jsString(userRef)),
                  \(jsString(scope.isEmpty ? "basic" : scope)),
                  'true', 'false', 'false',
                  \(jsString(Self.logoUrl))
                );
                inst.verify({
                  displayInKycError: true,
                  onReady:     function()  { post({ type: 'ready' }); },
                  onSubmitted: function()  { post({ type: 'submitted' }); },
                  onSuccess:   function(r) {
                    var ref = (r && r.res && r.res.reference) ? r.res.reference : null;
                    post({ type: 'success', reference: ref });
                  },
                  onError:     function(e) { post({ type: 'error', message: (e && e.message) ? e.message : 'Verification failed.' }); },
                  onFailed:    function(e) { post({ type: 'error', message: (e && e.message) ? e.message : 'Verification failed.' }); },
                  onCancel:    function()  { post({ type: 'cancel' }); },
                  onClose:     function()  { post({ type: 'close' }); }
                });
              } catch (err) {
                post({ type: 'error', message: String((err && err.message) || err) });
              }
            };
            // Two beats so the script tag has a chance to evaluate even on
            // slow networks; if SDK is already registered, fire immediately.
            if (window.InitNetAppsNinVerification) { launch(); }
            else { setTimeout(launch, 100); setTimeout(function(){ if (!window.__ninLaunched) launch(); }, 1500); }
          })();
          </script>
        </body></html>
        """
    }

    /// JSON-quote a string for safe inline JS embedding.
    private func jsString(_ s: String) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let str = String(data: d, encoding: .utf8),
           str.hasPrefix("["), str.hasSuffix("]") {
            return String(str.dropFirst().dropLast())
        }
        return "\"\(s)\""
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let parent: NinAuthWebView
        private var terminalFired = false
        init(_ parent: NinAuthWebView) { self.parent = parent }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "ninauth" else { return }
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "success":
                terminalFired = true
                let ref = (body["reference"] as? String) ?? ""
                if ref.isEmpty {
                    parent.onResult(.failure(.externalConsentFailed(message: "No verification reference returned.")))
                } else {
                    parent.onResult(.success(ref))
                }
            case "error":
                terminalFired = true
                let msg = (body["message"] as? String) ?? "Verification failed."
                parent.onResult(.failure(.externalConsentFailed(message: msg)))
            case "cancel":
                terminalFired = true
                parent.onResult(.failure(.externalConsentFailed(message: "User cancelled at provider.")))
            case "close":
                // Terminal cleanup — only treat as a cancel if no
                // success/error/cancel has fired (older SDK builds only
                // emit onClose for dismissal).
                if !terminalFired {
                    parent.onResult(.failure(.externalConsentFailed(message: "Verification window closed.")))
                }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onResult(.failure(.externalConsentFailed(message: error.localizedDescription)))
        }

        @available(iOS 15.0, *)
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }
    }
}
#endif
