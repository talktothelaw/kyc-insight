#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Read-only panel that replaces the section form when a section is already
/// `approved` or `pending`. 1:1 port of
/// `kyc-web-wiget-v2/src/components/primitives/SubmissionStatusPanel.tsx`.
///
/// Title + description match the web copy verbatim so a customer seeing
/// the same section across web and iOS reads exactly the same wording.
@available(iOS 15.0, *)
struct SubmissionStatusPanelView: View {
    let section: WidgetSection
    /// Optional CTA — show "Back to current step" only when the user is
    /// behind the frontier (i.e. somewhere ahead is the actual cursor).
    let onBackToCurrent: (() -> Void)?

    private var isApproved: Bool { section.status == .approved }

    private var icon: String { isApproved ? "checkmark" : "clock.fill" }
    private var accent: Color { isApproved ? .green : .orange }
    private var title: String {
        isApproved ? "Already approved" : "Submission pending review"
    }
    private var description: String {
        isApproved
            ? "This requirement has been verified — no further action needed."
            : "We have your submission and a reviewer is taking a look. We will notify you once it is decided."
    }

    var body: some View {
        VStack(spacing: 14) {
            iconChip
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(section.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.4)
                .textCase(.uppercase)
            Text(description)
                .font(.system(size: 14))
                .foregroundColor(KYCBrand.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if let onBackToCurrent {
                Button(action: onBackToCurrent) {
                    HStack(spacing: 6) {
                        Text("Back to current step")
                            .font(.system(size: 14, weight: .semibold))
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(KYCBrand.primary)
                    .cornerRadius(10)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
    }

    private var iconChip: some View {
        ZStack {
            Circle().fill(accent.opacity(0.12)).frame(width: 84, height: 84)
            Image(systemName: icon)
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(accent)
        }
    }
}
#endif
