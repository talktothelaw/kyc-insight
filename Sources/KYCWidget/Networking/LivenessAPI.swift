import Foundation

/// 1:1 Swift port of `kyc-web-wiget-v2/src/services/livenessApi.ts`.
///
/// The backend's session model lives at:
///   `kyc-backend/src/services/liveness/` (model + service + resolver).
///
/// Lifecycle: `createLivenessSession` → run the challenge sequence the
/// server hands back → `submitLivenessEvidence`. The submission response
/// already carries the final verdict (`passed` / `failed` /
/// `requires_manual_review`) — the backend ran its validator + risk
/// scorer atomically.
public struct LivenessCompletedChallengeInput: Codable, Sendable {
    public let code: String
    public let completedAt: String   // ISO-8601
    public let clientPassed: Bool
    public let durationMs: Int?

    public init(code: String, completedAt: String, clientPassed: Bool, durationMs: Int? = nil) {
        self.code = code
        self.completedAt = completedAt
        self.clientPassed = clientPassed
        self.durationMs = durationMs
    }
}

public struct LivenessDeviceMetaInput: Codable, Sendable {
    public let userAgent: String?
    public let platform: String?
    public let cameraLabel: String?

    public init(userAgent: String? = nil, platform: String? = nil, cameraLabel: String? = nil) {
        self.userAgent = userAgent
        self.platform = platform
        self.cameraLabel = cameraLabel
    }
}

public struct LivenessSessionDTO: Decodable, Sendable {
    public let id: String
    public let sessionToken: String
    public let status: String
    public let challengeSequence: [String]
    public let completedChallenges: [Completed]
    public let retryCount: Int
    public let riskScore: Double?
    public let expiresAt: String
    public let failureReason: String?

    public struct Completed: Decodable, Sendable {
        public let code: String
        public let completedAt: String
        public let clientPassed: Bool
        public let durationMs: Int?
    }
}

@MainActor
public final class LivenessAPI {
    private let client: GraphQLClient
    public init(client: GraphQLClient) { self.client = client }

    /// Field set returned by every session-shaped mutation/query. Kept in
    /// one constant so the four calls below stay in sync.
    private static let sessionFields = """
      id
      sessionToken
      status
      challengeSequence
      completedChallenges { code completedAt clientPassed durationMs }
      retryCount
      riskScore
      expiresAt
      failureReason
    """

    public struct CreateInput: Sendable {
        public let userRef: String?
        public let customerId: String?
        public let kycSubmissionId: String?
        public let levelSlug: String?
        public let levelId: String?
        public let requirementId: String?
        public let providerId: String?
        public let deviceMeta: LivenessDeviceMetaInput?
        public let challengesPerSession: Int?

        public init(
            userRef: String? = nil,
            customerId: String? = nil,
            kycSubmissionId: String? = nil,
            levelSlug: String? = nil,
            levelId: String? = nil,
            requirementId: String? = nil,
            providerId: String? = nil,
            deviceMeta: LivenessDeviceMetaInput? = nil,
            challengesPerSession: Int? = nil
        ) {
            self.userRef = userRef
            self.customerId = customerId
            self.kycSubmissionId = kycSubmissionId
            self.levelSlug = levelSlug
            self.levelId = levelId
            self.requirementId = requirementId
            self.providerId = providerId
            self.deviceMeta = deviceMeta
            self.challengesPerSession = challengesPerSession
        }
    }

