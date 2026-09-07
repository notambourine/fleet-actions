# pnpm-pin

Assert the root `package.json` pins an exact `packageManager` version.

An unpinned package manager means corepack resolves whatever is newest at install time,
so two runs of the same commit can install through different resolvers. That is the same
class of drift a lockfile exists to remove, one level up.

Root only: workspaces inherit the field, and corepack reads the root manifest. A repo
with no `package.json` passes silently, so consumers can leave the input on by default.

Accepted: `pnpm@10.4.1`, a corepack hash suffix (`pnpm@10.4.1+sha512.abc`), a prerelease
(`pnpm@10.4.1-rc.1`), and any manager name, not just pnpm. Rejected: a bare name, a range,
a partial version, and `latest`.

`test/run.sh` covers all of those plus a manifest `jq` cannot parse, which must fail
rather than read as a pass.
