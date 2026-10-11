import XCTest
@testable import KYCWidget

@MainActor
final class LivenessVideoE2ETests: XCTestCase {

    private let tinyJpeg = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/4gHYSUNDX1BST0ZJTEUAAQEAAAHIAAAAAAQwAABtbnRyUkdCIFhZWiAH4AABAAEAAAAAAABhY3NwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAA9tYAAQAAAADTLQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAlkZXNjAAAA8AAAACRyWFlaAAABFAAAABRnWFlaAAABKAAAABRiWFlaAAABPAAAABR3dHB0AAABUAAAABRyVFJDAAABZAAAAChnVFJDAAABZAAAAChiVFJDAAABZAAAAChjcHJ0AAABjAAAADxtbHVjAAAAAAAAAAEAAAAMZW5VUwAAAAgAAAAcAHMAUgBHAEJYWVogAAAAAAAAb6IAADj1AAADkFhZWiAAAAAAAABimQAAt4UAABjaWFlaIAAAAAAAACSgAAAPhAAAts9YWVogAAAAAAAA9tYAAQAAAADTLXBhcmEAAAAAAAQAAAACZmYAAPKnAAANWQAAE9AAAApbAAAAAAAAAABtbHVjAAAAAAAAAAEAAAAMZW5VUwAAACAAAAAcAEcAbwBvAGcAbABlACAASQBuAGMALgAgADIAMAAxADb/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAAIAAgDASIAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAAAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAUAQEAAAAAAAAAAAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AAA//2Q=="

    private let verdicts: Set<String> = ["passed", "failed", "requires_manual_review"]

    private let videoNotRequested = "This check requires a video recording. Please update to the latest version of the app."

    private func api() throws -> LivenessAPI {
        let raw = ProcessInfo.processInfo.environment["KYC_E2E_GQL"] ?? ""
        let endpoint = try XCTUnwrap(URL(string: raw))
        return LivenessAPI(client: GraphQLClient(endpoint: endpoint, publicKey: "NA_PUB_TEST-video-e2e", session: URLSession(configuration: .ephemeral)))
    }

    private func submitInput(_ session: LivenessSessionDTO) -> LivenessAPI.SubmitInput {
        let now = ISO8601DateFormatter().string(from: Date())
        return LivenessAPI.SubmitInput(
            sessionToken: session.sessionToken,
            selfieImage: tinyJpeg,
            livelinessImages: [tinyJpeg],
            completedChallenges: session.challengeSequence.map { LivenessCompletedChallengeInput(code: $0, completedAt: now, clientPassed: true) }
        )
    }

    func testUploadsClipThenSubmitReachesAVerdict() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KYC_E2E_GQL"] != nil, "KYC_E2E_GQL is not set")
        let api = try api()
        let session = try await api.createSession(LivenessAPI.CreateInput(userRef: "video-e2e-user"))
        XCTAssertTrue(session.requireVideo)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("liveness-e2e-\(UUID().uuidString).mp4")
        try Data(count: 64 * 1024).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = RecordedClip(url: url, contentType: "video/mp4")
        let upload = try await api.requestVideoUpload(token: session.sessionToken, contentType: clip.contentType, sizeBytes: clip.sizeBytes)
        try await api.uploadVideo(upload, clip: clip)
        let result = try await api.submitEvidence(submitInput(session))
        print("ios e2e verdict session=\(session.sessionToken) status=\(result.status) riskScore=\(String(describing: result.riskScore))")
        XCTAssertTrue(verdicts.contains(result.status), result.status)
    }

    func testSubmitWithoutUploadIsRefused() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KYC_E2E_GQL"] != nil, "KYC_E2E_GQL is not set")
        let api = try api()
        let session = try await api.createSession(LivenessAPI.CreateInput(userRef: "video-e2e-user"))
        do {
            _ = try await api.submitEvidence(submitInput(session))
            XCTFail("submit without a video upload must be refused")
        } catch GraphQLClientError.server(let message, _) {
            print("ios e2e refusal session=\(session.sessionToken) message=\(message)")
            XCTAssertEqual(message, videoNotRequested)
        }
    }
}
