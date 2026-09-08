# actionlint

Workflow static check from [kjanat/actionlint](https://github.com/kjanat/actionlint),
the released fork of rhysd/actionlint, with ShellCheck and pyflakes bundled in its image.

Callers reach this through `fleet-ci.yml`'s `actionlint*` inputs.

## Why a Dockerfile and not `uses: kjanat/actionlint@<sha>`

The fork's release tags point at a commit whose `action.yml` references the container
by mutable tag. A digest lands one commit later, under the floating `v1.N` tag, which
no `v1.N.P` tag ever points at. Pinning that commit meant an updater `ignore`, a
manual re-resolve per release, and a self-test job to prove the digest was still there.

`Dockerfile` here is a single `FROM image:tag@sha256:...`. Renovate's docker
manager rewrites tag and digest together, so the pin moves through an ordinary bump
PR and nothing floats. The image's entrypoint is the action, so `action.yml` only
mirrors the fork's inputs and positional `args`.

## Tests

`test/ACTION-LEVEL` names the self-test jobs. The `fleet-ci` job is the clean case over
this repo. `actionlint-planted` runs the action against a workflow with a known error
and fails unless the action does. That is what catches a bump that reorders the
entrypoint's positional arguments.
