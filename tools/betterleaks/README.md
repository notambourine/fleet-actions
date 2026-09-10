# betterleaks

Scan commit history or the worktree for secrets from a digest-pinned image.

## Why the image is the pin

The `Dockerfile` digest is the dependency pin Dependabot updates. The runner verifies the
digest before starting the container.

Engine and rule updates require a digest bump.

Docker container actions are Linux-only, so the action no longer runs on macOS or
Windows runners.

## Scan modes

`git` scans commit history and requires `fetch-depth: 0`. Findings are tied to commits.

`dir` scans the worktree only. `betterleaks-log-opts` and `betterleaks-pr-range` narrow
a `git` scan and are ignored with a warning under `dir`.

Validation is disabled. `--redact=100` hides matched values from logs.

## Tests

Run `test/run.sh`. `betterleaks-self-scan` in `self-test.yml` tests the container action.
