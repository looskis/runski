import XCTest
@testable import RunskiCore

/// End-to-end execution of a synthetic job message with no network: exercises the
/// contexts, `if:` evaluation, run steps, workflow/file commands, continue-on-error,
/// masking and job outputs.
final class JobRunnerTests: XCTestCase {
    func makeEnv() throws -> (Paths, RunnerRecord, RunskiConfig, Logger) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("runski-test-\(UUID().uuidString)")
        let paths = Paths(home: home)
        try paths.ensure()
        let record = RunnerRecord(name: "test-runner", githubUrl: "https://github.com/acme/app", agentId: 1, poolId: 1, poolName: nil,
                                  serverUrl: "https://pipelines.invalid/", serverUrlV2: nil, useV2Flow: false, useRunnerAdminFlow: false,
                                  labels: ["self-hosted", "macOS"], ephemeral: false, registeredAt: Date(), runnerVersion: "2.337.0")
        var cfg = RunskiConfig()
        cfg.preventSleepDuringJobs = false
        cfg.cancelGraceSeconds = 1
        return (paths, record, cfg, Logger(level: .debug))
    }

    func script(_ id: String, _ text: String, condition: String? = nil, coe: Bool = false, env: [(String, String)] = [], name: String? = nil) -> ActionStep {
        return ActionStep(type: "action", id: UUID().uuidString.lowercased(), name: id,
                          reference: ActionStep.Reference(type: "script", name: nil, ref: nil, repositoryType: nil, path: nil, image: nil),
                          displayNameToken: .string(name ?? id), displayName: nil, contextName: id, condition: condition,
                          continueOnError: coe ? .boolean(true) : nil, timeoutInMinutes: nil,
                          inputs: .mapping([(key: .string("script"), value: try! TemplateScalar.parse(text).token)]),
                          environment: env.isEmpty ? nil : .mapping(env.map { (key: .string($0.0), value: try! TemplateScalar.parse($0.1).token) }))
    }

    func message(steps: [ActionStep], outputs: TemplateToken? = nil) -> AgentJobRequestMessage {
        let github = ContextData.dict([
            ("repository", .string("acme/app")), ("ref", .string("refs/heads/main")), ("sha", .string("abc123")),
            ("event_name", .string("push")), ("run_id", .string("42")), ("actor", .string("octocat")),
            ("event", .dict([("head_commit", .dict([("message", .string("hello"))]))])),
        ])
        return AgentJobRequestMessage(messageType: "PipelineAgentJobRequest",
                                      plan: .init(scopeIdentifier: "00000000-0000-0000-0000-000000000000", planId: "plan", planType: "actions", version: 12, artifactUri: nil),
                                      timeline: .init(id: "tl", changeId: nil), jobId: "job-1", jobDisplayName: "build", jobName: "build",
                                      jobContainer: nil, jobServiceContainers: nil, jobOutputs: outputs, requestId: 7, lockedUntil: nil,
                                      resources: nil, contextData: ["github": github, "matrix": .dict([("os", .string("macos"))]), "vars": .dict([("GREETING", .string("hi"))])],
                                      workspace: nil, maskHints: nil,
                                      environmentVariables: [.mapping([(key: .string("JOB_ENV"), value: .string("from-job")), (key: .string("FROM_EXPR"), value: .expression("matrix.os"))])],
                                      defaults: nil, actionsEnvironment: nil,
                                      variables: ["system.github.token": VariableValue(value: "ghs_secret_token_value", isSecret: true),
                                                  "MY_SECRET": VariableValue(value: "hunter2", isSecret: true)],
                                      steps: steps, fileTable: nil, billingOwnerId: nil, snapshot: nil)
    }

    func testEndToEndScriptJob() async throws {
        let (paths, record, cfg, log) = try makeEnv()
        let steps = [
            script("first", "echo hello from $JOB_ENV and $FROM_EXPR\necho \"out1=v1\" >> \"$GITHUB_OUTPUT\"\necho \"NEWVAR=set-by-first\" >> \"$GITHUB_ENV\"\necho \"/custom/bin\" >> \"$GITHUB_PATH\"\necho '::add-mask::dynamic-secret'\necho 'ML<<EOF' >> \"$GITHUB_OUTPUT\"\necho 'line1' >> \"$GITHUB_OUTPUT\"\necho 'line2' >> \"$GITHUB_OUTPUT\"\necho 'EOF' >> \"$GITHUB_OUTPUT\"",
                   condition: "success() && (github.event_name == 'push')"),
            script("second", "echo NEWVAR=$NEWVAR\necho PATH=$PATH\necho out1=${{ steps.first.outputs.out1 }}\necho ML=\"${{ steps.first.outputs.ML }}\"\necho token=${{ github.token }} secret=$MY_SECRET dyn=dynamic-secret\necho '::warning file=a.txt,line=3::careful'\necho '::set-output name=legacy::works'\ntest \"$GITHUB_REPOSITORY\" = acme/app\ntest \"$RUNNER_OS\" = macOS\ntest \"$CI\" = true\ntest \"$GITHUB_ACTIONS\" = true",
                   env: [("MY_SECRET", "${{ secrets.MY_SECRET }}")]),
            script("skipped", "echo never", condition: "success() && (github.event_name == 'pull_request')"),
            script("fails", "echo about to fail\nexit 3", coe: true),
            script("after-coe", "echo outcome=${{ steps.fails.outcome }} conclusion=${{ steps.fails.conclusion }} job=${{ job.status }}\ntest \"${{ steps.fails.outcome }}\" = failure"),
            script("hard-fail", "exit 1"),
            script("not-run", "echo should not run"),
            script("cleanup", "echo cleanup runs on failure: ${{ job.status }}", condition: "always()"),
            script("only-on-failure", "echo failure branch", condition: "failure()"),
        ]
        let outputs: TemplateToken = .mapping([(key: .string("o1"), value: .expression("steps.first.outputs.out1")),
                                               (key: .string("legacy"), value: .expression("steps.second.outputs.legacy")),
                                               (key: .string("leak"), value: .expression("secrets.MY_SECRET"))])
        let runner = JobRunner(message: message(steps: steps, outputs: outputs), record: record, paths: paths, config: cfg, http: HTTPClient(),
                               log: log, localSecrets: ["LOCAL_ONE": "local-value"])
        let outcome = await runner.run()

        XCTAssertEqual(outcome.result, "failed")
        XCTAssertEqual(outcome.outputs["o1"]?.value, "v1")
        XCTAssertEqual(outcome.outputs["legacy"]?.value, "works")
        XCTAssertNil(outcome.outputs["leak"], "secret-valued outputs must be dropped")

        let byName = Dictionary(uniqueKeysWithValues: outcome.stepResults.map { ($0.name, $0) })
        XCTAssertEqual(byName["first"]?.conclusion, "succeeded")
        XCTAssertEqual(byName["second"]?.conclusion, "succeeded")
        XCTAssertEqual(byName["skipped"]?.conclusion, "skipped")
        XCTAssertEqual(byName["fails"]?.conclusion, "succeeded", "continue-on-error turns failure into success")
        XCTAssertEqual(byName["after-coe"]?.conclusion, "succeeded")
        XCTAssertEqual(byName["hard-fail"]?.conclusion, "failed")
        XCTAssertEqual(byName["not-run"]?.conclusion, "skipped")
        XCTAssertEqual(byName["cleanup"]?.conclusion, "succeeded")
        XCTAssertEqual(byName["only-on-failure"]?.conclusion, "succeeded")
        XCTAssertEqual(byName["second"]?.annotations?.first?.message, "careful")
        XCTAssertEqual(byName["second"]?.annotations?.first?.path, "a.txt")
        XCTAssertEqual(byName["second"]?.annotations?.first?.startLine, 3)
        XCTAssertEqual(byName["hard-fail"]?.annotations?.first?.message, "Process completed with exit code 1.")

        let logText = try String(contentsOf: runner.logger.localFileURL!, encoding: .utf8)
        XCTAssertTrue(logText.contains("hello from from-job and macos"))
        XCTAssertTrue(logText.contains("NEWVAR=set-by-first"))
        XCTAssertTrue(logText.contains("PATH=/custom/bin:"))
        XCTAssertTrue(logText.contains("out1=v1"))
        XCTAssertTrue(logText.contains("ML=\"line1\nline2\"") || logText.contains("ML=\"line1"))
        XCTAssertTrue(logText.contains("token=*** secret=*** dyn=***"), "secrets must be masked: \(logText)")
        XCTAssertFalse(logText.contains("hunter2"))
        XCTAssertFalse(logText.contains("ghs_secret_token_value"))
        XCTAssertTrue(logText.contains("outcome=failure conclusion=success job=success"))
        XCTAssertTrue(logText.contains("cleanup runs on failure: failure"))
        XCTAssertTrue(logText.contains("failure branch"))
        XCTAssertFalse(logText.contains("should not run"))
        XCTAssertTrue(logText.contains("##[warning]careful"))
        XCTAssertTrue(logText.contains("Local runski secrets available to steps: LOCAL_ONE"))
        try? FileManager.default.removeItem(at: paths.home)
    }

    func testLocalCompositeAndHashFiles() async throws {
        let (paths, record, cfg, log) = try makeEnv()
        // Lay out a workspace with a local composite action.
        let ws = paths.workDir.appendingPathComponent("test-runner/app/app")
        try FileManager.default.createDirectory(at: ws.appendingPathComponent(".github/actions/greet"), withIntermediateDirectories: true)
        try """
        name: greet
        inputs:
          who:
            default: world
          shout:
            required: false
        outputs:
          greeting:
            value: ${{ steps.g.outputs.text }}
        runs:
          using: composite
          steps:
            - id: g
              shell: bash
              run: |
                echo "text=hello ${{ inputs.who }}" >> "$GITHUB_OUTPUT"
                echo "action_path=$GITHUB_ACTION_PATH"
            - if: ${{ inputs.shout == 'yes' }}
              shell: bash
              run: echo SHOUTING
            - shell: bash
              run: echo "lock=${{ hashFiles('**/lock.txt') }}"
        """.write(to: ws.appendingPathComponent(".github/actions/greet/action.yml"), atomically: true, encoding: .utf8)
        try "abc".write(to: ws.appendingPathComponent("lock.txt"), atomically: true, encoding: .utf8)

        let uses = ActionStep(type: "action", id: "u1", name: "greet", reference: ActionStep.Reference(type: "repository", name: nil, ref: nil, repositoryType: "self", path: "./.github/actions/greet", image: nil),
                              displayNameToken: nil, displayName: nil, contextName: "greet", condition: "success()", continueOnError: nil, timeoutInMinutes: nil,
                              inputs: .mapping([(key: .string("who"), value: .expression("github.actor")), (key: .string("shout"), value: .string("yes"))]), environment: nil)
        let check = script("check", "echo greeting=${{ steps.greet.outputs.greeting }}\ntest \"${{ steps.greet.outputs.greeting }}\" = 'hello octocat'")
        let msg = message(steps: [uses, check])
        var m = msg
        m.workspace = .init(clean: nil)
        let runner = JobRunner(message: m, record: record, paths: paths, config: cfg, http: HTTPClient(), log: log, localSecrets: [:])
        let outcome = await runner.run()
        let logText = try String(contentsOf: runner.logger.localFileURL!, encoding: .utf8)
        XCTAssertEqual(outcome.result, "succeeded", logText)
        XCTAssertTrue(logText.contains("greeting=hello octocat"))
        XCTAssertTrue(logText.contains("SHOUTING"))
        XCTAssertTrue(logText.contains("action_path=\(ws.path)/./.github/actions/greet"))
        XCTAssertTrue(logText.range(of: "lock=[0-9a-f]{64}", options: .regularExpression) != nil, logText)
        try? FileManager.default.removeItem(at: paths.home)
    }

    func testCancellation() async throws {
        let (paths, record, cfg, log) = try makeEnv()
        let steps = [script("sleepy", "sleep 30"), script("after", "echo after"), script("always", "echo always ${{ job.status }}", condition: "always()")]
        let runner = JobRunner(message: message(steps: steps), record: record, paths: paths, config: cfg, http: HTTPClient(), log: log, localSecrets: [:])
        let t = Task { await runner.run() }
        try await Task.sleep(for: .seconds(1.5))
        runner.cancel()
        let outcome = await t.value
        let logText = try String(contentsOf: runner.logger.localFileURL!, encoding: .utf8)
        XCTAssertEqual(outcome.result, "canceled", logText)
        let byName = Dictionary(uniqueKeysWithValues: outcome.stepResults.map { ($0.name, $0) })
        XCTAssertEqual(byName["sleepy"]?.conclusion, "canceled")
        XCTAssertEqual(byName["after"]?.conclusion, "skipped")
        XCTAssertEqual(byName["always"]?.conclusion, "succeeded")
        XCTAssertTrue(logText.contains("always cancelled"), logText)
        try? FileManager.default.removeItem(at: paths.home)
    }

    func testCommandAndEnvFileParsing() throws {
        let c = ActionCommand.parse("::error file=a%2Cb.txt,line=3::bad%0Athing%25")!
        XCTAssertEqual(c.name, "error")
        XCTAssertEqual(c.properties["file"], "a,b.txt")
        XCTAssertEqual(c.data, "bad\nthing%")
        XCTAssertNil(ActionCommand.parse("::unknown::x"))
        XCTAssertNil(ActionCommand.parse("plain text"))
        let kv = try EnvFile.parse("A=1\nB<<EOF\nx\ny\nEOF\nC=\n")
        XCTAssertEqual(kv.map(\.0), ["A", "B", "C"])
        XCTAssertEqual(kv[1].1, "x\ny")
        XCTAssertEqual(kv[2].1, "")
        XCTAssertThrowsError(try EnvFile.parse("B<<EOF\nx\n"))
        XCTAssertThrowsError(try EnvFile.parse("garbage"))
        XCTAssertEqual(JobRunner.splitArgs("-command \". 'a b.ps1'\""), ["-command", ". 'a b.ps1'"])
        XCTAssertEqual(JobRunner.splitArgs("--noprofile -e /tmp/x.sh"), ["--noprofile", "-e", "/tmp/x.sh"])
    }
}
