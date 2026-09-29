import Foundation

/// Well-known Actions service resource locations (`_apis/connectionData` identifiers).
public enum VSSResource {
    public static let pools = "a8c47e17-4d56-4a56-92bb-de7ea7dc65be"
    public static let agents = "e298ef32-5878-4cab-993c-043836571f42"
    public static let sessions = "134e239e-2df3-4794-a6f6-24f1f19ec8dc"
    public static let messages = "c3a054f6-7a8a-49c0-944e-3a8e5d7adfd7"
    public static let jobRequests = "fc825784-c92a-4299-9221-998a02d1b54f"
    public static let jobMessage = "25adab70-1379-4186-be8e-b643061ebe3a"
    public static let timelineRecords = "8893bc5b-35b2-4be7-83cb-99e683551db4"
    public static let timelines = "83597576-cc2c-453c-bea6-2882ae6a1653"
    public static let logs = "46f5667d-263a-4684-91b1-dff7fdcf64e2"
    public static let planEvents = "557624af-b29e-4c20-8ab0-0399d2204f3f"
    public static let feedLines = "858983e4-19bd-4c5e-864c-507b59b58b12"
    public static let actionDownloadInfo = "27d7f831-88c1-4719-8ca1-6a061dad90eb"
}

/// Client for a VSS-style service (the Actions "pipelines" tenant, or a job's
/// `SystemVssConnection`). Resolves routes through the location service and
/// applies the `api-version` media-type parameter convention.
public final class VSSClient: @unchecked Sendable {
    public let baseURL: URL
    public var authorization: Authorization
    public let http: HTTPClient
    /// Resolve routes via `_apis/connectionData` (true for the pipelines tenant; false for
    /// broker/run/results services and in tests).
    public var useLocationService: Bool
    private var connectionData: ConnectionData?
    private var locationFailed = false
    private let lock = NSLock()

    /// Fallback route templates used if the location service is unreachable.
    private static let fallbackRoutes: [String: String] = [
        VSSResource.pools: "_apis/distributedtask/pools/{poolId}",
        VSSResource.agents: "_apis/distributedtask/pools/{poolId}/agents/{agentId}",
        VSSResource.sessions: "_apis/distributedtask/pools/{poolId}/sessions/{sessionId}",
        VSSResource.messages: "_apis/distributedtask/pools/{poolId}/messages/{messageId}",
        VSSResource.jobRequests: "_apis/distributedtask/pools/{poolId}/jobrequests/{requestId}",
        VSSResource.jobMessage: "_apis/distributedtask/pools/{poolId}/jobrequests/{requestId}/jobmessage",
        VSSResource.timelineRecords: "{scopeIdentifier}/_apis/distributedtask/hubs/{hubName}/plans/{planId}/timelines/{timelineId}/records",
        VSSResource.timelines: "{scopeIdentifier}/_apis/distributedtask/hubs/{hubName}/plans/{planId}/timelines/{timelineId}",
        VSSResource.logs: "{scopeIdentifier}/_apis/distributedtask/hubs/{hubName}/plans/{planId}/logs/{logId}",
        VSSResource.planEvents: "{scopeIdentifier}/_apis/distributedtask/hubs/{hubName}/plans/{planId}/events",
        VSSResource.feedLines: "{scopeIdentifier}/_apis/distributedtask/hubs/{hubName}/plans/{planId}/timelines/{timelineId}/records/{recordId}/feed",
        VSSResource.actionDownloadInfo: "{scopeIdentifier}/_apis/distributedtask/hubs/{hubName}/plans/{planId}/jobs/{jobId}/actiondownloadinfo",
    ]

    public init(baseURL: URL, authorization: Authorization, http: HTTPClient, useLocationService: Bool = true) {
        self.baseURL = baseURL
        self.authorization = authorization
        self.http = http
        self.useLocationService = useLocationService
    }

    // MARK: Location service

    private func loadConnectionData() async -> ConnectionData? {
        guard useLocationService else { return nil }
        if let cd = lock.withLock({ connectionData }) { return cd }
        if lock.withLock({ locationFailed }) { return nil }
        var comps = URLComponents(url: baseURL.appendingPathComponent("_apis/connectionData"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "connectOptions", value: "1"),
            URLQueryItem(name: "lastChangeId", value: "-1"),
            URLQueryItem(name: "lastChangeId64", value: "-1"),
        ]
        do {
            let cd: ConnectionData? = try await request("GET", url: comps.url!, apiVersion: "1.0", body: nil, timeout: 20)
            lock.withLock { connectionData = cd }
            return cd
        } catch {
            lock.withLock { locationFailed = true }
            return nil
        }
    }

