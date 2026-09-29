import Foundation

/// api.github.com helpers for registration and the companion tooling.
public enum GitHubAPI {
    public enum Scope: Sendable {
        case repo(owner: String, name: String)
        case org(String)
        case enterprise(String)

        /// `repos/o/r`, `orgs/o`, `enterprises/e`
        public var pathPrefix: String {
            switch self {
            case .repo(let o, let r): return "repos/\(o)/\(r)"
            case .org(let o): return "orgs/\(o)"
            case .enterprise(let e): return "enterprises/\(e)"
            }
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case invalidURL(String)
        public var description: String {
            switch self {
            case .invalidURL(let u): return "unsupported GitHub URL '\(u)': expected https://github.com/owner/repo, /org or /enterprises/name"
            }
        }
    }

    public static func isHosted(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "github.com" || h == "www.github.com" || h == "github.localhost" || h.hasSuffix(".ghe.com") || h.hasSuffix(".ghe.localhost")
    }

    public static func apiBase(for githubUrl: String) -> URL {
        let u = URL(string: githubUrl)!
        var comps = URLComponents()
        comps.scheme = u.scheme ?? "https"
        if isHosted(u.host ?? "") {
            comps.host = "api." + (u.host ?? "github.com").replacingOccurrences(of: "www.", with: "")
            comps.path = ""
        } else {
            comps.host = u.host
            comps.port = u.port
            comps.path = "/api/v3"
        }
        return comps.url!
    }

    public static func scope(for githubUrl: String) throws -> Scope {
        guard let u = URL(string: githubUrl) else { throw Error.invalidURL(githubUrl) }
        let parts = u.path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init).filter { !$0.isEmpty }
        switch parts.count {
        case 1: return .org(parts[0])
        case 2:
            if parts[0].caseInsensitiveCompare("enterprises") == .orderedSame { return .enterprise(parts[1]) }
            return .repo(owner: parts[0], name: parts[1])
        default: throw Error.invalidURL(githubUrl)
        }
    }

    public static func url(_ base: URL, _ path: String, query: [String: String] = [:]) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var p = comps.path
        if !p.hasSuffix("/") { p += "/" }
        comps.path = p + path
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return comps.url!
    }

    /// Exchange a PAT for a registration or removal token.
    public static func runnerToken(kind: String, githubUrl: String, pat: String, http: HTTPClient) async throws -> String {
        let scope = try scope(for: githubUrl)
        let u = url(apiBase(for: githubUrl), "\(scope.pathPrefix)/actions/runners/\(kind)-token")
        let basic = Data("github:\(pat)".utf8).base64EncodedString()
        let resp: RunnerRegistrationToken? = try await http.json("POST", u, headers: [
            "Authorization": "Basic \(basic)",
            "Accept": "application/vnd.github.v3+json",
        ], body: Data())
        guard let resp else { throw HTTPError(status: 0, url: u, body: "empty token response", headers: [:]) }
        return resp.token
    }

    /// `POST /actions/runner-registration` → tenant URL + short-lived bearer.
    public static func authenticate(githubUrl: String, token: String, event: String, http: HTTPClient) async throws -> GitHubAuthResult {
        let u = url(apiBase(for: githubUrl), "actions/runner-registration")
        let body = try ServiceJSON.encoder().encode(RunnerRegistrationRequest(url: githubUrl, runnerEvent: event))
        let resp: GitHubAuthResult? = try await http.json("POST", u, headers: [
            "Authorization": "RemoteAuth \(token)",
            "Content-Type": "application/json; charset=utf-8",
            "Accept": "application/json",
        ], body: body)
        guard let resp else { throw HTTPError(status: 0, url: u, body: "empty registration response", headers: [:]) }
        return resp
    }
}
