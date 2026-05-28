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
    // Internal-mode CAC business consent. Backend wires this to mono.cac
    // with `submitConsentIdentifier`; same OTP flow as DL/Passport.
    case cac_consent
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

public struct AcceptConsentDisclosureResponse: Decodable, Sendable {
    public let success: Bool
    public let error: Bool
    public let message: String?
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

// Public-key gate from the backend's consent module. The widget pre-flights
// this on session load to detect a schema that mixes direct-flow providers
// with a business the super-admin hasn't unlocked for direct verification.
//
// `directProviderCounterparts` is the server-owned direct→consent mapping
// (e.g. nin → nin_consent). The SDK reads it from this response instead of
// hardcoding the list — adding a new entry on the backend propagates without
// an SDK release.
public struct DirectProviderCounterpart: Decodable, Sendable {
    public let directType: String
    public let consentType: String
}

public struct ConsentModeResponse: Decodable, Sendable {
    public let allowDirectVerification: Bool
    public let directVerificationAllowedTypes: [String]
    public let directProviderCounterparts: [DirectProviderCounterpart]?
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

    /// Records the disclosure-accept step required by the backend before
    /// `submitConsentIdentifier` will send the OTP. 1:1 with the web's
    /// `acceptConsentDisclosure` in `services/consentApi.ts:299` — the
    /// internal-mode flow gates the OTP send on this row existing.
    public func acceptConsentDisclosure(
        consentAcceptanceId: String,
        scopeId: String,
        userAgent: String?
    ) async throws -> AcceptConsentDisclosureResponse {
        let mutation = """
        mutation acceptConsentDisclosure($input: AcceptConsentDisclosureInput!) {
          acceptConsentDisclosure(input: $input) {
            success error message
          }
        }
        """
        var input: [String: Any] = [
            "consentAcceptanceId": consentAcceptanceId,
            "scopeId":             scopeId,
        ]
        if let userAgent { input["userAgent"] = userAgent }
        return try await client.execute(
            query: mutation, variables: ["input": input],
            rootField: "acceptConsentDisclosure",
            as: AcceptConsentDisclosureResponse.self
        )
    }

    // Internal-mode inputs the backend accepts: { consentAcceptanceId,
    // phoneNumber?, identifier } / { consentAcceptanceId, otpCode } /
    // { consentAcceptanceId }. Sending extra fields like processToken or
    // sessionId is a hard GraphQL validation failure.
    public func submitConsentIdentifier(
        consentAcceptanceId: String,
        phoneNumber: String?,
        identifier: [String: String]
    ) async throws -> SubmitConsentIdentifierResponse {
        let mutation = """
        mutation submitConsentIdentifier($input: SubmitConsentIdentifierInput!) {
          submitConsentIdentifier(input: $input) {
            success error message phoneHint otpSentAt code
          }
        }
        """
        var input: [String: Any] = [
            "consentAcceptanceId": consentAcceptanceId,
            "identifier":          identifier,
        ]
        if let phoneNumber { input["phoneNumber"] = phoneNumber }
        return try await client.execute(
            query: mutation, variables: ["input": input],
            rootField: "submitConsentIdentifier",
            as: SubmitConsentIdentifierResponse.self
        )
    }

    public func verifyConsentIdentifierOtp(
        consentAcceptanceId: String,
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
            "consentAcceptanceId": consentAcceptanceId,
            "otpCode":             otpCode,
        ]
        return try await client.execute(
            query: mutation, variables: ["input": input],
            rootField: "verifyConsentIdentifierOtp",
            as: VerifyConsentIdentifierOtpResponse.self
        )
    }

    public func resendConsentIdentifierOtp(
        consentAcceptanceId: String
    ) async throws -> ResendConsentOtpResponse {
        let mutation = """
        mutation resendConsentIdentifierOtp($input: ResendConsentOtpInput!) {
          resendConsentIdentifierOtp(input: $input) {
            success error message otpSentAt resendCount
          }
        }
        """
        let input: [String: Any] = [
            "consentAcceptanceId": consentAcceptanceId,
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
    // Read the authenticated business's direct-verification gate. Pure read,
    // no billing. Used by the session preflight to fail fast with a clear
    // message when the schema needs a provider the business isn't approved
    // for — instead of letting the submission round-trip and surface a 403.
    public func getMyConsentMode() async throws -> ConsentModeResponse {
        let query = """
        query getMyConsentMode {
          getMyConsentMode {
            allowDirectVerification
            directVerificationAllowedTypes
            directProviderCounterparts { directType consentType }
          }
        }
        """
        return try await client.execute(
            query: query, variables: [:],
            rootField: "getMyConsentMode",
            as: ConsentModeResponse.self
        )
    }

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