    /// Build a URL for a resource id, substituting `{routeValues}` and dropping
    /// unresolved optional segments (mirrors the .NET `VssHttpClientBase` behaviour).
    public func url(for resource: String, route: [String: String], query: [String: String] = [:]) async -> URL {
        var template = VSSClient.fallbackRoutes[resource] ?? ""
        var values = route
        if let cd = await loadConnectionData(),
           let def = cd.locationServiceData.serviceDefinitions.first(where: { $0.identifier.caseInsensitiveCompare(resource) == .orderedSame }) {
            template = def.relativePath
            values["area"] = def.serviceType
            values["resource"] = def.displayName
        }
        var path = template
        let regex = try! NSRegularExpression(pattern: "/*\\{([^}]+)\\}")
        let ns = path as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: path, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            let whole = ns.substring(with: m.range)
            let slashes = whole.prefix { $0 == "/" }
            if let v = values.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value {
                result += slashes + v.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        path = result.hasPrefix("/") ? String(result.dropFirst()) : result
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var basePath = comps.path
        if !basePath.hasSuffix("/") { basePath += "/" }
        comps.path = basePath + path
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return comps.url!
    }

    // MARK: Requests

    /// JSON request against a resource location.
    @discardableResult
    public func request<T: Decodable>(_ method: String, resource: String, apiVersion: String,
                                      route: [String: String], query: [String: String] = [:],
                                      body: (any Encodable)? = nil, timeout: TimeInterval? = nil,
                                      as type: T.Type = T.self) async throws -> T? {
        let u = await url(for: resource, route: route, query: query)
        return try await request(method, url: u, apiVersion: apiVersion, body: body, timeout: timeout)
    }

    /// JSON request against an explicit URL, with api-version media-type parameters.
    @discardableResult
    public func request<T: Decodable>(_ method: String, url: URL, apiVersion: String?,
                                      body: (any Encodable)?, contentType: String? = nil,
                                      timeout: TimeInterval? = nil, as type: T.Type = T.self) async throws -> T? {
        let suffix = apiVersion.map { "; api-version=\($0)" } ?? ""
        var headers: [String: String] = [
            "Accept": "application/json" + suffix,
            "X-TFS-FedAuthRedirect": "Suppress",
            "X-TFS-Session": UUID().uuidString,
            "X-VSS-E2EID": UUID().uuidString,
        ]
        var bodyData: Data? = nil
        if let body {
            bodyData = try ServiceJSON.encoder().encode(AnyEncodable(body))
            headers["Content-Type"] = (contentType ?? "application/json; charset=utf-8") + suffix
        }
        let resp = try await sendAuthorized(method, url, headers: headers, body: bodyData, timeout: timeout)
        if resp.isEmpty || resp.status == 204 { return nil }
        if T.self == NoContent.self { return NoContent() as? T }
        do {
            return try ServiceJSON.decoder().decode(T.self, from: resp.data)
        } catch {
            // Keep the full body for diagnosis; protocol responses evolve.
            let dump = Paths().logsDir.appendingPathComponent("decode-failure-\(Int(Date().timeIntervalSince1970)).json")
            try? resp.data.write(to: dump)
            throw HTTPError(status: resp.status, url: url, body: "decode error \(error) (body saved to \(dump.path)): \(String(decoding: resp.data.prefix(500), as: UTF8.self))", headers: resp.headers)
        }
    }

    /// Raw-body request (log uploads).
    @discardableResult
    public func send(_ method: String, url: URL, apiVersion: String?, headers extra: [String: String] = [:],
                     body: Data?, timeout: TimeInterval? = nil) async throws -> HTTPResponse {
        let suffix = apiVersion.map { "; api-version=\($0)" } ?? ""
        var headers: [String: String] = [
            "Accept": "application/json" + suffix,
            "X-TFS-FedAuthRedirect": "Suppress",
        ]
        for (k, v) in extra { headers[k] = v }
        if body != nil, headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/octet-stream" + suffix
        }
        return try await sendAuthorized(method, url, headers: headers, body: body, timeout: timeout)
    }

    private func sendAuthorized(_ method: String, _ url: URL, headers: [String: String], body: Data?,
                                timeout: TimeInterval?) async throws -> HTTPResponse {
        var headers = headers
        if let auth = try await authorization.header(forceRefresh: false) { headers["Authorization"] = auth }
        do {
            return try await http.send(method, url, headers: headers, body: body, timeout: timeout)
        } catch let err as HTTPError where (err.status == 401 || err.status == 400) && authorization.isRefreshable {
            if let auth = try await authorization.header(forceRefresh: true) { headers["Authorization"] = auth }
            return try await http.send(method, url, headers: headers, body: body, timeout: timeout)
        }
    }
}

public struct NoContent: Decodable {}

public struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void
    public init(_ value: any Encodable) { encodeImpl = value.encode }
    public func encode(to encoder: Encoder) throws { try encodeImpl(encoder) }
}
