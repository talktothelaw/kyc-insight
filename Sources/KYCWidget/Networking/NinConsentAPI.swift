import Foundation

/// 1:1 Swift port of `kyc-web-wiget-v2/src/services/ninConsentApi.ts`.
public struct InitiateNinConsentResponse: Decodable, Sendable {
    public let sessionId: String?
    public let widgetUrl: String?
    public let clientId: String?
    public let scope: String?
    public let userRef: String?
}

@MainActor
final class NinConsentAPI {
    private let client: GraphQLClient
    init(client: GraphQLClient) { self.client = client }

    /// Kick off the consent flow. Returns the external auth URL the user
    /// must visit in `WebConsentSheet`.
    func initiate(processToken: String, scope: String?, providerId: String?, levelSlug: String?) async throws -> InitiateNinConsentResponse {
        let mutation = """
        mutation InitiateNinConsent($processToken: String!, $scope: NinAuthScope, $providerId: String, $levelSlug: String) {
          initiateNinConsent(processToken: $processToken, scope: $scope, providerId: $providerId, levelSlug: $levelSlug) {
            sessionId widgetUrl clientId scope userRef
          }
        }
        """
        var vars: [String: Any] = ["processToken": processToken]
        if let scope { vars["scope"] = scope }
        if let providerId { vars["providerId"] = providerId }
        if let levelSlug { vars["levelSlug"] = levelSlug }
        return try await client.execute(
            query: mutation, variables: vars,
            rootField: "initiateNinConsent",
            as: InitiateNinConsentResponse.self
        )
    }

    /// After the user completes the external consent, call this with the
    /// reference returned by the provider. Backend writes kyc_v2 and
    /// returns success — we only need the reference value (opaque token).
    func complete(processToken: String, reference: String, providerId: String?, levelSlug: String?) async throws -> String {
        let mutation = """
        mutation CompleteNinConsent($processToken: String!, $reference: String!, $providerId: String, $levelSlug: String) {
          completeNinConsent(processToken: $processToken, reference: $reference, providerId: $providerId, levelSlug: $levelSlug)
        }
        """
        var vars: [String: Any] = ["processToken": processToken, "reference": reference]
        if let providerId { vars["providerId"] = providerId }
        if let levelSlug { vars["levelSlug"] = levelSlug }
        return try await client.execute(
            query: mutation, variables: vars,
            rootField: "completeNinConsent",
            as: String.self
        )
    }
}
