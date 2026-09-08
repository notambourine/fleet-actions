# fleet-actions

Treat every workflow change as a fleet-wide CI change.

- Land changes through squash pull requests.
- Tag patches and dependency updates as `v1.N.P`. Tag input changes as `v1.N`.
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
