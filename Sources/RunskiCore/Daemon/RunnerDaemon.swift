import Foundation

/// Runs every registered runner ("slot") concurrently: each slot long-polls GitHub
/// for jobs, executes at most one job at a time, and reports results.
public final class RunnerDaemon: @unchecked Sendable {
    public let paths: Paths
    public let config: RunskiConfig
    public let store: RunnerStore
    public let secrets: SecretStore
    public let http: HTTPClient
    public let log: Logger
    private var slots: [SlotLoop] = []

    public init(paths: Paths, config: RunskiConfig, store: RunnerStore, secrets: SecretStore, log: Logger) {
        self.paths = paths; self.config = config; self.store = store; self.secrets = secrets; self.log = log
        http = HTTPClient()
        if config.trace { http.trace = { [log] in log.debug($0) } }
    }

    /// Blocks until cancelled (SIGTERM/SIGINT → Task cancellation).
    public func run() async throws {
        try paths.ensure()
        let records = store.list()
        guard !records.isEmpty else {
            log.error("No runners registered. Run `runski register --url https://github.com/owner/repo --token <token>` first.")
            throw WorkerError("no runners registered")
        }
        log.info("runski \(RunskiVersion.current) starting with \(records.count) runner slot(s); vault backend: \(store.vault.backend.rawValue)")
        if config.idle.requiredIdleSeconds > 0 {
            log.info("idle gating enabled: accepting jobs only after \(Int(config.idle.requiredIdleSeconds))s without user input")
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for rec in records {
                let creds: RunnerCredentials
                do { creds = try store.credentials(for: rec.name) }
                catch { log.error("cannot unseal credentials for '\(rec.name)': \(error)"); continue }
                let slot = try SlotLoop(record: rec, credentials: creds, daemon: self)
                slots.append(slot)
                group.addTask { try await slot.run() }
            }
            try await group.waitForAll()
        }
    }

    /// Cancel any running jobs and drop sessions (called on SIGTERM).
    public func shutdown() async {
        for s in slots { await s.shutdown() }
    }
}

/// One registered runner: poll → dispatch → repeat.
final class SlotLoop: @unchecked Sendable {
    let record: RunnerRecord
    let daemon: RunnerDaemon
    let listener: MessageListener
    let log: Logger
    private var currentJob: JobDispatch?
    private let lock = NSLock()

    init(record: RunnerRecord, credentials: RunnerCredentials, daemon: RunnerDaemon) throws {
        self.record = record
        self.daemon = daemon
        log = daemon.log.child(record.name)
        listener = try MessageListener(record: record, credentials: credentials, http: daemon.http, log: log)
    }

    func run() async throws {
        log.info("listening for jobs (\(record.githubUrl), labels: \(record.labels.joined(separator: ", ")))")
        defer { Task { await listener.deleteSession() } }
        while !Task.isCancelled {
            try await waitUntilIdleIfNeeded()
            let msg: IncomingMessage
            do {
                msg = try await listener.next()
            } catch let e as ListenerError {
                switch e {
                case .runnerRemoved:
                    log.error("\(e). Removing local registration for '\(record.name)'.")
                    try? daemon.store.remove(record.name)
                    return
                case .sessionConflict, .fatal:
                    log.error("\(e)")
                    throw e
                }
            }
            switch msg.type.lowercased() {
            case MessageType.pipelineAgentJobRequest.lowercased():
                await listener.acknowledge(msg)
                do {
                    let job = try ServiceJSON.decoder().decode(AgentJobRequestMessage.self, from: msg.body)
                    await dispatch(job, runServiceUrl: nil)
                } catch {
                    log.error("failed to decode job message: \(error)")
                }
            case MessageType.runnerJobRequest.lowercased():
                do {
                    let ref = try ServiceJSON.decoder().decode(RunnerJobRequestRef.self, from: msg.body)
                    await listener.acknowledge(msg, jobRef: ref)
                    let job: AgentJobRequestMessage
                    if let rs = ref.runServiceUrl, let base = URL(string: rs), let id = ref.runnerRequestId {
                        let client = RunServiceClient(baseURL: base, authorization: .oauth(listener.oauth), http: daemon.http)
                        job = try await client.acquireJob(messageId: id, billingOwnerId: ref.billingOwnerId)
                        await dispatch(job, runServiceUrl: base)
                    } else if let id = ref.runnerRequestId {
                        job = try await listener.legacyJobMessage(id: id)
                        await dispatch(job, runServiceUrl: nil)
                    }
                } catch let e as HTTPError where [404, 409, 422].contains(e.status) {
                    log.warn("job was not available to acquire (\(e.status)); another runner may have taken it")
                } catch {
                    log.error("failed to acquire job: \(error)")
                }
            case MessageType.jobCancellation.lowercased():
                await listener.acknowledge(msg)
                if let c = try? ServiceJSON.decoder().decode(JobCancellationMessage.self, from: msg.body) {
                    cancelJob(id: c.jobId)
                }
            case MessageType.forceTokenRefresh.lowercased():
                await listener.acknowledge(msg)
                await listener.oauth.invalidate()
            default:
                await listener.acknowledge(msg)
                log.info("ignoring message of type \(msg.type)")
            }
        }
    }

    private func waitUntilIdleIfNeeded() async throws {
        let required = daemon.config.idle.requiredIdleSeconds
        guard required > 0 else { return }
        var announced = false
        while HostPower.idleSeconds() < required {
            if !announced { log.info("user is active; going offline until the Mac has been idle for \(Int(required))s"); announced = true }
            await listener.deleteSession()
            try await Task.sleep(for: .seconds(min(60, max(5, required / 4))))
        }
        if announced { log.info("Mac is idle; coming back online") }
    }

