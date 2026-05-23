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
    /// Provider auth/flag flags — backend GraphQL schema declares these as
    /// `Boolean` (see `kyc-backend/src/services/kyc/typeDefs.ts:
    /// RBVNVerificationFlowType`). Web treats them as `string` only because
    /// JavaScript doesn't type-check; Swift can't be that loose.
    public let auth: Bool
    public let flag: Bool
    public let redirectUrl: String?
    public let rawData: AnyCodable?
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
        // Types match the GraphQL schema at
        // `kyc-backend/src/services/kyc/typeDefs.ts:RBVNVerificationFlowType`
        // — msg:String, auth:Boolean, flag:Boolean, data:JSON. All are
        // optional because the backend resolver returns `undefined` (→ GQL
        // null at every field) when the upstream BVN provider errors out
        // and `bvnService.ts:95` swallows the exception.
        struct RawFlow: Decodable {
            let msg: String?
            let auth: Bool?
            let flag: Bool?
            let data: AnyCodable?
        }
        let mutation = """
        mutation RequestBVNVerificationFlow($processToken: String, $kycType: String) {
          RequestBVNVerificationFlow(processToken: $processToken, kycType: $kycType) {
            msg auth flag data
          }
        }
        """
        print("[KYC BvnAPI] requestFlow processToken=\(processToken.prefix(8))… kycType=\(kycType)")
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
        print("[KYC BvnAPI] requestFlow done msg=\(raw.msg ?? "-") auth=\(raw.auth.map(String.init) ?? "-") flag=\(raw.flag.map(String.init) ?? "-") redirectUrl=\(redirectUrl ?? "<nil>")")
        return BvnFlow(
            msg: raw.msg ?? "",
            auth: raw.auth ?? false,
            flag: raw.flag ?? false,
            redirectUrl: redirectUrl,
            rawData: raw.data
        )
    }
}
