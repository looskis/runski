import Foundation

/// The run service (`run_service_url`): acquire, renew and complete jobs.
public struct RunServiceClient {
    let client: VSSClient
    let base: URL

    public init(baseURL: URL, authorization: Authorization, http: HTTPClient) {
        var b = baseURL
        if !b.absoluteString.hasSuffix("/") { b = URL(string: b.absoluteString + "/")! }
        base = b
        client = VSSClient(baseURL: b, authorization: authorization, http: http, useLocationService: false)
    }

    private func url(_ path: String) -> URL { base.appendingPathComponent(path) }

    public func acquireJob(messageId: String, billingOwnerId: String?) async throws -> AgentJobRequestMessage {
        let req = AcquireJobRequest(streamId: messageId, jobMessageId: messageId, billingOwnerId: billingOwnerId, runnerOS: Platform.osLabel)
        var lastError: Error?
        for attempt in 0..<5 {
            do {
                let msg: AgentJobRequestMessage? = try await client.request("POST", url: url("acquirejob"), apiVersion: nil, body: req, timeout: 60)
                guard let msg else { throw HTTPError(status: 0, url: url("acquirejob"), body: "empty acquirejob response", headers: [:]) }
                return msg
            } catch let err as HTTPError where [404, 409, 422].contains(err.status) {
                throw err
            } catch {
                lastError = error
                try await Task.sleep(for: .seconds(Double.random(in: 5...15) * Double(attempt + 1) / 2))
            }
        }
        throw lastError!
    }

    public func renewJob(planId: String, jobId: String) async throws -> RenewJobResponse? {
        try await client.request("POST", url: url("renewjob"), apiVersion: nil, body: RenewJobRequest(planId: planId, jobId: jobId), timeout: 30)
    }

    public func completeJob(_ req: CompleteJobRequest) async throws {
        var lastError: Error?
        for _ in 0..<5 {
            do {
                let _: NoContent? = try await client.request("POST", url: url("completejob"), apiVersion: nil, body: req, timeout: 60)
                return
            } catch let err as HTTPError where err.status == 401 || err.status == 404 {
                throw err
            } catch {
                lastError = error
                try await Task.sleep(for: .seconds(5))
            }
        }
        throw lastError!
    }
}

/// The results receiver (`system.github.results_endpoint`): step status + log blobs.
public struct ResultsClient {
    let client: VSSClient
    let http: HTTPClient
    let base: URL
    let planId: String
    let jobId: String
    private let changeOrder = Counter()

    final class Counter: @unchecked Sendable {
        private var n: Int64 = 0
        private let lock = NSLock()
        func next() -> Int64 { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    public init(endpoint: URL, token: String, planId: String, jobId: String, http: HTTPClient) {
        var b = endpoint
        if !b.absoluteString.hasSuffix("/") { b = URL(string: b.absoluteString + "/")! }
        base = b
        self.http = http
        self.planId = planId
        self.jobId = jobId
        client = VSSClient(baseURL: b, authorization: .bearer(token), http: http, useLocationService: false)
    }

    private func twirp(_ method: String) -> URL {
        base.appendingPathComponent("twirp/results.services.receiver.Receiver/\(method)")
    }

    public func updateSteps(_ steps: [Results.Step]) async throws {
        guard !steps.isEmpty else { return }
        let req = Results.StepsUpdateRequest(steps: steps, changeOrder: changeOrder.next(),
                                             workflowJobRunBackendId: jobId, workflowRunBackendId: planId)
        let u = base.appendingPathComponent("twirp/github.actions.results.api.v1.WorkflowStepUpdateService/WorkflowStepsUpdate")
        let _: JSONValue? = try await client.request("POST", url: u, apiVersion: nil, body: req, timeout: 30)
    }

    /// Upload a complete log (single block blob) for a step or the job and register its metadata.
    public func uploadLog(stepId: String?, content: Data, lineCount: Int64) async throws {
        let req = Results.SignedURLRequest(workflowRunBackendId: planId, workflowJobRunBackendId: jobId, stepBackendId: stepId)
        let signed: Results.SignedURLResponse? = try await client.request(
            "POST", url: twirp(stepId == nil ? "GetJobLogsSignedBlobURL" : "GetStepLogsSignedBlobURL"), apiVersion: nil, body: req, timeout: 30)
        guard let signed, let logsUrl = signed.logsUrl, let blobURL = URL(string: logsUrl) else {
            throw HTTPError(status: 0, url: twirp("GetStepLogsSignedBlobURL"), body: "no logs_url", headers: [:])
        }
        var headers = ["Content-Type": "text/plain"]
        if signed.blobStorageType == Results.azureBlobStorage { headers["x-ms-blob-type"] = "BlockBlob" }
        _ = try await http.send("PUT", blobURL, headers: headers, body: content, timeout: 120)
        let meta = Results.LogsMetadata(workflowRunBackendId: planId, workflowJobRunBackendId: jobId, stepBackendId: stepId,
                                        uploadedAt: ServiceJSON.shortTimestamp(), lineCount: lineCount, size: nil)
        let _: JSONValue? = try await client.request(
            "POST", url: twirp(stepId == nil ? "CreateJobLogsMetadata" : "CreateStepLogsMetadata"), apiVersion: nil, body: meta, timeout: 30)
    }

    public func uploadStepSummary(stepId: String, content: Data) async throws {
        let req = Results.SignedURLRequest(workflowRunBackendId: planId, workflowJobRunBackendId: jobId, stepBackendId: stepId)
        let signed: Results.SignedURLResponse? = try await client.request("POST", url: twirp("GetStepSummarySignedBlobURL"), apiVersion: nil, body: req, timeout: 30)
        guard let signed, let s = signed.summaryUrl, let blobURL = URL(string: s) else { return }
        var headers: [String: String] = [:]
        if signed.blobStorageType == Results.azureBlobStorage { headers["x-ms-blob-type"] = "BlockBlob" }
        _ = try await http.send("PUT", blobURL, headers: headers, body: content, timeout: 60)
        let meta = Results.LogsMetadata(workflowRunBackendId: planId, workflowJobRunBackendId: jobId, stepBackendId: stepId,
                                        uploadedAt: ServiceJSON.shortTimestamp(), lineCount: nil, size: Int64(content.count))
        let _: JSONValue? = try await client.request("POST", url: twirp("CreateStepSummaryMetadata"), apiVersion: nil, body: meta, timeout: 30)
    }
}

/// Legacy pipelines job server (timeline records, logs, feed, plan events, action download info).
public struct LegacyJobServer {
    let client: VSSClient
    let plan: AgentJobRequestMessage.Plan

