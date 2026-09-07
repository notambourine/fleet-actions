# betterleaks

Secret scan over commit history or the worktree, from a cosign-verified,
sha256-checked release. Absorbed from `betterleaks-action`.

Callers reach this through `fleet-ci.yml`'s `betterleaks` input, plus `scan-mode` and
the `betterleaks-*` inputs. See the repo README for that table.

## Why the verification chain is two stages

`cosign verify-blob` checks `checksums.txt` against the sigstore bundle, asserting the
file came from `betterleaks/betterleaks`' own release workflow at the matching tag.
`sha256sum -c` then checks the tarball against that verified manifest. cosign is never
piped: a pipe would let a verify failure reach the scan step on an unverified binary if
`pipefail` were ever lost.

The tarball unpacks under `RUNNER_TEMP`, not the workspace. A compressed Go binary is
exactly the entropy a secret scanner flags, and the scan walks the workspace.

## Why the version floats

`version: latest` resolves the newest betterleaks release each run, because a frozen
ruleset is the thing `latest` exists to avoid. The cost is that one upstream release
with a new rule can turn the whole fleet red at once with no code change anywhere.
`betterleaks-version` is the escape hatch: pin an exact version, land the fix, float
again. `self-test.yml`'s `betterleaks-pinned-version` job keeps that path working.

## Scan modes

`git` walks commit history and needs `fetch-depth: 0`; the action fails fast on a
shallow clone rather than silently scanning less. It fingerprints commits, so a finding
cannot be resolved by editing the file afterward.

`dir` scans the worktree only. `betterleaks-log-opts` and `betterleaks-pr-range` narrow
a `git` scan and are ignored with a warning under `dir`.

Validation stays off, so no candidate secret is ever sent to a vendor API, and
`--redact=100` keeps a finding out of a public log.

## Tests

There is no `test/run.sh` here, and `test/ACTION-LEVEL` records why so `self-test.yml`'s
discovery skips this directory instead of failing on it. Both real cases assert behavior
that exists only through `uses:` (`betterleaks-self-scan` dogfoods the action against
this repo; `betterleaks-pinned-version` asserts a step *output*), so they live as named
jobs in `self-test.yml` alongside a job that extracts every `run:` block with `yq` and
runs ShellCheck over it. The action's whole product is embedded bash.
