# guarddog

Scan tracked code and referenced actions with
[DataDog/guarddog](https://github.com/DataDog/guarddog). `guarddog` is disabled by default in
`fleet-ci.yml` because action scans fetch source and rule updates require a pin bump.

## Scans

| Gate | Default | Network | Covers |
| --- | --- | --- | --- |
| `local-scan` | on | none | YARA rules over the tracked tree |
| `actions` | on | fetches action source | JavaScript of the actions each workflow references |
| `registry-verify` | off | a round trip per package | Downloads and scores every declared dependency |

`registry-verify` is disabled by default because it downloads every declared dependency.

## Local scan

The local scan copies tracked files to a temporary directory and runs rules for each detected
ecosystem:

| Ecosystem | Manifest anywhere in the tree |
| --- | --- |
| `npm` | `package.json` |
| `pypi` | `requirements.txt`, `requirements-*.txt`, `pyproject.toml`, `setup.py` |
| `go` | `go.mod` |
| `crates` | `Cargo.lock`, `Cargo.toml` |
| `rubygems` | `Gemfile`, `Gemfile.lock` |

Untracked files are excluded. A checkout without an index uses a pruned `find`.

## Reaching an installed tree

Use `scan-paths` for untracked installed dependencies:

```yaml
- run: npm ci
- uses: notambourine/fleet-actions/tools/guarddog@<sha> # v1.0.1
  with:
    scan-paths: npm:node_modules
    local-scan: false
    actions: false
```

`<ecosystem>:<path>` selects one rule set. A bare path uses every selected ecosystem. Missing
paths fail.

`exclude-paths` cannot reach inside a `scan-paths` target: exclusion works by staging
the kept files, and these are read where they lie.

`fleet-ci` has no `scan-paths` input because it does not install dependencies.

## Excluding a path

`exclude-paths` removes matching tracked paths before staging:

```yaml
with:
  exclude-paths: |
    dist/*
    *.min.js
```

Patterns are repo-relative. `*` crosses `/`. Excluding a workflow also excludes its action scan.

Exclude rules by name or ecosystem:

```yaml
with:
  exclude-rules: |
    typosquatting
    pypi:repository_integrity_mismatch
```

A bare name applies to every ecosystem. Prefix ecosystem-specific rules, such as
`pypi:repository_integrity_mismatch`.

## Allowlisting a package

Use `exclude-packages` to suppress one dependency:

```yaml
with:
  exclude-packages: |
    left-pad@1.3.0
    @acme/*
    github_action:acme/deploy-action
```

A bare name matches every version and ecosystem. `<name>@<version>` selects one version.
`<ecosystem>:<name>` selects an ecosystem; `github_action` selects action scans. `*` is a glob.

This reaches the `verify` commands only: the `actions` gate and `registry-verify`.
A local scan reports file paths rather than packages, so `exclude-paths` is its knob.

Suppressions are logged per target.

## Install

Dependabot updates `pyproject.toml` and `uv.lock`. Installation audits the lockfile, verifies
artifact hashes, and disables source builds.

The `tarsafe` override in `pyproject.toml` retains the traversal fix excluded by
GuardDog 3.2.0's metadata. Remove it when a GuardDog release includes that fix.

## Reporting

Risks at or above `minimum-risk` fail the job. The default is `suspicious`.

JSON output provides the risk score. Malformed reports and scan errors fail.

## Sandbox

GuardDog uses Landlock with no network and a restricted filesystem. Unsupported platforms fail.
`sandbox: false` disables the sandbox.

## Local use

```bash
GD_ROOT=/path/to/repo bash tools/guarddog/scripts/run-guarddog.sh
```

Environment variables mirror the inputs: `GD_ECOSYSTEMS`, `GD_LOCAL_SCAN`, `GD_ACTIONS`,
`GD_REGISTRY_VERIFY`, `GD_SCAN_PATHS`, `GD_EXCLUDE_PATHS`, `GD_EXCLUDE_RULES`,
`GD_EXCLUDE_PACKAGES`, `GD_INCLUDE_DEV`, `GD_SANDBOX`, `GD_BIN`, `GD_STAGE`. `GD_PLAN_ONLY=true` prints the
commands it would run and touches nothing.

## Tests

Run `test/run.sh`.
