import SwiftUI
import KYCWidget
import UIKit

/// Sample host UI for the native KYC Insight widget.
///
/// Flow:
/// 1. User edits any of the config fields (defaults are pre-filled with a
///    known-good test set).
/// 2. Taps "Start verification".
/// 3. We construct a `KYCWidgetConfig`, wire every lifecycle callback into
///    an in-memory event log, and present the widget modally.
/// 4. The widget runs the entire verification UI **natively** — SwiftUI
///    forms, native camera capture, native file picker. The only WebView
///    that appears is for external consent providers (Mono NIN / BVN).
struct RootView: View {

    @State private var publicKey  = "NA_PUB_PROD-d762c143e897455f6088fa549e32f6d9"
    @State private var slug       = "mno_kyc_supplier_registration_form"
    @State private var userRef    = "test_01"
    @State private var name       = "Sample Customer"
    @State private var levelSlug  = "tier_1"
    @State private var vName      = "Lawrence"

    @State private var log: [String] = []
    @State private var widget: KYCWidget?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Identity") {
                        field("Public key",  text: $publicKey,  mono: true)
                        field("Slug",        text: $slug,       mono: true)
                        field("User ref",    text: $userRef,    mono: true)
                        field("Name",        text: $name)
                        field("Level slug",  text: $levelSlug,  mono: true)
                        field("vName (optional)", text: $vName)
                    }

                    Button(action: startVerification) {
                        Text("Start verification")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(red: 0.12, green: 0.23, blue: 0.54))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    eventLog
                }
                .padding()
            }
            .navigationTitle("KYC Insight")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(1.0)
            content()
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            TextField(label, text: text)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(6)
        }
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Event log").font(.headline)
                Spacer()
                Text("\(log.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Button("Clear") { log.removeAll() }
                    .font(.system(size: 12, weight: .medium))
                    .disabled(log.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if log.isEmpty {
                        Text("No events yet. Tap “Start verification”.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 240)
            .padding(8)
            .background(Color(.systemBackground))
            .cornerRadius(8)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    // MARK: - Launch

    private func startVerification() {
        let config = KYCWidgetConfig(
            publicKey: publicKey.trimmingCharacters(in: .whitespacesAndNewlines),
            userRef:   userRef.trimmingCharacters(in: .whitespacesAndNewlines),
            slug:      slug.trimmingCharacters(in: .whitespacesAndNewlines),
            name:      name.trimmingCharacters(in: .whitespacesAndNewlines),
            levelSlug: levelSlug.trimmingCharacters(in: .whitespacesAndNewlines),
            vName: vName.isEmpty ? nil : vName,
            display: .modal,
            demoMode: false  // ← always hit the real backend on tap; no cached / mocked schema
        )

        let w = KYCWidget(config: config)
        w.onReady          = { appendLog("READY") }
        w.onLevelChange    = { (lvl: KYCWidgetLevel) in appendLog("LEVEL CHANGE  \(lvl.slug) [\(lvl.index)]") }
        w.onLevelApproved  = { (lvl: KYCWidgetLevel) in appendLog("LEVEL APPROVED \(lvl.slug) [\(lvl.index)]") }
        w.onSubmit         = { _ in appendLog("SUBMIT") }
        w.onSuccess        = { _ in appendLog("SUCCESS") }
        w.onError          = { (err: KYCWidgetError) in appendLog("ERROR  \(err.localizedDescription)") }
        w.onClose          = {
            appendLog("CLOSE")
            widget = nil
        }
        widget = w

        guard let presenter = topPresentedViewController() else {
            appendLog("ERROR  no presenter")
            return
        }
        w.present(from: presenter)
    }

    private func appendLog(_ line: String) {
        let ts = Self.timeFormatter.string(from: Date())
        log.append("\(ts) \(line)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func topPresentedViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
        let root = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
