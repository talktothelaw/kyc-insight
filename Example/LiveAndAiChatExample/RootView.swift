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
    /// Custom GraphQL gateway. Mirrors the web playground's
    /// `gqlEndpoint` field — defaults to production but the developer can
    /// flip to localhost for local kyc-backend iteration. Simulator can
    /// reach the host machine via `http://localhost:PORT`; a physical
    /// device needs the host's LAN IP (e.g. `http://192.168.1.42:3000`).
    @State private var gqlEndpoint = "https://kyc-api.netapps.ng/graphql"

    @State private var log: [EventLogEntry] = []
    @State private var widget: KYCWidget?

    /// One row in the Event Log. The `kind` drives the badge colour +
    /// label so each lifecycle event is scannable at a glance.
    struct EventLogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let kind: EventKind
        let detail: String
    }
    enum EventKind: String {
        case info, ready, levelChange, levelApproved, submit, success, error, close
        var label: String {
            switch self {
            case .info:          return "INFO"
            case .ready:         return "READY"
            case .levelChange:   return "LEVEL CHANGE"
            case .levelApproved: return "LEVEL APPROVED"
            case .submit:        return "SUBMIT"
            case .success:       return "SUCCESS"
            case .error:         return "ERROR"
            case .close:         return "CLOSE"
            }
        }
        var color: Color {
            switch self {
            case .info:          return .secondary
            case .ready:         return .blue
            case .levelChange:   return .purple
            case .levelApproved: return .green
            case .submit:        return .orange
            case .success:       return .green
            case .error:         return .red
            case .close:         return .gray
            }
        }
    }

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

                    section("Gateway") {
                        field("GraphQL endpoint", text: $gqlEndpoint, mono: true)
                        HStack(spacing: 8) {
                            preset("Production", "https://kyc-api.netapps.ng/graphql")
                            preset("Localhost",  "http://localhost:3000/graphql")
                            preset("Sim host",   "http://127.0.0.1:3000/graphql")
                        }
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
    private func preset(_ label: String, _ value: String) -> some View {
        Button(label) { gqlEndpoint = value }
            .font(.system(size: 11, weight: .medium))
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(
                (gqlEndpoint == value
                    ? Color(red: 0.12, green: 0.23, blue: 0.54)
                    : Color(.tertiarySystemBackground))
            )
            .foregroundColor(gqlEndpoint == value ? .white : .primary)
            .cornerRadius(6)
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if log.isEmpty {
                            Text("No events yet. Tap “Start verification”.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(log) { entry in
                                eventRow(entry).id(entry.id)
                            }
                        }
                    }
                }
                .onChange(of: log.count) { _ in
                    // Auto-scroll to the latest event so you don't
                    // have to drag to find it during a live run.
                    if let last = log.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            .frame(minHeight: 200, maxHeight: 320)
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
        let trimmedEndpoint = gqlEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = URL(string: trimmedEndpoint) ?? KYCWidgetConfig.defaultGQLEndpoint
        appendLog(.info, "Endpoint → \(endpoint.absoluteString)")
        let config = KYCWidgetConfig(
            publicKey: publicKey.trimmingCharacters(in: .whitespacesAndNewlines),
            userRef:   userRef.trimmingCharacters(in: .whitespacesAndNewlines),
            slug:      slug.trimmingCharacters(in: .whitespacesAndNewlines),
            name:      name.trimmingCharacters(in: .whitespacesAndNewlines),
            levelSlug: levelSlug.trimmingCharacters(in: .whitespacesAndNewlines),
            vName: vName.isEmpty ? nil : vName,
            display: .modal,
            gqlEndpoint: endpoint,
            demoMode: false  // ← always hit the real backend on tap; no cached / mocked schema
        )

        let w = KYCWidget(config: config)
        // EVERY public callback the KYCWidget exposes — wired here so
        // the Event Log shows you exactly when each fires in real time.
        // Payloads are surfaced where they exist (section name for
        // SUBMIT, level slug + index for LEVEL CHANGE / LEVEL APPROVED,
        // typed error description for ERROR) so you can see what's
        // happening without attaching a debugger.
        w.onReady = {
            appendLog(.ready, "Widget loaded — schema fetched, cursor placed")
        }
        w.onLevelChange = { (lvl: KYCWidgetLevel) in
            appendLog(.levelChange, "→ \(lvl.slug) (index \(lvl.index))")
        }
        w.onLevelApproved = { (lvl: KYCWidgetLevel) in
            appendLog(.levelApproved, "✓ \(lvl.slug) (index \(lvl.index)) — every section approved")
        }
        w.onSubmit = { (payload: Any?) in
            let sectionName = (payload as? WidgetSection)?.name ?? "(unknown section)"
            appendLog(.submit, "Section ‘\(sectionName)’ submitted")
        }
        w.onSuccess = { _ in
            appendLog(.success, "All tiers complete — verification submitted")
        }
        w.onError = { (err: KYCWidgetError) in
            appendLog(.error, err.localizedDescription)
        }
        w.onClose = {
            appendLog(.close, "User dismissed the widget")
            widget = nil
        }
        widget = w

        guard let presenter = topPresentedViewController() else {
            appendLog(.error, "No presenter view controller found — can't present widget")
            return
        }
        w.present(from: presenter)
    }

    /// Coloured-badge row for one event. The badge label + colour
    /// makes lifecycle events scannable without reading every line.
    @ViewBuilder
    private func eventRow(_ entry: EventLogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(entry.kind.label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.3)
                .foregroundColor(entry.kind.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(entry.kind.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .frame(width: 96, alignment: .leading)
            Text(entry.detail)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// New tagged-append API — every callsite passes the event kind so
    /// the row renders with the right badge colour. The legacy bare
    /// string `appendLog(_ line:)` is gone; everything goes through
    /// this typed entry-point.
    private func appendLog(_ kind: EventKind, _ detail: String) {
        log.append(EventLogEntry(timestamp: Date(), kind: kind, detail: detail))
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
