# runski design

**Problem.** GitHub Actions bills by the minute, and macOS minutes cost 10× Linux
minutes. Teams with idle Macs on desks pay for compute they already own.

**Solution.** `runski` turns any Mac into a GitHub Actions runner. It speaks
GitHub's own runner protocol natively, so nothing about the workflow changes
except `runs-on`. It is a single Swift binary with no .NET or Node dependency for
`run:` steps, keeps its credentials behind the Secure Enclave, and runs as a
launchd agent that survives crashes and reboots.

## The three questions

### 1. How does GitHub dispatch a job to us?

We do not build a CI system; we plug into the one GitHub already has. GitHub has a
first-class notion of a **self-hosted runner**, and self-hosted minutes are free
on every plan. A runner is a client that:

1. **Registers once.** `POST api.github.com/actions/runner-registration` with a
   registration token returns a tenant URL and a short-lived bearer. With that we
   create a `TaskAgent` (name, labels, an RSA-2048 public key) either on the
   pipelines tenant (`POST …/pools/{id}/agents`) or, for new tenants, through the
   "runner admin" flow (`POST api.github.com/actions/runners/register`). GitHub
   returns an OAuth `clientId` + `authorizationUrl`.
2. **Authenticates continuously.** Every access token is minted by signing a JWT
   (PS256, `iss=sub=clientId`, `aud=authorizationUrl`, 5 min) with the private
   key and POSTing it to the token endpoint as a `client_credentials` grant.
3. **Long-polls a queue.** It creates a session (`POST …/sessions` or
   `POST {broker}/session`) and then loops on `GET …/messages?sessionId=…&status=Online`
   (50 s server hold). On github.com today the tenant answers with
   `BrokerMigration` and the runner follows it to the broker service, whose
   `RunnerJobRequest` message points at a **run service**. The runner then
   `POST {run_service}/acquirejob`, receives the full `AgentJobRequestMessage`
   (steps as `TemplateToken` trees, contexts as `PipelineContextData`, secrets as
   masked variables, endpoints for logs/results), renews the lock every 60 s, and
   finally `POST completejob` with the conclusion, outputs, per-step results and
   annotations. Legacy tenants use the pipelines timeline/log APIs and a
   `JobCompleted` plan event instead; runski implements both.
4. **Streams logs.** Step status goes to the results service
   (`WorkflowStepsUpdate`), step and job logs are uploaded as blobs to signed
   URLs, and the live console is fed over the `FeedStreamUrl` websocket, so the
   Actions UI looks identical to a hosted job.

Because GitHub evaluates the workflow file server-side (triggers, `needs`,
matrix expansion, job-level `if`, concurrency groups, `runs-on` label matching),
runski only has to implement **job execution** faithfully. Porting means changing
one line:

```yaml
runs-on: [self-hosted, runski]        # was: macos-latest
```

The companion action `looskis/pick-runner` (in `actions/pick-runner`) makes this
safe: it checks whether a runner with your labels is online and emits either your
labels or a hosted fallback, so jobs never queue forever while every Mac is asleep.

### 2. How is concurrency managed?

* **GitHub's queue does the scheduling.** One registered runner executes one job
  at a time; GitHub assigns a queued job to the first idle runner whose labels
  match. `concurrency:` groups, `max-parallel`, and `needs:` are enforced
  server-side exactly as for hosted runners.
* **Slots.** `runski register --slots N` registers `name`, `name-2`, … as separate
  runners. The daemon polls all of them concurrently and can run N jobs in
  parallel, each in its own work directory (`~/.runski/_work/<slot>/`). Pick N by
  CPU/RAM; Xcode builds usually want N=1–2 on a laptop, more on a Mac Studio.
* **Fleet.** Register several Macs into the same repo/org (optionally in a runner
  group). GitHub spreads jobs across whichever are online.
* **Idle gating (optional).** `runski config --idle-seconds 600` makes a slot go
  offline (drop its session) while someone is typing on the Mac and come back after
  10 minutes of no input. Combined with `pick-runner`, jobs fall back to hosted
  runners instead of waiting. Running jobs are never interrupted by user activity.
* **Sleep.** While a job runs, runski holds an `IOPMAssertion` so the Mac does not
  idle-sleep mid-build.
* **Cancellation.** A `JobCancellation` message (from the UI or `concurrency:
  cancel-in-progress`) terminates the current step's whole process tree (SIGINT →
  SIGTERM → SIGKILL), marks the job `canceled`, and still runs `always()` steps.

### 3. What about dependencies?

Three different things hide behind "dependencies":