    public init(endpoint: URL, token: String, plan: AgentJobRequestMessage.Plan, http: HTTPClient) {
        client = VSSClient(baseURL: endpoint, authorization: .bearer(token), http: http)
        self.plan = plan
    }

    private var route: [String: String] {
        ["scopeIdentifier": plan.scope, "hubName": plan.hubName, "planId": plan.planId]
    }

    public func updateTimelineRecords(timelineId: String, _ records: [TimelineRecord]) async throws {
        guard !records.isEmpty else { return }
        var r = route; r["timelineId"] = timelineId
        let _: JSONValue? = try await client.request("PATCH", resource: VSSResource.timelineRecords, apiVersion: "5.1-preview.1",
                                                     route: r, body: TimelineRecordsUpdate(count: records.count, value: records), timeout: 60)
    }

    public func appendFeed(timelineId: String, jobRecordId: String, stepId: String, lines: [String], startLine: Int64?) async throws {
        var r = route; r["timelineId"] = timelineId; r["recordId"] = jobRecordId
        let _: NoContent? = try await client.request("POST", resource: VSSResource.feedLines, apiVersion: "5.1-preview.1",
                                                     route: r, body: TimelineRecordFeedLines(count: lines.count, value: lines, stepId: stepId, startLine: startLine), timeout: 60)
    }

    /// Create a log, upload its content, and return the log id for the timeline record.
    public func uploadLog(recordId: String, content: Data) async throws -> Int {
        let created: TaskLog? = try await client.request("POST", resource: VSSResource.logs, apiVersion: "5.1-preview.1",
                                                         route: route, body: TaskLog(path: "logs\\\(recordId)", createdOn: ServiceJSON.timestamp(), lastChangedOn: ServiceJSON.timestamp()), timeout: 60)
        guard let id = created?.id else { throw HTTPError(status: 0, url: client.baseURL, body: "no log id", headers: [:]) }
        var r = route; r["logId"] = String(id)
        let u = await client.url(for: VSSResource.logs, route: r)
        _ = try await client.send("POST", url: u, apiVersion: "5.1-preview.1", headers: ["Content-Type": "application/octet-stream"], body: content, timeout: 120)
        return id
    }

    public func raiseJobCompleted(_ event: JobCompletedEvent) async throws {
        var lastError: Error?
        for _ in 0..<5 {
            do {
                let _: NoContent? = try await client.request("POST", resource: VSSResource.planEvents, apiVersion: "2.0-preview.1",
                                                             route: route, body: event, timeout: 60)
                return
            } catch let err as HTTPError where err.matches("PlanNotFound", "PlanSecurity", "PlanTerminated") {
                throw err
            } catch {
                lastError = error
                try await Task.sleep(for: .seconds(5))
            }
        }
        throw lastError!
    }

    public func resolveActionDownloadInfo(jobId: String, actions: [ActionReference]) async throws -> ActionDownloadInfoCollection? {
        var r = route; r["jobId"] = jobId
        return try await client.request("POST", resource: VSSResource.actionDownloadInfo, apiVersion: "6.0-preview.1",
                                        route: r, body: ActionReferenceList(actions: actions), timeout: 60)
    }
}
