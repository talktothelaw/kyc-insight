import Foundation

/// 1:1 Swift port of `kyc-web-wiget-v2/src/services/consentApi.ts` (the
/// consent-acceptance module that succeeded the older `initiateNinConsent`
/// / `completeNinConsent` pair).
///
/// NIN / DL / Passport go through `initConsent` → `mode: 'internal' |
/// 'external'` branch:
///   • internal — native OTP form (submitConsentIdentifier +
///     verifyConsentIdentifierOtp + resendConsentIdentifierOtp).
///   • external — WKWebView opens `widgetConfig.widgetUrl` (NINAuth SDK
///     hosted page), polls `getRequirementStatus` until terminal.

public enum ConsentType: String, Sendable {
    case nin_consent, bvn_consent, name_consent
    case drivers_license_consent, passport_consent
}

public struct ConsentWidgetConfig: Decodable, Sendable {
    public let clientId: String
    public let widgetUrl: String
    public let scope: String?
    public let userRef: String
    public let consentSessionId: String
}

public struct ConsentIdentifierField: Decodable, Sendable, Identifiable {
    public let key: String
    public let label: String
    public let inputType: String   // text | date | phone
    public let placeholder: String?
    public let required: Bool
    public let pattern: String?
    public var id: String { key }
}

public struct ConsentDisclosureField: Decodable, Sendable, Hashable {
    public let key: String
    public let label: String
    public let description: String?
}

public struct ConsentDisclosureScope: Decodable, Sendable {
    public let scopeId: String
    public let summary: String?
    public let fields: [ConsentDisclosureField]
}

public struct InitConsentResponse: Decodable, Sendable {
    public let success: Bool
    public let error: Bool
    public let message: String?
    public let consentAcceptanceId: String?
    public let consentSessionId: String?
    public let expiresAt: String?
    public let mode: String?    // "internal" | "external"
    public let widgetConfig: ConsentWidgetConfig?
    public let providerType: String?
    public let levelName: String?
    public let disclosureScope: ConsentDisclosureScope?
    public let identifierFields: [ConsentIdentifierField]?
}

public struct SubmitConsentIdentifierResponse: Decodable, Sendable {
    public let success: Bool
    public let error: Bool
    public let message: String?
    public let phoneHint: String?
    public let otpSentAt: String?
    public let code: String?
}

public struct VerifyConsentIdentifierOtpResponse: Decodable, Sendable {
    public let success: Bool
    public let error: Bool
    public let message: String?
    public let code: String?
    // sanitizedData omitted — never carries raw NIN/BVN; the safe reference
    // is the consentAcceptanceId already in our hands.
}

public struct ResendConsentOtpResponse: Decodable, Sendable {
    public let success: Bool
    public let error: Bool
    public let message: String?
    public let otpSentAt: String?
    public let resendCount: Int?
}

public struct RequirementStatusResponse: Decodable, Sendable {
    public let consentAcceptanceId: String?
    public let requirementState: String       // 'auto_completed' | 'awaiting_final_submission' | 'failed' | …
    public let consentStatus: String?
    public let decisionResult: String?
    public let kycSubmissionId: String?
    public let kycSubmissionStatus: String?
    public let consentGivenAt: String?
    public let webhookReceivedAt: String?
    public let finalizedAt: String?
}

public struct FinalizeRequirementResponse: Decodable, Sendable {
    public let success: Bool
    public let error: Bool
    public let message: String?
    public let requirementState: String
    public let kycSubmissionId: String?
    public let alreadyFinalized: Bool?
}

@MainActor
public final class ConsentAPI {
    private let client: GraphQLClient
    public init(client: GraphQLClient) { self.client = client }

    public func initConsent(processToken: String, consentType: ConsentType, providerId: String?, levelSlug: String?) async throws -> InitConsentResponse {
        let mutation = """
        mutation initConsent($input: InitConsentInput!) {
          initConsent(input: $input) {
            success error message
            consentAcceptanceId consentSessionId expiresAt mode
            widgetConfig { clientId widgetUrl scope userRef consentSessionId }
            providerType levelName
            disclosureScope { scopeId summary fields { key label description } }
            identifierFields { key label inputType placeholder required pattern }
          }
        }
        """
        var input: [String: Any] = [
            "processToken": processToken,
            "consentType":  consentType.rawValue,
        ]
        if let providerId { input["providerId"] = providerId }
        if let levelSlug  { input["levelSlug"]  = levelSlug }
        return try await client.execute(
            query: mutation, variables: ["input": input],
            rootField: "initConsent", as: InitConsentResponse.self
        )
    }

