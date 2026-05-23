import Foundation

/// 1:1 Swift port of `kyc-web-wiget-v2/src/services/locationApi.ts`.
/// Drives the cascading country → state → LGA dropdowns inside
/// ``LocationFieldView``.
public struct LocationCountry: Decodable, Identifiable, Hashable {
    public let _id: String
    public let name: String
    public let code: String?
    public var id: String { _id }
}

public struct LocationState: Decodable, Identifiable, Hashable {
    public let _id: String
    public let name: String
    public let code: String?
    public let lgas: [String]?
    public var id: String { _id }
}

@MainActor
final class LocationAPI {
    private let client: GraphQLClient
    init(client: GraphQLClient) { self.client = client }

    private struct CountriesEnvelope: Decodable { let getActiveCountries: [LocationCountry] }
    func countries() async throws -> [LocationCountry] {
        let query = "query GetActiveCountries { getActiveCountries { _id name code } }"
        let env = try await client.execute(
            query: query, variables: nil,
            rootField: "getActiveCountries",
            as: [LocationCountry].self
        )
        return env
    }

    func states(countryId: String) async throws -> [LocationState] {
        let query = """
        query GetStates($countryId: ID!) {
          getStates(countryId: $countryId) { _id name code lgas }
        }
        """
        return try await client.execute(
            query: query, variables: ["countryId": countryId],
            rootField: "getStates",
            as: [LocationState].self
        )
    }

    func lgas(stateId: String) async throws -> [String] {
        let query = """
        query GetLocalGovernmentArea($stateId: ID!) {
          getLocalGovernmentArea(stateId: $stateId)
        }
        """
        return try await client.execute(
            query: query, variables: ["stateId": stateId],
            rootField: "getLocalGovernmentArea",
            as: [String].self
        )
    }
}
