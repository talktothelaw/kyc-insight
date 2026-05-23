#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// A reusable bottom-sheet option picker with a built-in search field.
///
/// Used by every select-style field (`SelectField`, `LocationField`,
/// `SysSelectField`) so the picker UX is identical across the SDK.
/// Replaces the SwiftUI `confirmationDialog` that didn't scroll or
/// support search — fine for 3 options, bad for 200 countries / states.
///
/// Visual contract:
///   • Slides up from the bottom (.medium + .large detents so the user
///     can drag to expand on long lists).
///   • Header row with title, optional subtitle, and a Cancel button.
///   • Search field anchored under the header — filters as the user types.
///   • Scroll-able list of matches; tapping a row commits and dismisses.
///   • Checkmark on the currently-selected row.
@available(iOS 15.0, *)
struct SearchableOptionSheet<Option: Identifiable>: View {
    let title: String
    let subtitle: String?
    let options: [Option]
    let labelFor: (Option) -> String
    /// Optional secondary line under each row (e.g. RC number for CAC, code
    /// for a country). Returning `nil` collapses to a single-line row.
    let detailFor: (Option) -> String?
    let selected: Option?
    let onPick: (Option) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    init(
        title: String,
        subtitle: String? = nil,
        options: [Option],
        selected: Option? = nil,
        labelFor: @escaping (Option) -> String,
        detailFor: @escaping (Option) -> String? = { _ in nil },
        onPick: @escaping (Option) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.options = options
        self.selected = selected
        self.labelFor = labelFor
        self.detailFor = detailFor
        self.onPick = onPick
    }

    private var filtered: [Option] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return options }
        // Case-insensitive substring match against the displayed label OR
        // the detail line. Diacritic-insensitive so "Cote" finds "Côte
        // d'Ivoire" without the user typing the accent.
        return options.filter { opt in
            labelFor(opt).range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || (detailFor(opt)?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }

    var body: some View {
        NavigationView {
            list
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search \(title.lowercased())"
                )
        }
        .tint(KYCBrand.primary)
        // Detents + drag indicator are iOS 16+. iOS 15 just sees a full-
        // height sheet, which is still the right UX — long lists need the
        // room, and the navigation bar Cancel button is always reachable.
        .modifier(SheetDetentsModifier())
    }

    @ViewBuilder
    private var list: some View {
        if let subtitle, !subtitle.isEmpty, query.isEmpty {
            List {
                Section {
                    rows(filtered)
                } header: {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
        } else if filtered.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                Text("No matches for \"\(query)\"")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
        } else {
            List {
                rows(filtered)
            }
            .listStyle(.insetGrouped)
        }
    }

    private func rows(_ items: [Option]) -> some View {
        ForEach(items) { opt in
            Button {
                onPick(opt)
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(labelFor(opt))
                            .font(.system(size: 15))
                            .foregroundColor(.primary)
                        if let detail = detailFor(opt) {
                            Text(detail)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if let selected, selected.id == opt.id {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(KYCBrand.primary)
                    }
                }
            }
        }
    }
}

@available(iOS 15.0, *)
extension SysSelectOption: Identifiable {
    public var id: String { providerId }
}

// MARK: - Identifiable conformance for the WidgetOption type used by selects

@available(iOS 15.0, *)
extension WidgetOption: Identifiable {
    public var id: String { value }
}

/// Apply iOS 16+ sheet detents when available. iOS 15 just gets the
/// default full-height sheet (still the right UX for a long searchable
/// list — navigation Cancel button is always reachable).
@available(iOS 15.0, *)
private struct SheetDetentsModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        } else {
            content
        }
    }
}
#endif
