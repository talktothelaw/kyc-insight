import Foundation
import os.log

/// Errors surfaced by the GraphQL client.
public enum GraphQLClientError: Error, LocalizedError {
    case network(Error)
    case decoding(Error, rootField: String, rawJSON: String?)
    case server(message: String, code: String?)
    case noData

    public var errorDescription: String? {
        switch self {
        case .network(let err): return "Network error: \(err.localizedDescription)"
        case .decoding(let err, let rootField, _):
            // Surface the real DecodingError detail (which key was missing,
            // which type was wrong, which codingPath). `localizedDescription`
            // on DecodingError is useless ("data couldn't be read because it
            // isn't in the correct format"); the typed cases carry the real
            // info — that's what shows up in console logs AND in the inline
            // error message the user sees.
            return "Decode failed for \(rootField): \(decodingDetail(err))"
        case .server(let message, _): return message
        case .noData: return "Empty response from the server."
        }
    }

    /// Human-readable breakdown of a `DecodingError`. Falls back to the
    /// default `localizedDescription` for unknown error types.
    private func decodingDetail(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        switch e {
        case .keyNotFound(let key, let ctx):
            return "missing key '\(key.stringValue)' at \(path(ctx.codingPath))"
        case .typeMismatch(let type, let ctx):
            return "type mismatch: expected \(type) at \(path(ctx.codingPath)) — \(ctx.debugDescription)"
        case .valueNotFound(let type, let ctx):
            return "null where \(type) expected at \(path(ctx.codingPath))"
        case .dataCorrupted(let ctx):
            return "data corrupted at \(path(ctx.codingPath)) — \(ctx.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
    private func path(_ keys: [CodingKey]) -> String {
        keys.isEmpty ? "<root>" : keys.map { $0.stringValue }.joined(separator: ".")
    }
}

/// Tiny GraphQL client. Sends `{ query, variables }` JSON to the configured
/// endpoint with the merchant's public key in `x-public-key` — same auth
/// model the web widget uses (`kyc-web-wiget-v2/src/core/gqlClient.ts`).
public final class GraphQLClient {

    public let endpoint: URL
    public let publicKey: String
    private let session: URLSession

    /// Verbose logging toggle. Defaults to `true` in `DEBUG` builds, off in
    /// release. Logs go through `os.Logger` (subsystem `com.kycinsight.widget`,
    /// category `gql`) — visible in Xcode's console and `Console.app`. Set
    /// `GraphQLClient.debugLogging = false` if the dumps are too noisy.
    public static var debugLogging: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    private static let log = Logger(subsystem: "com.kycinsight.widget", category: "gql")

    public init(endpoint: URL, publicKey: String, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.publicKey = publicKey
        // No-cache by default. Every verification session must talk to the
        // live backend — a stale schema would render the wrong fields, the
        // wrong status pills, or stale rejection reasons. We use an
        // ephemeral configuration (no on-disk cache, no shared cookies
        // outside this client) AND set the request cache policy to
        // `.reloadIgnoringLocalAndRemoteCacheData` per call below. The
        // caller can still pass in their own session for tests.
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            // Don't cache HTTP responses in memory either.
            config.urlCredentialStorage = nil
            self.session = URLSession(configuration: config)
        }
    }

    /// Base URL minus the trailing `/graphql` segment. Used by the REST file
    /// upload route (POST raw bytes to `${apiBaseUrl}/file/upload/<id>`).
    public var apiBaseURL: URL {
        let str = endpoint.absoluteString
        if str.hasSuffix("/graphql") {
            return URL(string: String(str.dropLast("/graphql".count))) ?? endpoint
        }
        if str.hasSuffix("/graphql/") {
            return URL(string: String(str.dropLast("/graphql/".count))) ?? endpoint
        }
        return endpoint
    }

    /// Run a query / mutation and decode the `data.<rootField>` payload as `T`.
    /// `rootField` is the top-level field name in the GraphQL response (e.g.
    /// `"createMerchantCustomer"` for the customer-session query).
    public func execute<T: Decodable>(
        query: String,
        variables: [String: Any]? = nil,
        rootField: String,
        as type: T.Type = T.self
    ) async throws -> T {
        // Per-request: explicitly bypass any cache that might still be in
        // play (URLProtocol interceptors, system shared cache, etc.).
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publicKey, forHTTPHeaderField: "x-public-key")
        // Belt + braces — also send the Cache-Control header so any
        // upstream proxy (CDN, reverse proxy) honours no-cache.
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        var body: [String: Any] = ["query": query]
        if let variables { body["variables"] = variables }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        Self.logRequest(rootField: rootField, variables: variables)

        let data: Data
        do {
            let (raw, _) = try await session.data(for: request)
            data = raw
        } catch {
            Self.log.error("[GQL→\(rootField, privacy: .public)] network failed: \(error.localizedDescription, privacy: .public)")
            throw GraphQLClientError.network(error)
        }

        Self.logResponse(rootField: rootField, data: data)

        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.log.error("[GQL→\(rootField, privacy: .public)] response is not JSON")
            throw GraphQLClientError.noData
        }

