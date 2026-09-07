# fleet-actions

The fleet's CI surface as one reusable workflow. A repo calls `fleet-ci.yml` and passes
booleans instead of hand-writing a betterleaks job, a zizmor job, an actionlint job, and the
invariants that go with them.

## Call it

```yaml
name: ci

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  fleet:
    uses: notambourine/fleet-actions/.github/workflows/fleet-ci.yml@<sha> # v1.0
    with:
      tripwire: false
```

The example runs everything but `tripwire`, which is the last check still unabsorbed;
enabling it currently fails. Every tool defaults on, so pass `false` for each check you
need to skip.

Every tool runs as a step of one job, so this reports one check, `<calling job> / fleet`
(`fleet / fleet` above), no matter which subset a repo enables. That is the single name to
require in branch protection. A skipped step still reports; a skipped job never did.

## Resolve the pin

`v1` floats to the newest `v1.N` release. Resolve through it, but label with the immutable
tag it landed on.

```bash
sha=$(gh api repos/notambourine/fleet-actions/commits/v1 -q .sha)
tag=$(gh api repos/notambourine/fleet-actions/releases/latest -q .tag_name)
```

Write `@$sha # $tag`, so `@<sha> # v1.4`. Never write `@v1`, and never label a pin `# v1`.

The label has to be the immutable tag because zizmor's `ref-version-mismatch` audit
resolves the comment to a ref and compares it to the pinned commit. `# v1` is true only
for the instant the pin is current: the next release moves `v1`, and every consumer still
on the old commit starts failing the fleet's own zizmor gate at medium. `# v1.4` stays
true forever, and it is also what Dependabot rewrites the comment to, so the proposer and
the audit finally agree.

## Inputs

| Input | Default | Effect |
| --- | --- | --- |
| `betterleaks` | `true` | Secret scan, stock rules, `--confidence medium`, cosign-verified release. |
| `zizmor` | `true` | Workflow audit, medium severity and above. |
| `actionlint` | `true` | Workflow static check with ShellCheck and pyflakes. |
| `dashes` | `true` | Unicode dash ratchet on pull requests. |
| `tripwire` | `true` | Shai-Hulud worm fail-fast gate. |
| `wormhook` | `true` | npm supply-chain malware scan. |
| `pnpm-pin` | `true` | Assert `package.json` declares `packageManager`. |
| `scan-mode` | `git` | betterleaks subcommand. `git` fingerprints commits; `dir` scans the tree. |
| `fetch-depth` | `0` | Checkout depth for the one shared checkout. `scan-mode: git` requires `0`. |
| `betterleaks-version` | `latest` | Pin an exact betterleaks release when an upstream rule turns the fleet red. |
| `betterleaks-path` | `""` | Path to scan. Empty scans the workspace root. |
| `betterleaks-log-opts` | `""` | `git log` arguments narrowing a `git` scan. Beats `betterleaks-pr-range`. |
| `betterleaks-pr-range` | `false` | On `pull_request`, scan only the pull request's commits. |
| `dash-base-ref` | `""` | Base branch for the ratchet, without `origin/`. Empty resolves it from the event. |
| `dash-exclude` | `""` | Glob pathspecs added to the built-in hold-out list, one per line. |
| `dash-exclude-defaults` | `true` | Set `false` to gate the held-out paths like everything else. |
| `dash-force-zero` | `false` | Assert the tree carries no dash instead of ratcheting. |
| `actionlint-extra-labels` | `""` | Runner labels this repo uses beyond the fleet set, one per line. |
| `actionlint-config-extra` | `""` | Raw actionlint config YAML merged over the fleet config and the caller's own file. |

A caller's own `.github/actionlint.yaml` is merged in automatically, so migrating does not
drop its suppressions. Label lists union; the caller's file wins on conflicts, and
`actionlint-config-extra` wins over both.

## What the workflow owns

These stopped being prose each repo restates:

- One `ubuntu-latest` job, `timeout-minutes: 15`, every tool a step. One runner spin-up
  and one checkout instead of one per tool.
- Every gate step carries `!cancelled()`, so a failing tool never hides the tools after it.
- Workflow-level `contents: read`, no job-level permissions.
- One checkout at the caller's `fetch-depth` (default `0`), `persist-credentials: false`.
  Depth 0 is a superset of what betterleaks and the dash ratchet each need.
- Every action pinned `@<40-char-sha> # <tag>`, resolved from a release tag to its commit.
- `setup-uv` with a blank `cache-dependency-glob` and a weekly `cache-suffix` rotation.
- One concurrency group per calling repo, calling workflow, and ref, cancelling only on
  pull requests.

`ubuntu-slim` stays declared to actionlint because the caller's own workflows may target
it. It is no longer the runner tier here: two tools already forbade it (betterleaks needs
`envsubst` for cosign, `kjanat/actionlint` is a Docker action needing a daemon).

## Status

Everything runs except `tripwire`, which fails with a message naming the input to disable
until it is absorbed.

## Tools

| Directory | What it is |
| --- | --- |
| `tools/betterleaks` | Secret scan from a cosign-verified release, absorbed from `betterleaks-action`. Tested by named jobs in `self-test.yml`, not a `run.sh`. |
| `tools/dashes` | The unicode-dash ratchet, absorbed from `dash-ratchet`. `test/run.sh` runs ~40 cases twice, under the ambient locale and under `LC_ALL=C`. |
| `tools/pnpm-pin` | Asserts the root `package.json` pins an exact `packageManager`. |

`wormhook` stays an external pinned action. It ships a Claude Code plugin that
`notambourine/claude` consumes, so absorbing it would freeze its pattern updates.

`self-test.yml` discovers `tools/<name>/test/run.sh` and runs it when `tools/<name>/` changed,
so absorbing a tool drops in a directory and edits no workflow.
