import Foundation

/// One timeline record (the job, or a step).
public final class StepRecord: @unchecked Sendable {
    public let id: String
    public let parentId: String?
    public let type: String        // "Job" | "Task"
    public var name: String
    public let refName: String
    public let order: Int
    public var state = "pending"   // pending | inProgress | completed
    public var result: String?     // succeeded | succeededWithIssues | failed | canceled | skipped | abandoned
    public var startTime: Date?
    public var finishTime: Date?
    public var issues: [Issue] = []
    public var lines: [String] = []
    public var lineCount: Int64 = 0
    public var logId: Int?
    public var variables: [String: VariableValue] = [:]
    public var actionName: String?
    public var actionRef: String?
    public var actionType: String?

    init(id: String, parentId: String?, type: String, name: String, refName: String, order: Int) {
        self.id = id; self.parentId = parentId; self.type = type; self.name = name; self.refName = refName; self.order = order
    }

    var timelineRecord: TimelineRecord {
        TimelineRecord(id: id, parentId: parentId, type: type, name: name, refName: refName,
                       startTime: startTime.map { ServiceJSON.timestamp($0) }, finishTime: finishTime.map { ServiceJSON.timestamp($0) },
                       currentOperation: nil, percentComplete: state == "completed" ? 100 : 0, state: state, result: result,
                       resultCode: nil, changeId: nil, lastModified: ServiceJSON.timestamp(), workerName: nil,
                       order: type == "Job" ? nil : order, log: logId.map { TaskLogReference(id: $0, location: nil) },
                       errorCount: issues.filter { $0.type == "error" }.count, warningCount: issues.filter { $0.type == "warning" }.count,
                       issues: issues.isEmpty ? nil : issues, location: nil, attempt: 1, identifier: nil,
                       agentPlatform: type == "Job" ? Platform.osLabel : nil, variables: variables.isEmpty ? nil : variables)
    }

    var resultsStep: Results.Step {
        let status: Int
        switch state {
        case "inProgress": status = 3
        case "pending": status = 5
        case "completed": status = 6
        default: status = 0
        }
        let conclusion: Int
        switch result {
        case "succeeded", "succeededWithIssues": conclusion = 2
        case "failed": conclusion = 3
        case "canceled": conclusion = 4
        case "skipped": conclusion = 7
        default: conclusion = 0
        }
        return Results.Step(externalId: id, number: order, name: name, status: status,
                            startedAt: startTime.map { ServiceJSON.shortTimestamp($0) },
                            completedAt: finishTime.map { ServiceJSON.shortTimestamp($0) }, conclusion: conclusion)
    }

    var stepResultSummary: StepResultSummary {
        StepResultSummary(externalId: id, number: order, name: name, status: state == "completed" ? "completed" : "in_progress",
                          conclusion: result, startedAt: startTime.map { ServiceJSON.timestamp($0) },
                          completedAt: finishTime.map { ServiceJSON.timestamp($0) }, completedLogUrl: nil, completedLogLines: nil,
                          annotations: issues.isEmpty ? nil : issues.map { $0.annotation(stepNumber: order) })
    }
}

extension Issue {
    func annotation(stepNumber: Int) -> Annotation {
        let d = data ?? [:]
        func num(_ k: String) -> Int64? { d[k].flatMap { Int64($0) } }
        var line = num("line") ?? 0
        var endLine = num("endLine") ?? line
        let col = num("col") ?? 0
        let endCol = num("endColumn") ?? col
        let path = d["file"]
        if (path ?? "").isEmpty, line == 0, let l = num("logFileLineNumber") { line = l; endLine = l }
        let level: String
        switch type.lowercased() {
        case "error": level = "failure"
        case "warning": level = "warning"
        case "notice": level = "notice"
        default: level = "unknown"
        }
        return Annotation(level: level, message: message, path: path, startLine: line == 0 ? nil : line, endLine: endLine == 0 ? nil : endLine,
                          startColumn: col == 0 ? nil : col, endColumn: endCol == 0 ? nil : endCol, stepNumber: Int64(stepNumber), rawDetails: nil)
    }
}

