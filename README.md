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
    permissions:
      contents: read
    uses: notambourine/fleet-actions/.github/workflows/fleet-ci.yml@<sha> # v1.0.1
    # guarddog and runner-tier default to false. Other checks default to true.
    # with:
    #   guarddog: true
    #   runner-tier: true # Suggest clear ubuntu-slim cost savings in private repos.
    #   runner-tier-exclude: | # Job-key globs to omit from suggestions.
    #     e2e-*
    #   scan-mode: git # betterleaks scans the full history.
    #   wormhook-mode: deep # Includes tracked node_modules when present.
    #   betterleaks-pr-range: false # Scan history, not only PR commits.
    #   dash-force-zero: false # Reject new dashes without policing old ones.
    #   dash-exclude: | # Built-in exclusions only; add pathspecs here.
    #     docs/vendor/**
    #   tripwire-allow: | # Empty by default; add content exceptions here.
    #     docs/security.md
    #   guarddog-registry-verify: false # Do not download declared dependencies.
    #   guarddog-ecosystems: auto # Infer ecosystems from tracked manifests.
    #   guarddog-minimum-risk: suspicious # Low-risk findings remain visible.
    #   guarddog-exclude-paths: | # Empty; add tracked globs here.
    #     dist/*
    #   guarddog-exclude-rules: | # Empty; scope rules with ecosystem:rule.
    #     pypi:repository_integrity_mismatch
    #   guarddog-exclude-packages: | # Empty; drops one package, not a rule.
    #     left-pad@1.3.0
    #   pin-osv-severity: high # An unrated OSV record always counts as critical.
    #   pin-osv-require-attestation: false # Unresolved images warn, they do not fail.
    #   pin-osv-allow: | # Empty; waives one OSV identifier.
    #     GHSA-0000-0000-0000
    #   actionlint-extra-labels: | # Empty; add custom runner labels here.
    #     large-runner
    #   actionlint-require-permissions: job # workflow, or off, relaxes it.
    #   actionlint-job-timeout-min: 5 # 0 drops the bound.
    #   actionlint-job-timeout-max: 15 # ubuntu-slim kills a job at 15 anyway.
```

## Job permissions and timeouts

actionlint enforces two fleet policies. Every job in the calling repository, including
the one calling this workflow, must declare `permissions:`. An empty `permissions: {}`
satisfies the policy; neither scope judges whether the grants are minimal. Every job must also declare a
`timeout-minutes:` between 5 and 15; a job calling a reusable workflow is exempt, since
a caller-side timeout does not reach it.

Relax either through the inputs above rather than by disabling `actionlint`.

## Runner tier

`runner-tier` suggests `ubuntu-slim` only for clearly lightweight jobs in private repositories.
Suggestions are notices and never fail CI. It stays silent for public repositories, local
actions, concurrent work, builds, installs, services, containers, and jobs over five minutes.

Every check except `guarddog` and `runner-tier` is enabled by default. The workflow reports one check named
`<workflow name> / <calling job>`, so these two names are load-bearing: the
example above reports `notambourine / fleet-actions`. This workflow's own job id
never appears in the check name.

Pin the workflow to a commit and label it with the immutable release tag:

```bash
sha=$(gh api repos/notambourine/fleet-actions/commits/v1 -q .sha)
tag=$(gh api repos/notambourine/fleet-actions/releases/latest -q .tag_name)
```

Use `@$sha # $tag`. Do not use `@v1` or label a commit pin `# v1`.

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
| `tools/betterleaks` | Secret scan from a digest-pinned betterleaks image. |
| `tools/dashes` | Unicode dash ratchet. |
| `tools/guarddog` | Malware heuristics over the tracked tree and referenced actions. |
| `tools/pin-osv` | OSV advisories and malware at the commit behind each action and image pin. |
| `tools/pnpm-pin` | Exact `packageManager` version. |
| `tools/runner-tier` | Conservative `ubuntu-slim` cost suggestions for private repositories. |
| `tools/tripwire` | Supply-chain persistence indicators. |

Script-backed tool suites live in `tools/<name>/test/run.sh`. Pull requests run
affected suites; pushes and schedules run all suites.
