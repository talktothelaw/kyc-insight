#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Brand footer — mirrors `kyc-web-wiget-v2/src/components/layout/WidgetShell.tsx:197-206`.
/// Renders the real KYC Insight wordmark PNG (resource-bundled with the
/// SDK, same file the web ships) inside a soft chip, followed by the
/// "Powered by Netapps Marketplace Limited · © year" attribution line.
@available(iOS 15.0, *)
struct BrandFooter: View {
    private var year: Int {
        Calendar.current.component(.year, from: Date())
    }

    var body: some View {
        VStack(spacing: 6) {
            logoChip
            Text("Powered by Netapps Marketplace Limited · © \(String(year))")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private var logoChip: some View {
        if let logo = BrandImages.kycInsightLogo {
            logo
                .resizable()
                .scaledToFit()
                .frame(height: 18)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
                .cornerRadius(8)
        } else {
            // Resource missing — fall back to a typographic mark so the
            // footer still renders something brand-aligned.
            HStack(spacing: 4) {
                Image(systemName: "shield.checkered")
                    .foregroundColor(KYCBrand.primary)
                Text("KYC Insight")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(KYCBrand.ink)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(.systemBackground))
            .cornerRadius(8)
        }
    }
}

/// Header strip — shows tier badge + section counter at the top of the
/// main content area on iPhone (the JourneyOutline is in a top sheet).
@available(iOS 15.0, *)
struct SectionProgressStrip: View {
    @ObservedObject var session: KYCWidgetSession
    let onOpenOutline: () -> Void

    var body: some View {
        if let step = session.currentStep {
            HStack(spacing: 8) {
                Button(action: onOpenOutline) {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet")
                        Text("\(session.currentStepIndex + 1)/\(session.schema?.steps.count ?? 1)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(Capsule())
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(step.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("Section \(session.currentSectionIndex + 1) of \(step.sections.count)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                progressBar
                    .frame(width: 70)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            let total = session.schema?.steps.count ?? 1
            let pct = Double(session.currentStepIndex + 1) / Double(total)
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemGray5))
                Capsule()
                    .fill(KYCBrand.primary)
                    .frame(width: max(8, proxy.size.width * pct))
            }
        }
        .frame(height: 4)
    }
}
#endif
