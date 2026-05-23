#if canImport(UIKit)
import UIKit
import WebKit
import AVFoundation

/// UIViewController that hosts the WKWebView running the KYC widget.
///
/// You normally don't instantiate this directly — call
/// ``KYCWidget/present(from:animated:)`` or ``KYCWidget/makeViewController()``.
/// Exposed publicly so apps that want custom presentation (push into a
/// nav stack, embed inside a tab, etc.) can do so.
public final class KYCWidgetViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private weak var widget: KYCWidget?
    private let url: URL
    private let bridge: WebViewBridge

    private var webView: WKWebView!
    private var loadingIndicator: UIActivityIndicatorView!

    init(widget: KYCWidget, url: URL) {
        self.widget = widget
        self.url = url
        self.bridge = WebViewBridge(widget: widget)
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureWebView()
        configureLoadingIndicator()
        loadWidget()
    }

    // MARK: - WebView setup

    private func configureWebView() {
        // 1. User content controller — install the bridge shim at document
        //    start so the widget's React tree sees it before any of its own
        //    bridge code runs.
        let userContent = WKUserContentController()
        userContent.add(bridge, name: BridgeUserScript.messageHandlerName)
        let shim = WKUserScript(
            source: BridgeUserScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContent.addUserScript(shim)

        // 2. Configuration — allow inline media playback so the widget's
        //    camera preview doesn't punt to QuickTime fullscreen, allow
        //    auto-playback (no user-gesture requirement) so liveness video
        //    flows can start their stream without a tap.
        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptEnabled = true
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        config.websiteDataStore = .default()

        // 3. The web view itself — pinned to the safe area so we don't
        //    overlap the home indicator or notch on devices that need it.
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // Useful when wiring up a remote debugger; harmless in production.
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        self.webView = webView
    }

    private func configureLoadingIndicator() {
        let indicator: UIActivityIndicatorView
        if #available(iOS 13.0, *) {
            indicator = UIActivityIndicatorView(style: .medium)
        } else {
            indicator = UIActivityIndicatorView(style: .gray)
        }
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        indicator.startAnimating()
        view.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        self.loadingIndicator = indicator
    }

    private func loadWidget() {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingIndicator.stopAnimating()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadingIndicator.stopAnimating()
        widget?.handleLoadFailure(message: error.localizedDescription)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadingIndicator.stopAnimating()
        widget?.handleLoadFailure(message: error.localizedDescription)
    }

    // MARK: - WKUIDelegate (camera + microphone)

    /// iOS 15+ replaces the legacy double-prompt flow for `getUserMedia`
    /// with a single delegate callback. Grant whatever the widget asks for
    /// — the user has already approved camera/mic via `AVCaptureDevice.requestAccess`
    /// upstream (see ``MediaPermissions``).
    @available(iOS 15.0, *)
    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }

    /// Allow target="_blank" links (e.g. NINAuth's external auth window) to
    /// open in the same WebView instead of being silently dropped.
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // MARK: - Outbound bridge

    /// Send a `destroy` command into the widget. The widget acks with a
    /// `close` message which the bridge routes to ``KYCWidget/onClose``.
    func postDestroyCommand() {
        WebViewBridge.post(type: "destroy", into: webView)
    }

    // MARK: - Dismissal

    /// Called by ``KYCWidget`` when the widget posts a `close` event or the
    /// host explicitly calls ``KYCWidget/destroy()``.
    func dismissFromWidget() {
        guard let presenting = presentingViewController else {
            // Pushed onto a nav stack rather than presented — pop.
            navigationController?.popViewController(animated: true)
            return
        }
        presenting.dismiss(animated: true)
    }
}
#endif
