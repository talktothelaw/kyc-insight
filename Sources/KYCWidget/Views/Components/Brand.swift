#if canImport(SwiftUI)
import SwiftUI

/// Brand palette — single source of truth for every "this is the KYC
/// Insight widget" colour. Values match the web widget exactly (see
/// `kyc-web-wiget-v2/src/core/theme.ts`).
public enum KYCBrand {
    /// `#1E3A8A` — primary navy. Used for Continue / Submit buttons,
    /// active links, progress fills, and the SwiftUI accent tint.
    public static let primary       = Color(red: 30/255,  green: 58/255,  blue: 138/255)
    /// `#3B5998` — slightly lighter for hover / pressed states.
    public static let primaryHover  = Color(red: 59/255,  green: 89/255,  blue: 152/255)
    /// `#F8FAFC` — page tint behind the widget card.
    public static let canvas        = Color(red: 248/255, green: 250/255, blue: 252/255)
    /// `#0F172A` — primary text.
    public static let ink           = Color(red: 15/255,  green: 23/255,  blue: 42/255)
    /// `#475569` — secondary / muted text.
    public static let inkMuted      = Color(red: 71/255,  green: 85/255,  blue: 105/255)
}

/// Convenience view modifier: tint everything the modified subtree draws
/// with the brand navy. Applied at the widget shell so every Button,
/// ProgressView, Toggle, Picker accent picks it up automatically.
@available(iOS 15.0, *)
extension View {
    func kycBranded() -> some View {
        self.tint(KYCBrand.primary)
            .accentColor(KYCBrand.primary)
    }
}
#endif
