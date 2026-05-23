#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Inline banner shown above a rejected section's form, explaining why
/// the prior submission was rejected. 1:1 port of
/// `kyc-web-wiget-v2/src/components/primitives/RejectionBanner.tsx`.
///
/// Self-fetches on mount via `KycRejectedLogForModal(processToken, kycType)`.
/// Renders nothing while loading or when the backend returns an empty
/// reason — better silence than a flicker of "Loading…" → blank.
@available(iOS 15.0, *)
struct RejectionBannerView: View {
    let processToken: String
    let kycType: String
    let publicKey: String
    let endpoint: URL

    @State private var reason: String?

    var body: some View {
        Group {
            if let reason, !reason.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Previous submission was rejected")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(reason)
                            .font(.system(size: 13))
                            .foregroundColor(KYCBrand.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                )
                .cornerRadius(10)
            }
        }
        .task { await fetchReason() }
    }

    private func fetchReason() async {
        guard !processToken.isEmpty, !kycType.isEmpty else { return }
        let api = RejectedLogAPI(client: GraphQLClient(endpoint: endpoint, publicKey: publicKey))
        do {
            let r = try await api.reason(processToken: processToken, kycType: kycType)
            // Empty string means "no log on file" → keep banner hidden.
            if !r.isEmpty { reason = r }
        } catch {
            // Silent — same as the web; the form below is still usable.
        }
    }
}
#endif
