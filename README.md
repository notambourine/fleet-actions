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
    uses: notambourine/fleet-actions/.github/workflows/fleet-ci.yml@<sha> # v1
    with:
      betterleaks: false
      dashes: false
      tripwire: false
      wormhook: false
      pnpm-pin: false
```

The example runs zizmor and actionlint. Keep existing jobs for the five unfinished
checks; enabling those inputs currently fails. Every tool defaults on, so pass
`false` for each check you need to skip.

## Resolve the pin

`v1` floats to the newest `v1.N` release. Resolve it to a commit and label it with the tag
you resolved from, which is what Dependabot and the fleet's pin light read.

```bash
sha=$(gh api repos/notambourine/fleet-actions/commits/v1 -q .sha)
```

Write `@$sha # v1`. Never write `@v1`.

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
| `fetch-depth` | `0` | Checkout depth. `scan-mode: git` requires `0`. |
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

- `timeout-minutes: 5` on every job.
- Workflow-level `contents: read`, no job-level permissions.
- `persist-credentials: false` on every checkout; `fetch-depth: 0` only where history is an input.
- Every action pinned `@<40-char-sha> # <tag>`, resolved from a release tag to its commit.
- `ubuntu-slim` everywhere except where the tool forbids it. betterleaks needs `envsubst` for
  cosign; `kjanat/actionlint` is a Docker action and needs a daemon.
- `setup-uv` with a blank `cache-dependency-glob` and a weekly `cache-suffix` rotation.
- One concurrency group per calling repo, calling workflow, and ref, cancelling only on
  pull requests.

## Status

`zizmor` and `actionlint` run. The rest fail with a message naming the input to disable until
they are absorbed.
