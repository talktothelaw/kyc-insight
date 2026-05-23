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

@available(iOS 15.0, *)
struct CheckboxFieldView: View {
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
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(checked ? KYCBrand.primary : Color(.systemGray3), lineWidth: 2)
                            .frame(width: 20, height: 20)
                        if checked {
                            RoundedRectangle(cornerRadius: 4).fill(KYCBrand.primary).frame(width: 20, height: 20)
                            Image(systemName: "checkmark").foregroundColor(.white).font(.system(size: 12, weight: .bold))
                        }
                    }
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
#endif
