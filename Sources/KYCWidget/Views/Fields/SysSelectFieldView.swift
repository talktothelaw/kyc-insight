#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Native SysSelectField — the customer picks one verification method
/// from a list (e.g. NIN, BVN, Driver's License), and the chosen method's
/// own sub-fields render inline below the picker. 1:1 port of
/// `kyc-web-wiget-v2/src/components/fields/SysSelectField.tsx`.
///
/// The composite value stored on `session.values[field.id]` is:
///   ```
///   {
///     selectedType: String,        // chosen provider's `type`
///     selectedProviderId: String,  // chosen provider's `_id`
///     values: [fieldName: AnyCodable]   // sub-field values keyed by name
///   }
///   ```
@available(iOS 15.0, *)
struct SysSelectFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession

    @State private var presenting = false
    @State private var selectedOption: SysSelectOption?

    var body: some View {
        // Render the parent picker and the sub-fields as siblings,
        // NOT nested inside a single FieldShell — otherwise the
        // parent's error border (drawn around `content`) wraps the
        // entire stack (picker + every sub-field's input area +
        // helper text) and looks visually overwhelming. With sibling
        // layout the red border hugs ONLY the picker, and the sub-
        // field underneath carries its own field-shell visuals.
        VStack(alignment: .leading, spacing: 12) {
            FieldShell(
                label: field.label, required: field.required,
                helper: selectedOption == nil
                    ? "Choose how you'd like to verify, then complete its inputs."
                    : nil,
                error: session.fieldErrors[field.id]
            ) {
                methodButton
            }
            if let opt = selectedOption {
                VStack(spacing: 12) {
                    ForEach(opt.fields) { sub in
                        SysSubFieldRow(parentField: field, parentSession: session, option: opt, subField: sub)
                    }
                }
            }
        }
        .sheet(isPresented: $presenting) {
            SearchableOptionSheet(
                title: "Verification method",
                subtitle: "Pick one — its inputs will appear below.",
                options: field.sysSelectOptions ?? [],
                selected: selectedOption,
                labelFor: { $0.label },
                detailFor: { _ in nil }
            ) { picked in choose(picked) }
        }
        .onAppear {
            // Restore prior selection from session value.
            if let dict = session.values[field.id]?.dictValue,
               let id = dict["selectedProviderId"]?.stringValue,
               let opt = field.sysSelectOptions?.first(where: { $0.providerId == id }) {
                selectedOption = opt
            }
        }
    }

    private var methodButton: some View {
        Button { presenting = true } label: {
            FieldBox {
                HStack {
                    Image(systemName: "checkmark.shield")
                        .foregroundColor(KYCBrand.primary)
                        .frame(width: 28, height: 28)
                        .background(KYCBrand.primary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text(selectedOption?.label ?? "Choose verification method")
                        .font(.system(size: 14, weight: selectedOption == nil ? .regular : .medium))
                        .foregroundColor(selectedOption == nil ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func choose(_ option: SysSelectOption) {
        selectedOption = option
        // Reset the composite value to the new selection with empty sub-values.
        session.setValue(.object([
            "selectedType":       .string(option.providerType),
            "selectedProviderId": .string(option.providerId),
            "values":             .object([:]),
        ]), for: field.id)
    }
}

/// Renders one sub-field of the picked SysSelect option. Reads / writes
/// the sub-value through a child session value so the parent field's
/// composite stays in sync.
@available(iOS 15.0, *)
private struct SysSubFieldRow: View {
    let parentField: WidgetField
    @ObservedObject var parentSession: KYCWidgetSession
    let option: SysSelectOption
    let subField: WidgetField

    var body: some View {
        // The child renders against a SHADOW session that proxies value
        // mutations into the parent's composite. Simpler than a full
        // duplicate session: we override setValue / values lookup to write
        // into the parent's `values[parentField.id].values[subField.name]`.
        FieldRenderer(field: subField, session: parentSession)
            .onAppear { ensureCompositeInitialised() }
    }

    private func ensureCompositeInitialised() {
        // Seed an empty composite on first render so child writes land cleanly.
        if parentSession.values[parentField.id]?.dictValue == nil {
            parentSession.setValue(.object([
                "selectedType":       .string(option.providerType),
                "selectedProviderId": .string(option.providerId),
                "values":             .object([:]),
            ]), for: parentField.id)
        }
    }
}
#endif
