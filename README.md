# fleet-actions

Reusable CI for NoTambourine repositories. One job runs secret scanning, workflow
validation, Unicode dash checks, supply-chain malware checks, and package-manager
pin validation.

## Usage

```yaml
name: notambourine

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  fleet-actions:
    uses: notambourine/fleet-actions/.github/workflows/fleet-ci.yml@<sha> # v1.0.1
```

All checks are enabled by default. The workflow reports one check named
`<workflow name> / <calling job>`, so these two names are load-bearing: the
example above reports `notambourine / fleet-actions`. This workflow's own job id
never appears in the check name.

Pin the workflow to a commit and label it with the immutable release tag:

```bash
sha=$(gh api repos/notambourine/fleet-actions/commits/v1 -q .sha)
tag=$(gh api repos/notambourine/fleet-actions/releases/latest -q .tag_name)
```

Use `@$sha # $tag`. Do not use `@v1` or label a commit pin `# v1`.

## Configuration

Override only what the repository needs. Set any check name (`betterleaks`,
`zizmor`, `actionlint`, `dashes`, `tripwire`, `wormhook`, `pnpm-pin`, or
`guarddog`) to `false` to disable it.

```yaml
jobs:
  fleet-actions:
    uses: notambourine/fleet-actions/.github/workflows/fleet-ci.yml@<sha> # v1.0.1
    with:
      betterleaks-pr-range: true # Scan only commits in the pull request.
      dash-force-zero: true # Reject every Unicode dash instead of ratcheting.
      dash-exclude: | # Add repo-relative glob pathspecs to the defaults.
        docs/vendor/**
      tripwire-allow: | # Permit IOC literals in matching file contents.
        docs/security.md
      guarddog-registry-verify: true # Download and score declared dependencies.
      guarddog-ecosystems: npm # Otherwise inferred from manifests.
      guarddog-minimum-risk: high # Default: suspicious.
      guarddog-exclude-paths: | # Skip tracked paths; a workflow skips its actions too.
        dist/*
      guarddog-exclude-rules: | # Suppress a rule for every scan or one ecosystem.
        pypi:repository_integrity_mismatch
      actionlint-extra-labels: | # Add repository-specific runner labels.
        large-runner
```

[The reusable workflow](.github/workflows/fleet-ci.yml) documents every input and
default. It also merges `.github/actionlint.yaml` or `.github/actionlint.yml` from
the caller; `actionlint-config-extra` takes precedence.

## Scanning installed dependencies

`fleet-ci` never installs dependencies. Scan `node_modules` in the build job after
`npm ci`:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - uses: actions/setup-node@<sha> # vX.Y.Z
        with:
          node-version-file: .nvmrc
          cache: npm

      # Keep this after setup-node and before npm ci so its npm shim wins.
      - uses: SocketDev/action@2d3f25590c6ed6ba11a9a14c064d962a3a04698f # v1.3.1
        with:
          mode: firewall-free

      - run: npm ci

      - uses: notambourine/wormhook@<sha> # v0.31.1
        with:
          mode: deep

      - uses: notambourine/fleet-actions/tools/guarddog@<sha> # v1.0.1
        with:
          scan-paths: npm:node_modules
          local-scan: false
          actions: false

      - run: npm run test
```

The two `false` values avoid repeating the fleet scan. Keep wormhook enabled in
`fleet-ci` when this build job can be skipped.

## Local actions

| Path | Check |
| --- | --- |
| `tools/betterleaks` | Verified betterleaks installation and scan. |
| `tools/dashes` | Unicode dash ratchet. |
| `tools/guarddog` | Malware heuristics over the tracked tree and referenced actions. |
| `tools/pnpm-pin` | Exact `packageManager` version. |
| `tools/tripwire` | Supply-chain persistence indicators. |

Script-backed tool suites live in `tools/<name>/test/run.sh`. Betterleaks is tested
through named workflow jobs. Pull requests run affected suites; pushes and schedules
run all suites.
