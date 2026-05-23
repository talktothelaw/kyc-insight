#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Shared shell around every field: label row (with required *), helper
/// text, and an error message when validation fails. The actual input
/// renders inside the `content` slot.
@available(iOS 15.0, *)
struct FieldShell<Content: View>: View {
    let label: String?
    let required: Bool
    let helper: String?
    let error: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label, !label.isEmpty {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    if required {
                        Text("*").foregroundColor(.red).font(.system(size: 13, weight: .semibold))
                    }
                }
            }
            content
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(error != nil ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1)
                )
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            } else if let helper, !helper.isEmpty {
                Text(helper)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// Standard input box look — used by every textual input.
@available(iOS 15.0, *)
struct FieldBox<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
    }
}
#endif
