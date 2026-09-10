# runner-tier

Suggest `ubuntu-slim` for clearly lightweight `ubuntu-latest` jobs in private repositories.
Suggestions are notices and never fail CI. The check reads workflow files offline.

Slim costs $0.002/minute versus $0.006/minute for the standard private-repository Linux runner.
Public repositories have no billed Linux runner savings, so the action stays silent there.

## Exclusions

The check excludes jobs with any of these conditions.

| Condition | Reason |
| --- | --- |
| `container:` or `services:` | slim is already a container and runs unprivileged |
| any action step, external script, or concurrent shell work | the workflow does not expose its resource needs |
| Docker | slim has no Docker-in-Docker |
| an install-or-build command (`npm ci`, `uv sync`, `cargo build`, a `setup-*`, …) | slim has 1 CPU and a minimal image |
| a tool `ubuntu-latest` preinstalls and slim does not (`envsubst`, a browser, `ffmpeg`, `kubectl`, …) | the step fails on a missing binary |
| `timeout-minutes` absent, non-numeric, or above 5 | the saving is not clear enough to recommend |
| a job-level `uses:` | reusable workflow calls have no runner |

The tool list covers known gaps, not all slim software. Silence means keep the standard runner.

## Suppressions

Pass job-key globs to `runner-tier-exclude`, one per line:

```yaml
with:
  runner-tier: true
  runner-tier-exclude: |
    e2e-*
```

## Local use

```bash
bash /path/to/tools/runner-tier/scripts/check-runner-tier.sh
```

`RUNNER_TIER_FILES` and `RUNNER_TIER_EXCLUDE` set the inputs. Local scans assume a private
repository; set `RUNNER_TIER_PRIVATE=false` to skip suggestions. Requires `yq` (mikefarah v4).
Exit codes: 0 no suggestions, 1 suggestions, 2 scan error. The action converts suggestions to a
successful notice; direct script callers can distinguish them.

## Tests

Run `test/run.sh`.
