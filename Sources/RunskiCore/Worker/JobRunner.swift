import Foundation

public struct JobOutcome: Sendable {
    public var result: String                  // succeeded | failed | canceled
    public var outputs: [String: VariableValue]
    public var stepResults: [StepResultSummary]
    public var annotations: [Annotation]
}

/// Executes one job: builds the expression contexts, runs pre/main/post steps with
/// the runner's semantics, processes workflow + file commands, and produces the
/// outcome to report back.
public final class JobRunner: @unchecked Sendable {
    let message: AgentJobRequestMessage
    let record: RunnerRecord
    let paths: Paths
    let config: RunskiConfig
    let http: HTTPClient
    let log: Logger
    public let logger: JobLogger
    let masker: SecretMasker
    let actions: ActionManager
    let localSecrets: [String: String]

    // Directories
    let workRoot: String
    let tempDir: String
    let fileCommandsDir: String
    var workspace: String
    let runnerWorkspace: String

    // Contexts
    var github = ExprValue.ExprObject()
    var jobCtx = ExprValue.ExprObject()
    var runnerCtx = ExprValue.ExprObject()
    var staticContexts: [String: ExprValue] = [:]
    var globalEnv: [(String, String)] = []
    var prependPath: [String] = []
    var stepsRoot = ExprValue.ExprObject()
    var jobResult = "succeeded"
    var cancelled = false
    var currentProcess: ProcessRunner?
    var actionState: [String: [String: String]] = [:]
    var prepared: [String: PreparedAction] = [:]
    var echoCommands = false
    var stepDebug = false
    let lock = NSLock()

    struct PreparedAction {
        let manifest: ActionManifest
        let directory: String
        let nameWithOwner: String?
        let ref: String?
    }

    enum StepStage { case pre, main, post }

    final class PendingStep {
        let record: StepRecord
        let step: ActionStep
        let stage: StepStage
        let action: PreparedAction?
        let stateKey: String
        var displayNameResolved = false
        init(record: StepRecord, step: ActionStep, stage: StepStage, action: PreparedAction?, stateKey: String) {
            self.record = record; self.step = step; self.stage = stage; self.action = action; self.stateKey = stateKey
        }
    }

    var postSteps: [PendingStep] = []

    public init(message: AgentJobRequestMessage, record: RunnerRecord, paths: Paths, config: RunskiConfig, http: HTTPClient,
                log: Logger, localSecrets: [String: String]) {
        self.message = message; self.record = record; self.paths = paths; self.config = config; self.http = http; self.log = log
        self.localSecrets = localSecrets
        masker = SecretMasker()
        let resultsOnly = message.messageType?.caseInsensitiveCompare(MessageType.runnerJobRequest) == .orderedSame
            || message.variable("system.jobRequestType")?.caseInsensitiveCompare(MessageType.runnerJobRequest) == .orderedSame
        logger = JobLogger(message: message, runnerName: record.name, resultsOnly: resultsOnly, paths: paths, config: config,
                           http: http, masker: masker, log: log)
        actions = ActionManager(message: message, paths: paths, http: http, log: log, masker: masker, githubUrl: record.githubUrl)
        workRoot = paths.workDir.appendingPathComponent(record.name).path
        tempDir = workRoot + "/_temp"
        fileCommandsDir = tempDir + "/_runner_file_commands"
        let repo = message.context("github")?["repository"]?.stringValue ?? "repo"
        let repoName = repo.split(separator: "/").last.map(String.init) ?? repo
        runnerWorkspace = workRoot + "/" + repoName
        workspace = runnerWorkspace + "/" + repoName
    }

    // MARK: - Cancellation

    public func cancel() {
        lock.lock()
        cancelled = true
        if jobResult != "failed" { jobResult = "canceled" }
        let p = currentProcess
        if p != nil { currentProcessWasTerminated = true }
        lock.unlock()
        p?.terminate()
    }

    // MARK: - Top level

    public func run() async -> JobOutcome {
        let setup = logger.addStep(name: "Set up job", refName: "JobExtension_Init")
        logger.start(setup)
        var setupFailed = false
        do {
            try await setUpJob(setup)
        } catch {
            logger.error(setup, "\(error)")
            logger.addIssue(setup, type: "error", message: "\(error)")
            setupFailed = true
        }
        logger.complete(setup, result: setupFailed ? "failed" : "succeeded")

        var queue: [PendingStep] = []
        if !setupFailed {
            queue = pendingMainSteps
        } else {
            jobResult = "failed"
            for p in pendingMainSteps { logger.complete(p.record, result: "skipped") }
        }

        while !queue.isEmpty {
            let step = queue.removeFirst()
            await runStep(step)
            if queue.isEmpty, !postSteps.isEmpty {
                queue = postSteps.reversed()
                postSteps = []
            }
        }

        let final = logger.addStep(name: "Complete job", refName: "JobExtension_Final")
        logger.start(final)
        var outputs: [String: VariableValue] = [:]
        if !setupFailed {
            outputs = evaluateJobOutputs(final)
        }
        cleanTemp()
        logger.complete(final, result: "succeeded")

        let result = lock.withLock { jobResult }
        await logger.finish(result: result)
        let steps = logger.allSteps
        return JobOutcome(result: result, outputs: outputs, stepResults: steps.map(\.stepResultSummary),
                          annotations: [])
    }

    private var pendingMainSteps: [PendingStep] = []

    // MARK: - Set up job

