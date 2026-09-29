import Foundation

/// Registers and removes runners, supporting both the legacy pipelines flow
/// (`POST pools/{id}/agents`) and the v2 "runner admin" flow
/// (`POST /actions/runners/register`) that github.com now returns for new tenants.
public struct Registrar {
    public struct Options: Sendable {
        public var githubUrl: String
        public var name: String
        public var labels: [String]
        public var runnerGroup: String?
        public var ephemeral: Bool = false
        public var replace: Bool = false
        public var noDefaultLabels: Bool = false
        public init(githubUrl: String, name: String, labels: [String]) {
            self.githubUrl = githubUrl; self.name = name; self.labels = labels
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case unsupportedTokenSchema(String)
        case noRunnerGroup
        case runnerGroupNotFound(String)
        case alreadyExists(String)
        case missingAuthorization
        public var description: String {
            switch self {
            case .unsupportedTokenSchema(let s): return "unsupported token schema \(s)"
            case .noRunnerGroup: return "no self-hosted runner group available"
            case .runnerGroupNotFound(let g): return "runner group '\(g)' not found"
            case .alreadyExists(let n): return "a runner named '\(n)' already exists; pass --replace to take it over"
            case .missingAuthorization: return "service did not return clientId/authorizationUrl"
            }
        }
    }

    let http: HTTPClient
    let log: (String) -> Void

    public init(http: HTTPClient, log: @escaping (String) -> Void = { _ in }) {
        self.http = http
        self.log = log
    }

    public static func defaultLabels() -> [String] { ["self-hosted", Platform.osLabel, Platform.archLabel, "runski"] }

    /// Register a runner with a registration token. Returns the record + credentials to persist.
    public func register(_ opts: Options, registrationToken: String) async throws -> (RunnerRecord, RunnerCredentials) {
        let auth = try await GitHubAPI.authenticate(githubUrl: opts.githubUrl, token: registrationToken, event: "register", http: http)
        if let schema = auth.tokenSchema, schema.caseInsensitiveCompare("OAuthAccessToken") != .orderedSame {
            throw Error.unsupportedTokenSchema(schema)
        }
        let key = try RSAKey.generate()
        var labels = opts.noDefaultLabels ? [] : Registrar.defaultLabels().map { AgentLabel(name: $0, type: "system") }
        for l in opts.labels where !l.trimmingCharacters(in: .whitespaces).isEmpty {
            let name = l.trimmingCharacters(in: .whitespaces)
            if !labels.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                labels.append(AgentLabel(name: name, type: "user"))
            }
        }

        var agent = TaskAgent(
            id: nil, name: opts.name, version: HTTPClient.runnerVersion,
            osDescription: Platform.osDescription, ephemeral: opts.ephemeral, disableUpdate: true,
            maxParallelism: 1, provisioningState: "Provisioned", createdOn: ServiceJSON.timestamp(),
            labels: labels,
            authorization: TaskAgentAuthorization(publicKey: TaskAgentPublicKey(
                exponent: key.exponent.base64EncodedString(), modulus: key.modulus.base64EncodedString())),
            properties: nil)

        var record = RunnerRecord(name: opts.name, githubUrl: opts.githubUrl, agentId: 0, poolId: 0, poolName: nil,
                                  serverUrl: auth.url, serverUrlV2: nil, useV2Flow: false, useRunnerAdminFlow: false,
                                  labels: labels.map(\.name), ephemeral: opts.ephemeral, registeredAt: Date(),
                                  runnerVersion: HTTPClient.runnerVersion)

        if auth.useV2Flow == true {
            log("Using runner-admin (v2) registration flow")
            let (id, poolId, poolName, authz) = try await registerV2(opts, registrationToken: registrationToken, agent: agent, key: key)
            record.agentId = id
            record.poolId = poolId
            record.poolName = poolName
            record.useV2Flow = true
            record.useRunnerAdminFlow = true
            record.serverUrlV2 = authz.serverUrl
            let creds = RunnerCredentials(clientId: authz.clientId, authorizationUrl: authz.authorizationUrl,
                                          requireFipsCryptography: true, rsaPrivateKeyPKCS1: key.pkcs1)
            return (record, creds)
        }

        log("Using pipelines (legacy) registration flow")
        let vss = VSSClient(baseURL: URL(string: auth.url)!, authorization: .bearer(auth.token), http: http)
        // Pick the runner group ("pool").
        let pools: VssList<TaskAgentPool>? = try await vss.request("GET", resource: VSSResource.pools, apiVersion: "5.1-preview.1",
                                                                   route: [:], query: ["poolType": "Automation"])
        let all = pools?.value ?? []
        let selfHosted = all.filter { $0.isHosted != true }
        guard !selfHosted.isEmpty else { throw Error.noRunnerGroup }
        let pool: TaskAgentPool
        if let g = opts.runnerGroup {
            guard let p = selfHosted.first(where: { $0.name.caseInsensitiveCompare(g) == .orderedSame }) else { throw Error.runnerGroupNotFound(g) }
            pool = p
        } else {
            pool = selfHosted.first { $0.isInternal == true } ?? selfHosted[0]
        }
        record.poolId = pool.id
        record.poolName = pool.name

