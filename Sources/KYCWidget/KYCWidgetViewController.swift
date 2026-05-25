#if canImport(UIKit) && canImport(SwiftUI)
import UIKit
import SwiftUI

/// `UIHostingController` wrapping ``KYCWidgetView``. Holds the session and
/// dispatches lifecycle callbacks back through the parent ``KYCWidget``.
@available(iOS 15.0, *)
public final class KYCWidgetViewController: UIHostingController<AnyView> {

    private weak var widget: KYCWidget?
    let session: KYCWidgetSession

    init(widget: KYCWidget) {
        self.widget = widget
        let session = KYCWidgetSession(config: widget.config)
        session.widget = widget
        self.session = session
        super.init(rootView: AnyView(EmptyView()))
        let close: () -> Void = { [weak widget] in widget?.destroy() }
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
}
#endif
