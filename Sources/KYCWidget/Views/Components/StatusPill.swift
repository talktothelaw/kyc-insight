#if canImport(SwiftUI)
import SwiftUI

@available(iOS 15.0, *)
struct StatusPill: View {
    let status: WidgetStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.3)
        }
        .foregroundColor(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(background)
        .clipShape(Capsule())
    }

    private var icon: String {
        switch status {
        case .approved:    return "checkmark"
        case .pending:     return "clock.fill"
        case .rejected:    return "exclamationmark"
        case .initialized: return "circle"
        }
    }
    private var label: String {
        switch status {
        case .approved:    return "APPROVED"
        case .pending:     return "PENDING"
        case .rejected:    return "REJECTED"
        case .initialized: return "PENDING"
        }
    }
    private var foreground: Color {
        switch status {
        case .approved:    return Color.green
        case .pending:     return Color.orange
        case .rejected:    return Color.red
        case .initialized: return Color.secondary
        }
    }
    private var background: Color {
        switch status {
        case .approved:    return Color.green.opacity(0.12)
        case .pending:     return Color.orange.opacity(0.12)
        case .rejected:    return Color.red.opacity(0.12)
        case .initialized: return Color(.tertiarySystemFill)
        }
    }
}

/// Small dot showing per-section status in the sidebar outline.
@available(iOS 15.0, *)
struct StatusDot: View {
    let status: WidgetStatus
    let active: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: 18, height: 18)
            if let glyph {
                Image(systemName: glyph)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
            }
            if active && status == .initialized {
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var fill: Color {
        switch status {
        case .approved: return .green
        case .pending:  return .orange
        case .rejected: return .red
        case .initialized: return active ? KYCBrand.primary : Color(.systemGray3)
        }
    }
    private var glyph: String? {
        switch status {
        case .approved: return "checkmark"
        case .pending:  return "clock.fill"
        case .rejected: return "xmark"
        case .initialized: return nil
        }
    }
}
#endif
