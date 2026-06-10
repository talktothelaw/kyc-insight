#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

@available(iOS 15.0, *)
struct SelectFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession
    @State private var presenting = false
    @State private var selection: String = ""

    var body: some View {
        FieldShell(
            label: field.label, required: field.required,
            helper: nil, error: session.fieldErrors[field.id]
        ) {
            Button { presenting = true } label: {
                FieldBox {
                    HStack {
                        Text(selectedLabel)
                            .font(.system(size: 15))
                            .foregroundColor(selection.isEmpty ? .secondary : .primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $presenting) {
            SearchableOptionSheet(
                title: field.label,
                subtitle: field.required ? "Required" : nil,
                options: field.options ?? [],
                selected: field.options?.first(where: { $0.value == selection }),
                labelFor: { $0.label }
            ) { picked in
                selection = picked.value
                session.setValue(.string(picked.value), for: field.id)
            }
        }
        .onAppear {
            if let existing = session.values[field.id]?.stringValue { selection = existing }
        }
    }

    private var selectedLabel: String {
        if selection.isEmpty { return "Select…" }
        return field.options?.first(where: { $0.value == selection })?.label ?? selection
    }
}

@available(iOS 15.0, *)
struct RadioFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession
    @State private var selection: String = ""

    var body: some View {
        FieldShell(
            label: field.label, required: field.required,
            helper: nil, error: session.fieldErrors[field.id]
        ) {
            VStack(spacing: 6) {
                ForEach(field.options ?? [], id: \.value) { option in
                    Button {
                        selection = option.value
                        session.setValue(.string(option.value), for: field.id)
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .strokeBorder(selection == option.value ? KYCBrand.primary : Color(.systemGray3), lineWidth: 2)
                                    .frame(width: 20, height: 20)
                                if selection == option.value {
                                    Circle().fill(KYCBrand.primary).frame(width: 10, height: 10)
                                }
                            }
                            Text(option.label).font(.system(size: 14)).foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(selection == option.value
                                      ? KYCBrand.primary.opacity(0.08)
                                      : Color(.secondarySystemBackground))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear {
            if let existing = session.values[field.id]?.stringValue { selection = existing }
        }
    }
}

/// Polymorphic checkbox renderer — 1:1 with web `CheckboxField.tsx` and
/// Android `CheckboxFieldKyc`.
///   • options non-empty → multi-select GROUP; stored value is an
///     `.array` of the selected option *values* (`[String]`), toggling
///     membership.
///   • no options        → single boolean toggle (`.bool`).
@available(iOS 15.0, *)
struct CheckboxFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession

    var body: some View {
        if let options = field.options, !options.isEmpty {
            CheckboxGroupFieldView(field: field, session: session, options: options)
        } else {
            CheckboxToggleFieldView(field: field, session: session)
        }
    }
}

/// Single boolean toggle. The label inside the box IS the field's label.
@available(iOS 15.0, *)
private struct CheckboxToggleFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession
    @State private var checked = false

    var body: some View {
        FieldShell(label: nil, required: false, helper: nil, error: session.fieldErrors[field.id]) {
            Button {
                checked.toggle()
                session.setValue(.bool(checked), for: field.id)
            } label: {
                HStack(spacing: 10) {
                    CheckboxBox(checked: checked)
                    Text(field.label)
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .onAppear { checked = session.values[field.id]?.boolValue ?? false }
    }
}

/// Multi-select checkbox group. Stored value is the array of currently-checked
/// option values; a non-array (initial nil, or a legacy boolean) reads as
/// empty so the UI starts unchecked — exactly web's `Array.isArray(value) ? … : []`.
@available(iOS 15.0, *)
private struct CheckboxGroupFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession
    let options: [WidgetOption]

    private var selected: [String] {
        session.values[field.id]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    private func toggle(_ optValue: String) {
        let current = selected
        let next = current.contains(optValue)
            ? current.filter { $0 != optValue }
            : current + [optValue]
        session.setValue(.array(next.map { .string($0) }), for: field.id)
    }

    var body: some View {
        FieldShell(
            label: field.label, required: field.required,
            helper: nil, error: session.fieldErrors[field.id]
        ) {
            VStack(spacing: 6) {
                ForEach(options, id: \.value) { option in
                    let isChecked = selected.contains(option.value)
                    Button {
                        toggle(option.value)
                    } label: {
                        HStack(spacing: 10) {
                            CheckboxBox(checked: isChecked)
                            Text(option.label).font(.system(size: 14)).foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isChecked
                                      ? KYCBrand.primary.opacity(0.08)
                                      : Color(.secondarySystemBackground))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Shared square check-box visual used by both checkbox variants.
@available(iOS 15.0, *)
private struct CheckboxBox: View {
    let checked: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(checked ? KYCBrand.primary : Color(.systemGray3), lineWidth: 2)
                .frame(width: 20, height: 20)
            if checked {
                RoundedRectangle(cornerRadius: 4).fill(KYCBrand.primary).frame(width: 20, height: 20)
                Image(systemName: "checkmark").foregroundColor(.white).font(.system(size: 12, weight: .bold))
            }
        }
    }
}
#endif
