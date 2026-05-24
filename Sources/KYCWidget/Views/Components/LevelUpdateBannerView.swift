#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Banner shown above the form when a section the user previously
/// engaged with needs additional input. 1:1 with the web's
/// `components/primitives/LevelUpdateBanner.tsx`.
///
/// The trigger is `WidgetSection.requiresUpdate`, which is derived in
/// `SchemaNormalizer` from the backend's per-field `alreadySupplied`
/// stamps (server-side `helpers/fieldSupplyResolver.ts`). The reason
/// dictates the copy:
///
///   • `.pending_placeholder`  — section status is pending; merchant
///     added a new provider to a previously-approved tier.
///   • `.requirements_changed` — section status is approved; merchant
///     added a new required field on an already-approved provider.
@available(iOS 15.0, *)
struct LevelUpdateBannerView: View {
    let reason: RequiresUpdateReason?

    private var title: String {
        switch reason {
        case .pending_placeholder: return "New requirement added to this tier"
        case .requirements_changed: return "Additional information needed"
        case .none: return "Additional information needed"
        }
    }
    private var body_: String {
        switch reason {
        case .pending_placeholder:
            return "This section was added to your verification after your earlier submissions. Please complete it to finish the tier."
        case .requirements_changed:
            return "This section was previously verified, but a new required field has been added since. Provide the missing information and submit again."
        case .none:
            return "The requirements for this section have changed. Please review and submit again."
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(KYCBrand.primary)
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Text(body_)
                    .font(.system(size: 13))
                    .foregroundColor(KYCBrand.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KYCBrand.primary.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(KYCBrand.primary.opacity(0.35), lineWidth: 1)
        )
        .cornerRadius(10)
    }
}
#endif
