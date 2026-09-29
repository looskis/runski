# looskis/pick-runner

A tiny composite action that decides *where* your job should run: on one of your
own Macs running [runski](../../README.md) when one is online, or on a GitHub-hosted
runner when none is. It costs a few seconds of `ubuntu-latest` time and removes
the biggest fear of self-hosted runners: a job stuck in "Queued" because every Mac
is asleep.

```yaml
jobs:
  where:
    runs-on: ubuntu-latest
    outputs:
      runs-on: ${{ steps.pick.outputs.runs-on }}
    steps:
      - id: pick
        uses: looskis/pick-runner@v1
        with:
          labels: runski,arm64        # labels your Macs were registered with
          fallback: macos-latest      # or '["macos-14"]'

  build:
    needs: where
    runs-on: ${{ fromJSON(needs.where.outputs.runs-on) }}
    steps:
      - uses: actions/checkout@v4
      - run: xcodebuild -scheme App test
```

| input | default | meaning |
|---|---|---|
| `labels` | `runski` | Labels (comma-separated) a runner must carry, besides `self-hosted`. |
| `fallback` | `macos-latest` | `runs-on` to use when no runner is online. A label or a JSON array. |
| `require-idle` | `false` | Only choose runners that are online **and not busy**. |
| `scope` | `repo` | `repo` or `org`, wherever your runners are registered. |
| `token` | `github.token` | Needs read access to runners (`administration: read` on the repo, or `organization_self_hosted_runners: read`). |

Outputs: `runs-on` (JSON array), `self-hosted` (`true`/`false`), `runner` (name).

Publishing: this directory is meant to live at the root of its own repository
(`looskis/pick-runner`) so it can be listed on the GitHub Marketplace; the `action.yml`
is self-contained.
