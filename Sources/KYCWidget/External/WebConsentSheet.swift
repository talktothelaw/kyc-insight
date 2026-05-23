#if canImport(SwiftUI) && canImport(UIKit) && canImport(WebKit)
import SwiftUI
import UIKit
import WebKit

/// External-consent web sheet.
///
/// THIS IS THE ONLY PLACE THE SDK USES `WKWebView`. The native renderer
/// handles everything else; this sheet exists because some consent
/// providers (Mono NIN, Mono BVN, NINAuth) host their authentication and
/// OTP flow on their own web page with no native iOS SDK. We load that
/// page in a sandboxed `WKWebView`, watch for the configured redirect URL,
/// extract the auth `reference` query param, and hand it back to the
/// native session.
@available(iOS 15.0, *)
struct WebConsentSheet: View {
    let initialURL: URL
    /// URL prefixes that signal completion. When the WKWebView navigates
    /// to any of these, the sheet pulls the `reference` (or `code`) query
    /// param and resolves with it.
    let successURLPrefixes: [String]
    let cancelURLPrefixes: [String]
    let onResult: (Result<String, KYCWidgetError>) -> Void

    @Environment(\.presentationMode) private var presentationMode
    /// Driven by `ConsentWebView`'s navigation delegate. While the page is
    /// still loading we cover the blank WKWebView with a native spinner +
    /// "Loading verification…" label — the WebView itself paints a white
    /// rectangle until first content render, which looks broken.
    @State private var isLoading = true