    private func setUpJob(_ rec: StepRecord) async throws {
        logger.write(rec, "Current runner version: '\(record.runnerVersion)' (runski \(RunskiVersion.current))")
        logger.write(rec, "Runner name: '\(record.name)'")
        logger.write(rec, "Machine: \(Platform.hostName) (\(Platform.osDescription), \(Platform.archLabel))")
        if let wf = message.variable("system.workflowFileFullPath") {
            logger.group(rec, "Operating System"); logger.write(rec, "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"); logger.endGroup(rec)
            logger.write(rec, "Uses: \(wf)\(message.variable("system.workflowFileRef").map { "@\($0)" } ?? "")")
        }

        // Secrets → masker.
        for (k, v) in message.variables ?? [:] where v.isSecret == true {
            if k.caseInsensitiveCompare("ACTIONS_STEP_DEBUG") == .orderedSame || k.caseInsensitiveCompare("ACTIONS_RUNNER_DEBUG") == .orderedSame { continue }
            if let val = v.value { masker.add(val) }
        }
        for hint in message.maskHints ?? [] where hint.type.caseInsensitiveCompare("regex") == .orderedSame { masker.addRegex(hint.value) }
        for ep in message.resources?.endpoints ?? [] { for (_, v) in ep.authorization?.parameters ?? [:] { masker.add(v) } }
        if let token = message.variable("system.github.token") {
            masker.add(token)
            masker.add(Data("x-access-token:\(token)".utf8).base64EncodedString())
        }
        for (_, v) in localSecrets { masker.add(v) }

        // Directories.
        let fm = FileManager.default
        try? fm.removeItem(atPath: tempDir)
        for d in [workRoot, tempDir, fileCommandsDir, tempDir + "/_github_workflow", runnerWorkspace, workspace, paths.toolCacheDir.path] {
            try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        if let clean = message.workspace?.clean?.lowercased(), ["all", "resources"].contains(clean) {
            try? fm.removeItem(atPath: workspace)
            try fm.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        }

        // Contexts.
        buildContexts()
        let debugVar = message.variable("ACTIONS_STEP_DEBUG") ?? staticContexts["vars"]?.objectValue?["ACTIONS_STEP_DEBUG"]?.asString
        stepDebug = debugVar?.caseInsensitiveCompare("true") == .orderedSame
        if stepDebug { runnerCtx["debug"] = .string("1") }

        // Job-level env (workflow env then job env; last wins).
        for tok in message.environmentVariables ?? [] {
            let pairs = try TemplateEvaluator.evaluateStringMap(tok, context: context(scope: nil, stepEnv: []))
            for (k, v) in pairs { setGlobalEnv(k, v) }
        }
        if let perms = message.variable("system.github.token.permissions"), let data = perms.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            logger.group(rec, "GITHUB_TOKEN Permissions")
            for k in obj.keys.sorted() { logger.write(rec, "\(k): \(obj[k] ?? "")") }
            logger.endGroup(rec)
        }
        if !localSecrets.isEmpty {
            logger.write(rec, "Local runski secrets available to steps: \(localSecrets.keys.sorted().joined(separator: ", "))")
        }
        if message.jobContainer != nil, case .null = message.jobContainer! {} else if message.jobContainer != nil {
            throw WorkerError("Container jobs are not supported on macOS runners")
        }

        // Steps → records + actions.
        let steps = message.steps ?? []
        var refs: [(nameWithOwner: String, ref: String)] = []
        for s in steps where s.reference.type.caseInsensitiveCompare("repository") == .orderedSame && s.reference.repositoryType?.caseInsensitiveCompare("self") != .orderedSame {
            if let n = s.reference.name, let r = s.reference.ref { refs.append((n, r)) }
        }
        if !refs.isEmpty {
            logger.group(rec, "Prepare all required actions")
            logger.write(rec, "Getting action download info")
        }
        let resolved = await actions.resolve(refs) { logger.write(rec, $0) }
        for s in steps {
            let ctx = context(scope: nil, stepEnv: [])
            let name = displayName(for: s, context: ctx, resolved: nil)
            let r = logger.addStep(name: name, refName: s.name ?? s.contextName ?? s.id, id: s.id)
            let stateKey = s.id
            var action: PreparedAction? = nil
            if s.reference.type.caseInsensitiveCompare("repository") == .orderedSame {
                do {
                    action = try await prepare(reference: s.reference, resolved: resolved, rec: rec, depth: 0)
                } catch {
                    logger.error(rec, "\(error)")
                    throw error
                }
                r.actionName = s.reference.name; r.actionRef = s.reference.ref; r.actionType = "repository"
            } else if s.reference.type.caseInsensitiveCompare("containerRegistry") == .orderedSame {
                throw WorkerError("Container action is only supported on Linux (step '\(name)')")
            }
            let pending = PendingStep(record: r, step: s, stage: .main, action: action, stateKey: stateKey)
            if let a = action, case .node(_, _, let pre, _, _, _) = a.manifest.runs, pre != nil {
                let preRec = logger.addStep(name: "Pre \(name)", refName: "pre-\(s.id)")
                pendingMainSteps.append(PendingStep(record: preRec, step: s, stage: .pre, action: a, stateKey: stateKey))
            }
            pendingMainSteps.append(pending)
        }
        if !refs.isEmpty { logger.endGroup(rec) }
        // Re-order: all pre steps first (in step order), then main steps.
        let pres = pendingMainSteps.filter { $0.stage == .pre }
        let mains = pendingMainSteps.filter { $0.stage == .main }
        pendingMainSteps = pres + mains
        // Node runtime check for JS actions.
        if pendingMainSteps.contains(where: { if case .node = $0.action?.manifest.runs { return true }; return false }) {
            _ = try await nodeBinary(version: "node20", rec: rec)
        }
    }

    private func prepare(reference: ActionStep.Reference, resolved: [String: ActionManager.Resolved], rec: StepRecord, depth: Int) async throws -> PreparedAction {
        guard depth < 10 else { throw WorkerError("Composite action depth exceeded") }
        var dir: String
        var owner: String? = nil, ref: String? = nil
        if reference.repositoryType?.caseInsensitiveCompare("self") == .orderedSame || reference.name == nil {
            let p = reference.path ?? "."
            dir = p.hasPrefix("/") ? p : workspace + "/" + p
        } else {
            let key = "\(reference.name!)@\(reference.ref ?? "")"
            if let cached = prepared[key + "/" + (reference.path ?? "")] { return cached }
            guard let r = resolved[key] ?? resolved.values.first(where: { "\($0.nameWithOwner)@\($0.ref)".caseInsensitiveCompare(key) == .orderedSame }) else {
                throw WorkerError("Could not resolve action '\(key)'")
            }
            dir = try await actions.download(r) { logger.write(rec, $0) }
            if let p = reference.path, !p.isEmpty { dir += "/" + p }
            owner = reference.name; ref = reference.ref
        }
        let manifest = try ActionManifest.load(directory: dir)
        if case .docker = manifest.runs { throw WorkerError("Container action is only supported on Linux ('\(reference.name ?? dir)')") }
        let pa = PreparedAction(manifest: manifest, directory: dir, nameWithOwner: owner, ref: ref)
        if case .composite(let steps) = manifest.runs {
            // Recursively prepare nested `uses:`.
            var nested: [(nameWithOwner: String, ref: String)] = []
            for st in steps {
                if let uses = st["uses"]?.stringValue, !uses.hasPrefix("./"), !uses.hasPrefix("docker://") {
                    let (n, _, r) = JobRunner.splitUses(uses)
                    nested.append((n, r))
                }
            }
            let more = nested.isEmpty ? [:] : await actions.resolve(nested) { logger.write(rec, $0) }
            for st in steps {
                guard let uses = st["uses"]?.stringValue else { continue }
                let childRef: ActionStep.Reference
                if uses.hasPrefix("./") {
                    childRef = ActionStep.Reference(type: "repository", name: nil, ref: nil, repositoryType: "self", path: uses, image: nil)
                    // Composite-local: relative to the action directory, not the workspace.
                    let childDir = dir + "/" + uses
                    let m = try ActionManifest.load(directory: childDir)
                    prepared["local:" + childDir] = PreparedAction(manifest: m, directory: childDir, nameWithOwner: nil, ref: nil)
                    continue
                } else if uses.hasPrefix("docker://") {
                    throw WorkerError("Container action is only supported on Linux ('\(uses)')")
                } else {
                    let (n, p, r) = JobRunner.splitUses(uses)
                    childRef = ActionStep.Reference(type: "repository", name: n, ref: r, repositoryType: "GitHub", path: p, image: nil)
                }
                _ = try await prepare(reference: childRef, resolved: more.merging(resolved) { a, _ in a }, rec: rec, depth: depth + 1)
            }
        }
        if let o = owner { prepared["\(o)@\(ref ?? "")/\(reference.path ?? "")"] = pa }
        return pa
    }

