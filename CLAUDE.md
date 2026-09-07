# fleet-actions

Treat every workflow change as a fleet-wide CI change.

- Land changes through squash pull requests.
- Tag patches and dependency updates as `v1.N.P`. Tag input changes as `v1.N`.
- Keep `refs/tags/v1` mutable. The release workflow promotes it.
- Pin actions to 40-character SHAs and label them with immutable release tags.
- Keep every gate in the single `fleet` job and use `!cancelled()` on gate steps.
- Add `tools/<name>/test/run.sh` with every new script-backed tool.
- Test both clean input and a planted positive that must fail.
- Keep the tree free of Unicode dashes, zero-width characters, and live IOC literals.
- Require only checks that report on every pull request.
- Set `wormhook: false` when wormhook calls this workflow.
