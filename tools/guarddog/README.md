# guarddog

Fail CI when code in the tree, or in an action a workflow reaches for, looks like
malware. Wraps [DataDog/guarddog](https://github.com/DataDog/guarddog), whose risk
model needs both a capability (spawn a process, reach the network) and a threat
indicator (obfuscated payload, exfil domain) before it scores anything, which is what
keeps it quieter than a pattern-matcher.

Callers reach this through `fleet-ci.yml`'s `guarddog*` inputs.

## Two gates, and the one that is off

| Gate | Default | Network | Covers |
| --- | --- | --- | --- |
| `local-scan` | on | none | YARA rules over the tracked tree |
| `actions` | on | fetches action source | JavaScript of the actions each workflow references |
| `registry-verify` | off | a round trip per package | Downloads and scores every declared dependency |

`registry-verify` is off because Socket and the update bots already watch declared
dependencies, and it is the expensive path: `verify` downloads each package from its
registry. The other two are what nothing else in the fleet does. `tripwire` matches
known IOC literals in the tree; this scores unknown code heuristically. Nobody reads
the JavaScript inside a referenced action, and that code runs with the workflow's token.

## What a local scan reads

The tracked tree, staged into a scratch directory. Each ecosystem whose manifest the
tree holds contributes one scan, because the rule set differs by ecosystem and the tree
does not:

| Ecosystem | Manifest anywhere in the tree |
| --- | --- |
| `npm` | `package.json` |
| `pypi` | `requirements.txt`, `requirements-*.txt`, `pyproject.toml`, `setup.py` |
| `go` | `go.mod` |
| `crates` | `Cargo.lock`, `Cargo.toml` |
| `rubygems` | `Gemfile`, `Gemfile.lock` |

Tracked means `git ls-files`, so `node_modules` and untracked build output are out
without an exclusion. A checkout with no index falls back to a pruned `find`.

## Reaching an installed tree

Tracked means untracked is invisible, so `node_modules` after an `npm ci` needs saying
out loud. `scan-paths` scans a path in place, staging skipped:

```yaml
- run: npm ci
- uses: notambourine/fleet-actions/tools/guarddog@<sha> # v1.0.1
  with:
    scan-paths: npm:node_modules
    local-scan: false
    actions: false
```

`<ecosystem>:<path>` picks the rule set; a bare path runs every selected ecosystem over
it, which is usually waste. A path that does not exist is an error, so a renamed
directory fails loudly instead of scanning nothing. Runtime scales with the installed
tree, which is why this belongs in the build job rather than in the fleet check.

`exclude-paths` cannot reach inside a `scan-paths` target: exclusion works by staging
the kept files, and these are read where they lie.

There is no fleet-ci input for this. `fleet-ci` never installs, and a committed
dependency tree is tracked, so the local scan already covers it.

## Excluding a path

guarddog has no ignore file, no config file, no baseline, and no path allowlist. Its
only knobs are whole-rule (`--exclude-rules`), file extension
(`GUARDDOG_YARA_EXT_EXCLUDE`), and a few env thresholds. So exclusion is this wrapper's
job: an excluded path never reaches the staged tree the scan reads.

```yaml
with:
  exclude-paths: |
    dist/*
    *.min.js
```

Patterns match tracked repo-relative paths and `*` crosses `/`, so `dist/*` drops the
whole subtree. Excluding a workflow drops it from the `actions` gate too.

Whole rules go the other way:

```yaml
with:
  exclude-rules: |
    typosquatting
    pypi:repository_integrity_mismatch
```

A bare name applies to every ecosystem scanned. guarddog validates rule names per
ecosystem and a pypi-only name errors on an npm scan, so scope those with a prefix.
The metadata rules that do live WHOIS and DNS lookups are the ones worth dropping if
they turn the check red without a code change: `typosquatting`,
`potentially_compromised_email_domain`, `unclaimed_maintainer_email_domain`, and
`repository_integrity_mismatch`, which DataDog excludes in their own CI. They only
apply to `registry-verify` anyway; a local scan has no registry metadata to read.

## Install

`requirements.txt` is a hash-pinned resolution of `guarddog` and its 33 transitive
dependencies, installed with `uv pip install --require-hashes`. Nothing resolves a
version at run time, and Dependabot's `pip` entry for this directory is what moves the
pin. That is the tradeoff: the ruleset only advances when a bump lands.

The upstream README recommends `uvx guarddog`, which resolves the tool and its whole
tree from PyPI on every run. No bot gates that.

Regenerate the pin with:

```bash
echo guarddog==<version> |
  uv pip compile --generate-hashes --universal --python-version 3.12 - \
    -o tools/guarddog/requirements.txt
```

Keep `--python-version` and the action's `python-version` input in step. The install
step asserts the binary reports the version the file pins.

## Reporting

Risks labelled `suspicious` or `high_risk` fail the job. Set `minimum-risk` to `low`
or `high` to change the threshold. Upstream's sample workflow emits SARIF into GitHub
code scanning instead, which needs `security-events: write` from every caller and moves
findings off the fleet check.

`--output-format json` is load-bearing rather than cosmetic. It carries GuardDog's risk
score, which separates common low-risk capabilities from suspicious combinations. The
wrapper also fails malformed reports and scan errors.

guarddog also exits non-zero on a scan error, so a flagged target and a broken scan
look alike from outside. Read the group in the log.

## Sandbox

guarddog extracts and analyses untrusted content inside a kernel sandbox (Landlock on
Linux) with no network and a restricted filesystem, because extraction itself has been
the vulnerability: CVE-2022-23530, CVE-2022-23531, CVE-2026-22870, CVE-2026-22871. It
fails rather than silently dropping the sandbox when the platform cannot provide one,
which is also what happens inside another sandbox that already denies the syscall.
`sandbox: false` runs without it.

## Local use

```bash
GD_ROOT=/path/to/repo bash tools/guarddog/scripts/run-guarddog.sh
```

Environment variables mirror the inputs: `GD_ECOSYSTEMS`, `GD_LOCAL_SCAN`, `GD_ACTIONS`,
`GD_REGISTRY_VERIFY`, `GD_SCAN_PATHS`, `GD_EXCLUDE_PATHS`, `GD_EXCLUDE_RULES`,
`GD_INCLUDE_DEV`, `GD_SANDBOX`, `GD_BIN`, `GD_STAGE`. `GD_PLAN_ONLY=true` prints the
commands it would run and touches nothing.

## Tests

`test/run.sh` asserts detection, gate toggles, path exclusion, and argument assembly in
plan mode, so no case reaches a registry. Three cases carry the weight: a stub reporting
zero issues must pass, a stub reporting issues must fail the job, and a stub reporting
issues while exiting 0 must still fail, which is the upstream behavior the JSON flag
exists to defeat. A fourth probes the staged tree to prove an excluded path never
reaches it.