    var body: some View {
        NavigationView {
            ZStack {
                // Solid base layer — even if the overlay races the WebView's
                // first paint, the background never flashes white.
                Color(.systemBackground).ignoresSafeArea()
                ConsentWebView(
                    url: initialURL,
                    successPrefixes: successURLPrefixes,
                    cancelPrefixes: cancelURLPrefixes,
                    isLoading: $isLoading,
                    onResult: { result in
                        presentationMode.wrappedValue.dismiss()
                        onResult(result)
                    }
                )
                if isLoading {
                    LoadingOverlay()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            // Only animate AFTER the first commit — the initial overlay
            // appearance must be instant, not faded in from invisible.
            .animation(.easeInOut(duration: 0.18), value: isLoading)
            .navigationBarTitle("Verification", displayMode: .inline)
            .navigationBarItems(
                trailing: Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                    onResult(.failure(.externalConsentFailed(message: "User cancelled.")))
                }
            )
        }
    }
}

/// Native loading state for the consent sheet. UIKit `UIActivityIndicator`
/// via SwiftUI's `ProgressView` so the spinner matches the rest of iOS.
@available(iOS 15.0, *)
private struct LoadingOverlay: View {
    var body: some View {
        ZStack {
            // Solid background so the blank WKWebView doesn't bleed
            // through during the first 200ms before the page paints.
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                Text("Loading verification…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }
}

@available(iOS 15.0, *)
struct ConsentWebView: UIViewRepresentable {
    let url: URL
    let successPrefixes: [String]
    let cancelPrefixes: [String]
    @Binding var isLoading: Bool
    let onResult: (Result<String, KYCWidgetError>) -> Void

    /// JS message-handler names the i-gree BVN consent page tries when
    /// firing `BVN_CONSENT_RECEIVED` / `BVN_CONSENT_CLOSE_REQUESTED`. We
    /// register ALL of them so whichever one the page tries first lands.
    /// Names are case-sensitive and must match the page's allowlist
    /// (see contract §2.2).
    fileprivate static let bvnBridgeNames = ["bvnConsent", "BVNConsent", "kycBridge", "KycBridge"]

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        for name in Self.bvnBridgeNames {
            contentController.add(context.coordinator, name: name)
        }
        // Forward the WebView's `console.log/.warn/.error` to Swift so the
        // probe's diagnostics show up in Xcode's console. Without this the
        // probe's "I never got a postMessage" hints stay trapped inside
        // WebKit's hidden console.
        contentController.add(context.coordinator, name: "kycConsole")
        print("[KYC WebConsentSheet] registered bridge handlers: \(Self.bvnBridgeNames) + kycConsole — loading: \(url.absoluteString)")

        // Inject a small probe script BEFORE the page loads. It runs at
        // document_start, listens for the DOM CustomEvent fallback
        // (`bvn:consent-received`) AND captures any postMessage the page
        // sends to itself, then forwards them through our `bvnConsent`
        // handler. This guards against pages whose JS only reaches for
        // `window.parent`/`window.opener` (which don't exist for a
        // WKWebView root document) — without the probe, those messages
        // would never reach Swift even when the page dispatched them.
        let probeJS = """
        (function() {
          // Forward all console output to native so it shows in Xcode.
          ['log','warn','error','info','debug'].forEach(function(level) {
            var orig = console[level].bind(console);
            console[level] = function() {
              try {
                var parts = Array.prototype.slice.call(arguments).map(function(a) {
                  try { return typeof a === 'string' ? a : JSON.stringify(a); }
                  catch (e) { return String(a); }
                });
                window.webkit.messageHandlers.kycConsole.postMessage({ level: level, line: parts.join(' ') });
              } catch (e) {}
              orig.apply(console, arguments);
            };
          });
          var bridgeNames = \(Self.bvnBridgeNamesJSON);
          var send = function(payload, channel) {
            for (var i = 0; i < bridgeNames.length; i++) {
              var name = bridgeNames[i];
              try {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name]) {
                  window.webkit.messageHandlers[name].postMessage(payload);
                  return;
                }
              } catch (e) {}
            }
            console.log('[KYC bridge probe] no message handler matched, payload:', payload, 'channel:', channel);
          };
          // DOM CustomEvent fallback per contract §2.5
          document.addEventListener('bvn:consent-received', function(e) {
            console.log('[KYC bridge probe] dom event received', e.detail);
            send(e.detail, 'dom-custom-event');
          });
          // Catch messages the page tries to send via window.parent /
          // window.opener / window.top — none of those exist for the
          // WKWebView root document, so the page's own postMessage call
          // would silently no-op. We re-route by listening on `message`
          // (which DOES fire when the page calls `window.postMessage(...)`
          // on its OWN window as a fallback) and forwarding through the
          // native handler.
          window.addEventListener('message', function(e) {
            console.log('[KYC bridge probe] window message', { data: e.data, origin: e.origin });
            if (e && e.data && e.data.source === 'i-gree-bvn-service') {
              send(e.data, 'window-message');
            }
          });
          console.log('[KYC bridge probe] installed, handlers available:',
            Object.keys((window.webkit && window.webkit.messageHandlers) || {}));
        })();
        """
        let userScript = WKUserScript(source: probeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        contentController.addUserScript(userScript)

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // Paint the WebView background as systemBackground so the slim
        // moment between overlay-fade and full content render doesn't
        // flash a pure-white block (looks jarring in dark mode).
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.load(URLRequest(url: url))
        return webView
    }

    /// JSON-encoded form of `bvnBridgeNames` used inside the probe JS.
    fileprivate static let bvnBridgeNamesJSON: String = {
        guard let d = try? JSONSerialization.data(withJSONObject: bvnBridgeNames),
              let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }()

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let parent: ConsentWebView
        /// Prevents the bridge from firing the success callback twice if
        /// the page posts both `BVN_CONSENT_RECEIVED` and the follow-up
        /// `BVN_CONSENT_CLOSE_REQUESTED`. Same idea as the web client's
        /// `flowRef` cancellation.
        private var consentDelivered = false
        /// Wall-clock time the most recent navigation started, used to
        /// enforce a minimum overlay display of 350ms. Without this, fast
        /// page loads (cached resources, simulator) flicker the spinner
        /// for ~50ms — visible as a flash, looks broken.
        private var navStart: Date?
        init(_ parent: ConsentWebView) { self.parent = parent }

        // MARK: - Bridge messages (i-gree BVN consent contract)

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // Forward JS console output to Xcode separately from bridge
            // payloads so they don't interfere with parsing.
            if message.name == "kycConsole" {
                if let dict = message.body as? [String: Any] {
                    let level = (dict["level"] as? String) ?? "log"
                    let line  = (dict["line"]  as? String) ?? String(describing: dict)
                    print("[KYC WebView console.\(level)] \(line)")
                }
                return
            }

            // Bridge payload is delivered as the raw object on iOS — but the
            // page also dispatches a DOM CustomEvent that some shells inject
            // as a stringified JSON. Handle both forms defensively.
            let body: [String: Any]?
            if let dict = message.body as? [String: Any] {
                body = dict
            } else if let str = message.body as? String,
                      let data = str.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                body = parsed
            } else {
                body = nil
            }
            guard let payload = body else {
                print("[KYC WebConsentSheet] bridge message \(message.name) had unknown body type: \(type(of: message.body))")
                return
            }
            let source = payload["source"] as? String
            let type   = payload["type"]   as? String
            print("[KYC WebConsentSheet] bridge \(message.name) source=\(source ?? "-") type=\(type ?? "-") raw=\(payload)")
            // Per contract §1: always validate `source` AND `type` —
            // never trust shape alone.
            guard source == "i-gree-bvn-service",
                  type == "BVN_CONSENT_RECEIVED" || type == "BVN_CONSENT_CLOSE_REQUESTED" else {
                return
            }
            guard !consentDelivered else { return }
            consentDelivered = true
            // No reference token in this contract — BVN data ships
            // server-to-server via the RHResponseURL webhook. Surface
            // the success signal with an empty ref; BvnFieldView's
            // background polling picks up the completed status on the
            // next getBvnStatus tick (or sooner via onDismiss).
            Task { @MainActor in
                parent.onResult(.success(""))
            }
        }

        // MARK: - Loading state

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            navStart = Date()
            print("[KYC WebConsentSheet] nav START → \(webView.url?.absoluteString ?? "<nil>")")
            Task { @MainActor in parent.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[KYC WebConsentSheet] nav FINISH → \(webView.url?.absoluteString ?? "<nil>")")
            // Wait until `didFinish` (not `didCommit`) so the spinner stays
            // until the page has actually rendered, not just received its
            // first byte. Also enforce a minimum 350ms total — fast loads
            // would otherwise blink the overlay on and off in <100ms.
            dismissOverlayAfterMinimum()
        }

        private func dismissOverlayAfterMinimum() {
            let minimum: TimeInterval = 0.35
            let elapsed = navStart.map { Date().timeIntervalSince($0) } ?? minimum
            let remaining = max(0, minimum - elapsed)
            Task { @MainActor in
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                parent.isLoading = false
            }
        }

        // MARK: - Redirect interception

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow); return
            }
            let str = url.absoluteString
            if parent.successPrefixes.contains(where: str.hasPrefix) {
                decisionHandler(.cancel)
                let reference = url.queryParam("reference")
                    ?? url.queryParam("code")
                    ?? ""
                if reference.isEmpty {
                    parent.onResult(.failure(.externalConsentFailed(message: "No reference in redirect URL.")))
                } else {
                    parent.onResult(.success(reference))
                }
                return
            }
            if parent.cancelPrefixes.contains(where: str.hasPrefix) {
                decisionHandler(.cancel)
                parent.onResult(.failure(.externalConsentFailed(message: "User cancelled at provider.")))
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in parent.isLoading = false }
            parent.onResult(.failure(.externalConsentFailed(message: error.localizedDescription)))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in parent.isLoading = false }
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

