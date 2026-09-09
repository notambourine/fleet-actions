# guarddog

Fail CI when code in the tree, or in an action a workflow reaches for, looks like
malware. Wraps [DataDog/guarddog](https://github.com/DataDog/guarddog), whose risk
model needs both a capability (spawn a process, reach the network) and a threat
indicator (obfuscated payload, exfil domain) before it scores anything, which is what
keeps it quieter than a pattern-matcher.

Callers reach this through `fleet-ci.yml`'s `guarddog*` inputs, and `guarddog: false` is
the default there: the `actions` gate fetches action source over the network, and a
hash-pinned ruleset only advances when a bump lands, so a caller opts in rather than
inherits it. This repo's own `self-test` sets `guarddog: true`, which is what covers the
gate.

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

## Allowlisting a package

`exclude-rules` is the wrong tool for one noisy dependency: it drops the rule for every
package in the scan. `exclude-packages` drops the package instead, and only the package,
by removing its entry from the report before the report is scored:

```yaml
with:
  exclude-packages: |
    left-pad@1.3.0
    @acme/*
    github_action:acme/deploy-action
```

A bare name covers every version and every ecosystem. `<name>@<version>` holds to that
version, so the next release comes back red. `<ecosystem>:<name>` scopes an entry, and
`github_action` is a scope here even though it is not an ecosystem elsewhere. `*` globs,
and an npm scope's leading `@` is not read as a version.

This reaches the `verify` commands only: the `actions` gate and `registry-verify`.
A local scan reports file paths rather than packages, so `exclude-paths` is its knob.

Every suppression prints in the target's log group. Nothing warns about an entry that
matched nothing, because a per-target warning would fire on every target the package
does not appear in.

## Install

Dependabot updates the GuardDog requirement and its resolved tree through the native
`uv` ecosystem. `uv audit --locked` rejects known vulnerabilities before installation.
`uv sync --locked` installs the committed versions and verifies artifact
hashes. A stale lockfile fails the install; CI never updates it. Source builds are
disabled so build dependencies cannot resolve outside the lockfile.

The `tarsafe` override in `pyproject.toml` retains the traversal fix excluded by
GuardDog 3.2.0's metadata. Remove it when a GuardDog release includes that fix.

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
`GD_EXCLUDE_PACKAGES`, `GD_INCLUDE_DEV`, `GD_SANDBOX`, `GD_BIN`, `GD_STAGE`. `GD_PLAN_ONLY=true` prints the
commands it would run and touches nothing.

## Tests

`test/run.sh` asserts detection, gate toggles, path and package exclusion, and argument
assembly in
plan mode, so no case reaches a registry. Three cases carry the weight: a stub reporting
zero issues must pass, a stub reporting issues must fail the job, and a stub reporting
issues while exiting 0 must still fail, which is the upstream behavior the JSON flag
exists to defeat. A fourth probes the staged tree to prove an excluded path never
reaches it.
