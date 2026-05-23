import Foundation

/// 1:1 Swift port of `kyc-web-wiget-v2/src/services/kycApi.ts:submitKyc`.
@MainActor
final class KycSubmissionAPI {
    private let client: GraphQLClient
    init(client: GraphQLClient) { self.client = client }

    /// Run the `KycSubmission` mutation. Returns the message the backend
    /// responds with — usually an opaque success indicator.
    func submit(_ payload: BuildSubmission.BuiltPayload) async throws -> String {
        let mutation = """
        mutation KycSubmission($data: KycPayloadV2!) {
          KycSubmission(data: $data)
        }
        """
        // The backend ships `KycSubmission` as a JSON scalar — decode as
        // AnyCodable then coerce to whatever string-shaped result it returns.
        let result = try await client.execute(
            query: mutation,
            variables: ["data": payload.toVariable()],
            rootField: "KycSubmission",
            as: AnyCodable.self
        )
        if let s = result.stringValue { return s }
        if let dict = result.dictValue, let message = dict["message"]?.stringValue { return message }
        return "Submitted"
    }
}
