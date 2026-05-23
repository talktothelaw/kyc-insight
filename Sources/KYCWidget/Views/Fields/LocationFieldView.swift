#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Native LocationField. Each location-kind field (country / state / lga)
/// renders independently as an action-sheet select, but they cascade:
///   • country → triggers `getStates(countryId:)` for any peer state field
///     sharing the same prefix group.
///   • state → triggers `getLocalGovernmentArea(stateId:)` for any peer lga.
///
/// Cross-field coordination flows through the shared ``LocationStore`` on
/// the session — one store per prefix group keeps all related dropdowns
/// in sync so re-selecting the country properly clears stale state + lga.
@available(iOS 15.0, *)
struct LocationFieldView: View {
    let field: WidgetField
    @ObservedObject var session: KYCWidgetSession
    @StateObject private var loader: LocationLoader
    @State private var presenting = false

    init(field: WidgetField, session: KYCWidgetSession) {
        self.field = field
        self.session = session
        _loader = StateObject(wrappedValue: LocationLoader.shared(for: session))
    }

    private var tier: LocationTier { .from(field.name) }
    private var prefix: String { SchemaNormalizer.locationPrefix(field.name) }

    var body: some View {
        FieldShell(
            label: field.label, required: field.required,
            helper: helperText,
            error: session.fieldErrors[field.id]
        ) {
            Button { presenting = true } label: {
                FieldBox {
                    HStack {
                        Text(displayLabel)
                            .font(.system(size: 15))
                            .foregroundColor(displayLabel == placeholder ? .secondary : .primary)
                        Spacer()
                        if loader.isLoading(for: tier, prefix: prefix) {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }
        .sheet(isPresented: $presenting) {
            SearchableOptionSheet(
                title: field.label,
                subtitle: locationSheetSubtitle,
                options: options,
                selected: options.first(where: { $0.value == currentSelectionId }),
                labelFor: { $0.label },
                detailFor: { $0.detail }
            ) { picked in
                select(picked)
            }
        }
        .task {
            // Auto-load countries on first appear; states/lgas only after parent picked.
            if tier == .country { await loader.loadCountries() }
        }
        .onAppear {
            if let existing = session.values[field.id]?.dictValue {
                if let id = existing["_id"]?.stringValue {
                    loader.markSelection(tier: tier, prefix: prefix, id: id)
                }
            }
        }
    }

    // MARK: - Display

    private var placeholder: String {
        switch tier {
        case .country: return "Select country"
        case .state:   return parentCountrySelected ? "Select state" : "Pick a country first"
        case .lga:     return parentStateSelected   ? "Select LGA"   : "Pick a state first"
        }
    }
    private var displayLabel: String {
        if let dict = session.values[field.id]?.dictValue,
           let name = dict["name"]?.stringValue {
            return name
        }
        return placeholder
    }
    private var helperText: String? {
        switch tier {
        case .country: return nil
        case .state:   return "Choose your country to populate states."
        case .lga:     return "Choose your state to populate LGAs."
        }
    }
    private var isDisabled: Bool {
        switch tier {
        case .country: return loader.isLoading(for: .country, prefix: prefix)
        case .state:   return !parentCountrySelected
        case .lga:     return !parentStateSelected
        }
    }
    private var parentCountrySelected: Bool {
        loader.selectedCountryId(prefix: prefix) != nil
    }
    private var parentStateSelected: Bool {
        loader.selectedStateId(prefix: prefix) != nil
    }

    // MARK: - Options pulled from the loader

    private var options: [LocOption] {
        switch tier {
        case .country:
            return loader.countries.map { LocOption(label: $0.name, detail: $0.code, value: $0._id) }
        case .state:
            return loader.states(prefix: prefix).map { LocOption(label: $0.name, detail: $0.code, value: $0._id) }
        case .lga:
            return loader.lgas(prefix: prefix).map { LocOption(label: $0, detail: nil, value: $0) }
        }
    }

    private var currentSelectionId: String {
        session.values[field.id]?.dictValue?["_id"]?.stringValue ?? ""
    }

    private var locationSheetSubtitle: String? {
        switch tier {
        case .country: return "Pick the customer's country."
        case .state:   return "Filtered for the selected country."
        case .lga:     return "Filtered for the selected state."
        }
    }

    struct LocOption: Identifiable, Hashable {
        let label: String
        let detail: String?
        let value: String
        var id: String { value }
    }

    private func select(_ option: LocOption) {
        // Store as a compact `{ _id, name }` so the submission engine has
        // both the backend id (to send) and the human label (for analytics).
        session.setValue(.object([
            "_id":  .string(option.value),
            "name": .string(option.label),
        ]), for: field.id)
        loader.markSelection(tier: tier, prefix: prefix, id: option.value)

        // Cascade — load children automatically.
        Task {
            switch tier {
            case .country: await loader.loadStates(countryId: option.value, prefix: prefix)
            case .state:   await loader.loadLgas(stateId: option.value, prefix: prefix)
            case .lga:     break
            }
        }
    }
}

// MARK: - Tier enum

enum LocationTier { case country, state, lga
    static func from(_ name: String) -> LocationTier {
        let n = name.lowercased()
        if n.contains("country") { return .country }
        if n.contains("state") || n.contains("region") || n.contains("province") { return .state }
        return .lga
    }
}

// MARK: - LocationLoader — one per session, shared across fields by prefix

@available(iOS 15.0, *)
@MainActor
final class LocationLoader: ObservableObject {
    @Published private(set) var countries: [LocationCountry] = []
    @Published private(set) var statesByPrefix: [String: [LocationState]] = [:]
    @Published private(set) var lgasByPrefix:   [String: [String]] = [:]
    @Published private(set) var loadingTiers:   Set<String> = []   // "<prefix>:<tier>"

    private var selectedCountryIds: [String: String] = [:]
    private var selectedStateIds:   [String: String] = [:]

    private weak var session: KYCWidgetSession?
    private let api: LocationAPI

    // One loader per session — shared lookup avoids re-fetching for every
    // peer field in the same prefix group.
    private static var registry: [ObjectIdentifier: LocationLoader] = [:]
    static func shared(for session: KYCWidgetSession) -> LocationLoader {
        let key = ObjectIdentifier(session)
        if let existing = registry[key] { return existing }
        let loader = LocationLoader(session: session)
        registry[key] = loader
        return loader
    }
    /// Drop the loader entry for a session — called from
    /// ``KYCWidgetSession/deinit`` so a fresh "start verification" hits the
    /// backend with no leftover countries / states / lgas in memory.
    nonisolated static func evict(for key: ObjectIdentifier) {
        // Hop to the main actor since the registry is a main-actor static.
        Task { @MainActor in registry.removeValue(forKey: key) }
    }

    init(session: KYCWidgetSession) {
        self.session = session
        let endpoint = session.config.gqlEndpoint
        let key = session.config.publicKey
        self.api = LocationAPI(client: GraphQLClient(endpoint: endpoint, publicKey: key))
    }

    func isLoading(for tier: LocationTier, prefix: String) -> Bool {
        loadingTiers.contains("\(prefix):\(tier)")
    }

    func selectedCountryId(prefix: String) -> String? { selectedCountryIds[prefix] }
    func selectedStateId(prefix: String) -> String?   { selectedStateIds[prefix] }
    func states(prefix: String) -> [LocationState]    { statesByPrefix[prefix] ?? [] }
    func lgas(prefix: String) -> [String]             { lgasByPrefix[prefix] ?? [] }

    func markSelection(tier: LocationTier, prefix: String, id: String) {
        switch tier {
        case .country:
            selectedCountryIds[prefix] = id
            // Selecting a new country invalidates the state + lga choices.
            selectedStateIds.removeValue(forKey: prefix)
            statesByPrefix.removeValue(forKey: prefix)
            lgasByPrefix.removeValue(forKey: prefix)
        case .state:
            selectedStateIds[prefix] = id
            lgasByPrefix.removeValue(forKey: prefix)
        case .lga:
            break
        }
    }

    func loadCountries() async {
        guard countries.isEmpty else { return }
        let key = "all:country"
        loadingTiers.insert(key)
        defer { loadingTiers.remove(key) }
        do { countries = try await api.countries() }
        catch { /* swallow — leave dropdown empty so user retries */ }
    }

    func loadStates(countryId: String, prefix: String) async {
        let key = "\(prefix):state"
        loadingTiers.insert(key)
        defer { loadingTiers.remove(key) }
        do { statesByPrefix[prefix] = try await api.states(countryId: countryId) }
        catch { }
    }

    func loadLgas(stateId: String, prefix: String) async {
        let key = "\(prefix):lga"
        loadingTiers.insert(key)
        defer { loadingTiers.remove(key) }
        do { lgasByPrefix[prefix] = try await api.lgas(stateId: stateId) }
        catch { }
    }
}
#endif
