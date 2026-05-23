import Foundation

/// 1:1 Swift port of `kyc-web-wiget-v2/src/services/rejectedLogApi.ts`.
///
/// Fetches the most recent rejection reason for a `(processToken, kycType)`
/// pair from the legacy V1 query `KycRejectedLogForModal`. The backend may
/// return an empty string when no rejection log exists — the caller treats
/// empty as "nothing to show" and renders no banner.
@MainActor
final class RejectedLogAPI {
    private let client: GraphQLClient
    init(client: GraphQLClient) { self.client = client }

    func reason(processToken: String, kycType: String) async throws -> String {
        let query = """
        query KycRejectedLogForModal($processToken: String!, $kycType: String!) {
          KycRejectedLogForModal(processToken: $processToken, kycType: $kycType)
        }
        """
        // The backend response is a String scalar (`KycRejectedLogForModal: String!`).
        // Empty string => no log; the banner stays hidden.
        return try await client.execute(
            query: query,
            variables: ["processToken": processToken, "kycType": kycType],
            rootField: "KycRejectedLogForModal",
            as: String.self
        )
    }
}
