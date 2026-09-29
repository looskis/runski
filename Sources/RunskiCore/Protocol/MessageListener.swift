import Foundation

/// A decoded message from the queue.
public struct IncomingMessage: Sendable {
    public let raw: TaskAgentMessage
    public let body: Data          // decrypted JSON body
    public var type: String { raw.messageType }
}

public enum ListenerError: Error, CustomStringConvertible {
    case runnerRemoved(String)
    case sessionConflict
    case fatal(String)
    public var description: String {
        switch self {
        case .runnerRemoved(let s): return "runner no longer exists on GitHub: \(s)"
        case .sessionConflict: return "another process holds a session for this runner"
        case .fatal(let s): return s
        }
    }
}

/// Long-polls the Actions service (or the broker) for one registered runner.
///
/// Mirrors `MessageListener`/`BrokerMessageListener` in actions/runner:
/// - creates a session, decrypting the AES session key with the runner's RSA key,
/// - polls `messages` (VSS) or `message` (broker) with `status=Online|Busy`,
/// - follows `BrokerMigration` hops,
/// - acknowledges/deletes messages, and re-creates the session on expiry.
public actor MessageListener {
    public enum Status: String, Sendable { case online = "Online", busy = "Busy" }

    let record: RunnerRecord
    let key: RSAKey
    let oauth: OAuthTokenProvider
    let http: HTTPClient
    let log: Logger
    let vss: VSSClient

    private var session: TaskAgentSession?
    private var sessionKey: Data?
    private var brokerBase: URL?
    private var lastMessageId: Int64?
    private(set) var status: Status = .online
    private var pollTask: Task<IncomingMessage?, Error>?
    private var stopped = false

    public init(record: RunnerRecord, credentials: RunnerCredentials, http: HTTPClient, log: Logger) throws {
        self.record = record
        self.key = try RSAKey(pkcs1: credentials.rsaPrivateKeyPKCS1)
        self.http = http
        self.log = log
        let scheme: RSAKey.SignatureScheme = (credentials.requireFipsCryptography || record.serverUrlV2 != nil) ? .ps256 : .rs256
        self.oauth = OAuthTokenProvider(clientId: credentials.clientId, authorizationUrl: credentials.authorizationUrl,
                                        key: key, scheme: scheme, http: http)
        self.vss = VSSClient(baseURL: URL(string: record.serverUrl)!, authorization: .oauth(oauth), http: http)
        if record.useV2Flow, let v2 = record.serverUrlV2 { brokerBase = URL(string: v2) }
    }

    public var isBrokerFlow: Bool { brokerBase != nil }

    // MARK: Session

    private func brokerURL(_ path: String, query: [String: String]) -> URL {
        var comps = URLComponents(url: brokerBase!, resolvingAgainstBaseURL: false)!
        var p = comps.path
        if !p.hasSuffix("/") { p += "/" }
        comps.path = p + path
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return comps.url!
    }

    private func pollQuery() -> [String: String] {
        var q = [
            "sessionId": session?.sessionId ?? "",
            "status": status.rawValue,
            "runnerVersion": record.runnerVersion,
            "os": Platform.osLabel,
            "architecture": Platform.archLabel,
            "disableUpdate": "true",
        ]
        if !isBrokerFlow, let last = lastMessageId { q["lastMessageId"] = String(last) }
        return q
    }

    public func createSession() async throws {
        let agentRef = TaskAgent(id: record.agentId, name: record.name, version: record.runnerVersion,
                                 osDescription: Platform.osDescription, ephemeral: record.ephemeral ? true : nil,
                                 disableUpdate: nil, maxParallelism: nil, provisioningState: nil, createdOn: nil,
                                 labels: [], authorization: TaskAgentAuthorization(publicKey: TaskAgentPublicKey(exponent: "", modulus: "")),
                                 properties: nil)
        let request = TaskAgentSession(sessionId: "00000000-0000-0000-0000-000000000000", encryptionKey: nil,
                                       ownerName: "\(Platform.hostName) (PID: \(ProcessInfo.processInfo.processIdentifier))",
                                       agent: agentRef, useFipsEncryption: false, brokerMigrationMessage: nil)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let created: TaskAgentSession?
                if isBrokerFlow {
                    created = try await vss.request("POST", url: brokerURL("session", query: [:]), apiVersion: nil, body: request)
                } else {
                    created = try await vss.request("POST", resource: VSSResource.sessions, apiVersion: "5.1-preview.1",
                                                    route: ["poolId": String(record.poolId)], body: request)
                }
                guard let created else { throw ListenerError.fatal("empty session response") }
                if !isBrokerFlow, let migration = created.brokerMigrationMessage, let url = URL(string: migration.brokerBaseUrl) {
                    log.info("service asked us to move to broker \(migration.brokerBaseUrl)")
                    brokerBase = url
                    continue
                }
                session = created
                sessionKey = try decryptSessionKey(created)
                log.info("session \(created.sessionId ?? "?") established (\(isBrokerFlow ? "broker" : "pipelines"))")
                return
            } catch let err as HTTPError {
                if err.matches("invalid_client", "invalid_grant", "TaskAgentNotFoundException", "RunnerNotFound") || err.status == 404 {
                    throw ListenerError.runnerRemoved(err.description)
                }
                if err.status == 409 || err.matches("TaskAgentSessionConflictException") {
                    attempt += 1
                    if attempt >= 8 { throw ListenerError.sessionConflict }
                    log.warn("session conflict (another runner process?), retrying in 30s")
                } else if err.matches("TaskAgentPoolNotFoundException", "AccessDeniedException", "VssUnauthorizedException", "RunnerVersionTooOld") {
                    throw ListenerError.fatal(err.description)
                } else {
                    log.warn("session create failed: \(err.description); retrying in 30s")
                }
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.warn("session create failed: \(error); retrying in 30s")
                try await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func decryptSessionKey(_ s: TaskAgentSession) throws -> Data? {
        guard let ek = s.encryptionKey, let v = ek.value, !v.isEmpty, let data = Data(base64Encoded: v) else { return nil }
        if ek.encrypted {
            return try key.decryptOAEP(data, hash: s.useFipsEncryption == true ? .sha256 : .sha1)
        }
        return data
    }

    public func deleteSession() async {
        guard let s = session, let id = s.sessionId else { return }
        do {
            if isBrokerFlow {
                let _: NoContent? = try await vss.request("DELETE", url: brokerURL("session", query: [:]), apiVersion: nil, body: nil, timeout: 30)
            } else {
                let _: NoContent? = try await vss.request("DELETE", resource: VSSResource.sessions, apiVersion: "5.1-preview.1",
                                                          route: ["poolId": String(record.poolId), "sessionId": id], timeout: 30)
            }
        } catch {
            log.warn("failed to delete session: \(error)")
        }
        session = nil
        sessionKey = nil
    }

    // MARK: Polling

    public func setStatus(_ new: Status) {
        guard new != status else { return }
        status = new
        pollTask?.cancel()   // re-poll immediately with the new status
    }

    /// Blocks until a message arrives. Handles retries, session recovery and broker hops.
    public func next() async throws -> IncomingMessage {
        var consecutiveErrors = 0
        while true {
            try Task.checkCancellation()
            if session == nil { try await createSession() }
            let task = Task { try await self.pollOnce() }
            pollTask = task
            do {
                let result = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                consecutiveErrors = 0
                if let msg = result { return msg }
                continue
            } catch is CancellationError {
                if Task.isCancelled { throw CancellationError() }
                continue   // status change: poll again
            } catch let err as URLError where err.code == .cancelled {
                if Task.isCancelled { throw CancellationError() }
                continue
            } catch let err as HTTPError {
                if err.matches("TaskAgentSessionExpiredException", "RunnerSessionInvalid") {
                    log.warn("session expired; re-creating")
                    session = nil
                    continue
                }
                if err.matches("TaskAgentNotFoundException", "RunnerNotFound") {
                    throw ListenerError.runnerRemoved(err.description)
                }
                if err.matches("RunnerVersionTooOld") {
                    throw ListenerError.fatal("GitHub rejected our runner version (\(record.runnerVersion)): \(err.description)")
                }
                if err.matches("AccessDeniedException", "VssUnauthorizedException") || err.status == 401 || err.status == 403 {
                    await oauth.invalidate()
                    session = nil
                    consecutiveErrors += 1
                } else {
                    consecutiveErrors += 1
                }
                try await backoff(consecutiveErrors, error: err.description)
            } catch {
                consecutiveErrors += 1
                try await backoff(consecutiveErrors, error: "\(error)")
            }
        }
    }

    private func backoff(_ n: Int, error: String) async throws {
        let secs = n <= 5 ? Double.random(in: 15...30) : Double.random(in: 30...60)
        log.warn("poll error (\(n)): \(error); retrying in \(Int(secs))s")
        try await Task.sleep(for: .seconds(secs))
    }

    private func pollOnce() async throws -> IncomingMessage? {
        var msg: TaskAgentMessage?
        if isBrokerFlow {
            msg = try await vss.request("GET", url: brokerURL("message", query: pollQuery()), apiVersion: nil, body: nil, timeout: 100)
        } else {
            msg = try await vss.request("GET", resource: VSSResource.messages, apiVersion: "6.0-preview.1",
                                        route: ["poolId": String(record.poolId)], query: pollQuery(), timeout: 60)
        }
        guard var m = msg else { return nil }
        var body = try decrypt(m)

        // Legacy sessions can be bounced to the broker per poll.
        if m.messageType.caseInsensitiveCompare(MessageType.brokerMigration) == .orderedSame {
            let migration = try ServiceJSON.decoder().decode(BrokerMigration.self, from: body)
            guard let url = URL(string: migration.brokerBaseUrl) else { return nil }
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var p = comps.path; if !p.hasSuffix("/") { p += "/" }
            comps.path = p + "message"
            comps.queryItems = pollQuery().map { URLQueryItem(name: $0.key, value: $0.value) }
            let hop: TaskAgentMessage? = try await vss.request("GET", url: comps.url!, apiVersion: nil, body: nil, timeout: 100)
            guard let hop else { return nil }
            m = hop
            body = Data((hop.body ?? "").utf8)
        }
        if let id = m.messageId { lastMessageId = id }
        return IncomingMessage(raw: m, body: body)
    }

    private func decrypt(_ m: TaskAgentMessage) throws -> Data {
        guard let bodyStr = m.body else { return Data() }
        guard let ivStr = m.iv, !ivStr.isEmpty, let key = sessionKey,
              let iv = Data(base64Encoded: ivStr), let ct = Data(base64Encoded: bodyStr) else {
            return Data(bodyStr.utf8)
        }
        return try AESCBC.decryptMessageBody(ct, key: key, iv: iv)
    }

    /// Acknowledge (broker) or delete (pipelines) a message once we own it.
    public func acknowledge(_ msg: IncomingMessage, jobRef: RunnerJobRequestRef? = nil) async {
        do {
            if isBrokerFlow {
                guard msg.type.caseInsensitiveCompare(MessageType.runnerJobRequest) == .orderedSame,
                      let ref = jobRef, let reqId = ref.runnerRequestId else { return }
                var q = pollQuery(); q.removeValue(forKey: "disableUpdate")
                let _: NoContent? = try await vss.request("POST", url: brokerURL("acknowledge", query: q), apiVersion: nil,
                                                          body: ["runnerRequestId": reqId], timeout: 5)
            } else if let id = msg.raw.messageId {
                let _: NoContent? = try await vss.request("DELETE", resource: VSSResource.messages, apiVersion: "5.1-preview.1",
                                                          route: ["poolId": String(record.poolId), "messageId": String(id)],
                                                          query: ["sessionId": session?.sessionId ?? ""], timeout: 30)
            }
        } catch {
            log.warn("failed to acknowledge message: \(error)")
        }
    }

    /// Legacy renew of the job lock (pipelines flow).
    public func renewJobRequest(requestId: Int64) async throws {
        let _: JSONValue? = try await vss.request("PATCH", resource: VSSResource.jobRequests, apiVersion: "5.1-preview.1",
                                                  route: ["poolId": String(record.poolId), "requestId": String(requestId)],
                                                  query: ["lockToken": "00000000-0000-0000-0000-000000000000"],
                                                  body: RenewAgentRequest(requestId: requestId), timeout: 30)
    }

    /// Fetch a job message by id (broker message without run_service_url).
    public func legacyJobMessage(id: String) async throws -> AgentJobRequestMessage {
        let msg: AgentJobRequestMessage? = try await vss.request("GET", resource: VSSResource.jobMessage, apiVersion: "6.0-preview.1",
                                                                 route: ["poolId": String(record.poolId), "messageId": id])
        guard let msg else { throw ListenerError.fatal("empty job message") }
        return msg
    }
}