/// Collects job output and fans it out to: the local job log file, GitHub (results
/// service or legacy timeline/log APIs), the live console feed, and an optional HTTP sink.
public final class JobLogger: @unchecked Sendable {
    public let masker: SecretMasker
    public let jobRecord: StepRecord
    private(set) var records: [StepRecord] = []
    private let lock = NSLock()
    private let log: Logger
    private let localFile: FileHandle?
    public let localFileURL: URL?
    private let results: ResultsClient?
    private let legacy: LegacyJobServer?
    private let timelineId: String?
    private let feed: LiveFeed?
    private let httpSink: HTTPLogSink?
    private var jobLines: [String] = []
    private var jobLineCount: Int64 = 0
    private var nextOrder = 1
    private var uploadTasks: [Task<Void, Never>] = []

    public init(message: AgentJobRequestMessage, runnerName: String, resultsOnly: Bool, paths: Paths, config: RunskiConfig,
                http: HTTPClient, masker: SecretMasker, log: Logger) {
        self.masker = masker
        self.log = log
        jobRecord = StepRecord(id: message.jobId, parentId: nil, type: "Job", name: message.jobDisplayName ?? message.jobName ?? "job",
                               refName: message.jobName ?? "", order: 0)
        jobRecord.state = "inProgress"
        jobRecord.startTime = Date()
        timelineId = message.timeline?.id

        let token = message.systemConnection?.authorization?.parameters?["AccessToken"]
        if let ep = message.variable("system.github.results_endpoint"), let u = URL(string: ep), let token {
            results = ResultsClient(endpoint: u, token: token, planId: message.plan.planId, jobId: message.jobId, http: http)
        } else { results = nil }
        if !resultsOnly, let sc = message.systemConnection, let u = URL(string: sc.url), let token {
            legacy = LegacyJobServer(endpoint: u, token: token, plan: message.plan, http: http)
        } else { legacy = nil }

        if let feedUrl = message.systemConnection?.data?["FeedStreamUrl"], !feedUrl.isEmpty, let token {
            var s = feedUrl
            if !resultsOnly { s = s.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://") }
            feed = URL(string: s).map { LiveFeed(url: $0, token: token, userAgent: http.userAgent, log: log) }
        } else { feed = nil }

        let runId = message.context("github")?["run_id"]?.stringValue ?? "run"
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safeName = (message.jobName ?? "job").replacingOccurrences(of: "/", with: "_")
        let url = paths.jobLogsDir.appendingPathComponent("\(stamp)-\(runId)-\(safeName).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        localFile = try? FileHandle(forWritingTo: url)
        localFileURL = localFile == nil ? nil : url

        if let sinkCfg = config.logSink, let u = URL(string: sinkCfg.url) {
            httpSink = HTTPLogSink(url: u, headers: sinkCfg.headers ?? [:], batch: sinkCfg.batchLines ?? 200,
                                   interval: sinkCfg.flushIntervalSeconds ?? 2, http: http, log: log,
                                   meta: ["runner": runnerName, "job": message.jobDisplayName ?? "", "run_id": runId,
                                          "repository": message.context("github")?["repository"]?.stringValue ?? ""])
        } else { httpSink = nil }
    }

    // MARK: Records

    @discardableResult
    public func addStep(name: String, refName: String, id: String? = nil) -> StepRecord {
        lock.lock(); defer { lock.unlock() }
        let r = StepRecord(id: id ?? UUID().uuidString.lowercased(), parentId: jobRecord.id, type: "Task", name: name, refName: refName, order: nextOrder)
        nextOrder += 1
        records.append(r)
        return r
    }

    public var allSteps: [StepRecord] { lock.withLock { records } }

    public func start(_ r: StepRecord) {
        lock.lock(); r.state = "inProgress"; r.startTime = Date(); lock.unlock()
        publish([r])
    }

    public func complete(_ r: StepRecord, result: String) {
        lock.lock()
        r.state = "completed"; r.result = result; r.finishTime = Date()
        if r.startTime == nil { r.startTime = r.finishTime }
        let lines = r.lines
        r.lines = []
        lock.unlock()
        let count = r.lineCount
        if !lines.isEmpty || r.type == "Task" {
            enqueue { [self] in await uploadStepLog(r, lines: lines, lineCount: count) }
        }
        publish([r])
    }

    public func addIssue(_ r: StepRecord, type: String, message: String, data: [String: String] = [:]) {
        lock.lock(); r.issues.append(Issue(type: type, category: "General", message: message, isInfrastructureIssue: nil, data: data)); lock.unlock()
    }

    private func publish(_ rs: [StepRecord]) {
        let snapshot = rs.map(\.timelineRecord)
        let resultsSteps = rs.filter { $0.type == "Task" }.map(\.resultsStep)
        enqueue { [self] in
            if let legacy, let timelineId {
                do { try await legacy.updateTimelineRecords(timelineId: timelineId, snapshot) }
                catch { log.warn("timeline update failed: \(error)") }
            }
            if let results {
                do { try await results.updateSteps(resultsSteps) }
                catch { log.warn("results step update failed: \(error)") }
            }
        }
    }

    // MARK: Lines

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    /// Write a log line for a step (masked). Pass `nil` for job-level output.
    public func write(_ record: StepRecord?, _ raw: String) {
        let masked = masker.mask(raw)
        let ts = JobLogger.stamp.string(from: Date())
        let stamped = "\(ts) \(masked)"
        lock.lock()
        if let record {
            record.lines.append(stamped)
            record.lineCount += 1
        }
        jobLines.append(stamped)
        jobLineCount += 1
        let stepId = record?.id ?? jobRecord.id
        let lineNo = record?.lineCount ?? jobLineCount
        lock.unlock()
        localFile?.write(Data("\(ts) [\(record?.name ?? "job")] \(masked)\n".utf8))
        feed?.append(stepId: stepId, line: masked, lineNumber: lineNo)
        httpSink?.append(step: record?.name ?? "job", line: masked, ts: ts)
    }

    public func group(_ record: StepRecord?, _ title: String) { write(record, "##[group]\(title)") }
    public func endGroup(_ record: StepRecord?) { write(record, "##[endgroup]") }
    public func error(_ record: StepRecord?, _ msg: String) { write(record, "##[error]\(msg)") }
    public func warning(_ record: StepRecord?, _ msg: String) { write(record, "##[warning]\(msg)") }
    public func debug(_ record: StepRecord?, _ msg: String) { write(record, "##[debug]\(msg)") }

    // MARK: Uploads

    private func enqueue(_ op: @escaping @Sendable () async -> Void) {
        let t = Task { await op() }
        lock.lock(); uploadTasks.append(t); lock.unlock()
    }

    private func uploadStepLog(_ r: StepRecord, lines: [String], lineCount: Int64) async {
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let results {
            do { try await results.uploadLog(stepId: r.id, content: data, lineCount: lineCount) }
            catch { log.warn("results log upload failed for '\(r.name)': \(error)") }
        }
        if let legacy {
            do {
                let id = try await legacy.uploadLog(recordId: r.id, content: data)
                lock.withLock { r.logId = id }
                if let timelineId { try await legacy.updateTimelineRecords(timelineId: timelineId, [r.timelineRecord]) }
            } catch { log.warn("legacy log upload failed for '\(r.name)': \(error)") }
        }
    }

    public func uploadStepSummary(_ r: StepRecord, markdown: Data) async {
        if let results {
            do { try await results.uploadStepSummary(stepId: r.id, content: markdown) }
            catch { log.warn("step summary upload failed: \(error)") }
        }
    }

    /// Complete the job record, flush everything, upload the job log.
    public func finish(result: String) async {
        let (lines, count) = lock.withLock { () -> ([String], Int64) in
            jobRecord.state = "completed"; jobRecord.result = result; jobRecord.finishTime = Date()
            let l = jobLines; jobLines = []
            return (l, jobLineCount)
        }
        await feed?.flushAndClose()
        await httpSink?.flushAndClose()
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let results {
            do { try await results.uploadLog(stepId: nil, content: data, lineCount: count) }
            catch { log.warn("job log upload failed: \(error)") }
        }
        if let legacy {
            do {
                let id = try await legacy.uploadLog(recordId: jobRecord.id, content: data)
                lock.withLock { jobRecord.logId = id }
                if let timelineId { try await legacy.updateTimelineRecords(timelineId: timelineId, [jobRecord.timelineRecord]) }
            } catch { log.warn("legacy job log upload failed: \(error)") }
        }
        let pending = lock.withLock { uploadTasks }
        for t in pending { await t.value }
        try? localFile?.close()
    }
}

/// Live console feed over the FeedStreamUrl websocket.
final class LiveFeed: @unchecked Sendable {
    private let url: URL
    private let token: String
    private let userAgent: String
    private let log: Logger
    private var task: URLSessionWebSocketTask?
    private var pending: [String: [(Int64, String)]] = [:]
    private let lock = NSLock()
    private var flusher: Task<Void, Never>?
    private var failures = 0
    private var closed = false

    init(url: URL, token: String, userAgent: String, log: Logger) {
        self.url = url; self.token = token; self.userAgent = userAgent; self.log = log
        connect()
        flusher = Task { [weak self] in
            while let self, !self.closed {
                try? await Task.sleep(for: .milliseconds(500))
                await self.flush()
            }
        }
    }

    private func connect() {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let t = URLSession.shared.webSocketTask(with: req)
        t.resume()
        task = t
    }

    func append(stepId: String, line: String, lineNumber: Int64) {
        lock.lock()
        let truncated = line.count > 1024 ? String(line.prefix(1024)) + "..." : line
        pending[stepId, default: []].append((lineNumber, truncated))
        if pending[stepId]!.count > 1024 { pending[stepId]!.removeFirst() }
        lock.unlock()
    }

    func flush() async {
        let batch = lock.withLock { () -> [String: [(Int64, String)]] in let b = pending; pending = [:]; return b }
        guard let task, failures < 10 else { return }
        for (stepId, lines) in batch where !lines.isEmpty {
            for chunk in stride(from: 0, to: lines.count, by: 100) {
                let slice = Array(lines[chunk..<min(lines.count, chunk + 100)])
                let payload = TimelineRecordFeedLines(count: slice.count, value: slice.map(\.1), stepId: stepId, startLine: slice.first?.0)
                guard let data = try? ServiceJSON.encoder().encode(payload) else { continue }
                do {
                    try await task.send(.string(String(decoding: data, as: UTF8.self)))
                    failures = 0
                } catch {
                    failures += 1
                    if failures == 1 { log.debug("live feed send failed: \(error)") }
                    if failures < 10 { connect() }
                    return
                }
            }
        }
    }

    func flushAndClose() async {
        await flush()
        closed = true
        flusher?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
    }
}

/// Optional user-configured HTTP endpoint that receives batched log lines as JSON.
final class HTTPLogSink: @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let batch: Int
    private let http: HTTPClient
    private let log: Logger
    private let meta: [String: String]
    private var lines: [[String: String]] = []
    private let lock = NSLock()
    private var flusher: Task<Void, Never>?
    private var closed = false

    init(url: URL, headers: [String: String], batch: Int, interval: Double, http: HTTPClient, log: Logger, meta: [String: String]) {
        self.url = url; self.headers = headers; self.batch = batch; self.http = http; self.log = log; self.meta = meta
        flusher = Task { [weak self] in
            while let self, !self.closed {
                try? await Task.sleep(for: .seconds(interval))
                await self.flush()
            }
        }
    }

    func append(step: String, line: String, ts: String) {
        lock.lock()
        lines.append(["step": step, "line": line, "ts": ts])
        let full = lines.count >= batch
        lock.unlock()
        if full { Task { await flush() } }
    }

    func flush() async {
        let out = lock.withLock { () -> [[String: String]] in let o = lines; lines = []; return o }
        guard !out.isEmpty else { return }
        var body: [String: Any] = meta
        body["lines"] = out
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var h = headers
        h["Content-Type"] = "application/json"
        do { _ = try await http.send("POST", url, headers: h, body: data, timeout: 30) }
        catch { log.warn("log sink POST failed: \(error)") }
    }

    func flushAndClose() async {
        closed = true
        flusher?.cancel()
        await flush()
    }
}
