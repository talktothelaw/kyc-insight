#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// The unified vertical journey outline — tiers across the whole flow,
/// sections nested under the active tier. Mirrors `JourneyOutline.tsx`
/// in the web SDK. Used as a top sheet on iPhone (mobile) or as a side
/// rail on iPad / larger windows.
@available(iOS 15.0, *)
struct JourneyOutlineView: View {
    @ObservedObject var session: KYCWidgetSession
    let onSelect: (Int, Int) -> Void

    var body: some View {
        let steps = session.schema?.steps ?? []
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { (tierIdx, step) in
                tierRow(index: tierIdx, step: step)
                if tierIdx == session.currentStepIndex {
                    sectionList(for: step, tierIdx: tierIdx)
                }
                if tierIdx < steps.count - 1 {
                    Rectangle()
                        .fill(Color(.separator))
                        .frame(height: 1)
                        .padding(.leading, 26)
                }
            }
        }
    }

    @ViewBuilder
    private func tierRow(index: Int, step: WidgetStep) -> some View {
        let isActive = index == session.currentStepIndex
        let isApproved = stepIsApproved(step)
        // Tier-level frontier — can navigate to any tier <= tierFrontier.
        let canNavigate = index <= session.tierFrontier
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isApproved ? Color.green : (isActive ? KYCBrand.primary : Color(.systemGray4)))
                    .frame(width: 22, height: 22)
                if isApproved {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                } else if !canNavigate {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isActive ? .primary : (canNavigate ? .secondary : Color.secondary.opacity(0.6)))
                Text("\(step.sections.count) section\(step.sections.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Lock to the tier frontier — same gate the web applies.
            if canNavigate { onSelect(index, 0) }
        }
    }

    private func sectionList(for step: WidgetStep, tierIdx: Int) -> some View {
        // Section-level frontier — only computed for the active tier. For
        // earlier tiers every section is reachable (the tier is complete).
        let frontier = tierIdx == session.currentStepIndex
            ? session.currentStepFrontier
            : step.sections.count - 1
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(step.sections.enumerated()), id: \.element.id) { (secIdx, section) in
                let isActive = tierIdx == session.currentStepIndex && secIdx == session.currentSectionIndex
                let canNavigate = secIdx <= frontier
                HStack(spacing: 10) {
                    StatusDot(status: section.status, active: isActive)
                    Text(section.name)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isActive ? .primary : (canNavigate ? .secondary : Color.secondary.opacity(0.5)))
                    Spacer()
                    if !canNavigate {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                .padding(.leading, 32)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isActive ? KYCBrand.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if canNavigate { onSelect(tierIdx, secIdx) }
                }
            }
        }
    }

    private func stepIsApproved(_ step: WidgetStep) -> Bool {
        guard !step.sections.isEmpty else { return false }
        return step.sections.allSatisfy { $0.status == .approved }
    }
}
#endif
