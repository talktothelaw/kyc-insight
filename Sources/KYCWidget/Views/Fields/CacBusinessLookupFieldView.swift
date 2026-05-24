#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Native CAC Business Lookup. 1:1 port of
/// `kyc-web-wiget-v2/src/components/fields/CacBusinessLookupField.tsx`.
///
/// Three-step flow:
///   1. Search by business name (`searchCacBusinesses` mutation).
///   2. Customer picks one match from the result list.
///   3. Run the configured checks (`executeCacBusinessChecks`) — backend
///      writes a kyc_v2 row and returns `kycSubmissionId`, which we store
///      on the field value so the submission engine surfaces it as a
///      `{ field, value, type: 'ref' }` entry.
@available(iOS 15.0, *)
struct CacBusinessLookupFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession

    @State private var query: String = ""
    @State private var phase: Phase = .search
    @State private var matches: [CacBusinessMatch] = []
    @State private var picked: CacBusinessMatch?
    @State private var statusMessage: String?

    /// Always-on checks the example demos. In real production these come
    /// from `extras` on the field; the simulator demo just runs the basic set.
    private let allChecks = ["directors", "shareholders", "secretary", "psc", "status_report"]

    enum Phase: Equatable { case search, searching, pickingBusiness, executing, done, failed }

    var body: some View {
        FieldShell(
            label: field.label, required: field.required,
            helper: "Search for your registered business by name, pick the match, and we'll pull the CAC checks.",
            error: session.fieldErrors[field.id]
        ) {
            VStack(spacing: 10) {
                if phase != .done {
                    FieldBox {
                        HStack {
                            TextField("Business name", text: $query)
                                .font(.system(size: 15))
                                .disabled(phase != .search && phase != .failed)
                            Button(action: { Task { await search() } }) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(KYCBrand.primary)
                            }
                            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || phase == .searching)
                        }
                    }
                }

                switch phase {
                case .searching: ProgressView("Searching…").controlSize(.small)
                case .pickingBusiness, .executing:
                    matchesList
                case .done:
                    if let picked {
                        completedCard(picked)
                    }
                case .failed:
                    if let statusMessage {
                        Text(statusMessage).font(.system(size: 12)).foregroundColor(.red)
                    }
                default: EmptyView()
                }
            }
        }
    }

    private var matchesList: some View {
        VStack(spacing: 6) {
            ForEach(matches) { match in
                Button { Task { await execute(for: match) } } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.name ?? "Unnamed").font(.system(size: 14, weight: .semibold))
                            HStack(spacing: 6) {
                                if let rc = match.rcNumber { Text("RC \(rc)") }
                                if let type = match.type { Text("· \(type)") }
                            }
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        }
                        Spacer()
                        if phase == .executing, picked?.id == match.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "chevron.right").foregroundColor(.secondary).font(.system(size: 12))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(phase == .executing)
            }
        }
    }

    private func completedCard(_ picked: CacBusinessMatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                Text(picked.name ?? "Verified").font(.system(size: 15, weight: .semibold))
            }
            if let rc = picked.rcNumber {
                Text("RC \(rc)").font(.system(size: 12)).foregroundColor(.secondary)
            }
            Text("\(allChecks.count) CAC check\(allChecks.count == 1 ? "" : "s") executed")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08))
        .cornerRadius(10)
    }

    private func search() async {
        phase = .searching
        statusMessage = nil
        let api = CacAPI(client: GraphQLClient(endpoint: session.config.gqlEndpoint, publicKey: session.config.publicKey))
        do {
            let res = try await api.search(
                processToken: session.schema?.processToken ?? "",
                providerId: session.currentSection?.providerId,
                levelSlug: session.currentStep?.slug,
                name: query.trimmingCharacters(in: .whitespaces)
            )
            matches = res.matches ?? []
            phase = matches.isEmpty ? .failed : .pickingBusiness
            if matches.isEmpty { statusMessage = res.message ?? "No matches found." }
        } catch {
            phase = .failed
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func execute(for match: CacBusinessMatch) async {
        picked = match
        phase = .executing
        let api = CacAPI(client: GraphQLClient(endpoint: session.config.gqlEndpoint, publicKey: session.config.publicKey))
        do {
            var businessSnapshot: [String: Any] = ["id": match.id]
            if let name = match.name             { businessSnapshot["name"] = name }
            if let rc = match.rcNumber           { businessSnapshot["rcNumber"] = rc }
            if let addr = match.address          { businessSnapshot["address"] = addr }
            if let type = match.type             { businessSnapshot["type"] = type }
            if let status = match.status         { businessSnapshot["status"] = status }
            if let reg = match.registrationDate  { businessSnapshot["registrationDate"] = reg }
            let res = try await api.executeChecks(
                processToken: session.schema?.processToken ?? "",
                providerId: session.currentSection?.providerId,
                levelSlug: session.currentStep?.slug,
                companyId: match.id,
                selectedBusiness: businessSnapshot,
                checks: allChecks
            )
            if let kycSubmissionId = res.kycSubmissionId, res.success {
                phase = .done
                session.setValue(.object([
                    "verified":         .bool(true),
                    "kycSubmissionId":  .string(kycSubmissionId),
                    "selectedBusiness": .object([
                        "id":       .string(match.id),
                        "name":     .string(match.name ?? ""),
                        "rcNumber": .string(match.rcNumber ?? ""),
                    ]),
                    "executedChecks":   .array(allChecks.map { .string($0) }),
                ]), for: field.id)
            } else {
                phase = .failed
                statusMessage = res.message ?? "Check execution failed."
            }
        } catch {
            phase = .failed
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
#endif
