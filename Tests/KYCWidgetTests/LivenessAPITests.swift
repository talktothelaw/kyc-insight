import XCTest
@testable import KYCWidget

/// Verifies LivenessAPI request shape and response decoding against a
/// stubbed URLSession. We don't have to hit the live backend; the only
/// contracts we care about are:
///   • the GraphQL query string includes the field set we declared
///   • the variables payload uses the right keys (camelCase)
///   • the response decodes onto LivenessSessionDTO
@MainActor
final class LivenessAPITests: XCTestCase {

    // MARK: - URLProtocol stub

    /// Captures the most recent request and returns a canned response.
    final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        static var lastBodyJSON: [String: Any]?
        static var lastHeaders: [String: String] = [:]
        static var responseData: Data = Data()
        static var statusCode: Int = 200

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            // URLSession strips the httpBody for stream-based bodies; httpBodyStream
            // is what's actually populated by URLSessionUploadTask. Cover both.
            let bodyData: Data? = {
                if let d = request.httpBody { return d }
                if let stream = request.httpBodyStream {
                    stream.open()
                    var data = Data()
                    let bufSize = 4096
                    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                    defer { buf.deallocate() }
                    while stream.hasBytesAvailable {
                        let read = stream.read(buf, maxLength: bufSize)
                        if read <= 0 { break }
                        data.append(buf, count: read)
                    }
                    stream.close()
                    return data
                }
                return nil
            }()
            if let data = bodyData, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                Self.lastBodyJSON = json
            }
            Self.lastHeaders = (request.allHTTPHeaderFields ?? [:])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseData)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    // MARK: - helpers

    private func makeClient() -> GraphQLClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return GraphQLClient(
            endpoint: URL(string: "https://example.test/graphql")!,
            publicKey: "NA_PUB_TEST-xxx",
            session: session
        )
    }

    private func stub(rootField: String, payload: [String: Any]) {
        let envelope: [String: Any] = ["data": [rootField: payload]]
        StubURLProtocol.responseData = try! JSONSerialization.data(withJSONObject: envelope)
        StubURLProtocol.statusCode = 200
    }

    private static let samplePayload: [String: Any] = [
        "id": "abc123",
        "sessionToken": "SESSION_TOKEN_42",
        "status": "pending",
        "challengeSequence": ["TURN_HEAD_LEFT", "BLINK_TWICE", "TAKE_SELFIE"],
        "completedChallenges": [],
        "retryCount": 0,
        "riskScore": NSNull(),
        "expiresAt": "2030-01-01T00:00:00.000Z",
        "failureReason": NSNull(),
    ]

    override func tearDown() {
        StubURLProtocol.lastBodyJSON = nil
        StubURLProtocol.lastHeaders = [:]
        StubURLProtocol.responseData = Data()
        super.tearDown()
    }

    // MARK: - tests

    func test_createSession_sendsCorrectQueryAndVariables() async throws {
        stub(rootField: "createLivenessSession", payload: Self.samplePayload)
        let api = LivenessAPI(client: makeClient())
        let result = try await api.createSession(LivenessAPI.CreateInput(
            userRef: "test_001",
            levelSlug: "tier_1",
            deviceMeta: LivenessDeviceMetaInput(userAgent: "iOS-Test", platform: "iOS-17", cameraLabel: nil),
            challengesPerSession: 3
        ))
        // — request inspection —
        let body = try XCTUnwrap(StubURLProtocol.lastBodyJSON)
        let query = try XCTUnwrap(body["query"] as? String)
        XCTAssertTrue(query.contains("createLivenessSession"))
        XCTAssertTrue(query.contains("challengeSequence"))
        XCTAssertTrue(query.contains("riskScore"))
        let variables = try XCTUnwrap(body["variables"] as? [String: Any])
        let input = try XCTUnwrap(variables["input"] as? [String: Any])
        XCTAssertEqual(input["userRef"] as? String, "test_001")
        XCTAssertEqual(input["levelSlug"] as? String, "tier_1")
        XCTAssertEqual(input["challengesPerSession"] as? Int, 3)
        let meta = try XCTUnwrap(input["deviceMeta"] as? [String: Any])
        XCTAssertEqual(meta["userAgent"] as? String, "iOS-Test")
        XCTAssertEqual(meta["platform"] as? String, "iOS-17")
        XCTAssertNil(meta["cameraLabel"]) // optional, omitted when nil
        XCTAssertEqual(StubURLProtocol.lastHeaders["x-public-key"], "NA_PUB_TEST-xxx")

        // — response decoding —
        XCTAssertEqual(result.sessionToken, "SESSION_TOKEN_42")
        XCTAssertEqual(result.status, "pending")
        XCTAssertEqual(result.challengeSequence, ["TURN_HEAD_LEFT", "BLINK_TWICE", "TAKE_SELFIE"])
        XCTAssertNil(result.riskScore)
    }

    func test_submitEvidence_decodesPassedVerdict() async throws {
        var passed = Self.samplePayload
        passed["status"] = "passed"
        passed["riskScore"] = 85
        passed["completedChallenges"] = [
            ["code": "TURN_HEAD_LEFT", "completedAt": "2030-01-01T00:00:05.000Z", "clientPassed": true, "durationMs": 1200],
            ["code": "BLINK_TWICE", "completedAt": "2030-01-01T00:00:09.000Z", "clientPassed": true, "durationMs": 1800],
            ["code": "TAKE_SELFIE", "completedAt": "2030-01-01T00:00:14.000Z", "clientPassed": true, "durationMs": 2200],
        ]
        stub(rootField: "submitLivenessEvidence", payload: passed)
        let api = LivenessAPI(client: makeClient())
        let result = try await api.submitEvidence(LivenessAPI.SubmitInput(
            sessionToken: "SESSION_TOKEN_42",
            selfieImage: "data:image/jpeg;base64,/9j/test",
            livelinessImages: ["data:image/jpeg;base64,/9j/a", "data:image/jpeg;base64,/9j/b"],
            completedChallenges: [
                LivenessCompletedChallengeInput(code: "TURN_HEAD_LEFT", completedAt: "2030-01-01T00:00:05.000Z", clientPassed: true, durationMs: 1200),
                LivenessCompletedChallengeInput(code: "BLINK_TWICE", completedAt: "2030-01-01T00:00:09.000Z", clientPassed: true, durationMs: 1800),
                LivenessCompletedChallengeInput(code: "TAKE_SELFIE", completedAt: "2030-01-01T00:00:14.000Z", clientPassed: true, durationMs: 2200),
            ]
        ))
        XCTAssertEqual(result.status, "passed")
        XCTAssertEqual(result.riskScore, 85)
        XCTAssertEqual(result.completedChallenges.count, 3)

        // The mutation body must carry our session token + frames + log.
        let body = try XCTUnwrap(StubURLProtocol.lastBodyJSON)
        let input = try XCTUnwrap((body["variables"] as? [String: Any])?["input"] as? [String: Any])
        XCTAssertEqual(input["sessionToken"] as? String, "SESSION_TOKEN_42")
        XCTAssertEqual((input["livelinessImages"] as? [String])?.count, 2)
        XCTAssertEqual((input["completedChallenges"] as? [[String: Any]])?.count, 3)
    }

    func test_retrySession_callsRightMutation() async throws {
        var refreshed = Self.samplePayload
        refreshed["retryCount"] = 1
        stub(rootField: "retryLivenessSession", payload: refreshed)
        let api = LivenessAPI(client: makeClient())
        let result = try await api.retrySession(token: "SESSION_TOKEN_42")
        XCTAssertEqual(result.retryCount, 1)
        let body = try XCTUnwrap(StubURLProtocol.lastBodyJSON)
        XCTAssertTrue((body["query"] as? String)?.contains("retryLivenessSession") ?? false)
        let variables = try XCTUnwrap(body["variables"] as? [String: Any])
        XCTAssertEqual(variables["sessionToken"] as? String, "SESSION_TOKEN_42")
    }
}
