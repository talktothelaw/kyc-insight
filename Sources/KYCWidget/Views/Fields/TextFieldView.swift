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

/// Date OR Date+Time picker. `withTime` is set by FieldRenderer based on
/// the field kind — `.date` → just the date (yyyy-MM-dd), `.datetime` →
/// date + time spinner (yyyy-MM-dd'T'HH:mm). Submission format matches
/// the web's `<input type="date">` / `<input type="datetime-local">`
/// output exactly so the backend sees the same wire shape from both
/// clients.
@available(iOS 15.0, *)
struct DateFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession
    let withTime: Bool
    @State private var date: Date = Date()

    init(field: WidgetField, session: KYCWidgetSession, withTime: Bool = false) {
        self.field = field
        self.session = session
        self.withTime = withTime
    }

    var body: some View {
        FieldShell(
            label: field.label, required: field.required,
            helper: nil, error: session.fieldErrors[field.id]
        ) {
            FieldBox {
                HStack {
                    DatePicker(
                        "",
                        selection: $date,
                        in: ...Date(),
                        displayedComponents: withTime ? [.date, .hourAndMinute] : .date
                    )
                    .labelsHidden()
                    .onChange(of: date) { newValue in
                        let iso = (withTime ? Self.datetimeIso : Self.dateIso).string(from: newValue)
                        session.setValue(.string(iso), for: field.id)
                    }
                    Spacer()
                }
            }
        }
        .onAppear {
            // Restore prior value if present, otherwise leave the picker
            // on `Date()` without writing — the user has to interact to
            // populate the field, matching web behaviour where the
            // <input> is blank until the user picks.
            if let s = session.values[field.id]?.stringValue, !s.isEmpty,
               let parsed = (withTime ? Self.datetimeIso : Self.dateIso).date(from: s) {
                date = parsed
            }
        }
    }

    private static let dateIso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = .init(identifier: "en_US_POSIX")
        // Pin to the user's current time zone so the calendar day the user
        // SAW in the picker is the day we serialize. Without this, native
        // SwiftUI DatePicker stores a Date (UTC-anchored) and the formatter
        // re-interprets it in device locale — users in UTC+1 picking
        // "2026-05-24" could send "2026-05-23" if the underlying Date
        // landed at "2026-05-23T23:00:00Z". Mirrors the web's custom
        // segmented DatePicker which avoids the Date() round-trip entirely.
        f.timeZone = .current
        return f
    }()
    private static let datetimeIso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.locale = .init(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}

/// Native time-only picker. Mirrors `<input type="time">` — emits a
/// canonical `HH:mm` (24-hour) string.
@available(iOS 15.0, *)
struct TimeFieldView: View {
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
                    DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .onChange(of: date) { newValue in
                            session.setValue(.string(Self.timeIso.string(from: newValue)), for: field.id)
                        }
                    Spacer()
                }
            }
        }
        .onAppear {
            if let s = session.values[field.id]?.stringValue, !s.isEmpty,
               let parsed = Self.timeIso.date(from: s) {
                date = parsed
            }
        }
    }

    private static let timeIso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = .init(identifier: "en_US_POSIX")
        return f
    }()
}
#endif
