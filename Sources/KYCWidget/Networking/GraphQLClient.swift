import Foundation

/// Errors surfaced by the GraphQL client.
public enum GraphQLClientError: Error, LocalizedError {
    case network(Error)
    case decoding(Error)
    case server(message: String, code: String?)
    case noData

    public var errorDescription: String? {
        switch self {
        case .network(let err): return "Network error: \(err.localizedDescription)"
        case .decoding(let err): return "Could not decode response: \(err.localizedDescription)"
        case .server(let message, _): return message
        case .noData: return "Empty response from the server."
        }
    }
}

/// Tiny GraphQL client. Sends `{ query, variables }` JSON to the configured
/// endpoint with the merchant's public key in `x-public-key` — same auth
/// model the web widget uses (`kyc-web-wiget-v2/src/core/gqlClient.ts`).
public final class GraphQLClient {

    public let endpoint: URL
    public let publicKey: String
    private let session: URLSession

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

        let data: Data
        do {
            let (raw, _) = try await session.data(for: request)
            data = raw
        } catch {
            throw GraphQLClientError.network(error)
        }

        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GraphQLClientError.noData
        }

        // GraphQL convention: `errors[]` (non-empty) wins.
        if let errors = parsed["errors"] as? [[String: Any]], !errors.isEmpty {
            let first = errors[0]
            let message = (first["message"] as? String) ?? "GraphQL error"
            let code = ((first["extensions"] as? [String: Any])?["code"] as? String)
            throw GraphQLClientError.server(message: message, code: code)
        }

        guard let payload = parsed["data"] as? [String: Any] else {
            throw GraphQLClientError.noData
        }
        // Treat both missing and explicit JSON null at the root field as
        // empty — some backend resolvers (e.g. RequestBVNVerification when
        // the upstream provider call fails) return `null` instead of an
        // error envelope. The web widget surfaces this as "Empty response
        // from <Mutation>" rather than a cryptic decoder error.
        guard let root = payload[rootField], !(root is NSNull) else {
            throw GraphQLClientError.noData
        }
        do {
            let raw = try JSONSerialization.data(withJSONObject: root, options: [])
            return try JSONDecoder().decode(T.self, from: raw)
        } catch {
            throw GraphQLClientError.decoding(error)
        }
    }
}
