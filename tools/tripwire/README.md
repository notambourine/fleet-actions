# tripwire

Fail CI on the persistence layer of the Shai-Hulud / Mini Shai-Hulud npm worm
(2025-09 through 2026-08 waves). Pure git-tree scan of the caller's tracked files:
no install, no network, no secrets, so it is safe as the first gate in a pipeline.

Package scanners catch malicious *packages*. This catches what the worm leaves behind:
a planted workflow that dumps every secret, a `prepare` hook running a dropper, or a
dead-drop payload committed to the repo.

Callers reach this through `fleet-ci.yml`'s `tripwire` and `tripwire-allow` inputs.
See the repo README for that table.

## What it catches

| Class | Examples |
| --- | --- |
| Dead-drop payload files | `router_init.js`, `tanstack_runner.js`, `setup_bun.js`, `bun_environment.js`, `set_bun.js`, `gh-token-monitor.sh`, `router_runtime.js`, `langchain_core-setup.pth`, `ensmallen_haswell.abi3.so`, `ensmallen_core2.abi3.so` |
| Agent/editor persistence hooks | `.claude/setup.mjs`, `.vscode/setup.mjs`, `.claude/router_runtime.js` |
| Python `.pth` startup hooks | a tracked `*.pth` running an `import ...; exec/os/subprocess` one-liner (Miasma/Hades PyPI wave) |
| Secret-exfil workflows | any `.github/workflows/*` dumping all secrets as JSON |
| Campaign dropper workflow | `shai-hulud-workflow.yml` by name. Checkmarx published the name only, so the body is not greppable |
| Hidden Unicode in agent configs | zero-width codepoints and Unicode Tag characters in a tracked `CLAUDE.md`, `AGENTS.md`, `.cursorrules`, `copilot-instructions.md`, or anything under a `.claude/` or `.cursor/` at any depth (TrapDoor). Emoji ZWJ, subdivision-flag tags, a leading BOM, Persian/Urdu/Hindi ZWNJ orthography, and binary files are exempt |
| Exfiltration domains | `api.masscan[.]cloud`, `git-tanstack[.]com`, `*.getsession[.]org`, `webhook[.]site`, ChainDrop's `npm-cache[.]com` / `awqhnjewqjkl[.]icu` / `pypi-get[.]com` / `js-mirror[.]com`, node-ipc's `sh.azurestaticprovider[.]net` |
| Campaign markers | the `SHA1[-]HULUD` runner name, the ransom token description, the `thebeautiful[march]oftime` / `thebeautiful[snads]oftime` C2-discovery strings, ChainDrop's `0xE1f2[...]3103` C2 contract, the `A9[-]0522` build tag with its resolver wallet and `:443/0x/[...]` endpoints, node-ipc's HMAC key and custom base-16 alphabet, and obfuscator.io's `const _0x[...]=_0x[...];` accessor alias |
| Known payload hashes | published SHA-256 of `router_init.js`, `tanstack_runner.js`, and the trojaned `node-ipc.cjs` |
| Malicious lifecycle hooks | `package.json` `preinstall`/`postinstall`/`prepare` invoking a known dropper or `bun.sh/install` |

Domains and markers here are defanged (`[.]`, `[-]`) so this file never trips the
scanner it documents. Keep it that way when adding a wave.

The obfuscator.io accessor alias names a *technique* rather than a campaign, so it is
the one marker with a plausible false positive: a repo committing its own obfuscated
bundle should exempt that path.

## Allowlist

Filename, hash, and lifecycle-script checks are never exempted. Content scans
(workflows, `.pth` files, agent configs, domains, markers) skip the scanner itself,
and `tripwire-allow` adds newline- or space-separated globs:

```yaml
with:
  tripwire: true
  tripwire-allow: "*SECURITY.md"
```

## The force-push gap

This gate cannot defend against a force-push that also rewrites or deletes the gate:
whoever can rewrite the branch can rewrite the workflow. Close it with a branch ruleset
carrying `non_fast_forward`, `deletion`, `pull_request`, and required status checks.

## Local use

Run from the repository being checked:

```bash
bash /path/to/tools/tripwire/scripts/supply-chain-tripwire.sh
```

`TRIPWIRE_ALLOW` is the environment equivalent of `tripwire-allow`.

## Tests

`test/run.sh` builds throwaway repos under `mktemp -d` with `GIT_CONFIG_GLOBAL=/dev/null`
and plants one IOC class per case, so no attack fixture is ever written into this repo's
own tree or index. Fixture IOC literals are assembled from split strings and byte escapes
so the suite never trips the scanner it tests.

## Updating the IOC list

New waves publish new filenames and domains. Add them to the matching array or regex in
`scripts/supply-chain-tripwire.sh`, add a case to `test/run.sh`, and keep marker literals
fragmented so the scanner never matches its own source.

## Sources

- Checkmarx: *Shai-Hulud 1.0* (2025-09), the `shai-hulud-workflow.yml` dropper
- Microsoft Security: *Shai-Hulud 2.0* (2025-12-09)
- StepSecurity: trojaned `node-ipc` 9.1.6 / 9.2.3 / 12.0.1 (2026-05)
- Phoenix Security: *TrapDoor* hidden-Unicode agent-config poisoning (2026-05)
- StepSecurity / Snyk / Sophos: *Mini Shai-Hulud* (2026-05)
- Socket.dev: *Mini Shai-Hulud / Miasma / Hades* PyPI and MCP wave (2026-06)
- Elastic / Microsoft / JFrog: *ChainDrop* keyv wave, on-chain C2 (2026-08)
- Unit 42: npm supply-chain attack tracking
- CISA: widespread npm ecosystem compromise alert

The `A9[-]0522` markers are field-observed with no vendor advisory behind them, a lower
provenance tier than everything above.
