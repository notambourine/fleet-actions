# pin-osv

Fail CI when [OSV](https://osv.dev) reports an advisory or malware at the source commit
behind a pin this repo executes. Every other dependency gate in the fleet reads declared
dependencies out of a manifest. Nothing reads the two surfaces a workflow actually runs:
the actions it references and the base images its Dockerfiles build on.

## Why the query is a commit

Both surfaces resolve to a commit, and OSV indexes GIT commit ranges, so one query per
commit covers the upstream repo whatever it ships: an image, a module, an npm package,
an action. That is strictly wider than asking about package coordinates.

The tj-actions compromise is the worked example:

| Query | Result |
| --- | --- |
| `{"commit": "a284dc18..."}` | `CVE-2025-30066` |
| `{"package": {"name": "tj-actions/changed-files", "ecosystem": "GitHub Actions"}}` | `[]` |

The package query misses it. OSV's `GitHub Actions` ecosystem holds reviewed advisories
keyed `owner/repo`, and this compromise is not one of them.

## How a pin becomes a commit

| Pin | Source of the commit |
| --- | --- |
| `uses: owner/repo@<40-hex>` | the pin already is the commit |
| `FROM host/owner/repo@sha256:...` | the image's build attestation names it |

An image whose attestation cannot be read is **unresolved**, never clean. It is reported
either way; `require-attestation` decides whether it also fails the job. That input is
off by default because most published images carry no attestation, which makes an
unresolved image a coverage gap to report rather than a finding against the pin. Of this
repo's own three image pins, only one is attested.

A local action (`./tools/...`, or the `$/` the release rewrites) has no upstream commit
and is skipped.

## Severity

Cumulative, so `high` covers critical. **A record with no severity label counts as
critical.** OSV leaves the label null on `CVE-` and `GO-` records, and CVE-2025-30066 is
one of them, so a threshold that dropped unrated records would miss the exact class of
event this gate exists for.

`MAL-` identifiers are their own decision, gated by `malware` rather than by severity,
so `severity: none` still fails on malware alone.

## What it does not cover

The attestation proves which commit an image was built from, not that the build was
reproducible from it. A maintainer whose account is compromised can poison the release
workflow and produce a valid attestation over poisoned output. Cooldown in
`dependabot.yml` and reading the release diff remain the answer there.

OSV is also a reporting feed: a compromise nobody has published yet is a clean query.
This gate raises the floor, it does not close the window.
