import Foundation

public struct HTTPError: Error, CustomStringConvertible {
    public let status: Int
    public let url: URL
    public let body: String
    public let headers: [String: String]

    public var description: String {
        let trimmed = body.count > 800 ? String(body.prefix(800)) + "…" : body
        return "HTTP \(status) \(url.absoluteString): \(trimmed)"
    }

    /// The VSS `typeKey` (e.g. `TaskAgentSessionExpiredException`) if the body is a wrapped exception.
    public var typeKey: String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["typeKey"] as? String
    }

    /// The broker `errorKind` (e.g. `RunnerNotFound`) if the body is a broker error.
    public var brokerErrorKind: String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["source"] as? String) == "actions-broker-listener" else { return nil }
        return obj["errorKind"] as? String
    }

    public func matches(_ needles: String...) -> Bool {
        let hay = (typeKey ?? "") + " " + (brokerErrorKind ?? "") + " " + body
        return needles.contains { hay.localizedCaseInsensitiveContains($0) }
    }
}

public struct HTTPResponse {
    public let status: Int
    public let data: Data
    public let headers: [String: String]
    public var isEmpty: Bool { data.isEmpty }
}

/// Thin URLSession wrapper with the headers the Actions service expects.
public final class HTTPClient: @unchecked Sendable {
    public static let runnerVersion = "2.337.0"

    public var userAgent: String
    public var trace: ((String) -> Void)?
    private let session: URLSession

    public init(timeout: TimeInterval = 100) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        userAgent = "GitHubActionsRunner-osx-\(Platform.archLabelLower)/\(HTTPClient.runnerVersion) runski/\(RunskiVersion.current) (\(Platform.osDescription))"
    }

    public func send(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil,
                     timeout: TimeInterval? = nil) async throws -> HTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpBody = body }
        if let timeout { req.timeoutInterval = timeout }
        trace?("→ \(method) \(url.absoluteString)\(body.map { " body=\(String(decoding: $0.prefix(2000), as: UTF8.self))" } ?? "")")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var hdrs: [String: String] = [:]
        for (k, v) in http.allHeaderFields { hdrs[String(describing: k).lowercased()] = String(describing: v) }
        trace?("← \(http.statusCode) \(url.absoluteString) \(String(decoding: data.prefix(2000), as: UTF8.self))")
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError(status: http.statusCode, url: url, body: String(decoding: data, as: UTF8.self), headers: hdrs)
        }
        return HTTPResponse(status: http.statusCode, data: data, headers: hdrs)
    }

    public func json<T: Decodable>(_ method: String, _ url: URL, headers: [String: String] = [:],
                                   body: Data? = nil, timeout: TimeInterval? = nil, as type: T.Type = T.self) async throws -> T? {
        let resp = try await send(method, url, headers: headers, body: body, timeout: timeout)
        if resp.isEmpty { return nil }
        return try ServiceJSON.decoder().decode(T.self, from: resp.data)
    }
}

public enum RunskiVersion {
    public static let current = "0.1.0"
}

public enum Platform {
    public static var archLabel: String {
        #if arch(arm64)
        return "ARM64"
        #else
        return "X64"
        #endif
    }
    public static var archLabelLower: String { archLabel.lowercased() }
    public static let osLabel = "macOS"
    public static var osDescription: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        sysctlbyname("kern.osrelease", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osrelease", &buf, &size, nil, 0)
        let rel = String(cString: buf)
        return "Darwin \(rel) macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    public static var hostName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}
