#if canImport(UIKit) && canImport(SwiftUI)
import UIKit
import SwiftUI

/// `UIHostingController` wrapping ``KYCWidgetView``. Holds the session and
/// dispatches lifecycle callbacks back through the parent ``KYCWidget``.
@available(iOS 15.0, *)
public final class KYCWidgetViewController: UIHostingController<AnyView> {

    // STRONG on purpose. Every other reference to KYCWidget in the SDK is
    // weak (session.widget, widget.hostViewController), so before this the
    // object stayed alive only while the host app happened to hold it:
    //
    //     let widget = KYCWidget(config: cfg)
    //     widget.present(from: self)
    //   }  // ← last strong reference gone, widget deallocated
    //
    // The controller stays on screen because UIKit retains it, but the close
    // button (`[weak widget] in widget?.destroy()`) silently does nothing and
    // every callback dispatched through `session.widget` is dropped. Owning it
    // here ties its lifetime to the presentation. No cycle: the widget's
    // reference back to this controller is weak.
    private let widget: KYCWidget
    let session: KYCWidgetSession

    init(widget: KYCWidget) {
        self.widget = widget
        let session = KYCWidgetSession(config: widget.config)
        session.widget = widget
        self.session = session
        super.init(rootView: AnyView(EmptyView()))
        // The close button must ALWAYS get the user off this screen. It goes
        // through the widget so `onClose` fires and the session tears down,
        // but falls back to dismissing directly if the widget was already
        // destroyed — a dead × is worse than a missed callback.
        let close: () -> Void = { [weak self] in
            guard let self else { return }
            if self.widget.isDestroyed {
                self.dismissFromPresenter()
            } else {
                self.widget.destroy()
            }
        }
        self.rootView = AnyView(KYCWidgetView(session: session, onRequestClose: close))
        self.modalPresentationStyle = .fullScreen
        // The widget has its own design language (KYCBrand) tuned for the
        // light-on-light marketing chrome of the web v2 widget. Inheriting
        // the host app's dark mode would invert backgrounds + text mid-flow
        // — sometimes the field shells stay light but the captured-thumb
        // tile / FieldShell border ends up dark, which is the "input I can
        // see there" the user flagged on the iOS screenshot. Pin to .light
        // so the rendering is identical to the web reference regardless of
        // the host app's appearance setting.
        self.overrideUserInterfaceStyle = .light
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Last-resort dismissal used when the widget can no longer do it.
    func dismissFromPresenter() {
        if let presenter = presentingViewController {
            presenter.dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }
}
#endif
