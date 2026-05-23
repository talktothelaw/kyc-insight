import Foundation

/// 1:1 Swift port of `kyc-web-wiget-v2/src/services/bvnApi.ts`.
public enum BvnStatusState: String, Decodable, Sendable {
    case not_started, in_progress, completed, failed, expired
}

public struct BvnStatus: Decodable, Sendable {
    public let state: BvnStatusState
    public let kycStatus: String?
    public let sessionAgeSeconds: Int?
    public let verificationUrl: String?
    public let message: String?
}

public struct BvnFlow: Sendable {
    public let msg: String
    public let auth: String
    public let flag: String
    public let redirectUrl: String?
}

@MainActor
final class BvnAPI {
    private let client: GraphQLClient
    init(client: GraphQLClient) { self.client = client }

    func getStatus(processToken: String, kycType: String?) async throws -> BvnStatus {
        let query = """
        query GetBvnStatus($processToken: String!, $kycType: String) {
          getBvnStatus(processToken: $processToken, kycType: $kycType) {
            state kycStatus sessionAgeSeconds verificationUrl message
          }
        }
        """
        var vars: [String: Any] = ["processToken": processToken]
        if let kycType { vars["kycType"] = kycType }
        return try await client.execute(
            query: query, variables: vars,
            rootField: "getBvnStatus",
            as: BvnStatus.self
        )
    }

    func requestFlow(processToken: String, kycType: String) async throws -> BvnFlow {
        struct RawFlow: Decodable { let msg: String; let auth: String; let flag: String; let data: AnyCodable? }
        let mutation = """
        mutation RequestBVNVerificationFlow($processToken: String, $kycType: String) {
          RequestBVNVerificationFlow(processToken: $processToken, kycType: $kycType) {
            msg auth flag data
          }
        }
        """
        let raw = try await client.execute(
            query: mutation,
            variables: ["processToken": processToken, "kycType": kycType],
            rootField: "RequestBVNVerificationFlow",
            as: RawFlow.self
        )
        // Drill into data.validRecords[0].url — same path the web does.
        var redirectUrl: String?
        if let valid = raw.data?.dictValue?["validRecords"]?.arrayValue,
           let first = valid.first?.dictValue,
           let url = first["url"]?.stringValue {
            redirectUrl = url
        }
        return BvnFlow(msg: raw.msg, auth: raw.auth, flag: raw.flag, redirectUrl: redirectUrl)
    }
}