    public func submitConsentIdentifier(
        processToken: String,
        consentAcceptanceId: String,
        sessionId: String,
        identifier: [String: String]
    ) async throws -> SubmitConsentIdentifierResponse {
        let mutation = """
        mutation submitConsentIdentifier($input: SubmitConsentIdentifierInput!) {
          submitConsentIdentifier(input: $input) {
            success error message phoneHint otpSentAt code
          }
        }
        """
        let input: [String: Any] = [
            "processToken":        processToken,
            "consentAcceptanceId": consentAcceptanceId,
            "sessionId":           sessionId,
            "identifier":          identifier,
        ]
        return try await client.execute(
            query: mutation, variables: ["input": input],
            rootField: "submitConsentIdentifier",
            as: SubmitConsentIdentifierResponse.self
        )
    }

    public func verifyConsentIdentifierOtp(
        processToken: String,
        consentAcceptanceId: String,
        sessionId: String,
        otpCode: String
    ) async throws -> VerifyConsentIdentifierOtpResponse {
        let mutation = """
        mutation verifyConsentIdentifierOtp($input: VerifyConsentIdentifierOtpInput!) {
          verifyConsentIdentifierOtp(input: $input) {
            success error message code
          }
        }
        """
        let input: [String: Any] = [
            "processToken":        processToken,
            "consentAcceptanceId": consentAcceptanceId,
            "sessionId":           sessionId,
            "otpCode":             otpCode,
        ]
        return try await client.execute(
            query: mutation, variables: ["input": input],
            rootField: "verifyConsentIdentifierOtp",
            as: VerifyConsentIdentifierOtpResponse.self
        )
    }

    public func resendConsentIdentifierOtp(
        processToken: String,
        consentAcceptanceId: String,
        sessionId: String
    ) async throws -> ResendConsentOtpResponse {
        let mutation = """
        mutation resendConsentIdentifierOtp($input: ResendConsentOtpInput!) {
          resendConsentIdentifierOtp(input: $input) {
            success error message otpSentAt resendCount
          }
        }
        """
        let input: [String: Any] = [
            "processToken":        processToken,
            "consentAcceptanceId": consentAcceptanceId,
            "sessionId":           sessionId,
        ]
        return try await client.execute(
            query: mutation, variables: ["input": input],
            rootField: "resendConsentIdentifierOtp",
            as: ResendConsentOtpResponse.self
        )
    }

    public func getRequirementStatus(
        processToken: String,
        providerId: String?,
        levelSlug: String?
    ) async throws -> RequirementStatusResponse {
        let query = """
        query getRequirementStatus($processToken: String!, $providerId: String, $levelSlug: String) {
          getRequirementStatus(processToken: $processToken, providerId: $providerId, levelSlug: $levelSlug) {
            consentAcceptanceId requirementState consentStatus decisionResult
            kycSubmissionId kycSubmissionStatus
            consentGivenAt webhookReceivedAt finalizedAt
          }
        }
        """
        var vars: [String: Any] = ["processToken": processToken]
        if let providerId { vars["providerId"] = providerId }
        if let levelSlug  { vars["levelSlug"]  = levelSlug }
        return try await client.execute(
            query: query, variables: vars,
            rootField: "getRequirementStatus",
            as: RequirementStatusResponse.self
        )
    }

    /// V2 consent finalisation. 1:1 with the web's
    /// `services/consentApi.ts:finalizeRequirement`. Use this — NOT
    /// the legacy `KycSubmission` mutation — for any section whose
    /// value carries a `consentAcceptanceId`. The legacy `KycPayloadV2`
    /// input type doesn't define a `consentReference` field, so
    /// submitting through that path raises "Field 'consentReference'
    /// is not defined by type 'KycPayloadV2'".
    ///
    /// `additionalPayload` is opaque JSON merged with the stored
    /// consent result server-side; we use it to carry the section's
    /// kycPayload + optionalType so file/custom fields land alongside
    /// the consent reference. NO raw NIN/BVN should ever be in it.
    public func finalizeRequirement(
        processToken: String,
        consentAcceptanceId: String,
        providerId: String?,
        levelSlug: String?,
        consentReference: String?,
        additionalPayload: [String: Any]?
    ) async throws -> FinalizeRequirementResponse {
        let mutation = """
        mutation finalizeRequirement($input: FinalizeRequirementInput!) {
          finalizeRequirement(input: $input) {
            success error message
            requirementState kycSubmissionId alreadyFinalized
          }
        }
        """
        var input: [String: Any] = [
            "processToken":        processToken,
            "consentAcceptanceId": consentAcceptanceId,
        ]
        if let providerId        { input["providerId"]        = providerId }
        if let levelSlug         { input["levelSlug"]         = levelSlug }
        if let consentReference  { input["consentReference"]  = consentReference }
        if let additionalPayload { input["additionalPayload"] = additionalPayload }
        return try await client.execute(
            query: mutation, variables: ["input": input],
            rootField: "finalizeRequirement",
            as: FinalizeRequirementResponse.self
        )
    }
}
