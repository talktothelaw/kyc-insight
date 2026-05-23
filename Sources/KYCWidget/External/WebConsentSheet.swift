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

    var body: some View {
        NavigationView {
            ConsentWebView(
                url: initialURL,
                successPrefixes: successURLPrefixes,
                cancelPrefixes: cancelURLPrefixes,
                onResult: { result in
                    presentationMode.wrappedValue.dismiss()
                    onResult(result)
                }
            )
            .navigationBarTitle("External consent", displayMode: .inline)
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
struct ConsentWebView: UIViewRepresentable {
    let url: URL
    let successPrefixes: [String]
    let cancelPrefixes: [String]
    let onResult: (Result<String, KYCWidgetError>) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: ConsentWebView
        init(_ parent: ConsentWebView) { self.parent = parent }

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
