# vet

Fail the job when a declared dependency carries a known advisory, or is a package OSV
marks malicious.

This is the surface no other fleet gate covers. wormhook, tripwire, and guarddog look for
malicious code: install-time exfiltration, worm payloads, packages that were never
legitimate. None of them notices an honest dependency with a published CVE. The update
proposer does, asynchronously, after the merge; this gate blocks the pull request that
introduces one.

## What runs

`vet scan --filter-fail` over the tracked tree with a generated filter suite. Severity is
cumulative, so `high` covers critical too, and `none` gates on malware alone. A caller
that outgrows two knobs supplies its own suite through `policy`, which then owns the whole
decision, malware included.

A repo with no package manifest passes without a scan.

## The pin, and what it does not cover

`Dockerfile` pins `ghcr.io/safedep/vet` by tag and digest, which is the one form
Renovate's docker manager rewrites. vet-action cannot be the pin: with no `version` it
asks GitHub for the latest vet release and downloads it unverified, and a `version` in
`with:` is a string no updater rewrites.

The pin freezes the engine and the suite, never the finding set. Vulnerability, malware,
and scorecard data come from `api.safedep.io/insights-community/v1` at scan time, keyless
through `VET_COMMUNITY_MODE`. That is deliberate for advisories: a CVE published today
should fail a pull request today. It also means the gate carries a hard dependency on a
third party being up, and every scanned package name and version leaves the runner.

## Failure modes

A policy match and a scan that could not complete both exit non-zero, and both fail the
job. The grouped log says which. There is no SARIF upload and no pull request comment:
findings are the job's failure, the way every other fleet gate reports.

`test/run.sh` covers suite assembly, severity cumulation, the caller policy takeover, and
both the clean and planted-finding paths against a stub. Nothing in the suite reaches the
network.