    private func cancelJob(id: String) {
        lock.lock(); let job = currentJob; lock.unlock()
        guard let job, job.message.jobId.caseInsensitiveCompare(id) == .orderedSame else { return }
        log.info("cancellation requested for job \(id)")
        job.cancel()
    }

    func shutdown() async {
        let job = lock.withLock { currentJob }
        job?.cancel()
        await listener.deleteSession()
    }

    private func dispatch(_ job: AgentJobRequestMessage, runServiceUrl: URL?) async {
        await listener.setStatus(.busy)
        defer { Task { await listener.setStatus(.online) } }
        let localSecrets = (try? daemon.secrets.all()) ?? [:]
        let d = JobDispatch(message: job, runServiceUrl: runServiceUrl, slot: self, localSecrets: localSecrets)
        lock.withLock { currentJob = d }
        defer { lock.withLock { currentJob = nil } }

        // Keep polling for JobCancellation while the job runs.
        let poller = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let msg = try? await listener.next() else { continue }
                if msg.type.caseInsensitiveCompare(MessageType.jobCancellation) == .orderedSame,
                   let c = try? ServiceJSON.decoder().decode(JobCancellationMessage.self, from: msg.body) {
                    await listener.acknowledge(msg)
                    cancelJob(id: c.jobId)
                } else if msg.type.caseInsensitiveCompare(MessageType.pipelineAgentJobRequest) == .orderedSame
                            || msg.type.caseInsensitiveCompare(MessageType.runnerJobRequest) == .orderedSame {
                    log.warn("received a second job while busy; leaving it unacknowledged for re-dispatch")
                } else {
                    await listener.acknowledge(msg)
                }
            }
        }
        await d.run()
        poller.cancel()
    }
}

/// Executes one job end to end: lock renewal, worker, completion report.
final class JobDispatch: @unchecked Sendable {
    let message: AgentJobRequestMessage
    let runServiceUrl: URL?
    unowned let slot: SlotLoop
    let localSecrets: [String: String]
    private var runner: JobRunner?
    private let lock = NSLock()

    init(message: AgentJobRequestMessage, runServiceUrl: URL?, slot: SlotLoop, localSecrets: [String: String]) {
        self.message = message; self.runServiceUrl = runServiceUrl; self.slot = slot; self.localSecrets = localSecrets
    }

    func cancel() { lock.withLock { runner }?.cancel() }

    func run() async {
        let log = slot.log
        let daemon = slot.daemon
        let name = message.jobDisplayName ?? message.jobName ?? message.jobId
        log.info("job started: '\(name)' (\(message.context("github")?["repository"]?.stringValue ?? "?") run \(message.context("github")?["run_id"]?.stringValue ?? "?"))")
        let assertion = daemon.config.preventSleepDuringJobs ? HostPower.SleepAssertion(reason: "runski: running GitHub Actions job \(name)") : nil
        defer { assertion?.release() }

        let jobToken = message.systemConnection?.authorization?.parameters?["AccessToken"]
        var runService: RunServiceClient? = nil
        if let rs = runServiceUrl ?? message.systemConnection.flatMap({ URL(string: $0.url) }), let jobToken,
           message.messageType?.caseInsensitiveCompare(MessageType.runnerJobRequest) == .orderedSame || runServiceUrl != nil {
            runService = RunServiceClient(baseURL: rs, authorization: .bearer(jobToken), http: daemon.http)
        }

        // Lock renewal (every 60s) until the job completes.
        let renew = Task { [weak self] in
            guard let self else { return }
            var failures = 0
            while !Task.isCancelled {
                do {
                    if let runService {
                        _ = try await runService.renewJob(planId: message.plan.planId, jobId: message.jobId)
                    } else if let reqId = message.requestId {
                        try await slot.listener.renewJobRequest(requestId: reqId)
                    }
                    failures = 0
                } catch let e as HTTPError where e.status == 404 || e.matches("TaskAgentJobNotFoundException", "TaskAgentJobTokenExpiredException") {
                    log.warn("job lock lost (\(e.status)); cancelling job")
                    cancel()
                    return
                } catch {
                    failures += 1
                    log.warn("renew failed (\(failures)): \(error)")
                }
                try? await Task.sleep(for: .seconds(failures == 0 ? 60 : Double.random(in: 5...15)))
            }
        }

        let r = JobRunner(message: message, record: slot.record, paths: daemon.paths, config: daemon.config, http: daemon.http,
                          log: log, localSecrets: localSecrets)
        lock.withLock { runner = r }
        let outcome = await r.run()
        renew.cancel()
        log.info("job finished: '\(name)' → \(outcome.result)\(r.logger.localFileURL.map { " (log: \($0.path))" } ?? "")")

        // Report completion.
        do {
            if let runService {
                let req = CompleteJobRequest(planId: message.plan.planId, jobId: message.jobId, conclusion: outcome.result,
                                             outputs: outcome.outputs.isEmpty ? nil : outcome.outputs,
                                             stepResults: outcome.stepResults, annotations: outcome.annotations.isEmpty ? nil : outcome.annotations,
                                             telemetry: nil, environmentUrl: nil, billingOwnerId: message.billingOwnerId)
                try await runService.completeJob(req)
            } else if let sc = message.systemConnection, let u = URL(string: sc.url), let jobToken {
                let legacy = LegacyJobServer(endpoint: u, token: jobToken, plan: message.plan, http: daemon.http)
                let event = JobCompletedEvent(jobId: message.jobId, requestId: message.requestId ?? 0, result: outcome.result,
                                              outputs: outcome.outputs.isEmpty ? nil : outcome.outputs, actionsEnvironment: nil)
                try await legacy.raiseJobCompleted(event)
            }
        } catch {
            log.error("failed to report job completion: \(error)")
        }
    }
}
