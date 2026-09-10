# runner-tier

Fail a job that asks for `ubuntu-latest` and needs nothing it provides over `ubuntu-slim`.
A cost gate, not a security gate: it is read entirely from the caller's workflow files, with
no network and no run history.

`ubuntu-slim` bills $0.002/min against `ubuntu-latest`'s $0.006, and GitHub rounds every job up
to a whole minute, so a gate finishing inside its first minute is a straight 3x. Slim is 1 CPU,
5 GB RAM, 14 GB disk, an unprivileged container, a minimal image, and a hard 15-minute kill.
The tier pays off up to 3x slower.

Callers reach this through `fleet-ci.yml`'s `runner-tier` and `runner-tier-exclude` inputs.
It is **opt-in**: a cost heuristic has no business failing a pull request nobody asked it to
judge. See the repo README for that table.

## What disqualifies a job

A job carrying any of these needs `ubuntu-latest` and is left alone.

| Disqualifier | Why slim cannot run it |
| --- | --- |
| `container:` or `services:` | slim is already a container and runs unprivileged |
| a `step-security/harden-runner` step | the egress monitor cannot load unprivileged; a job is slim OR hardened |
| docker: the literal in a step, a `docker://` action, or an in-tree `uses: ./x` (or `$/x`) whose `action.yml` is `runs.using: docker` | no Docker-in-Docker |
| an install-or-build command (`npm ci`, `uv sync`, `cargo build`, a `setup-*`, …) | 1 CPU and a minimal image is where the 3x goes away |
| a tool `ubuntu-latest` preinstalls and slim does not (`envsubst`, a browser, `ffmpeg`, `kubectl`, …) | the step fails on a missing binary |
| `timeout-minutes` absent, non-numeric, or above 15 | slim terminates the job at 15, so a larger cap is a ceiling the runner will not honor |
| a job-level `uses:` | a reusable-workflow call has no runner of its own; the tier lives in the callee |

The preinstalled-tool list is a **denylist of known gaps**, never slim's full software list, so
read every `run:` step and every action's own shell-outs before flipping a job. A `run:` calling
a repo script is opaque to this gate. Slim also sets no UTF-8 locale, which shifts `git grep -P`,
Python text I/O, and `sort` collation - reproduce that with `LC_ALL=C LANG=C` before the flip.

## Waivers

Two levels, and a caller can use either.

**Per job, inline.** A comment naming `ubuntu-slim` on the job's `runs-on` - a head comment
above the key, or a line comment on the key or its value. State the decision and the reason;
that comment is what the next reader sees.

```yaml
jobs:
  e2e:
    # Stays on ubuntu-slim's expensive sibling: playwright needs the preinstalled browsers.
    runs-on: ubuntu-latest
    timeout-minutes: 15
```

**Per pattern, by input.** `runner-tier-exclude` takes one glob per line, matched against the
job key. It is for a pattern spanning jobs whose YAML a caller does not own; prefer the comment
when the exception belongs to one job.

```yaml
with:
  runner-tier: true
  runner-tier-exclude: |
    e2e-*
```

Neither waiver may hide an invalid explicit value: a job whose `timeout-minutes` exceeds slim's
15-minute kill is already disqualified, so it never needs one.

## Local use

Run from the repository being checked:

```bash
bash /path/to/tools/runner-tier/scripts/check-runner-tier.sh
```

`RUNNER_TIER_FILES` and `RUNNER_TIER_EXCLUDE` are the environment equivalents of the two
inputs. Needs `yq` (mikefarah v4); exit 0 clean, 1 findings, 2 the scan could not run.

## Tests

`test/run.sh` writes each fixture workflow into a throwaway `mktemp -d` tree, so no fixture
lands in this repo's own `.github/workflows`. Cases cover a clean tree, a planted positive,
both waiver paths, and the in-tree docker action that is the reason this gate exists.
