# runski

**Use the idle Macs you already own as GitHub Actions runners.** No changes to your
workflows beyond `runs-on`, no GitHub-hosted macOS minutes on the bill.

```
brew install ... (coming)        # or: swift build -c release
runski register --url https://github.com/acme/app --token AXXXXXXXXXXXX
runski daemon install            # starts at login, restarts on crash
```

```yaml
jobs:
  test:
    runs-on: [self-hosted, runski]     # ← the only change
    steps:
      - uses: actions/checkout@v4
      - run: xcodebuild -scheme App test
```

## What it is

`runski` is a native Swift reimplementation of the GitHub Actions runner for
macOS. It registers with GitHub exactly like `actions/runner`, long-polls GitHub's
job queue, executes the job with the same semantics (expressions, contexts,
`if:`, `continue-on-error`, workflow commands, `GITHUB_OUTPUT`/`GITHUB_ENV`,
composite and JavaScript actions, pre/post steps) and streams logs back so the
Actions UI is indistinguishable from a hosted run.

Compared with the official runner it is:

* **one 5 MB binary**, no .NET runtime; `run:` steps need nothing but a shell;
* **Secure Enclave–backed**: the runner credential and any local secrets are
  sealed with a key that never leaves the chip (`runski secrets set …`);
* **a proper daemon**: launchd `KeepAlive`, restarts on crash, survives reboots,
  keeps the Mac awake during jobs, optionally goes offline while you are typing;
* **fleet-friendly** with the `looskis/pick-runner` action that falls back to
  hosted runners when no Mac is online.

See [docs/DESIGN.md](docs/DESIGN.md) for how dispatch, concurrency and
dependencies work.

## Install

Requires macOS 14+ and Xcode command line tools to build.

```bash
git clone https://github.com/looskis/runski && cd runski
swift build -c release
sudo cp .build/release/runski /usr/local/bin/
```

## Register

Get a registration token from **Settings → Actions → Runners → New self-hosted
runner** (repository, organization or enterprise), or let runski mint one from a
PAT with `--pat`.

```bash
runski register --url https://github.com/acme/app --token AXXXX \
  --labels xcode16,arm64 --slots 2
```

`--slots 2` registers `my-mac` and `my-mac-2` so two jobs can run at once.

## Run

```bash
runski run                 # foreground
runski daemon install      # LaunchAgent: starts at login, restarts if it crashes
runski status
runski logs
```

## Local secrets (never leave the Mac)

```bash
echo -n "hunter2" | runski secrets set SIGNING_PASSWORD
```

Every job then sees `$SIGNING_PASSWORD` in its environment, masked in all logs.
The value is sealed with the Secure Enclave and cannot be copied to another
machine.

## Only when idle

```bash
runski config --idle-seconds 600
```

The runner drops offline while someone is using the Mac and comes back after ten
minutes of no keyboard/mouse input. Jobs already running are never interrupted.
Pair it with `looskis/pick-runner` so queued jobs fall back to hosted runners.

## Ship logs elsewhere

```bash
runski config --log-sink https://logs.example.com/ingest \
  --log-sink-header 'Authorization: Bearer …'
```

Every job also writes a local file under `~/.runski/logs/jobs/`.

## Limitations

* Docker container actions, `container:` jobs and `services:` are not supported
  (GitHub's own macOS runners cannot run them either).
* Problem matchers (`::add-matcher`) are accepted but not applied.
* Self-hosted runners execute untrusted code from workflows: use them for private
  repositories, as GitHub recommends.

## Development

```bash
swift test
```

Protocol details were taken from `actions/runner` v2.337.0 and the Go
reimplementation `github-act-runner`; see `docs/DESIGN.md`.