* **Job dependencies (`needs:`)** — GitHub's orchestration, unchanged. Outputs
  flow through `needs.<job>.outputs` because runski reports job outputs at
  completion.
* **Actions (`uses:`)** — resolved through GitHub's launch service (or the legacy
  action-download endpoint, or a plain tarball URL with the job token), extracted
  into a content-addressed cache at `~/.runski/_actions/<owner>/<repo>/<ref>` keyed
  by resolved SHA, so a second job with the same `actions/checkout@v4` costs
  nothing. JavaScript actions run on Node 20/24; runski uses `node` from `PATH` if
  its major version is compatible and otherwise downloads the official build once
  into `~/.runski/externals`. Composite actions are executed natively (nested
  `uses:`/`run:`, inputs, outputs, `if:`). Docker actions and container jobs are
  not supported — GitHub's own macOS runners cannot run them either.
* **Toolchains (Xcode, Node, Python, Ruby, Go, Rust)** — whatever is installed on
  the Mac is on `PATH` (Homebrew paths are added automatically). `actions/setup-*`
  actions work as on any self-hosted runner: they populate `RUNNER_TOOL_CACHE`
  (`~/.runski/_tool`) on first use and hit the cache afterwards.

## Requirements → implementation

| requirement | how |
|---|---|
| Compatible syntax | Same job message and semantics as `actions/runner` 2.337: expression language (`Sources/RunskiCore/Expressions`), `TemplateToken`/`ContextData` codecs, `if:` normalisation, `continue-on-error`, `timeout-minutes`, `steps.*.outputs/outcome/conclusion`, `env`/`GITHUB_*`/`RUNNER_*` allowlists, workflow commands (`::set-output`, `::add-mask`, `::group`, `::warning file=…`), file commands (`GITHUB_OUTPUT/ENV/PATH/STATE/STEP_SUMMARY` incl. heredocs), `hashFiles()` (native, no Node), shells `bash/sh/zsh/python/pwsh` + custom `{0}` formats, pre/main/post ordering. |
| Marketplace action | `actions/pick-runner` — online/busy-aware `runs-on` selection with hosted fallback. |
| Secure Enclave secrets | `Vault`: one P-256 key that never leaves the Secure Enclave wraps everything at rest (ECDH → HKDF → AES-GCM). The runner's RSA credential and `runski secrets` values are sealed blobs that only this chip can open. Local secrets are injected into steps as env vars and are never uploaded to GitHub. Software fallback (with a warning) on Macs without an enclave. |
| Push out build logs | Live console feed (websocket), step/job logs to GitHub, a local file per job under `~/.runski/logs/jobs`, and an optional HTTP sink (`runski config --log-sink URL --log-sink-header 'Authorization: …'`) receiving batched JSON lines. |
| Lightweight and performant | One ~5 MB native binary, no CLR, ~10 MB RSS while idle, one HTTPS long-poll per slot. Actions cached by SHA. `ProcessType: Standard` in launchd so builds are not throttled onto efficiency cores. |
| Daemon that survives crashes | launchd LaunchAgent with `KeepAlive` (restarts on crash, 10 s throttle), `RunAtLoad`, log files under `~/.runski/logs`. On restart the runner re-creates its session; GitHub re-queues a job whose lock stopped being renewed. |

## Security notes

* Registration tokens and PATs are used once and never stored.
* The only persistent secret is the RSA private key, sealed by the enclave.
* Job secrets arrive per job inside the encrypted message and live only in memory.
* Every secret (and its base64/JSON/URL-encoded forms) is masked in every log sink.
* Self-hosted runners execute whatever the workflow says. Only use runski for
  private repositories or repositories where you control who can open PRs, exactly
  as GitHub's own guidance for self-hosted runners.

## Layout

```
Sources/RunskiCore/
  Crypto/       RSA (Security.framework), AES-CBC (CommonCrypto), JWT
  Vault/        Secure Enclave vault + local secret store
  Protocol/     models, TemplateToken/ContextData codecs, VSS client + location
                service, OAuth, registration, message listener (pipelines + broker),
                run service, results service, legacy job server
  Expressions/  lexer, parser, evaluator, template evaluation
  Worker/       job runner, action manager/manifests, node provider, job logger
                (GitHub/live feed/local/HTTP), process runner, glob/hashFiles,
                secret masker, workflow + file commands
  Daemon/       slot loop + job dispatch, launchd, idle/power
Sources/runski/ CLI
actions/pick-runner/  companion marketplace action
Tests/          expression, codec, crypto, vault, glob and end-to-end job tests
```
