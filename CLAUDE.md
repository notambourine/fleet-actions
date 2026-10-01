# fleet-actions

Treat every workflow change as a fleet-wide CI change.

- Answer every question about `fleet-ci.yml` and its inputs, not this repo's self-test.
- Land changes through squash pull requests.
- Never tag by hand. Every merge to main releases `v1.N.P`: `N` bumps when `fleet-ci.yml`
  inputs change, `P` otherwise.
- Add a `docs/release-notes/<topic>.md` when a release needs a change in the calling repository.
  The release workflow prepends notes added since the last tag.
- Keep `refs/tags/v1` mutable. The release workflow promotes it.
- Pin actions to 40-character SHAs and label them with immutable release tags.
- Resolve every dependency through a SHA pin Dependabot rewrites, or verify its provenance
  in the step. Never let a step resolve a version at run time.
- Keep the moving part in `uses:`. Dependabot does not rewrite a version inside `with:`.
- Keep every gate in the single `fleet` job and use `!cancelled()` on gate steps.
- Report findings by failing the job. Never route them to a separate surface.
- Add `tools/<name>/test/run.sh` with every new script-backed tool.
- Opt a tool out with `tools/<name>/test/ACTION-LEVEL` naming the jobs that cover it.
- Test both clean input and a planted positive that must fail.
- Keep the tree free of Unicode dashes, zero-width characters, and live IOC literals.
- Stage new files before running the dash check. It scans the index.
- Require only checks that report on every pull request.
- Set `wormhook: false` when wormhook calls this workflow.
