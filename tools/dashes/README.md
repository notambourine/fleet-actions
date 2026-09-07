# dashes

Reject added lines containing unicode dashes, and any rise in the repository total.
Existing dashes can stay until edited. Failures report file and line; counts appear in
the run summary. No automatic fixes.

Callers reach this through `fleet-ci.yml`'s `dashes` input and the `dash-*` inputs.
See the repo README for that table.

## Rules

Banned: U+2010 through U+2015, U+2212, and the HTML entities named `mdash`, `ndash`,
and `minus`. The old opt-out marker (`dash-` followed by `ok`) is also banned. Exclude
paths whose contents you cannot edit; there is no line opt-out.

Only regular tracked files are scanned. Files containing NUL bytes are skipped; git
attributes cannot exempt text files. Matching uses bytes, regardless of locale.

Default exclusions:

```text
**/node_modules/**   **/*.lock              **/CHANGELOG.md
**/vendor/**         **/package-lock.json   **/LICENSE*
**/.claude/**        **/npm-shrinkwrap.json **/CLAUDE.md
**/.cursor/**        **/pnpm-lock.yaml      **/AGENTS.md
                     **/bun.lockb
                     **/go.sum
```

`dash-exclude` adds to these. `dash-exclude-defaults: false` removes them, which is what
this repo runs against itself. Note the list does not cover `README.md` or `*.sh`.

## Local use

Run from the repository being checked:

```bash
/path/to/tools/dashes/scripts/check-dashes.sh origin/main  # fetched base
/path/to/tools/dashes/scripts/check-dashes.sh --staged     # HEAD vs index
/path/to/tools/dashes/scripts/check-dashes.sh --force-zero # tracked working tree
```

For a pre-commit hook, put `exec /path/to/tools/dashes/scripts/check-dashes.sh --staged`
in `.git/hooks/pre-commit` and make it executable. Hooks are bypassable; keep CI.

## Tests

`test/run.sh` builds throwaway repos under `mktemp -d` with `GIT_CONFIG_GLOBAL=/dev/null`
and runs the whole suite twice, once under the ambient locale and once under `LC_ALL=C`,
because a container runner sets no UTF-8 locale and the counts must not move. Fixture
dashes are built from byte escapes so the suite never trips this repo's own gate.
