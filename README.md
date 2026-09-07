# fleet-actions

Reusable CI for NoTambourine repositories. One job runs secret scanning, workflow
validation, Unicode dash checks, supply-chain malware checks, and package-manager
pin validation.

## Usage

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
    uses: notambourine/fleet-actions/.github/workflows/fleet-ci.yml@<sha> # v1.0.1
```

All checks are enabled by default. The workflow reports one check named
`<calling job> / fleet`.

Pin the workflow to a commit and label it with the immutable release tag:

```bash
sha=$(gh api repos/notambourine/fleet-actions/commits/v1 -q .sha)
tag=$(gh api repos/notambourine/fleet-actions/releases/latest -q .tag_name)
```

Use `@$sha # $tag`. Do not use `@v1` or label a commit pin `# v1`.

## Inputs

| Input | Default | Effect |
| --- | --- | --- |
| `betterleaks` | `true` | Run betterleaks with a verified release. |
| `zizmor` | `true` | Audit workflows at medium severity or higher. |
| `actionlint` | `true` | Run actionlint with ShellCheck and pyflakes. |
| `dashes` | `true` | Reject new Unicode dashes on pull requests. |
| `tripwire` | `true` | Scan for Shai-Hulud persistence indicators. |
| `wormhook` | `true` | Scan for npm supply-chain malware. |
| `pnpm-pin` | `true` | Require `package.json#packageManager`. |
| `scan-mode` | `git` | Set the betterleaks subcommand to `git` or `dir`. |
| `wormhook-mode` | `deep` | Set the wormhook scan depth to `fast` or `deep`. |
| `fetch-depth` | `0` | Set checkout depth. `scan-mode: git` requires `0`. |
| `betterleaks-version` | `latest` | Select `latest` or an exact betterleaks release. |
| `betterleaks-path` | `""` | Set the scan path. Empty uses the workspace root. |
| `betterleaks-log-opts` | `""` | Pass arguments to `git log`. Overrides `betterleaks-pr-range`. |
| `betterleaks-pr-range` | `false` | Scan only pull request commits. |
| `dash-base-ref` | `""` | Set the base branch without `origin/`. Empty uses the event. |
| `dash-exclude` | `""` | Add excluded glob pathspecs, one per line. |
| `dash-exclude-defaults` | `true` | Apply the built-in exclusions. |
| `dash-force-zero` | `false` | Require zero Unicode dashes in the tree. |
| `tripwire-allow` | `""` | Allow IOC literals in matching file contents. |
| `actionlint-extra-labels` | `""` | Add runner labels, one per line. |
| `actionlint-config-extra` | `""` | Merge raw YAML over the actionlint configuration. |

The workflow merges a caller's `.github/actionlint.yaml` or
`.github/actionlint.yml`. The extra config input takes precedence.

## Scanning installed dependencies

`fleet-ci` never installs, so its wormhook step sees source only. `deep` forces the
Tier-2 `node_modules` content walk and skips silently when the directory is absent,
which makes it free here and a real gate on a repo that commits the tree.

Reaching installed dependencies takes a second call in the build workflow, in the same
job as the install:

```yaml
- run: npm ci
- uses: notambourine/wormhook@<sha> # v0.31.1
  with:
    mode: deep
```

A repo that does this may pass `wormhook: false` to `fleet-ci` and rely on the
post-install scan alone. Keep the default `true` if the install runs behind a path
filter or in a job that can be skipped, since the fleet scan is what still reports.

## Local actions

| Path | Check |
| --- | --- |
| `tools/betterleaks` | Verified betterleaks installation and scan. |
| `tools/dashes` | Unicode dash ratchet. |
| `tools/pnpm-pin` | Exact `packageManager` version. |
| `tools/tripwire` | Supply-chain persistence indicators. |

Script-backed tool suites live in `tools/<name>/test/run.sh`. Betterleaks is tested
through named workflow jobs. Pull requests run affected suites; pushes and schedules
run all suites.
