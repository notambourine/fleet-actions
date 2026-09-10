# runner-tier

Find `ubuntu-latest` jobs that can use `ubuntu-slim`. The check reads workflow files offline.

`ubuntu-slim` costs $0.002/minute; `ubuntu-latest` costs $0.006/minute. Slim has 1 CPU, 5 GB RAM,
14 GB disk, an unprivileged container, a minimal image, and a 15-minute limit.

Enable it with the `runner-tier` input. It is disabled by default because it is a cost heuristic.

## Exclusions

The check excludes jobs with any of these conditions.

| Condition | Reason |
| --- | --- |
| `container:` or `services:` | slim is already a container and runs unprivileged |
| a `step-security/harden-runner` step | the egress monitor cannot load unprivileged |
| docker: the literal in a step, a `docker://` action, or an in-tree `uses: ./x` (or `$/x`) whose `action.yml` is `runs.using: docker` | no Docker-in-Docker |
| an install-or-build command (`npm ci`, `uv sync`, `cargo build`, a `setup-*`, …) | slim has 1 CPU and a minimal image |
| a tool `ubuntu-latest` preinstalls and slim does not (`envsubst`, a browser, `ffmpeg`, `kubectl`, …) | the step fails on a missing binary |
| `timeout-minutes` absent, non-numeric, or above 15 | slim terminates jobs at 15 minutes |
| a job-level `uses:` | reusable workflow calls have no runner |

The tool list covers known gaps, not all slim software. The check cannot inspect commands inside
repository scripts. Slim has no UTF-8 locale; test locale-sensitive jobs with `LC_ALL=C LANG=C`.

## Waivers

Add a comment containing `ubuntu-slim` above or on `runs-on`:

```yaml
jobs:
  e2e:
    # ubuntu-slim lacks Playwright browsers.
    runs-on: ubuntu-latest
    timeout-minutes: 15
```

For multiple jobs, pass job-key globs to `runner-tier-exclude`, one per line:

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

`RUNNER_TIER_FILES` and `RUNNER_TIER_EXCLUDE` set the inputs. Requires `yq` (mikefarah v4).
Exit codes: 0 clean, 1 findings, 2 scan error.

## Tests

Run `test/run.sh`.