        // GraphQL convention: `errors[]` (non-empty) wins.
        if let errors = parsed["errors"] as? [[String: Any]], !errors.isEmpty {
            let first = errors[0]
            let message = (first["message"] as? String) ?? "GraphQL error"
            let code = ((first["extensions"] as? [String: Any])?["code"] as? String)
            Self.log.error("[GQL→\(rootField, privacy: .public)] server error: \(message, privacy: .public) code=\(code ?? "-", privacy: .public)")
            throw GraphQLClientError.server(message: message, code: code)
        }

        guard let payload = parsed["data"] as? [String: Any] else {
            Self.log.error("[GQL→\(rootField, privacy: .public)] no `data` envelope in response")
            throw GraphQLClientError.noData
        }
        // Treat both missing and explicit JSON null at the root field as
        // empty — some backend resolvers (e.g. RequestBVNVerification when
        // the upstream provider call fails) return `null` instead of an
        // error envelope. The web widget surfaces this as "Empty response
        // from <Mutation>" rather than a cryptic decoder error.
        guard let root = payload[rootField], !(root is NSNull) else {
            Self.log.error("[GQL→\(rootField, privacy: .public)] root field missing or null")
            throw GraphQLClientError.noData
        }
        do {
            let raw = try JSONSerialization.data(withJSONObject: root, options: [])
            return try JSONDecoder().decode(T.self, from: raw)
        } catch {
            // Dump both the raw root JSON and the typed DecodingError so we
            // can see exactly what shape the server returned vs. what the
            // Swift type expected.
            let rootJSON = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "<unprintable>"
            Self.log.error("[GQL→\(rootField, privacy: .public)] decode FAILED: \(String(describing: error), privacy: .public)")
            Self.log.error("[GQL→\(rootField, privacy: .public)] root JSON was:\n\(rootJSON, privacy: .public)")
            print("[KYC GQL→\(rootField)] DECODE FAILED: \(error)")
            print("[KYC GQL→\(rootField)] ROOT JSON WAS:\n\(rootJSON)")
            throw GraphQLClientError.decoding(error, rootField: rootField, rawJSON: rootJSON)
        }
    }

    // MARK: - Logging helpers

    private static func logRequest(rootField: String, variables: [String: Any]?) {
        guard debugLogging else { return }
        let vars = variables.flatMap { dict -> String? in
            guard let d = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return nil }
            return String(data: d, encoding: .utf8)
        } ?? "<none>"
        log.debug("[GQL→\(rootField, privacy: .public)] → \(vars, privacy: .public)")
        // Plain print so the Xcode console shows it without any filter
        // gymnastics — Logger output is hidden unless the user widens the
        // log-level filter, which most people don't know to do.
        print("[KYC GQL→\(rootField)] REQUEST vars: \(vars)")
    }

    private static func logResponse(rootField: String, data: Data) {
        guard debugLogging else { return }
        if let s = String(data: data, encoding: .utf8) {
            let body = s.count > 4000 ? String(s.prefix(4000)) + "…[truncated \(s.count - 4000) bytes]" : s
            log.debug("[GQL→\(rootField, privacy: .public)] ← \(body, privacy: .public)")
            print("[KYC GQL→\(rootField)] RESPONSE \(body)")
        } else {
            log.debug("[GQL→\(rootField, privacy: .public)] ← <\(data.count) bytes, non-UTF8>")
            print("[KYC GQL→\(rootField)] RESPONSE <\(data.count) bytes, non-UTF8>")
        }
    }
}
