# pin-osv

Check the source commits behind pinned actions and base images against [OSV](https://osv.dev).

## Queries

OSV indexes GIT commit ranges. Action SHAs and image build attestations provide commits.

For CVE-2025-30066:

| Query | Result |
| --- | --- |
| `{"commit": "a284dc18..."}` | `CVE-2025-30066` |
| `{"package": {"name": "tj-actions/changed-files", "ecosystem": "GitHub Actions"}}` | `[]` |

The record has a GIT range and no package coordinate, so only the commit query matches.

`GHSA-gq52-6phf-x2r6` has an ECOSYSTEM range and no GIT range. Actions are queried by both
commit and package coordinate. Results are deduplicated by identifier.

The package version comes from the release comment (`@<sha> # v7.0.1`). Pins without a release
comment and container images are queried by commit only.

## Commit resolution

| Pin | Source of the commit |
| --- | --- |
| `uses: owner/repo@<40-hex>` | the pin already is the commit |
| `FROM host/owner/repo@sha256:...` | the image's build attestation names it |

An unreadable image attestation is unresolved. It emits a warning by default;
`require-attestation` makes it an error.

Local actions (`./tools/...` and `$/...`) are skipped.

## Severity

Thresholds are cumulative. Unrated records count as critical because OSV omits severity on some
`CVE-` and `GO-` records, including CVE-2025-30066.

The `malware` input controls `MAL-` identifiers independently. `severity: none` checks only malware.

## What it does not cover

The resolver does not verify attestation signatures or build reproducibility. It trusts GitHub's
upload authorization and the publisher's provenance claim. OSV queries cannot detect unpublished
compromises.
