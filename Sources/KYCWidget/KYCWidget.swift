import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The KYC Insight verification widget — native iOS host.
///
/// Construct with a ``KYCWidgetConfig``, wire up the lifecycle callbacks
/// you care about, then call ``present(from:animated:completion:)`` to
/// open the widget modally over your view hierarchy. All callbacks fire
/// on the main thread.
@available(iOS 15.0, *)
public final class KYCWidget {

    // MARK: - Lifecycle callbacks

    public var onReady: (() -> Void)?
    public var onLevelChange: ((KYCWidgetLevel) -> Void)?
    public var onLevelApproved: ((KYCWidgetLevel) -> Void)?
    public var onSubmit: ((Any?) -> Void)?
    public var onSuccess: ((Any?) -> Void)?
    public var onError: ((KYCWidgetError) -> Void)?
    public var onClose: (() -> Void)?

    // MARK: - State

    public let config: KYCWidgetConfig

    #if canImport(UIKit)
    /// Weak reference to the controller while it's mounted.
    public private(set) weak var hostViewController: KYCWidgetViewController?
    #endif

    private var isDestroyed = false

    public init(config: KYCWidgetConfig) {
        self.config = config
    }

    // MARK: - Presentation

    #if canImport(UIKit)
    /// Build the view controller. Throws on config validation failure.
    public func makeViewController() throws -> KYCWidgetViewController {
        try config.validate()
        let vc = KYCWidgetViewController(widget: self)
        hostViewController = vc
        return vc
    }

    /// Convenience: pre-warm camera permission, then present the widget
    /// modally over `presenter`.
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
                self.dispatchError(.unknown(message: error.localizedDescription))
            }
        }
        if prewarmPermissions {
            MediaPermissions.requestCamera { _ in
                MediaPermissions.requestMicrophone { _ in go() }
            }
        } else {
            go()
        }
    }
    #endif

    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        #if canImport(UIKit)
        if let vc = hostViewController {
            if let presenter = vc.presentingViewController {
                presenter.dismiss(animated: true)
            } else {
                vc.navigationController?.popViewController(animated: true)
            }
        }
        #endif
        onClose?()
    }

    // MARK: - Internal — dispatched by KYCWidgetSession on the main thread

    func dispatchReady() { onReady?() }
    func dispatchLevelChange(_ level: KYCWidgetLevel) { onLevelChange?(level) }
    func dispatchLevelApproved(_ level: KYCWidgetLevel) { onLevelApproved?(level) }
    func dispatchSubmit(payload: Any?) { onSubmit?(payload) }
    func dispatchSuccess() { onSuccess?(nil) }
    func dispatchError(_ err: KYCWidgetError) { onError?(err) }
}
