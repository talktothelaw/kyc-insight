#if canImport(SwiftUI) && canImport(UIKit) && canImport(AVFoundation)
import XCTest
@testable import KYCWidget

@MainActor
final class LivenessFlowTests: XCTestCase {

    final class RoutingStub: URLProtocol, @unchecked Sendable {
        static var responses: [String: [String: Any]] = [:]
        static var calls: [(root: String, variables: [String: Any])] = []
        static let roots = ["livenessClientSettings", "createLivenessSession", "submitLivenessEvidence", "retryLivenessSession", "requestLivenessVideoUpload", "livenessSession"]
        static var puts: [(path: String, contentType: String?, size: Int)] = []
        static var putStatus = 200

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buf, maxLength: buf.count)
                    if read <= 0 { break }
                    data.append(buf, count: read)
                }
                stream.close()
            }
            if request.httpMethod == "PUT" {
                Self.puts.append((request.url?.path ?? "", request.value(forHTTPHeaderField: "Content-Type"), data.count))
                let put = HTTPURLResponse(url: request.url!, statusCode: Self.putStatus, httpVersion: "HTTP/1.1", headerFields: [:])!
                client?.urlProtocol(self, didReceive: put, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let query = body["query"] as? String ?? ""
            let root = Self.roots.first { query.contains("\($0)(") } ?? ""
            Self.calls.append((root, body["variables"] as? [String: Any] ?? [:]))
            let envelope = Self.responses[root] ?? ["errors": [["message": "No stub for \(root)"]]]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: envelope))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private var committed: [AnyCodable?] = []

    override func setUp() {
        super.setUp()
        RoutingStub.responses = [:]
        RoutingStub.calls = []
        RoutingStub.puts = []
        RoutingStub.putStatus = 200
        committed = []
    }

    private func respond(_ root: String, _ payload: [String: Any]) {
        RoutingStub.responses[root] = ["data": [root: payload]]
    }

    private func fail(_ root: String, _ message: String) {
        RoutingStub.responses[root] = ["errors": [["message": message]]]
    }

    private func count(_ root: String) -> Int {
        RoutingStub.calls.filter { $0.root == root }.count
    }

    private func settings(_ skipMode: String) -> [String: Any] {
        ["skipMode": skipMode, "requireVideo": false, "maxRetries": 3]
    }

    private func dto(token: String = "tok-1", status: String = "pending", retriesRemaining: Int = 2,
                     expiresAt: String = "2099-01-01T00:00:00.000Z", requireVideo: Bool = false) -> [String: Any] {
        [
            "id": "id-\(token)",
            "sessionToken": token,
            "status": status,
            "challengeSequence": ["BLINK"],
            "completedChallenges": [],
            "retryCount": 0,
            "riskScore": NSNull(),
            "expiresAt": expiresAt,
            "failureReason": NSNull(),
            "retriesRemaining": retriesRemaining,
            "requireVideo": requireVideo,
        ]
    }

    private func makeFlow(levelSlug: String = "tier_1") -> LivenessFlow {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RoutingStub.self]
        let client = GraphQLClient(
            endpoint: URL(string: "https://example.test/graphql")!,
            publicKey: "NA_PUB_TEST-xxx",
            session: URLSession(configuration: config)
        )
        return LivenessFlow(
            api: LivenessAPI(client: client),
            createInput: LivenessAPI.CreateInput(levelSlug: levelSlug, kycType: "liveness_check"),
            commit: { [unowned self] in self.committed.append($0) }
        )
    }

    private let captured: AnyCodable = .object([
        "selfieImage": .string("s"),
        "livelinessImages": .array([.string("f")]),
        "livenessSessionId": .string("tok-1"),
    ])

    private func runToVerdict(_ flow: LivenessFlow) async {
        await flow.start().value
        await flow.submit(selfie: "s", frames: ["f"], completed: [])
    }

    private func clip() throws -> RecordedClip {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data(repeating: 7, count: 64).write(to: url)
        return RecordedClip(url: url, contentType: "video/mp4")
    }

    private func respondUpload() {
        respond("requestLivenessVideoUpload", [
            "uploadUrl": "https://s3.example/put",
            "headers": [["name": "Content-Type", "value": "video/mp4"]],
            "expiresAt": "2999-01-01T00:00:00.000Z",
        ])
    }

    func testVideoSessionUploadsTheClipBeforeSubmitting() async throws {
        respond("createLivenessSession", dto(token: "t1", requireVideo: true))
        respondUpload()
        respond("submitLivenessEvidence", dto(token: "t1", status: "passed", requireVideo: true))
        let flow = makeFlow()
        await flow.start().value
        let recorded = try clip()
        await flow.submit(selfie: "s", frames: ["f"], completed: [], clip: recorded)
        XCTAssertEqual(RoutingStub.puts.count, 1)
        XCTAssertEqual(RoutingStub.puts.first?.contentType, "video/mp4")
        XCTAssertEqual(RoutingStub.puts.first?.size, 64)
        XCTAssertEqual(RoutingStub.calls.first { $0.root == "requestLivenessVideoUpload" }?.variables["sizeBytes"] as? Int, 64)
        XCTAssertEqual(flow.shell, .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.url.path))
    }

    func testFailedUploadThenResubmitReuploadsWithoutRetry() async throws {
        respond("createLivenessSession", dto(token: "t1", requireVideo: true))
        respondUpload()
        RoutingStub.putStatus = 500
        let flow = makeFlow()
        await flow.start().value
        await flow.submit(selfie: "s", frames: ["f"], completed: [], clip: try clip())
        XCTAssertEqual(flow.shell, .error("Video upload failed. Please try again."))
        XCTAssertTrue(flow.canResubmit)
        RoutingStub.putStatus = 200
        respond("submitLivenessEvidence", dto(token: "t1", status: "passed", requireVideo: true))
        await flow.resubmit()
        XCTAssertEqual(flow.shell, .done)
        XCTAssertEqual(RoutingStub.puts.count, 2)
        XCTAssertEqual(count("retryLivenessSession"), 0)
    }

    func testStartingOverAfterAFailedUploadDeletesTheKeptClip() async throws {
        respond("createLivenessSession", dto(token: "t1", requireVideo: true))
        respondUpload()
        RoutingStub.putStatus = 500
        let flow = makeFlow()
        await flow.start().value
        let recorded = try clip()
        await flow.submit(selfie: "s", frames: ["f"], completed: [], clip: recorded)
        XCTAssertEqual(flow.shell, .error("Video upload failed. Please try again."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recorded.url.path))
        await flow.start().value
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.url.path))
    }

    func testVideoSessionWithoutAClipSaysTheDeviceCannotRecord() async {
        respond("createLivenessSession", dto(token: "t1", requireVideo: true))
        let flow = makeFlow()
        await flow.start().value
        await flow.submit(selfie: "s", frames: ["f"], completed: [], clip: nil)
        XCTAssertEqual(flow.shell, .error("This device cannot record the liveness video."))
        XCTAssertFalse(flow.canResubmit)
    }

    func testNonVideoSessionNeverUploads() async throws {
        respond("createLivenessSession", dto(token: "t1"))
        respond("submitLivenessEvidence", dto(token: "t1", status: "passed"))
        let flow = makeFlow()
        await flow.start().value
        await flow.submit(selfie: "s", frames: ["f"], completed: [], clip: try clip())
        XCTAssertEqual(RoutingStub.puts.count, 0)
        XCTAssertEqual(count("requestLivenessVideoUpload"), 0)
    }

    func test_autoSkipsWithoutCreatingASession() async {
        respond("livenessClientSettings", settings("AUTO"))
        let flow = makeFlow()
        await flow.loadSettings(levelSlug: "tier_1", kycType: "face_match_nin")
        XCTAssertEqual(committed, [.object(["skipped": .bool(true)])])
        XCTAssertEqual(count("createLivenessSession"), 0)
        XCTAssertEqual(flow.shell, .idle)
        XCTAssertEqual(RoutingStub.calls.first?.variables["levelSlug"] as? String, "tier_1")
        XCTAssertEqual(RoutingStub.calls.first?.variables["kycType"] as? String, "face_match_nin")
    }

    func test_currentStepSlugNotTheEntryLevelReachesTheSessionAndTheSettings() async {
        let config = KYCWidgetConfig(publicKey: "NA_PUB_TEST-xxx", userRef: "u1", slug: "biz", name: "Biz", levelSlug: "tier_1")
        let step = WidgetStep(id: "s2", name: "Tier 2", slug: "tier_2", status: .initialized, sections: [])
        let levelSlug = LivenessFieldView.levelSlug(step: step, config: config)
        XCTAssertEqual(levelSlug, "tier_2")
        XCTAssertEqual(LivenessFieldView.levelSlug(step: nil, config: config), "tier_1")
        respond("livenessClientSettings", settings("NONE"))
        respond("createLivenessSession", dto())
        let flow = makeFlow(levelSlug: levelSlug)
        await flow.loadSettings(levelSlug: levelSlug, kycType: "liveness_check")
        await flow.start().value
        let settingsCall = RoutingStub.calls.first { $0.root == "livenessClientSettings" }
        XCTAssertEqual(settingsCall?.variables["levelSlug"] as? String, "tier_2")
        let create = RoutingStub.calls.first { $0.root == "createLivenessSession" }
        XCTAssertEqual((create?.variables["input"] as? [String: Any])?["levelSlug"] as? String, "tier_2")
    }

    func test_autoDoesNotOverwriteAnExistingValue() async {
        respond("livenessClientSettings", settings("AUTO"))
        let flow = makeFlow()
        await flow.loadSettings(levelSlug: "tier_1", kycType: "liveness_check", currentValue: captured)
        XCTAssertEqual(flow.skipMode, "AUTO")
        XCTAssertTrue(committed.isEmpty)
        await makeFlow().loadSettings(levelSlug: "tier_1", kycType: "liveness_check", currentValue: .null)
        XCTAssertEqual(committed, [.object(["skipped": .bool(true)])])
    }

    func test_autoDoesNotSkipOnceStartWasTapped() async {
        respond("livenessClientSettings", settings("AUTO"))
        respond("createLivenessSession", dto())
        let flow = makeFlow()
        let start = flow.start()
        XCTAssertEqual(flow.shell, .preparing)
        await flow.loadSettings(levelSlug: "tier_1", kycType: "liveness_check")
        await start.value
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(flow.shell, .running)
    }

    func test_settingsFailureKeepsTheCameraFlow() async {
        fail("livenessClientSettings", "Internal server error")
        respond("createLivenessSession", dto())
        let flow = makeFlow()
        await flow.loadSettings(levelSlug: "tier_1", kycType: "liveness_check")
        XCTAssertEqual(flow.skipMode, "NONE")
        XCTAssertTrue(committed.isEmpty)
        await flow.start().value
        XCTAssertEqual(flow.shell, .running)
        XCTAssertEqual(count("createLivenessSession"), 1)
    }

    func test_optionalOffersSkipThatCommitsTheMarker() async {
        respond("livenessClientSettings", settings("OPTIONAL"))
        let flow = makeFlow()
        await flow.loadSettings(levelSlug: "tier_1", kycType: "liveness_check")
        XCTAssertEqual(flow.skipMode, "OPTIONAL")
        XCTAssertTrue(committed.isEmpty)
        flow.skip()
        XCTAssertEqual(committed, [.object(["skipped": .bool(true)])])
    }

    func test_passedCommitsTheValueWithItsSessionAndOffersNoRetake() async {
        respond("createLivenessSession", dto())
        respond("submitLivenessEvidence", dto(status: "passed"))
        let flow = makeFlow()
        await runToVerdict(flow)
        XCTAssertEqual(committed, [captured])
        XCTAssertEqual(flow.shell, .done)
        XCTAssertFalse(flow.canTryAgain)
        XCTAssertFalse(flow.outOfAttempts)
    }

    func test_manualReviewCommitsTheValueWithItsSession() async {
        respond("createLivenessSession", dto())
        respond("submitLivenessEvidence", dto(status: "requires_manual_review", retriesRemaining: 0))
        let flow = makeFlow()
        await runToVerdict(flow)
        XCTAssertEqual(committed, [captured])
        XCTAssertFalse(flow.canTryAgain)
        XCTAssertFalse(flow.outOfAttempts)
    }

    func test_submitFailureCommitsNothingAndTryAgainResubmitsTheSameEvidence() async {
        respond("createLivenessSession", dto())
        fail("submitLivenessEvidence", "Network down")
        let flow = makeFlow()
        await runToVerdict(flow)
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(flow.shell, .error("Network down"))
        XCTAssertNil(flow.verdict)
        XCTAssertTrue(flow.canResubmit)
        respond("submitLivenessEvidence", dto(status: "passed"))
        await flow.resubmit()
        XCTAssertEqual(committed, [captured])
        XCTAssertEqual(flow.shell, .done)
        XCTAssertEqual(flow.verdict?.status, "passed")
        XCTAssertFalse(flow.canResubmit)
        let submits = RoutingStub.calls.filter { $0.root == "submitLivenessEvidence" }
        XCTAssertEqual(submits.count, 2)
        XCTAssertEqual(submits[1].variables["input"] as? NSDictionary, submits[0].variables["input"] as? NSDictionary)
        XCTAssertEqual((submits[1].variables["input"] as? [String: Any])?["sessionToken"] as? String, "tok-1")
        XCTAssertEqual(count("createLivenessSession"), 1)
        XCTAssertEqual(count("retryLivenessSession"), 0)
    }

    func test_alreadyEvaluatedSessionRecoversTheVerdictFromTheSessionRead() async {
        respond("createLivenessSession", dto())
        fail("submitLivenessEvidence", "Liveness session is not in a submittable state (status: passed)")
        respond("livenessSession", dto(status: "passed"))
        let flow = makeFlow()
        await runToVerdict(flow)
        XCTAssertEqual(committed, [captured])
        XCTAssertEqual(flow.shell, .done)
        XCTAssertEqual(flow.verdict?.status, "passed")
        XCTAssertFalse(flow.canResubmit)
        XCTAssertEqual(count("livenessSession"), 1)
        XCTAssertEqual(RoutingStub.calls.last?.variables["sessionToken"] as? String, "tok-1")
    }

    func test_submitFailureOnAnExpiredSessionOffersNoResubmit() async {
        respond("createLivenessSession", dto(expiresAt: "2000-01-01T00:00:00.000Z"))
        fail("submitLivenessEvidence", "Liveness session has expired")
        let flow = makeFlow()
        await runToVerdict(flow)
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(flow.shell, .error("Liveness session has expired"))
        XCTAssertFalse(flow.canResubmit)
    }

    func test_failedVerdictClearsTheValueAndTryAgainReusesTheSession() async {
        respond("createLivenessSession", dto())
        respond("submitLivenessEvidence", dto(status: "failed", retriesRemaining: 2))
        respond("retryLivenessSession", dto(status: "pending", retriesRemaining: 2))
        let flow = makeFlow()
        await runToVerdict(flow)
        XCTAssertEqual(committed, [nil])
        XCTAssertTrue(flow.canTryAgain)
        XCTAssertEqual(flow.session?.retriesRemaining, 2)
        await flow.tryAgain().value
        XCTAssertEqual(flow.shell, .running)
        XCTAssertNil(flow.verdict)
        XCTAssertEqual(count("createLivenessSession"), 1)
        XCTAssertEqual(count("retryLivenessSession"), 1)
        XCTAssertEqual(RoutingStub.calls.last?.variables["sessionToken"] as? String, "tok-1")
    }

    func test_unexpectedStatusIsNotAcceptedAndOffersTryAgain() async {
        respond("createLivenessSession", dto())
        respond("submitLivenessEvidence", dto(status: "expired", retriesRemaining: 1))
        let flow = makeFlow()
        await runToVerdict(flow)
        XCTAssertEqual(committed, [nil])
        XCTAssertTrue(flow.canTryAgain)
    }

    func test_noAttemptsLeftWhenAFailedVerdictHasNoRetries() async {
        respond("createLivenessSession", dto())
        respond("submitLivenessEvidence", dto(status: "failed", retriesRemaining: 0))
        let flow = makeFlow()
        await runToVerdict(flow)
        XCTAssertTrue(flow.outOfAttempts)
        XCTAssertFalse(flow.canTryAgain)
        await flow.tryAgain().value
        XCTAssertEqual(flow.shell, .done)
        XCTAssertEqual(count("retryLivenessSession"), 0)
        XCTAssertEqual(count("createLivenessSession"), 1)
    }

    func test_refusedRetryShowsNoAttemptsLeftWithoutCreatingASession() async {
        for message in [
            "Retry limit exceeded (3). Session marked for manual review.",
            "This liveness check is already complete.",
        ] {
            RoutingStub.calls = []
            respond("createLivenessSession", dto())
            respond("submitLivenessEvidence", dto(status: "failed", retriesRemaining: 1))
            fail("retryLivenessSession", message)
            let flow = makeFlow()
            await runToVerdict(flow)
            await flow.tryAgain().value
            XCTAssertEqual(flow.shell, .done, message)
            XCTAssertTrue(flow.outOfAttempts, message)
            XCTAssertFalse(flow.canTryAgain, message)
            XCTAssertEqual(count("createLivenessSession"), 1, message)
        }
    }

    func test_transientRetryErrorShowsTheErrorAndTryAgainRepeatsTheRetry() async {
        respond("createLivenessSession", dto())
        respond("submitLivenessEvidence", dto(status: "failed", retriesRemaining: 2))
        fail("retryLivenessSession", "Gateway timeout")
        let flow = makeFlow()
        await runToVerdict(flow)
        await flow.tryAgain().value
        XCTAssertEqual(flow.shell, .error("Gateway timeout"))
        XCTAssertNotNil(flow.verdict)
        respond("retryLivenessSession", dto(status: "pending", retriesRemaining: 2))
        await flow.tryAgain().value
        XCTAssertEqual(flow.shell, .running)
        XCTAssertEqual(count("retryLivenessSession"), 2)
        XCTAssertEqual(count("createLivenessSession"), 1)
    }

    func test_expiredSessionIsReplacedOnTryAgain() async {
        respond("createLivenessSession", dto(expiresAt: "2000-01-01T00:00:00.000Z"))
        respond("submitLivenessEvidence", dto(status: "failed", retriesRemaining: 2, expiresAt: "2000-01-01T00:00:00.000Z"))
        let flow = makeFlow()
        await runToVerdict(flow)
        respond("createLivenessSession", dto(token: "tok-2"))
        await flow.tryAgain().value
        XCTAssertEqual(count("retryLivenessSession"), 0)
        XCTAssertEqual(count("createLivenessSession"), 2)
        XCTAssertEqual(flow.session?.sessionToken, "tok-2")
        XCTAssertEqual(flow.shell, .running)
    }

    func test_expiredSessionIsReplacedOnStart() async {
        respond("createLivenessSession", dto(expiresAt: "2000-01-01T00:00:00Z"))
        let flow = makeFlow()
        await flow.start().value
        flow.cancel()
        respond("createLivenessSession", dto(token: "tok-2"))
        await flow.start().value
        XCTAssertEqual(count("createLivenessSession"), 2)
        XCTAssertEqual(flow.session?.sessionToken, "tok-2")
    }

    func test_cancelDuringCaptureKeepsTheSession() async {
        respond("createLivenessSession", dto())
        let flow = makeFlow()
        await flow.start().value
        flow.cancel()
        XCTAssertEqual(flow.shell, .idle)
        await flow.start().value
        XCTAssertEqual(flow.shell, .running)
        XCTAssertEqual(flow.session?.sessionToken, "tok-1")
        XCTAssertEqual(count("createLivenessSession"), 1)
        XCTAssertEqual(count("retryLivenessSession"), 0)
    }

    func test_encodeFailureSurfacesTheErrorCard() async {
        respond("createLivenessSession", dto())
        let flow = makeFlow()
        await flow.start().value
        await flow.submit(selfie: nil, frames: [], completed: [])
        guard case .error = flow.shell else { return XCTFail("expected the error card, got \(flow.shell)") }
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(count("submitLivenessEvidence"), 0)
    }
}
#endif
