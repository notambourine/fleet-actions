# betterleaks

Secret scan over commit history or the worktree, from a digest-pinned image.
Absorbed from `betterleaks-action`.

Callers reach this through `fleet-ci.yml`'s `betterleaks` input, plus `scan-mode` and
the `betterleaks-*` inputs. See the repo README for that table.

## Why the image is the pin

Upstream ships release tarballs and a `ghcr.io/betterleaks/betterleaks` image. Only the
image carries a reference Dependabot rewrites, so the digest in `Dockerfile` is the pin
and the bump arrives as a reviewable PR. That replaces a run-time `gh release view`,
a cosign signature check, and a sha256 manifest check with a digest the runner enforces
before the container starts.

The cost is a frozen ruleset: a rule published upstream today does not fail a PR today.
It fails one once the Dependabot bump lands.

Docker container actions are Linux-only, so the action no longer runs on macOS or
Windows runners.

## Scan modes

`git` walks commit history and needs `fetch-depth: 0`; the action fails fast on a
shallow clone rather than silently scanning less. It fingerprints commits, so a finding
cannot be resolved by editing the file afterward.

`dir` scans the worktree only. `betterleaks-log-opts` and `betterleaks-pr-range` narrow
a `git` scan and are ignored with a warning under `dir`.

Validation stays off, so no candidate secret is ever sent to a vendor API, and
`--redact=100` keeps a finding out of a public log.

## Tests

`test/run.sh` drives `scripts/run-betterleaks.sh` in plan mode for validation and
argument assembly, and through a stub binary for the pass and fail exits. `self-test.yml`'s
`betterleaks-self-scan` job dogfoods the built action against this repo, which is the
only case that exercises the image itself.
