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
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
#endif