extension URL {
    fileprivate func queryParam(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}

/// Native shell for the NIN / DL / Passport consent field kinds. Calls
/// `initiateNinConsent` (real backend mutation) to get the external auth
/// URL, opens it in ``WebConsentSheet``, then calls `completeNinConsent`
/// with the returned reference. The opaque verified reference is stored
/// on the field value so the submission engine surfaces it at the top
/// level of `KycSubmission`.
@available(iOS 15.0, *)
struct ExternalConsentFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession

    @State private var phase: Phase = .idle
    @State private var sheetURL: URL?
    @State private var showSheet = false
    @State private var statusMessage: String?

    enum Phase: Equatable { case idle, requesting, awaitingConsent, completing, done, failed }

    var body: some View {
        FieldShell(
            label: field.label, required: field.required,
            helper: phase == .idle
                ? "You'll be redirected to the provider's secure page. Only an opaque reference returns here — never your raw NIN or BVN."
                : nil,
            error: session.fieldErrors[field.id]
        ) {
            VStack(spacing: 10) {
                Button(action: tap) {
                    HStack(spacing: 10) {
                        Image(systemName: phase == .done ? "checkmark.shield.fill" : "person.text.rectangle")
                            .foregroundColor(.white)
                        if phase == .requesting || phase == .completing {
                            ProgressView().tint(.white)
                        }
                        Text(buttonLabel)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(buttonColour)
                    .cornerRadius(10)
                }
                .disabled(phase == .requesting || phase == .completing || phase == .done)
                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(phase == .failed ? .red : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .sheet(isPresented: $showSheet) {
            if let url = sheetURL {
                // Provider redirects are merchant-specific (Mono / NINAuth /
                // etc.) — accept any URL containing a `reference` query
                // param as success. The empty cancel-prefix list means the
                // sheet only resolves via success or explicit user dismissal.
                WebConsentSheet(
                    initialURL: url,
                    successURLPrefixes: ["https://", "http://"],
                    cancelURLPrefixes:  []
                ) { result in
                    switch result {
                    case .success(let ref):
                        Task { await complete(reference: ref) }
                    case .failure(let err):
                        phase = .failed
                        statusMessage = err.localizedDescription
                    }
                }
            }
        }
    }

    private var buttonLabel: String {
        switch phase {
        case .idle:             return "Continue with consent provider"
        case .requesting:       return "Starting…"
        case .awaitingConsent:  return "Waiting for consent…"
        case .completing:       return "Finalising…"
        case .done:             return "Consent given ✓"
        case .failed:           return "Try again"
        }
    }
    private var buttonColour: Color {
        switch phase {
        case .done:   return Color.green
        case .failed: return Color.red
        default:      return KYCBrand.primary
        }
    }

    private func tap() {
        if phase == .failed { phase = .idle; statusMessage = nil; return }
        Task { await initiate() }
    }

    private func initiate() async {
        phase = .requesting
        statusMessage = nil
        let api = NinConsentAPI(client: GraphQLClient(endpoint: session.config.gqlEndpoint, publicKey: session.config.publicKey))
        do {
            let resp = try await api.initiate(
                processToken: session.schema?.processToken ?? "",
                scope: "basic",
                providerId: session.currentSection?.providerId,
                levelSlug: session.currentStep?.slug
            )
            guard let s = resp.widgetUrl, let url = URL(string: s) else {
                phase = .failed
                statusMessage = "Provider didn't return a consent URL."
                return
            }
            sheetURL = url
            phase = .awaitingConsent
            showSheet = true
        } catch {
            phase = .failed
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func complete(reference: String) async {
        phase = .completing
        let api = NinConsentAPI(client: GraphQLClient(endpoint: session.config.gqlEndpoint, publicKey: session.config.publicKey))
        do {
            _ = try await api.complete(
                processToken: session.schema?.processToken ?? "",
                reference: reference,
                providerId: session.currentSection?.providerId,
                levelSlug: session.currentStep?.slug
            )
            phase = .done
            session.setValue(.object([
                "verified": .bool(true),
                "consentReference": .string(reference),
            ]), for: field.id)
        } catch {
            phase = .failed
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
#endif
