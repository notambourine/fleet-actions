# fleet-actions

This repo is the fleet's CI gate. A push to `main` executes in every consumer's CI on
their next pin bump, so treat every change here as a change to every repo.

## Rules

- Never flip a tool from stub to live in a change that does not also add its suite.
  A green board over a dead gate is the one failure this repo cannot ship. A suite has to
  prove the gate FAILS on a planted positive; "clean repo passes" proves nothing. The only
  exemption is wormhook, which keeps its suite in its own repo.
- Keep the tree free of unicode dashes. The repo dogfoods its own dash gate at
  `exclude-defaults: false`, and the built-in hold-out list does not cover `README.md`
  or `*.sh`. Absorb inbound code by de-dashing it, never by excluding its path.
- Keep the tree free of zero-width characters and live IOC literals. Defang IOCs the
  way `tools/tripwire` does, in split literals the tripwire scanner cannot match.
- Keep one directory per tool: `tools/<name>/{action.yml, scripts/, test/run.sh}`.
  `self-test.yml` discovers `tools/<name>/test/run.sh`; absorbing a tool edits no workflow.
- Label every consumer pin with the immutable `v1.N` or `v1.N.P` tag, never `# v1`.
  zizmor's `ref-version-mismatch` resolves the comment and compares it to the pinned
  commit, so a floating label fails every consumer the moment `v1` moves past them.
- Name the release version by hand: `v1.N.P` for a patch or a dependency bump, `v1.N` for
  a change to the inputs consumers pass. No workflow can tell those apart, so nothing
  auto-increments. Consumers pin SHAs and take Dependabot's bump PR; `@v1` floats and is
  unsupported, so a consumer that resolves it accepts the breakage.
- Keep `refs/tags/v1` exempt from tag immutability. The floating tag is promoted by
  `PATCH .../git/refs/tags/v1`, which an immutable-tags ruleset breaks permanently.
- Land every change through a squash PR. `main` takes no direct push and the rulesets
  carry no bypass actors, so a commit written straight to `main` is rejected, not merged.
- Require only checks that report on every PR. `tools (<name>)` is path filtered and
  absent from most runs; requiring it leaves merges pending with nothing to clear them.
- Pin `wormhook: false` in wormhook's own CI. wormhook calls `fleet-ci.yml`, which calls
  wormhook, so a wormhook regression would otherwise leave no green path to fix it.
