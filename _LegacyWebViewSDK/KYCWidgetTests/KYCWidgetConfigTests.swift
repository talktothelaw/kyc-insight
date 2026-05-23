import XCTest
@testable import KYCWidget

final class KYCWidgetConfigTests: XCTestCase {

    private func validConfig(_ overrides: (inout KYCWidgetConfig) -> Void = { _ in }) -> KYCWidgetConfig {
        var c = KYCWidgetConfig(
            publicKey: "NA_PUB_PROD_demo",
            userRef: "user-001",
            slug: "supplier_registration",
            name: "Lawrence Olu",
            levelSlug: "tier_1"
        )
        overrides(&c)
        return c
    }

    // MARK: - Validation

    func test_missingPublicKey_throws() throws {
        let cfg = KYCWidgetConfig(publicKey: "", userRef: "u", slug: "s", name: "n", levelSlug: "l")
        XCTAssertThrowsError(try cfg.buildURL()) { err in
            guard case KYCWidgetError.missingRequiredConfig(let field) = err else {
                return XCTFail("Unexpected error: \(err)")
            }
            XCTAssertEqual(field, "publicKey")
        }
    }

    func test_missingUserRef_throws() {
        let cfg = KYCWidgetConfig(publicKey: "p", userRef: "", slug: "s", name: "n", levelSlug: "l")
        XCTAssertThrowsError(try cfg.buildURL())
    }

    func test_missingSlug_throws() {
        let cfg = KYCWidgetConfig(publicKey: "p", userRef: "u", slug: "", name: "n", levelSlug: "l")
        XCTAssertThrowsError(try cfg.buildURL())
    }

    func test_missingName_throws() {
        let cfg = KYCWidgetConfig(publicKey: "p", userRef: "u", slug: "s", name: "", levelSlug: "l")
        XCTAssertThrowsError(try cfg.buildURL())
    }

    func test_missingLevelSlug_throws() {
        let cfg = KYCWidgetConfig(publicKey: "p", userRef: "u", slug: "s", name: "n", levelSlug: "")
        XCTAssertThrowsError(try cfg.buildURL())
    }

    // MARK: - URL construction — query-param shape matches web SDK

    func test_buildURL_includesAllRequiredParams() throws {
        let url = try validConfig().buildURL()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        XCTAssertEqual(dict["publicKey"], "NA_PUB_PROD_demo")
        XCTAssertEqual(dict["userRef"], "user-001")
        XCTAssertEqual(dict["slug"], "supplier_registration")
        XCTAssertEqual(dict["name"], "Lawrence Olu")
        XCTAssertEqual(dict["levelSlug"], "tier_1")
        XCTAssertEqual(dict["display"], "modal")    // default
    }

    func test_buildURL_forwardsOptionalFields() throws {
        let cfg = KYCWidgetConfig(
            publicKey: "p", userRef: "u", slug: "s", name: "n", levelSlug: "l",
            vName: "Lawrence",
            environment: .live,
            display: .inline,
            gqlEndpoint: URL(string: "https://api.example.com/graphql"),
            debug: true
        )
        let url = try cfg.buildURL()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        XCTAssertEqual(dict["vName"], "Lawrence")
        XCTAssertEqual(dict["environment"], "live")
        XCTAssertEqual(dict["display"], "inline")
        XCTAssertEqual(dict["gqlEndpoint"], "https://api.example.com/graphql")
        XCTAssertEqual(dict["debug"], "true")
    }

    func test_buildURL_defaultsToProductionOrigin() throws {
        let url = try validConfig().buildURL()
        XCTAssertEqual(url.host, "kyc-verify-v2.netapps.ng")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.path, "/")
    }

    func test_buildURL_respectsCustomEnvironment() throws {
        let staging = URL(string: "https://staging.example.com")!
        var cfg = validConfig()
        cfg = KYCWidgetConfig(
            publicKey: cfg.publicKey, userRef: cfg.userRef, slug: cfg.slug,
            name: cfg.name, levelSlug: cfg.levelSlug,
            widgetEnvironment: .custom(staging)
        )
        let url = try cfg.buildURL()
        XCTAssertEqual(url.host, "staging.example.com")
    }

    func test_buildURL_omitsAbsentOptionals() throws {
        let url = try validConfig().buildURL()
        let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        XCTAssertFalse(names.contains("vName"))
        XCTAssertFalse(names.contains("environment"))
        XCTAssertFalse(names.contains("gqlEndpoint"))
        XCTAssertFalse(names.contains("debug"))
    }
}
