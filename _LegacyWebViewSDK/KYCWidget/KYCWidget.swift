import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The KYC Insight verification widget — native iOS host.
///
/// Construct with a ``KYCWidgetConfig``, wire up the lifecycle callbacks
/// you care about, then call ``present(from:animated:completion:)`` to
/// open the widget modally over your view hierarchy.
///
/// All callbacks fire on the main thread.
///
/// ```swift
/// let widget = KYCWidget(config: KYCWidgetConfig(
///     publicKey: "NA_PUB_PROD_…",
///     userRef: "user-1234",
///     slug: "supplier_registration",
///     name: "Lawrence Olu",
///     levelSlug: "tier_1"
/// ))
/// widget.onReady = { print("widget mounted") }
/// widget.onLevelApproved = { level in print("approved", level.slug) }
/// widget.onSuccess = { _ in print("done") }
/// widget.onClose = { print("dismissed") }
/// widget.present(from: self)
/// ```
public final class KYCWidget {

    // MARK: - Lifecycle callbacks (mirror the web SDK's KycWidgetCallbacks)

    /// Fired once the widget has mounted and is ready for input.
    public var onReady: (() -> Void)?
    /// Fired every time the customer moves to a new level (tier).
    public var onLevelChange: ((KYCWidgetLevel) -> Void)?
    /// Fired the moment a level transitions to **fully approved** (every
    /// requirement inside it reached `approved` status). Covers auto-approving
    /// levels (NIN / BVN that complete synchronously on submission) and
    /// manual-approval flows. Always fires BEFORE ``onLevelChange`` when
    /// the approval auto-advances to the next level.
    public var onLevelApproved: ((KYCWidgetLevel) -> Void)?
    /// Fired after each section is successfully submitted to the backend.
    public var onSubmit: ((AnyJSON?) -> Void)?
    /// Fired when every tier + section is approved or submitted.
    public var onSuccess: ((AnyJSON?) -> Void)?
    /// Fired on a fatal load or submission failure.
    public var onError: ((KYCWidgetError) -> Void)?
    /// Fired when the widget is destroyed — either because the customer
    /// closed it or because the host called ``destroy()``.
    public var onClose: (() -> Void)?

    // MARK: - State

    public let config: KYCWidgetConfig

    #if canImport(UIKit)
    /// Strong reference to the controller while it's mounted. Cleared on
    /// dismissal so the view tree gets deallocated.
    private(set) weak var hostViewController: KYCWidgetViewController?
    #endif

    private var isDestroyed = false

    // MARK: - Init

    public init(config: KYCWidgetConfig) {
        self.config = config
    }

    // MARK: - Presentation

    #if canImport(UIKit)
    /// Build the widget's view controller. Use this when you want custom
    /// presentation (push onto a nav stack, embed in a tab, etc.).
    /// Throws ``KYCWidgetError`` on config validation failure.
    public func makeViewController() throws -> KYCWidgetViewController {
        let url = try config.buildURL()
        let vc = KYCWidgetViewController(widget: self, url: url)
        hostViewController = vc
        return vc
    }

    /// Convenience: pre-warm camera + microphone permissions, then present
    /// the widget modally over `presenter`. If config validation fails,
    /// the ``onError`` callback fires and presentation is skipped.
    public func present(
        from presenter: UIViewController,
        animated: Bool = true,
        prewarmPermissions: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        let go: () -> Void = { [weak self] in
            guard let self else { return }
            do {
                let vc = try self.makeViewController()
                presenter.present(vc, animated: animated, completion: completion)
            } catch let err as KYCWidgetError {
                self.dispatchError(err)
            } catch {
                self.dispatchError(.widgetError(message: error.localizedDescription))
            }
        }
        if prewarmPermissions {
            MediaPermissions.prewarm(go)
        } else {
            go()
        }
    }
    #endif

    /// Tear down the widget. Posts a `destroy` command to the WebView (so
    /// in-flight network work can cancel cleanly), then dismisses the view
    /// controller. ``onClose`` fires exactly once even if `destroy()` is
    /// called multiple times.
    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        #if canImport(UIKit)
        if let vc = hostViewController {
            vc.postDestroyCommand()
            // Give the widget a beat to flush 'close' back to us through
            // the bridge; if it doesn't, we still dismiss after a tiny
            // delay so the host UI doesn't hang.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak vc] in
                vc?.dismissFromWidget()
            }
        }
        #endif
        onClose?()
    }

    // MARK: - Internal — bridge dispatch

    /// Called by ``WebViewBridge`` whenever the widget posts a lifecycle
    /// message. Runs on the main thread.
    func dispatch(_ message: BridgeMessage) {
        switch message.type {
        case "ready":
            onReady?()
        case "levelChange":
            if let level = AnyJSON.decodeLevel(message.payload) {
                onLevelChange?(level)
            }
        case "levelApproved":
            if let level = AnyJSON.decodeLevel(message.payload) {
                onLevelApproved?(level)
            }
        case "submit":
            onSubmit?(message.payload)
        case "success":
            onSuccess?(message.payload)
        case "error":
            let msg = AnyJSON.decodeMessage(message.payload) ?? "Unknown widget error"
            dispatchError(.widgetError(message: msg))
        case "close":
            // Customer closed the widget from inside (X button, Escape, etc.).
            // Mirror destroy() without re-posting to the bridge.
            handleWidgetInitiatedClose()
        default:
            break
        }
    }

    func handleLoadFailure(message: String) {
        dispatchError(.widgetError(message: message))
    }

    private func dispatchError(_ error: KYCWidgetError) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
    }

    private func handleWidgetInitiatedClose() {
        guard !isDestroyed else { return }
        isDestroyed = true
        #if canImport(UIKit)
        hostViewController?.dismissFromWidget()
        #endif
        onClose?()
    }
}