    public func createSession(_ input: CreateInput) async throws -> LivenessSessionDTO {
        let mutation = """
        mutation CreateLivenessSession($input: CreateLivenessSessionInput!) {
          createLivenessSession(input: $input) { \(Self.sessionFields) }
        }
        """
        var inputDict: [String: Any] = [:]
        if let v = input.userRef            { inputDict["userRef"] = v }
        if let v = input.customerId         { inputDict["customerId"] = v }
        if let v = input.kycSubmissionId    { inputDict["kycSubmissionId"] = v }
        if let v = input.levelSlug          { inputDict["levelSlug"] = v }
        if let v = input.levelId            { inputDict["levelId"] = v }
        if let v = input.requirementId      { inputDict["requirementId"] = v }
        if let v = input.providerId         { inputDict["providerId"] = v }
        if let v = input.challengesPerSession { inputDict["challengesPerSession"] = v }
        if let v = input.deviceMeta {
            var meta: [String: Any] = [:]
            if let s = v.userAgent   { meta["userAgent"] = s }
            if let s = v.platform    { meta["platform"] = s }
            if let s = v.cameraLabel { meta["cameraLabel"] = s }
            inputDict["deviceMeta"] = meta
        }
        return try await client.execute(
            query: mutation,
            variables: ["input": inputDict],
            rootField: "createLivenessSession",
            as: LivenessSessionDTO.self
        )
    }

    public struct SubmitInput: Sendable {
        public let sessionToken: String
        public let selfieImage: String?
        public let livelinessImages: [String]
        public let completedChallenges: [LivenessCompletedChallengeInput]
        public let selfieEvidenceUrl: String?
        public let videoEvidenceUrl: String?

        public init(
            sessionToken: String,
            selfieImage: String? = nil,
            livelinessImages: [String] = [],
            completedChallenges: [LivenessCompletedChallengeInput],
            selfieEvidenceUrl: String? = nil,
            videoEvidenceUrl: String? = nil
        ) {
            self.sessionToken = sessionToken
            self.selfieImage = selfieImage
            self.livelinessImages = livelinessImages
            self.completedChallenges = completedChallenges
            self.selfieEvidenceUrl = selfieEvidenceUrl
            self.videoEvidenceUrl = videoEvidenceUrl
        }
    }

    public func submitEvidence(_ input: SubmitInput) async throws -> LivenessSessionDTO {
        let mutation = """
        mutation SubmitLivenessEvidence($input: SubmitLivenessEvidenceInput!) {
          submitLivenessEvidence(input: $input) { \(Self.sessionFields) }
        }
        """
        var inputDict: [String: Any] = [
            "sessionToken": input.sessionToken,
            "completedChallenges": input.completedChallenges.map {
                var c: [String: Any] = [
                    "code": $0.code,
                    "completedAt": $0.completedAt,
                    "clientPassed": $0.clientPassed,
                ]
                if let d = $0.durationMs { c["durationMs"] = d }
                return c
            },
        ]
        if let v = input.selfieImage         { inputDict["selfieImage"] = v }
        if !input.livelinessImages.isEmpty   { inputDict["livelinessImages"] = input.livelinessImages }
        if let v = input.selfieEvidenceUrl   { inputDict["selfieEvidenceUrl"] = v }
        if let v = input.videoEvidenceUrl    { inputDict["videoEvidenceUrl"] = v }
        return try await client.execute(
            query: mutation,
            variables: ["input": inputDict],
            rootField: "submitLivenessEvidence",
            as: LivenessSessionDTO.self
        )
    }

    public func retrySession(token: String) async throws -> LivenessSessionDTO {
        let mutation = """
        mutation RetryLivenessSession($sessionToken: String!) {
          retryLivenessSession(sessionToken: $sessionToken) { \(Self.sessionFields) }
        }
        """
        return try await client.execute(
            query: mutation,
            variables: ["sessionToken": token],
            rootField: "retryLivenessSession",
            as: LivenessSessionDTO.self
        )
    }

    public func getSession(token: String) async throws -> LivenessSessionDTO {
        let query = """
        query LivenessSession($sessionToken: String!) {
          livenessSession(sessionToken: $sessionToken) { \(Self.sessionFields) }
        }
        """
        return try await client.execute(
            query: query,
            variables: ["sessionToken": token],
            rootField: "livenessSession",
            as: LivenessSessionDTO.self
        )
    }
}
