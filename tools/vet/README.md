# vet

Fail on declared dependencies with known advisories or OSV malware records.

## What runs

The action runs `vet scan --filter-fail` over the tracked tree. Severity is cumulative;
`none` checks malware only. `policy` replaces the generated filters, including malware.

A repo with no package manifest passes without a scan.

## Dependency pin

`Dockerfile` pins `ghcr.io/safedep/vet` by tag and digest. Dependabot updates both.

The pin freezes the engine and generated suite. Finding data comes from
`api.safedep.io/insights-community/v1` at scan time through `VET_COMMUNITY_MODE`. Package names
and versions leave the runner. API failures fail the job.

## Failure modes

A policy match or scan error fails the job. Details remain in the grouped log.

Run `test/run.sh`.