    static func splitUses(_ uses: String) -> (String, String?, String) {
        let parts = uses.split(separator: "@", maxSplits: 1).map(String.init)
        let ref = parts.count > 1 ? parts[1] : ""
        let segs = parts[0].split(separator: "/").map(String.init)
        guard segs.count >= 2 else { return (parts[0], nil, ref) }
        let name = segs[0] + "/" + segs[1]
        let path = segs.count > 2 ? segs[2...].joined(separator: "/") : nil
        return (name, path, ref)
    }

    // MARK: - Contexts

    private func buildContexts() {
        for (name, data) in message.contextData ?? [:] {
            staticContexts[name.lowercased()] = ExprValue.from(data)
        }
        github = ExprValue.ExprObject()
        if let g = staticContexts["github"]?.objectValue { for p in g.pairs { github[p.key] = p.value } }
        if let t = message.variable("system.github.token") { github["token"] = .string(t) }
        if let j = message.variable("system.github.job") { github["job"] = .string(j) }
        github["workspace"] = .string(workspace)
        github["event_path"] = .string(tempDir + "/_github_workflow/event.json")
        if github["server_url"] == nil { github["server_url"] = .string("https://github.com") }
        if github["api_url"] == nil { github["api_url"] = .string("https://api.github.com") }
        if github["graphql_url"] == nil { github["graphql_url"] = .string("https://api.github.com/graphql") }
        if let ev = github["event"], let data = try? JSONSerialization.data(withJSONObject: ExprValueBridge.foundation(ev), options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: tempDir + "/_github_workflow/event.json"))
        }

        jobCtx = ExprValue.ExprObject()
        if let j = staticContexts["job"]?.objectValue { for p in j.pairs { jobCtx[p.key] = p.value } }
        jobCtx["status"] = .string("success")
        jobCtx["container"] = .null
        jobCtx["services"] = .null

        runnerCtx = ExprValue.ExprObject([
            ("os", .string(Platform.osLabel)), ("arch", .string(Platform.archLabel)), ("name", .string(record.name)),
            ("environment", .string(message.variable("system.runnerEnvironment") ?? "self-hosted")),
            ("tool_cache", .string(paths.toolCacheDir.path)), ("temp", .string(tempDir)), ("workspace", .string(runnerWorkspace)),
        ])

        let secrets = ExprValue.ExprObject()
        for (k, v) in message.variables ?? [:] where v.isSecret == true {
            if k.caseInsensitiveCompare("system.accessToken") == .orderedSame || k.caseInsensitiveCompare("system.github.token") == .orderedSame { continue }
            secrets[k] = .string(v.value ?? "")
        }
        if secrets["GITHUB_TOKEN"] == nil, let t = message.variable("system.github.token") { secrets["GITHUB_TOKEN"] = .string(t) }
        staticContexts["secrets"] = .object(secrets)
        for k in ["strategy", "matrix", "needs", "inputs", "vars"] where staticContexts[k] == nil { staticContexts[k] = .null }
    }

    func setGlobalEnv(_ k: String, _ v: String) {
        if let i = globalEnv.firstIndex(where: { $0.0 == k }) { globalEnv[i].1 = v } else { globalEnv.append((k, v)) }
    }

    /// Full expression context for a step.
    func context(scope: ExprValue.ExprObject?, stepEnv: [(String, String)], inputs: ExprValue? = nil, actionStatus: String? = nil) -> ExpressionContext {
        let env = ExprValue.ExprObject([], caseSensitive: true)
        for (k, v) in globalEnv { env[k] = .string(v) }
        for (k, v) in stepEnv { env[k] = .string(v) }
        var values = staticContexts
        values["github"] = .object(github)
        values["job"] = .object(jobCtx)
        values["runner"] = .object(runnerCtx)
        values["env"] = .object(env)
        values["steps"] = .object(scope ?? stepsRoot)
        if let inputs { values["inputs"] = inputs }
        updateJobStatus()
        var ctx = ExpressionContext(values: values)
        let status = actionStatus ?? (jobCtx["status"]?.asString ?? "success")
        ctx.setFunction("success") { _ in .bool(status == "success") }
        ctx.setFunction("failure") { _ in .bool(status == "failure") }
        ctx.setFunction("cancelled") { [self] _ in .bool(lock.withLock { cancelled }) }
        ctx.setFunction("always") { _ in .bool(true) }
        let ws = workspace
        ctx.setFunction("hashFiles") { args in
            var patterns = args.map(\.asString)
            if let first = patterns.first, first.hasPrefix("--") {
                guard first.caseInsensitiveCompare("--follow-symbolic-links") == .orderedSame else { throw ExpressionError("Invalid glob option \(first), valid options are '--follow-symbolic-links'") }
                patterns.removeFirst()
            }
            return .string(try HashFiles.hash(patterns: patterns.joined(separator: "\n"), workspace: ws))
        }
        return ctx
    }

    private func updateJobStatus() {
        let (r, c) = lock.withLock { (jobResult, cancelled) }
        if c { jobCtx["status"] = .string("cancelled"); return }
        switch r {
        case "succeeded", "succeededWithIssues": jobCtx["status"] = .string("success")
        case "canceled": jobCtx["status"] = .string("cancelled")
        default: jobCtx["status"] = .string("failure")
        }
    }

    private func mergeJobResult(_ stepResult: String) {
        lock.lock()
        if ["canceled", "skipped", "abandoned"].contains(jobResult) { lock.unlock(); return }
        if stepResult == "failed" { jobResult = "failed" }
        else if stepResult == "canceled" { jobResult = "canceled" }
        lock.unlock()
        updateJobStatus()
    }

    // MARK: - Display names

    private func displayName(for s: ActionStep, context: ExpressionContext, resolved: String?) -> String {
        if let d = s.displayName, !d.isEmpty { return masker.mask(d) }
        if let tok = s.displayNameToken, let v = try? TemplateEvaluator.evaluateString(tok, context: context) { return formatStepName(v) }
        if s.displayNameToken != nil, case .string(let str) = s.displayNameToken! { return formatStepName(str) }
        switch s.reference.type.lowercased() {
        case "repository":
            if let n = s.reference.name {
                var spec = n
                if let p = s.reference.path, !p.isEmpty { spec += "/" + p }
                if let r = s.reference.ref { spec += "@" + r }
                return "Run " + spec
            }
            return "Run " + (s.reference.path ?? "./")
        case "containerregistry": return "Run " + (s.reference.image ?? "docker")
        default:
            if let script = s.inputs?["script"] {
                if case .string(let str) = script { return "Run " + formatStepName(str) }
                if let v = try? TemplateEvaluator.evaluateString(script, context: context) { return "Run " + formatStepName(v) }
                return "Run " + formatStepName(scriptTokenPreview(script))
            }
            return "Run"
        }
    }

    private func scriptTokenPreview(_ t: TemplateToken) -> String {
        if case .expression(let e) = t { return "${{ \(e) }}" }
        return t.stringValue ?? "run"
    }

    private func formatStepName(_ s: String) -> String {
        let trimmed = s.drop { $0.isWhitespace }
        let first = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.isEmpty ? "run" : masker.mask(first)
    }

    // MARK: - Running a step

    private func runStep(_ p: PendingStep) async {
        let rec = p.record
        let s = p.step
        let scope: ExprValue.ExprObject? = nil
        var stepEnv: [(String, String)] = []
        var ctx = context(scope: scope, stepEnv: [])

        // Refresh display name now that steps/env contexts exist.
        if p.stage == .main, !p.displayNameResolved {
            let name = displayName(for: s, context: ctx, resolved: nil)
            rec.name = name
            p.displayNameResolved = true
        }

        // Step env.
        do {
            stepEnv = try TemplateEvaluator.evaluateStringMap(s.environment, context: ctx)
            ctx = context(scope: scope, stepEnv: stepEnv)
        } catch {
            logger.start(rec); logger.error(rec, "Failed to evaluate step env: \(error)")
            finishStep(p, result: "failed", outcomeBeforeCOE: "failed"); return
        }

        // Condition.
        let condition: String
        switch p.stage {
        case .main: condition = s.condition ?? "success()"
        case .pre:
            if case .node(_, _, _, let preIf, _, _)? = p.action?.manifest.runs { condition = preIf ?? "always()" } else { condition = "always()" }
        case .post:
            if case .node(_, _, _, _, _, let postIf)? = p.action?.manifest.runs { condition = postIf ?? "always()" } else { condition = "always()" }
        }
        let shouldRun: Bool
        do { shouldRun = try Expression.evaluateCondition(condition, context: ctx) }
        catch {
            logger.start(rec); logger.error(rec, "Failed to evaluate condition '\(condition)': \(error)")
            finishStep(p, result: "failed", outcomeBeforeCOE: "failed"); return
        }
        guard shouldRun else {
            rec.startTime = Date()
            logger.complete(rec, result: "skipped")
            recordStepContext(s, scope: scope, outcome: "skipped", conclusion: "skipped")
            return
        }

        logger.start(rec)
        lock.withLock { currentProcessWasTerminated = false }
        let timeout: TimeInterval? = (try? TemplateEvaluator.evaluateNumber(s.timeoutInMinutes, context: ctx)).flatMap { $0 }.flatMap { $0 > 0 ? $0 * 60 : nil }
        var result: String
        do {
            let ok = try await execute(p, ctx: ctx, stepEnv: stepEnv, timeout: timeout)
            result = ok ? "succeeded" : "failed"
        } catch is CancellationError {
            result = "canceled"
        } catch {
            logger.error(rec, "\(error)")
            logger.addIssue(rec, type: "error", message: "\(error)")
            result = "failed"
        }
        if result == "failed", lock.withLock({ currentProcessWasTerminated }) { result = "canceled" }

        // continue-on-error
        var outcome = result
        if result == "failed" {
            if let coe = try? TemplateEvaluator.evaluateBool(s.continueOnError, context: ctx), coe == true {
                outcome = "failed"; result = "succeeded"
            }
        }
        finishStep(p, result: result, outcomeBeforeCOE: outcome)
    }

    private var currentProcessWasTerminated = false

    private func finishStep(_ p: PendingStep, result: String, outcomeBeforeCOE: String) {
        logger.complete(p.record, result: result)
        if p.stage == .main {
            recordStepContext(p.step, scope: nil, outcome: lower(outcomeBeforeCOE), conclusion: lower(result))
        }
        if result == "failed" || result == "canceled" { mergeJobResult(result) }
    }

    private func lower(_ r: String) -> String {
        switch r {
        case "succeeded", "succeededWithIssues": return "success"
        case "failed": return "failure"
        case "canceled": return "cancelled"
        case "skipped": return "skipped"
        default: return r
        }
    }

    private func recordStepContext(_ s: ActionStep, scope: ExprValue.ExprObject?, outcome: String, conclusion: String) {
        guard let name = s.contextName, !name.isEmpty, !name.hasPrefix("__") else { return }
        let target = scope ?? stepsRoot
        let entry = target[name]?.objectValue ?? ExprValue.ExprObject([("outputs", .obj())])
        entry["outcome"] = .string(outcome)
        entry["conclusion"] = .string(conclusion)
        target[name] = .object(entry)
    }

    private func stepOutputs(_ contextName: String?, scope: ExprValue.ExprObject?) -> ExprValue.ExprObject? {
        guard let name = contextName, !name.isEmpty, !name.hasPrefix("__") else { return nil }
        let target = scope ?? stepsRoot
        let entry = target[name]?.objectValue ?? ExprValue.ExprObject([("outputs", .obj())])
        target[name] = .object(entry)
        if entry["outputs"]?.objectValue == nil { entry["outputs"] = .obj() }
        return entry["outputs"]!.objectValue
    }

    // MARK: - Execution dispatch

    /// Returns true on success.
    private func execute(_ p: PendingStep, ctx: ExpressionContext, stepEnv: [(String, String)], timeout: TimeInterval?) async throws -> Bool {
        let rec = p.record
        let s = p.step
        github["action"] = .string(s.name ?? s.contextName ?? s.id)
        github["action_repository"] = p.action?.nameWithOwner.map { .string($0) } ?? .null
        github["action_ref"] = p.action?.ref.map { .string($0) } ?? .null
        github["action_path"] = .null
        github["action_status"] = .null

        let files = FileCommands(dir: fileCommandsDir)
        github["env"] = .string(files.env); github["path"] = .string(files.path); github["output"] = .string(files.output)
        github["state"] = .string(files.state); github["step_summary"] = .string(files.summary)
        defer { files.cleanup() }

        let outputs = stepOutputs(s.contextName, scope: nil)
        var ok: Bool
        if p.stage == .post, let children = compositePosts.removeValue(forKey: ObjectIdentifier(p)) {
            ok = true
            for (child, childAction, scope) in children.reversed() {
                logger.group(rec, child.record.name)
                let childCtx = context(scope: scope, stepEnv: stepEnv)
                do {
                    if try await runAction(child, action: childAction, rec: rec, ctx: childCtx, stepEnv: stepEnv, timeout: timeout, outputs: nil, scope: scope) == false { ok = false }
                } catch is CancellationError { logger.endGroup(rec); throw CancellationError() }
                catch { logger.error(rec, "\(error)"); ok = false }
                logger.endGroup(rec)
            }
        } else if s.reference.type.caseInsensitiveCompare("script") == .orderedSame {
            ok = try await runScript(rec, inputs: s.inputs, ctx: ctx, stepEnv: stepEnv, timeout: timeout, outputs: outputs, stateKey: p.stateKey, scope: nil, actionStatus: nil)
        } else if let action = p.action {
            ok = try await runAction(p, action: action, rec: rec, ctx: ctx, stepEnv: stepEnv, timeout: timeout, outputs: outputs, scope: nil)
        } else {
            throw WorkerError("Unsupported step reference '\(s.reference.type)'")
        }
        if !processFileCommands(files, rec: rec, outputs: outputs, stateKey: p.stateKey) { ok = false }
        return ok
    }

    // MARK: - Script steps

    private struct ShellSpec { let executable: String; let argFormat: String; let ext: String; let display: String }

    private func resolveShell(_ requested: String?, searchPath: String) throws -> ShellSpec {
        let builtins: [String: (String, String)] = [
            "bash": ("--noprofile --norc -e -o pipefail {0}", "sh"), "sh": ("-e {0}", "sh"),
            "pwsh": ("-command \". '{0}'\"", "ps1"), "powershell": ("-command \". '{0}'\"", "ps1"),
            "python": ("{0}", "py"), "zsh": ("-e {0}", "sh"),
        ]
        guard let requested, !requested.trimmingCharacters(in: .whitespaces).isEmpty else {
            let exe = findExecutable("bash", path: searchPath) ?? findExecutable("sh", path: searchPath) ?? "/bin/sh"
            return ShellSpec(executable: exe, argFormat: "-e {0}", ext: "sh", display: exe)
        }
        let trimmed = requested.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts[0]
        guard let exe = findExecutable(cmd, path: searchPath) else { throw WorkerError("\(cmd): command not found. Make sure '\(cmd)' is installed and on the PATH.") }
        if parts.count == 1 {
            guard let b = builtins[cmd.lowercased()] else {
                throw WorkerError("Invalid shell option. Shell must be a valid built-in (bash, sh, cmd, powershell, pwsh) or a format string containing '{0}'")
            }
            return ShellSpec(executable: exe, argFormat: b.0, ext: b.1, display: trimmed)
        }
        guard parts[1].contains("{0}") else { throw WorkerError("Invalid shell option. Shell must be a valid built-in (bash, sh, cmd, powershell, pwsh) or a format string containing '{0}'") }
        return ShellSpec(executable: exe, argFormat: parts[1], ext: "", display: trimmed)
    }

    private func defaultsRun() -> (shell: String?, workingDirectory: String?) {
        for tok in message.defaults ?? [] {
            if let run = tok["run"] {
                return (run["shell"]?.stringValue, run["working-directory"]?.stringValue)
            }
        }
        return (nil, nil)
    }

    private func runScript(_ rec: StepRecord, inputs: TemplateToken?, ctx: ExpressionContext, stepEnv: [(String, String)], timeout: TimeInterval?,
                           outputs: ExprValue.ExprObject?, stateKey: String, scope: ExprValue.ExprObject?, actionStatus: String?,
                           workingDirectoryBase: String? = nil, extraEnv: [(String, String)] = []) async throws -> Bool {
        let pairs = try TemplateEvaluator.evaluateStringMap(inputs, context: ctx)
        func input(_ n: String) -> String? { pairs.first { $0.0.caseInsensitiveCompare(n) == .orderedSame }?.1 }
        guard var script = input("script") else { throw WorkerError("run step has no script") }
        let defaults = defaultsRun()
        let env = processEnvironment(stepEnv: stepEnv + extraEnv, stateKey: stateKey, forNode: false)
        let shell = try resolveShell(input("shell") ?? (scope == nil ? defaults.shell : nil), searchPath: env["PATH"] ?? "")
        var cwd = workingDirectoryBase ?? workspace
        if let wd = input("workingDirectory") ?? (scope == nil ? defaults.workingDirectory : nil), !wd.isEmpty {
            cwd = wd.hasPrefix("/") ? wd : cwd + "/" + wd
        }
        if shell.ext == "ps1" {
            script = "$ErrorActionPreference = 'stop'\n" + script + "\nif ((Test-Path -LiteralPath variable:\\LASTEXITCODE)) { exit $LASTEXITCODE }"
        }
        if !script.hasSuffix("\n") { script += "\n" }
        let file = tempDir + "/" + UUID().uuidString.lowercased() + (shell.ext.isEmpty ? "" : "." + shell.ext)
        try script.write(toFile: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file)

        let args = shell.argFormat.replacingOccurrences(of: "{0}", with: file)
        logger.group(rec, "Run \(formatStepName(script))")
        for line in script.split(separator: "\n", omittingEmptySubsequences: false).dropLast() { logger.write(rec, "\u{1B}[36;1m\(line)\u{1B}[0m") }
        logger.write(rec, "shell: \(shell.display) \(shell.argFormat)")
        if !stepEnv.isEmpty {
            logger.write(rec, "env:")
            for (k, v) in stepEnv { logger.write(rec, "  \(k): \(v)") }
        }
        logger.endGroup(rec)

        let argv = JobRunner.splitArgs(args)
        let proc = ProcessRunner(executable: shell.executable, arguments: argv, environment: env, workingDirectory: cwd)
        proc.graceSeconds = (config.cancelGraceSeconds, max(1, config.cancelGraceSeconds / 3))
        let exit = try await spawn(proc, rec: rec, timeout: timeout, outputs: outputs, stateKey: stateKey)
        if exit.timedOut {
            logger.error(rec, "The action '\(rec.name)' has timed out after \(Int((timeout ?? 0) / 60)) minutes.")
            logger.addIssue(rec, type: "error", message: "The action '\(rec.name)' has timed out after \(Int((timeout ?? 0) / 60)) minutes.")
            return false
        }
        if exit.exitCode != 0 {
            if lock.withLock({ currentProcessWasTerminated }) { throw CancellationError() }
            logger.error(rec, "Process completed with exit code \(exit.exitCode).")
            logger.addIssue(rec, type: "error", message: "Process completed with exit code \(exit.exitCode).")
            return false
        }
        return true
    }

    /// Split a shell-style argument string honoring double quotes (as the runner does for `{0}` formats).
    static func splitArgs(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        var hasToken = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\\", inQuote, s.index(after: i) < s.endIndex, s[s.index(after: i)] == "\"" { cur.append("\""); i = s.index(i, offsetBy: 2); continue }
            if c == "\"" { inQuote.toggle(); hasToken = true }
            else if c == " ", !inQuote { if hasToken { out.append(cur); cur = ""; hasToken = false } }
            else { cur.append(c); hasToken = true }
            i = s.index(after: i)
        }
        if hasToken { out.append(cur) }
        return out
    }

    private func spawn(_ proc: ProcessRunner, rec: StepRecord, timeout: TimeInterval?, outputs: ExprValue.ExprObject?, stateKey: String) async throws -> ProcessRunner.Result {
        lock.withLock { currentProcess = proc }
        defer { lock.withLock { currentProcess = nil } }
        let handler = CommandHandler(runner: self, rec: rec, outputs: outputs, stateKey: stateKey)
        return try await proc.run(timeout: timeout) { isErr, line in
            handler.handle(line, isStderr: isErr)
        }
    }

    // MARK: - Actions

    private func nodeBinary(version: String, rec: StepRecord) async throws -> String {
        let provider = NodeProvider(paths: paths, config: config, http: http, log: log)
        return try await provider.node(for: version, searchPath: basePath()) { logger.write(rec, $0) }
    }

    private func runAction(_ p: PendingStep, action: PreparedAction, rec: StepRecord, ctx: ExpressionContext, stepEnv: [(String, String)],
                           timeout: TimeInterval?, outputs: ExprValue.ExprObject?, scope: ExprValue.ExprObject?, parentInputs: ExprValue? = nil) async throws -> Bool {
        let with = try TemplateEvaluator.evaluateStringMap(p.step.inputs, context: ctx)
        // Inputs = with + defaults for missing.
        var inputs: [(String, String)] = with
        for (name, spec) in action.manifest.inputs where !with.contains(where: { $0.0.caseInsensitiveCompare(name) == .orderedSame }) {
            if let def = spec.defaultValue {
                let v = try TemplateEvaluator.evaluateString(def, context: ctx) ?? ""
                inputs.append((name, v))
            }
            if spec.required, def(spec) == nil { logger.warning(rec, "Input '\(name)' is required but was not supplied") }
        }
        for (name, _) in with where !action.manifest.inputs.contains(where: { $0.0.caseInsensitiveCompare(name) == .orderedSame }) && action.nameWithOwner != nil {
            logger.warning(rec, "Unexpected input(s) '\(name)', valid inputs are [\(action.manifest.inputs.map(\.0).joined(separator: ", "))]")
        }
        switch action.manifest.runs {
        case .node(let version, let main, let pre, _, let post, _):
            let entry: String
            switch p.stage {
            case .pre: entry = pre ?? main
            case .main: entry = main
            case .post: entry = post ?? main
            }
            if p.stage == .main, let post {
                let postRec = logger.addStep(name: "Post \(rec.name)", refName: "post-\(p.step.id)")
                postSteps.append(PendingStep(record: postRec, step: p.step, stage: .post, action: action, stateKey: p.stateKey))
            }
            let node = try await nodeBinary(version: version, rec: rec)
            var env = processEnvironment(stepEnv: stepEnv, stateKey: p.stateKey, forNode: true)
            for (k, v) in inputs { env["INPUT_" + k.uppercased().replacingOccurrences(of: " ", with: "_")] = v }
            let script = action.directory + "/" + entry
            logger.write(rec, "##[debug]node \(script)")
            let proc = ProcessRunner(executable: node, arguments: [script], environment: env, workingDirectory: workspace)
            proc.graceSeconds = (config.cancelGraceSeconds, max(1, config.cancelGraceSeconds / 3))
            let exit = try await spawn(proc, rec: rec, timeout: timeout, outputs: outputs, stateKey: p.stateKey)
            if exit.timedOut { logger.error(rec, "The action '\(rec.name)' has timed out."); return false }
            if exit.exitCode != 0 {
                if lock.withLock({ currentProcessWasTerminated }) { throw CancellationError() }
                logger.error(rec, "Process completed with exit code \(exit.exitCode).")
                logger.addIssue(rec, type: "error", message: "Process completed with exit code \(exit.exitCode).")
                return false
            }
            return true
        case .composite(let steps):
            guard p.stage == .main else { return true }
            return try await runComposite(p, action: action, steps: steps, inputs: inputs, rec: rec, stepEnv: stepEnv, timeout: timeout, outputs: outputs)
        case .docker:
            throw WorkerError("Container action is only supported on Linux")
        }
    }

    private func def(_ i: ActionManifest.Input) -> TemplateToken? { i.defaultValue }

    private func runComposite(_ p: PendingStep, action: PreparedAction, steps: [TemplateToken], inputs: [(String, String)], rec: StepRecord,
                              stepEnv: [(String, String)], timeout: TimeInterval?, outputs: ExprValue.ExprObject?) async throws -> Bool {
        let inputsObj = ExprValue.obj(inputs.map { ($0.0, .string($0.1)) })
        let scope = ExprValue.ExprObject()
        var status = "success"
        let savedActionPath = github["action_path"]
        github["action_path"] = .string(action.directory)
        defer { github["action_path"] = savedActionPath ?? .null }
        var childPosts: [(PendingStep, PreparedAction)] = []

        for (i, tok) in steps.enumerated() {
            github["action_status"] = .string(status)
            var childEnv: [(String, String)] = stepEnv
            var ctx = context(scope: scope, stepEnv: childEnv, inputs: inputsObj, actionStatus: status)
            if let e = tok["env"] {
                for (k, v) in try TemplateEvaluator.evaluateStringMap(e, context: ctx) { childEnv.append((k, v)) }
                ctx = context(scope: scope, stepEnv: childEnv, inputs: inputsObj, actionStatus: status)
            }
            let id = tok["id"]?.stringValue
            let name: String
            if let n = tok["name"] { name = (try? TemplateEvaluator.evaluateString(n, context: ctx)) ?? "step" }
            else if let uses = tok["uses"]?.stringValue { name = "Run \(uses)" }
            else if let run = tok["run"] { name = "Run " + formatStepName((try? TemplateEvaluator.evaluateString(run, context: ctx)) ?? run.stringValue ?? "run") }
            else { name = "step \(i + 1)" }

            let cond = try Expression.normalizeCondition(tok["if"].flatMap { t -> String? in
                if case .expression(let e) = t { return "${{ \(e) }}" }
                return t.stringValue
            })
            let shouldRun = try Expression.evaluateCondition(cond, context: ctx)
            let childOutputs = stepOutputs(id, scope: scope)
            guard shouldRun else {
                if let id { let e = scope[id]?.objectValue ?? ExprValue.ExprObject([("outputs", .obj())]); e["outcome"] = .string("skipped"); e["conclusion"] = .string("skipped"); scope[id] = .object(e) }
                continue
            }
            logger.group(rec, name)
            var childResult: String
            do {
                let files = FileCommands(dir: fileCommandsDir)
                github["env"] = .string(files.env); github["path"] = .string(files.path); github["output"] = .string(files.output)
                github["state"] = .string(files.state); github["step_summary"] = .string(files.summary)
                var ok: Bool
                if let run = tok["run"] {
                    let inputsTok: TemplateToken = .mapping([(key: .string("script"), value: run)] +
                        (tok["shell"].map { [(key: .string("shell"), value: $0)] } ?? []) +
                        (tok["working-directory"].map { [(key: .string("workingDirectory"), value: $0)] } ?? []))
                    ok = try await runScript(rec, inputs: inputsTok, ctx: ctx, stepEnv: childEnv, timeout: timeout, outputs: childOutputs,
                                             stateKey: p.stateKey + "/" + String(i), scope: scope, actionStatus: status)
                } else if let uses = tok["uses"]?.stringValue {
                    let childAction: PreparedAction
                    if uses.hasPrefix("./") {
                        guard let a = prepared["local:" + action.directory + "/" + uses] else { throw WorkerError("local action \(uses) was not prepared") }
                        childAction = a
                    } else {
                        let (n, path, r) = JobRunner.splitUses(uses)
                        guard let a = prepared["\(n)@\(r)/\(path ?? "")"] else { throw WorkerError("action \(uses) was not prepared") }
                        childAction = a
                    }
                    let childStep = ActionStep(type: "action", id: p.step.id + "-" + String(i), name: id, reference: ActionStep.Reference(type: "repository", name: childAction.nameWithOwner, ref: childAction.ref, repositoryType: childAction.nameWithOwner == nil ? "self" : "GitHub", path: nil, image: nil),
                                               displayNameToken: nil, displayName: name, contextName: id, condition: nil, continueOnError: tok["continue-on-error"],
                                               timeoutInMinutes: nil, inputs: tok["with"], environment: nil)
                    let childPending = PendingStep(record: rec, step: childStep, stage: .main, action: childAction, stateKey: p.stateKey + "/" + String(i))
                    let before = postSteps.count
                    ok = try await runAction(childPending, action: childAction, rec: rec, ctx: ctx, stepEnv: childEnv, timeout: timeout, outputs: childOutputs, scope: scope, parentInputs: inputsObj)
                    // Child post steps are hoisted into the composite's own post.
                    if postSteps.count > before {
                        for ps in postSteps[before...] { childPosts.append((ps, childAction)) }
                        postSteps.removeSubrange(before...)
                    }
                } else {
                    throw WorkerError("composite step \(i + 1) has neither 'run' nor 'uses'")
                }
                if !processFileCommands(files, rec: rec, outputs: childOutputs, stateKey: p.stateKey + "/" + String(i)) { ok = false }
                files.cleanup()
                childResult = ok ? "success" : "failure"
            } catch is CancellationError {
                logger.endGroup(rec); throw CancellationError()
            } catch {
                logger.error(rec, "\(error)")
                childResult = "failure"
            }
            logger.endGroup(rec)
            var conclusion = childResult
            if childResult == "failure", let coe = try? TemplateEvaluator.evaluateBool(tok["continue-on-error"], context: ctx), coe == true { conclusion = "success" }
            if let id { let e = scope[id]?.objectValue ?? ExprValue.ExprObject([("outputs", .obj())]); e["outcome"] = .string(childResult); e["conclusion"] = .string(conclusion); scope[id] = .object(e) }
            if conclusion == "failure" { status = "failure" }
        }
        if !childPosts.isEmpty {
            let postRec = logger.addStep(name: "Post \(rec.name)", refName: "post-\(p.step.id)")
            let holder = PendingStep(record: postRec, step: p.step, stage: .post, action: action, stateKey: p.stateKey)
            compositePosts[ObjectIdentifier(holder)] = childPosts.map { ($0.0, $0.1, scope) }
            postSteps.append(holder)
        }
        // Outputs.
        do {
            let ctx = context(scope: scope, stepEnv: stepEnv, inputs: inputsObj, actionStatus: status)
            for (name, valueTok) in action.manifest.outputs {
                if let v = try? TemplateEvaluator.evaluateString(valueTok, context: ctx) { outputs?[name] = .string(v) }
            }
        }
        return status == "success"
    }

    private var compositePosts: [ObjectIdentifier: [(PendingStep, PreparedAction, ExprValue.ExprObject)]] = [:]

    // MARK: - Environment

    func basePath() -> String {
        var base = message.variable("PATH") ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var extras = config.extraPath
        for candidate in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"] where FileManager.default.fileExists(atPath: candidate) && !base.contains(candidate) {
            extras.append(candidate)
        }
        for e in extras.reversed() where !base.split(separator: ":").contains(Substring(e)) { base = e + ":" + base }
        return base
    }

    private static let githubEnvAllowlist: Set<String> = [
        "action_path", "action_ref", "action_repository", "action", "actor", "actor_id", "api_url", "artifacts", "artifacts_list", "base_ref",
        "env", "event_name", "event_path", "graphql_url", "head_ref", "job", "output", "path", "ref_name", "ref_protected", "ref_type", "ref",
        "repository", "repository_id", "repository_owner", "repository_owner_id", "retention_days", "run_attempt", "run_id", "run_number",
        "server_url", "sha", "state", "step_summary", "triggering_actor", "workflow", "workflow_ref", "workflow_sha", "workspace",
    ]

    func processEnvironment(stepEnv: [(String, String)], stateKey: String, forNode: Bool) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["NODE_ICU_DATA", "RUNSKI_HOME", "XPC_SERVICE_NAME"] { env.removeValue(forKey: k) }
        if config.exposeLocalSecrets { for (k, v) in localSecrets { env[k] = v } }
        for (k, v) in globalEnv { env[k] = v }
        for (k, v) in stepEnv { env[k] = v }
        for (k, v) in actionState[stateKey] ?? [:] { env["STATE_" + k] = v }
        var path = basePath()
        if let p = stepEnv.first(where: { $0.0 == "PATH" })?.1 { path = p }
        if !prependPath.isEmpty { path = prependPath.reversed().joined(separator: ":") + ":" + path }
        env["PATH"] = path
        for p in github.pairs where JobRunner.githubEnvAllowlist.contains(p.key.lowercased()) {
            switch p.value {
            case .string, .bool: env["GITHUB_" + p.key.uppercased()] = p.value.asString
            default: break
            }
        }
        for p in runnerCtx.pairs { env["RUNNER_" + p.key.uppercased()] = p.value.asString }
        env["GITHUB_ACTIONS"] = "true"
        if env["CI"] == nil { env["CI"] = "true" }
        if let sc = message.systemConnection {
            let token = sc.authorization?.parameters?["AccessToken"]
            if forNode {
                env["ACTIONS_RUNTIME_URL"] = sc.data?["PipelinesServiceUrl"] ?? sc.url
                if let token { env["ACTIONS_RUNTIME_TOKEN"] = token }
                if let cache = sc.data?["CacheServerUrl"] { env["ACTIONS_CACHE_URL"] = cache }
                if let results = sc.data?["ResultsServiceUrl"] { env["ACTIONS_RESULTS_URL"] = results }
            }
            if let idUrl = sc.data?["GenerateIdTokenUrl"], let token {
                env["ACTIONS_ID_TOKEN_REQUEST_URL"] = idUrl
                env["ACTIONS_ID_TOKEN_REQUEST_TOKEN"] = token
            }
        }
        if let orch = message.variable("system.orchestrationId") { env["ACTIONS_ORCHESTRATION_ID"] = orch }
        return env
    }

    // MARK: - Workflow commands

    final class CommandHandler {
        unowned let runner: JobRunner
        let rec: StepRecord
        let outputs: ExprValue.ExprObject?
        let stateKey: String
        var stopToken: String?

        init(runner: JobRunner, rec: StepRecord, outputs: ExprValue.ExprObject?, stateKey: String) {
            self.runner = runner; self.rec = rec; self.outputs = outputs; self.stateKey = stateKey
        }

        func handle(_ line: String, isStderr: Bool) {
            if let token = stopToken {
                if line.trimmingCharacters(in: .whitespaces) == "::\(token)::" { stopToken = nil; return }
                runner.logger.write(rec, line); return
            }
            guard line.contains("::"), let cmd = ActionCommand.parse(line) else {
                runner.logger.write(rec, line); return
            }
            let logger = runner.logger
            if runner.echoCommands, !["add-mask", "debug", "warning", "error", "notice"].contains(cmd.name) { logger.write(rec, line) }
            switch cmd.name {
            case "set-output":
                guard let n = cmd.properties["name"] else { return }
                outputs?[n] = .string(cmd.data)
                logger.debug(rec, "set-output \(n)")
            case "save-state":
                guard let n = cmd.properties["name"] else { return }
                runner.lock.withLock { runner.actionState[stateKey, default: [:]][n] = cmd.data }
            case "add-mask":
                runner.masker.add(cmd.data)
                logger.write(rec, "::add-mask::***")
            case "set-env", "add-path":
                let allowed = ProcessInfo.processInfo.environment["ACTIONS_ALLOW_UNSECURE_COMMANDS"]?.lowercased() == "true"
                    || runner.globalEnv.contains { $0.0 == "ACTIONS_ALLOW_UNSECURE_COMMANDS" && $0.1.lowercased() == "true" }
                guard allowed else {
                    logger.error(rec, "Unable to process command '\(line)' successfully.")
                    logger.error(rec, "The `\(cmd.name)` command is disabled. Please upgrade to using Environment Files or opt into unsecure command execution by setting the `ACTIONS_ALLOW_UNSECURE_COMMANDS` environment variable to `true`.")
                    runner.commandFailed = true
                    return
                }
                if cmd.name == "set-env", let n = cmd.properties["name"] { runner.setGlobalEnv(n, cmd.data) }
                if cmd.name == "add-path" { runner.addPath(cmd.data) }
            case "debug":
                if runner.stepDebug { logger.debug(rec, cmd.data) }
            case "warning", "error", "notice":
                var data = cmd.properties
                if let f = data["file"], !f.hasPrefix("/") { data["file"] = f }
                logger.write(rec, "##[\(cmd.name)]\(cmd.data)")
                logger.addIssue(rec, type: cmd.name, message: cmd.data, data: data)
            case "group": logger.write(rec, "##[group]\(cmd.data)")
            case "endgroup": logger.write(rec, "##[endgroup]")
            case "echo":
                switch cmd.data.lowercased() {
                case "on": runner.echoCommands = true
                case "off": runner.echoCommands = false
                default: logger.error(rec, "Invalid echo command value. Possible values can be: 'on', 'off'.")
                }
            case "stop-commands":
                guard !cmd.data.isEmpty else { logger.error(rec, "Invalid stop-commands token"); return }
                stopToken = cmd.data
                if cmd.data.count > 6 { runner.masker.add(cmd.data) }
            case "add-matcher", "remove-matcher":
                logger.debug(rec, "\(cmd.name) is accepted but problem matchers are not applied by runski")
            default:
                logger.write(rec, line)
            }
        }
    }

    var commandFailed = false

    func addPath(_ p: String) {
        prependPath.removeAll { $0 == p }
        prependPath.append(p)
    }

    // MARK: - File commands

    struct FileCommands {
        let env, path, output, state, summary: String
        init(dir: String) {
            let suffix = UUID().uuidString.lowercased()
            env = dir + "/set_env_" + suffix; path = dir + "/add_path_" + suffix; output = dir + "/set_output_" + suffix
            state = dir + "/save_state_" + suffix; summary = dir + "/step_summary_" + suffix
            for f in [env, path, output, state, summary] { FileManager.default.createFile(atPath: f, contents: nil) }
        }
        func cleanup() { for f in [env, path, output, state, summary] { try? FileManager.default.removeItem(atPath: f) } }
    }

    /// Returns false if a file command was malformed (fails the step).
    private func processFileCommands(_ f: FileCommands, rec: StepRecord, outputs: ExprValue.ExprObject?, stateKey: String) -> Bool {
        var ok = !commandFailed
        commandFailed = false
        func read(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
        do {
            for (k, v) in try EnvFile.parse(read(f.env)) {
                if k.uppercased() == "NODE_OPTIONS" {
                    logger.error(rec, "Can't store NODE_OPTIONS output parameter using '$GITHUB_ENV' command."); ok = false; continue
                }
                setGlobalEnv(k, v)
            }
        } catch { logger.error(rec, "Unable to process file command 'env' successfully. \(error)"); ok = false }
        do {
            for (k, v) in try EnvFile.parse(read(f.output)) { outputs?[k] = .string(v) }
        } catch { logger.error(rec, "Unable to process file command 'output' successfully. \(error)"); ok = false }
        do {
            for (k, v) in try EnvFile.parse(read(f.state)) { lock.withLock { actionState[stateKey, default: [:]][k] = v } }
        } catch { logger.error(rec, "Unable to process file command 'state' successfully. \(error)"); ok = false }
        for line in read(f.path).split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty { addPath(String(line)) }
        if let data = FileManager.default.contents(atPath: f.summary), !data.isEmpty {
            if data.count > 1024 * 1024 {
                logger.error(rec, "$GITHUB_STEP_SUMMARY upload aborted, supports content up to a size of 1024k, got \(data.count / 1024)k."); ok = false
            } else {
                let masked = Data(String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map { masker.mask(String($0)) }.joined(separator: "\n").utf8)
                let r = rec
                Task { await logger.uploadStepSummary(r, markdown: masked) }
            }
        }
        return ok
    }

    // MARK: - Outputs / cleanup

    private func evaluateJobOutputs(_ rec: StepRecord) -> [String: VariableValue] {
        var out: [String: VariableValue] = [:]
        guard let tok = message.jobOutputs else { return out }
        do {
            let ctx = context(scope: nil, stepEnv: [])
            for (k, v) in try TemplateEvaluator.evaluateStringMap(tok, context: ctx) where !v.isEmpty {
                if masker.mask(v) != v { logger.warning(rec, "Skip output '\(k)' since it may contain secret."); continue }
                out[k] = VariableValue(value: v)
                logger.write(rec, "Set output '\(k)'")
            }
        } catch {
            logger.error(rec, "Failed to evaluate job outputs: \(error)")
        }
        return out
    }

    private func cleanTemp() {
        try? FileManager.default.removeItem(atPath: tempDir)
    }
}

enum ExprValueBridge {
    static func foundation(_ v: ExprValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int64(n) : n
        case .string(let s): return s
        case .array(let a): return a.items.map(foundation)
        case .object(let o):
            var d: [String: Any] = [:]
            for p in o.pairs { d[p.key] = foundation(p.value) }
            return d
        }
    }
}
