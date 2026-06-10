import Foundation

/// 1:1 Swift port of `kyc-web-wiget-v2/src/services/cacApi.ts`.
public struct CacBusinessMatch: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String?
    public let rcNumber: String?
    public let address: String?
    public let type: String?
    public let status: String?
    public let registrationDate: String?
}

public struct CacSearchResponse: Decodable, Sendable {
    public let success: Bool
    public let error: Bool
    public let message: String?
    public let matches: [CacBusinessMatch]?
}

public struct CacExecuteResultRow: Decodable, Sendable {
    public let check: String
    public let billed: Bool?
    public let success: Bool?
    public let message: String?
}

public struct CacExecuteResponse: Decodable, Sendable {
    public let success: Bool
    public let error: Bool
    public let message: String?
    public let requirementState: String?
    public let kycSubmissionId: String?
    public let results: [CacExecuteResultRow]?
}

public struct CacEnabledCheck: Decodable, Sendable, Hashable {
    public let key: String
    public let enabled: Bool
}

public struct CacEnabledChecksResponse: Decodable, Sendable {
    public let success: Bool
    public let error: Bool
    public let message: String?
    public let checks: [CacEnabledCheck]?
}

public struct FinalizeCacRequirementResponse: Decodable, Sendable {
    public let success: Bool
    public let error: Bool
    public let message: String?
    public let requirementState: String?
    public let kycSubmissionId: String?
}

@MainActor
final class CacAPI {
    private let client: GraphQLClient
    init(client: GraphQLClient) { self.client = client }

    func search(processToken: String, providerId: String?, levelSlug: String?, name: String) async throws -> CacSearchResponse {
        let mutation = """
        mutation searchCacBusinesses($input: SearchCacBusinessesInput!) {
          searchCacBusinesses(input: $input) {
            success error message
            matches { id name rcNumber address type status registrationDate }
          }
        }
        """
        var input: [String: Any] = ["processToken": processToken, "name": name]
        if let providerId { input["providerId"] = providerId }
        if let levelSlug  { input["levelSlug"]  = levelSlug }
        return try await client.execute(
            query: mutation, variables: ["input": input],
            rootField: "searchCacBusinesses",
            as: CacSearchResponse.self
        )
    }

    /// Backend `ExecuteCacBusinessChecksInput` requires `companyId: String!`
    /// AND `selectedBusiness: JSON!` (audit snapshot). The earlier
    /// `selectedBusinessId` field never existed — sending it raises
    /// "Field 'selectedBusinessId' is not defined" before the resolver runs.
    func executeChecks(processToken: String, providerId: String?, levelSlug: String?, companyId: String, selectedBusiness: [String: Any], checks: [String]) async throws -> CacExecuteResponse {
        let mutation = """
        mutation executeCacBusinessChecks($input: ExecuteCacBusinessChecksInput!) {
          executeCacBusinessChecks(input: $input) {
            success error message requirementState kycSubmissionId
            results { check billed success message }
          }
        }
        """
        var input: [String: Any] = [
            "processToken":     processToken,
            "companyId":        companyId,
            "selectedBusiness": selectedBusiness,
            "checks":           checks,
        ]
        if let providerId { input["providerId"] = providerId }
        if let levelSlug  { input["levelSlug"]  = levelSlug }
        return try await client.execute(
            query: mutation, variables: ["input": input],
            rootField: "executeCacBusinessChecks",
            as: CacExecuteResponse.self
        )
    }

    // Returns each CAC sub-check + whether its underlying provider is enabled
    // by the super-admin. Used to hide rows the merchant has disabled (e.g.
    // shareholders) before the customer can pick them.
    func getEnabledChecks() async throws -> CacEnabledChecksResponse {
        let query = """
        query getCacEnabledChecks {
          getCacEnabledChecks {
            success error message
            checks { key enabled }
          }
        }
        """
        return try await client.execute(
            query: query, variables: [:],
            rootField: "getCacEnabledChecks",
            as: CacEnabledChecksResponse.self
        )
    }

    /// Step 3 — merge a CAC section's post-verification form fields into the
    /// held CAC submission so they land on ONE combined kyc_v2 row instead of a
    /// separate, disconnected one. Mirrors consent `finalizeRequirement` but
    /// keyed by the held CAC's `kycSubmissionId`. 1:1 with web
    /// `cacApi.finalizeCacRequirement` / backend `services/cac`
    /// `finalizeCacRequirement` resolver and Android `CacAPI.finalizeCacRequirement`.
    ///
    /// `additionalPayload` is the JSON `{ kycPayload: [{field, value, type?}], optionalType? }`.
    func finalizeCacRequirement(
        processToken: String,
        kycSubmissionId: String,
        providerId: String?,
        levelSlug: String?,
        additionalPayload: [String: Any]?
    ) async throws -> FinalizeCacRequirementResponse {
        let mutation = """
        mutation finalizeCacRequirement($input: FinalizeCacRequirementInput!) {
          finalizeCacRequirement(input: $input) {
            success error message requirementState kycSubmissionId
          }
        }
        """
        var input: [String: Any] = [
            "processToken":    processToken,
            "kycSubmissionId": kycSubmissionId,
        ]
        if let providerId        { input["providerId"]        = providerId }
        if let levelSlug         { input["levelSlug"]         = levelSlug }
        if let additionalPayload { input["additionalPayload"] = additionalPayload }
        return try await client.execute(
            query: mutation, variables: ["input": input],
            rootField: "finalizeCacRequirement",
            as: FinalizeCacRequirementResponse.self
        )
    }
}