        // Existing runner with this name?
        let existing: VssList<TaskAgent>? = try await vss.request("GET", resource: VSSResource.agents, apiVersion: "6.0-preview.2",
                                                                  route: ["poolId": "0"], query: ["agentName": opts.name])
        let created: TaskAgent?
        if let old = existing?.value.first(where: { $0.name.caseInsensitiveCompare(opts.name) == .orderedSame }) {
            guard opts.replace else { throw Error.alreadyExists(opts.name) }
            agent.id = old.id
            created = try await vss.request("PUT", resource: VSSResource.agents, apiVersion: "6.0-preview.2",
                                            route: ["poolId": String(pool.id), "agentId": String(old.id ?? 0)], body: agent)
        } else {
            created = try await vss.request("POST", resource: VSSResource.agents, apiVersion: "6.0-preview.2",
                                            route: ["poolId": String(pool.id)], body: agent)
        }
        guard let created, let id = created.id,
              let clientId = created.authorization.clientId, !clientId.isEmpty,
              let authUrl = created.authorization.authorizationUrl else { throw Error.missingAuthorization }
        record.agentId = id
        record.serverUrlV2 = created.serverUrlV2
        record.useV2Flow = created.serverUrlV2 != nil
        let fips = created.property("RequireFipsCryptography")?.boolValue ?? true
        let creds = RunnerCredentials(clientId: clientId, authorizationUrl: authUrl,
                                      requireFipsCryptography: fips, rsaPrivateKeyPKCS1: key.pkcs1)
        return (record, creds)
    }

    /// The runner-admin flow authenticates every api.github.com call with the
    /// registration token itself (`RemoteAuth`), as `RunnerDotcomServer` does.
    private func registerV2(_ opts: Options, registrationToken: String, agent: TaskAgent, key: RSAKey) async throws
        -> (Int64, Int64, String, RunnerV2RegisterResponse.Authorization) {
        let api = GitHubAPI.apiBase(for: opts.githubUrl)
        let scope = try GitHubAPI.scope(for: opts.githubUrl)
        let headers = ["Authorization": "RemoteAuth \(registrationToken)", "Accept": "application/json",
                       "Content-Type": "application/json; charset=utf-8"]
        let groups: RunnerGroupList? = try await http.json("GET", GitHubAPI.url(api, "\(scope.pathPrefix)/actions/runner-groups"), headers: headers)
        let selfHosted = (groups?.runnerGroups ?? []).filter { $0.isHosted != true }
        guard !selfHosted.isEmpty else { throw Error.noRunnerGroup }
        let group: RunnerGroupList.Group
        if let g = opts.runnerGroup {
            guard let p = selfHosted.first(where: { $0.name.caseInsensitiveCompare(g) == .orderedSame }) else { throw Error.runnerGroupNotFound(g) }
            group = p
        } else {
            group = selfHosted.first { $0.isDefault == true } ?? selfHosted[0]
        }

        var existingId: Int64? = nil
        let runners: RunnerList? = try await http.json("GET", GitHubAPI.url(api, "\(scope.pathPrefix)/actions/runners", query: ["name": opts.name]), headers: headers)
        if let r = runners?.runners.first(where: { $0.name.caseInsensitiveCompare(opts.name) == .orderedSame }) {
            guard opts.replace else { throw Error.alreadyExists(opts.name) }
            existingId = r.id
        }

        var body: [String: JSONValue] = [
            "url": .string(opts.githubUrl),
            "group_id": .number(Double(group.id)),
            "name": .string(opts.name),
            "version": .string(agent.version),
            "updates_disabled": .bool(true),
            "ephemeral": .bool(opts.ephemeral),
            "labels": .array(agent.labels.map { .object(["id": .number(0), "name": .string($0.name), "type": .string($0.type)]) }),
            "public_key": .string(key.xmlPublicKey),
        ]
        if let existingId {
            body["runner_id"] = .number(Double(existingId))
            body["replace"] = .bool(true)
        }
        let data = try ServiceJSON.encoder().encode(body)
        let resp: RunnerV2RegisterResponse? = try await http.json("POST", GitHubAPI.url(api, "actions/runners/register"), headers: headers, body: data)
        guard let resp else { throw Error.missingAuthorization }
        return (resp.id, group.id, group.name, resp.authorization)
    }

    /// Remove a runner from GitHub using a removal token.
    public func remove(_ record: RunnerRecord, removeToken: String) async throws {
        if record.useRunnerAdminFlow {
            let scope = try GitHubAPI.scope(for: record.githubUrl)
            let u = GitHubAPI.url(record.apiBase, "\(scope.pathPrefix)/actions/runners/\(record.agentId)")
            _ = try await http.send("DELETE", u, headers: ["Authorization": "RemoteAuth \(removeToken)", "Accept": "application/json"])
            return
        }
        let auth = try await GitHubAPI.authenticate(githubUrl: record.githubUrl, token: removeToken, event: "remove", http: http)
        let vss = VSSClient(baseURL: URL(string: record.serverUrl)!, authorization: .bearer(auth.token), http: http)
        let _: NoContent? = try await vss.request("DELETE", resource: VSSResource.agents, apiVersion: "6.0-preview.2",
                                                  route: ["poolId": String(record.poolId), "agentId": String(record.agentId)])
    }
}
