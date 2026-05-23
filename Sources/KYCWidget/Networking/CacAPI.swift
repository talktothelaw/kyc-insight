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

    func executeChecks(processToken: String, providerId: String?, levelSlug: String?, businessId: String, checks: [String]) async throws -> CacExecuteResponse {
        let mutation = """
        mutation executeCacBusinessChecks($input: ExecuteCacBusinessChecksInput!) {
          executeCacBusinessChecks(input: $input) {
            success error message requirementState kycSubmissionId
            results { check billed success message }
          }
        }
        """
        var input: [String: Any] = [
            "processToken": processToken,
            "selectedBusinessId": businessId,
            "checks": checks,
        ]
        if let providerId { input["providerId"] = providerId }
        if let levelSlug  { input["levelSlug"]  = levelSlug }
        return try await client.execute(
            query: mutation, variables: ["input": input],
            rootField: "executeCacBusinessChecks",
            as: CacExecuteResponse.self
        )
    }
}
