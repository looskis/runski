import Foundation

/// Caches and refreshes the OAuth bearer token used against the Actions service,
/// broker, run service and results service.
public actor OAuthTokenProvider {
    public let clientId: String
    public let authorizationUrl: String
    public let scheme: RSAKey.SignatureScheme
    private let key: RSAKey
    private let http: HTTPClient
    private var token: String?
    private var expiresAt: Date = .distantPast

    public init(clientId: String, authorizationUrl: String, key: RSAKey, scheme: RSAKey.SignatureScheme, http: HTTPClient) {
        self.clientId = clientId
        self.authorizationUrl = authorizationUrl
        self.key = key
        self.scheme = scheme
        self.http = http
    }

    public func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let token, Date() < expiresAt { return token }
        let assertion = try JWT.clientAssertion(clientId: clientId, audience: authorizationUrl, key: key, scheme: scheme)
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "client_assertion_type", value: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"),
            URLQueryItem(name: "client_assertion", value: assertion),
            URLQueryItem(name: "grant_type", value: "client_credentials"),
        ]
        // URLComponents percent-encodes for the query; form bodies additionally need '+' escaped.
        let body = (comps.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        guard let url = URL(string: authorizationUrl) else { throw URLError(.badURL) }
        let resp: OAuthTokenResponse? = try await http.json("POST", url, headers: [
            "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
            "Accept": "application/json",
        ], body: Data(body.utf8))
        guard let resp else { throw HTTPError(status: 0, url: url, body: "empty token response", headers: [:]) }
        token = resp.accessToken
        let ttl = TimeInterval(resp.expiresIn ?? 3600)
        expiresAt = Date().addingTimeInterval(max(60, ttl - 120))
        return resp.accessToken
    }

    public func invalidate() { token = nil; expiresAt = .distantPast }
}

/// Authorization strategies: a fixed bearer (registration tokens, job tokens) or OAuth.
public enum Authorization: Sendable {
    case none
    case bearer(String)
    case oauth(OAuthTokenProvider)
    case raw(String)   // full header value, e.g. "RemoteAuth xyz" or "Basic ..."

    func header(forceRefresh: Bool) async throws -> String? {
        switch self {
        case .none: return nil
        case .bearer(let t): return "Bearer \(t)"
        case .raw(let v): return v
        case .oauth(let p): return "Bearer \(try await p.token(forceRefresh: forceRefresh))"
        }
    }

    var isRefreshable: Bool { if case .oauth = self { return true }; return false }
}
