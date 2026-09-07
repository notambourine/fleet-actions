# shellcheck shell=bash
# Byte matching works without a UTF-8 locale and tolerates invalid encoding.
export DASH_BYTES='\xe2\x80[\x90-\x95]|\xe2\x88\x92|&(?:mdash|ndash|minus);'
export DASH_MARKER_BYTES='dash-[o]k'

_dash_defaults=(
	'**/node_modules/**'
	'**/vendor/**'
	'**/.claude/**'
	'**/.cursor/**'
	'**/*.lock'
	'**/package-lock.json'
	'**/npm-shrinkwrap.json'
	'**/pnpm-lock.yaml'
	'**/bun.lockb'
	'**/go.sum'
	'**/CHANGELOG.md'
	'**/LICENSE*'
	'**/CLAUDE.md'
	'**/AGENTS.md'
)

DASH_EXCLUDE_DIRS=()
if [ -n "${DASH_EXCLUDE:-}" ]; then
	while IFS= read -r _dash_dir; do
		[ -n "$_dash_dir" ] && DASH_EXCLUDE_DIRS+=("$_dash_dir")
	done <<<"$DASH_EXCLUDE"
	unset _dash_dir
fi

# `.` first, never an empty array: bash 3.2 (macOS) errors on "${empty[@]}" under `set -u`.
# shellcheck disable=SC2034  # out-param: read by the sourcing script
DASH_PATHSPEC=(.)
# glob magic: `**/name` hits every depth including the root, and a directory
# needs the trailing `/**` - the bare prefix matches the dir, not its files.
case "${DASH_EXCLUDE_DEFAULTS:-true}" in
true)
	for _dash_pat in "${_dash_defaults[@]}"; do
		DASH_PATHSPEC+=(":(exclude,glob)${_dash_pat}")
	done
	unset _dash_pat
	;;
false) ;;
*)
	echo "DASH_EXCLUDE_DEFAULTS takes true or false, not '${DASH_EXCLUDE_DEFAULTS}'" >&2
	exit 1
	;;
esac
unset _dash_defaults
if [ "${#DASH_EXCLUDE_DIRS[@]}" -gt 0 ]; then
	for _dash_dir in "${DASH_EXCLUDE_DIRS[@]}"; do
		DASH_PATHSPEC+=(":(exclude)${_dash_dir}")
	done
	unset _dash_dir
fi
