import XCTest
@testable import KYCWidget

/// Regression test for the scalar root-field crash.
///
/// `RequestFileUploadTwo` returns a bare JSON string (the upload ObjectId).
/// `GraphQLClient.execute` re-serialized the extracted root value with
/// `JSONSerialization.data(withJSONObject:options:[])`, which raises an
/// uncatchable ObjC `NSInvalidArgumentException` ("Invalid top-level type in
/// JSON write") for a top-level scalar — crashing the app. Fixed by passing
/// `.fragmentsAllowed`. Any scalar-returning op (String/Int/Bool) is affected.
@MainActor
final class GraphQLClientScalarTests: XCTestCase {

    final class Stub: URLProtocol, @unchecked Sendable {
        static var responseData = Data()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseData)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeClient() -> GraphQLClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub.self]
        return GraphQLClient(endpoint: URL(string: "https://example.test/graphql")!,
                             publicKey: "NA_PUB_TEST-xxx",
                             session: URLSession(configuration: cfg))
    }

    private func stub(_ envelope: [String: Any]) {
        Stub.responseData = try! JSONSerialization.data(withJSONObject: envelope, options: [])
    }

    override func tearDown() { Stub.responseData = Data(); super.tearDown() }

    func test_execute_decodesBareStringRootField_withoutCrashing() async throws {
        // The exact shape RequestFileUploadTwo returns: data.<field> is a bare string.
        stub(["data": ["RequestFileUploadTwo": "6a26cbaaba54b2ff42609573"]])
        let id = try await makeClient().execute(
            query: "mutation { RequestFileUploadTwo }",
            rootField: "RequestFileUploadTwo",
            as: String.self
        )
        XCTAssertEqual(id, "6a26cbaaba54b2ff42609573")
    }

    func test_execute_decodesBareIntRootField() async throws {
        stub(["data": ["someCount": 7]])
        let n = try await makeClient().execute(query: "query { someCount }", rootField: "someCount", as: Int.self)
        XCTAssertEqual(n, 7)
    }

    func test_execute_stillDecodesObjectRootField() async throws {
        stub(["data": ["obj": ["error": false, "message": "ok"]]])
        struct R: Decodable { let error: Bool; let message: String? }
        let r = try await makeClient().execute(query: "mutation { obj }", rootField: "obj", as: R.self)
        XCTAssertEqual(r.error, false)
        XCTAssertEqual(r.message, "ok")
    }
}
