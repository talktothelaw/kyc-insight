#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

@available(iOS 15.0, *)
struct TextFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession
    let keyboard: UIKeyboardType
    let secure: Bool

    @State private var text: String = ""
    @FocusState private var focused: Bool

    init(field: WidgetField, session: KYCWidgetSession, keyboard: UIKeyboardType, secure: Bool = false) {
        self.field = field
        self.session = session
        self.keyboard = keyboard
        self.secure = secure
    }

    var body: some View {
        FieldShell(
            label: field.label, required: field.required,
            helper: nil, error: session.fieldErrors[field.id]
        ) {
            FieldBox {
                HStack {
                    Group {
                        if secure {
                            SecureField(field.label, text: $text)
                        } else {
                            TextField(field.label, text: $text)
                        }
                    }
                    .keyboardType(keyboard)
                    .autocapitalization(autocap)
                    .disableAutocorrection(disableAutocorrect)
                    .focused($focused)
                    if !text.isEmpty {
                        Button {
                            text = ""
                            session.setValue(.string(""), for: field.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 15, design: keyboard == .numberPad || keyboard == .phonePad ? .monospaced : .default))
            }
        }
        .onAppear {
            if let existing = session.values[field.id]?.stringValue { text = existing }
        }
        .onChange(of: text) { newValue in
            session.setValue(.string(newValue), for: field.id)
        }
    }

    private var autocap: UITextAutocapitalizationType {
        switch keyboard {
        case .emailAddress, .phonePad, .numberPad, .URL: return .none
        default: return .sentences
        }
    }
    private var disableAutocorrect: Bool {
        switch keyboard {
        case .emailAddress, .phonePad, .numberPad, .URL: return true
        default: return false
        }
    }
}

@available(iOS 15.0, *)
struct DateFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession
    @State private var date: Date = Date()

    var body: some View {
        FieldShell(
            label: field.label, required: field.required,
            helper: nil, error: session.fieldErrors[field.id]
        ) {
            FieldBox {
                HStack {
                    DatePicker("", selection: $date, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .onChange(of: date) { newValue in
                            let iso = Self.iso.string(from: newValue)
                            session.setValue(.string(iso), for: field.id)
                        }
                    Spacer()
                }
            }
        }
    }

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = .init(identifier: "en_US_POSIX")
        return f
    }()
}
#endif
