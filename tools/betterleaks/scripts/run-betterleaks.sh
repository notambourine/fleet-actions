#!/usr/bin/env bash
# Run betterleaks over the checkout and fail the job on a finding.
#
# The image pin freezes the engine and its ruleset. A rule published today does not fail
# a PR today, which is the cost of trading `latest` for a digest Dependabot rewrites.
set -uo pipefail

BL_BIN="${BL_BIN:-betterleaks}"
BL_ROOT="${BL_ROOT:-${GITHUB_WORKSPACE:-$PWD}}"
BL_SCAN="${BL_SCAN:-git}"
BL_PATH="${BL_PATH:-}"
BL_CONFIDENCE="${BL_CONFIDENCE:-medium}"
BL_REDACT="${BL_REDACT:-100}"
BL_LOG_OPTS="${BL_LOG_OPTS:-}"
BL_PR_RANGE="${BL_PR_RANGE:-false}"
BL_PR_BASE="${BL_PR_BASE:-}"
BL_PR_HEAD="${BL_PR_HEAD:-}"
BL_PLAN_ONLY="${BL_PLAN_ONLY:-false}"

fail() {
	printf '::error::%s\n' "$1" >&2
	exit 1
}

target="${BL_PATH:-$BL_ROOT}"

case "$BL_SCAN" in
git | dir) ;;
*) fail "scan must be 'git' or 'dir' (got '$BL_SCAN')" ;;
esac
[[ "$BL_CONFIDENCE" =~ ^(low|medium|high)$ ]] ||
	fail "confidence must be low, medium, or high (got '$BL_CONFIDENCE')"
[[ "$BL_REDACT" =~ ^(100|[0-9]{1,2})$ ]] ||
	fail "redact must be 0-100 (got '$BL_REDACT')"

# The action overrides HOME, so the image's baked safe.directory never loads and git
# calls the mounted workspace dubiously owned. GIT_CONFIG_* does not depend on HOME.
git_index="${GIT_CONFIG_COUNT:-0}"
export "GIT_CONFIG_KEY_${git_index}=safe.directory"
export "GIT_CONFIG_VALUE_${git_index}=*"
export GIT_CONFIG_COUNT=$((git_index + 1))

log_opts="$BL_LOG_OPTS"
if [ -z "$log_opts" ] && [ "$BL_PR_RANGE" = true ] && [ -n "$BL_PR_BASE" ]; then
	log_opts="--no-merges ${BL_PR_BASE}..${BL_PR_HEAD}"
fi

if [ "$BL_SCAN" = git ]; then
	[ -d "$target" ] || fail "path '$target' is not a directory"
	if [ "$(git -C "$target" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
		fail "scan: git reads commit history; set fetch-depth: 0 on actions/checkout"
	fi
elif [ -n "$log_opts" ]; then
	printf '::warning::log-opts and pr-range apply to scan: git only; ignored\n'
	log_opts=""
fi

# Do not send candidate secrets to vendor validation APIs.
args=("$BL_SCAN" "$target" --no-banner "--redact=$BL_REDACT" --confidence "$BL_CONFIDENCE")
if [ -n "$log_opts" ]; then
	args+=("--log-opts=$log_opts")
fi

if [ "$BL_PLAN_ONLY" = true ]; then
	printf 'plan: %s %s\n' "$BL_BIN" "${args[*]}"
	printf 'git: safe.directory at GIT_CONFIG_KEY_%s of %s\n' "$git_index" "$GIT_CONFIG_COUNT"
	exit 0
fi

command -v "$BL_BIN" >/dev/null 2>&1 || fail "betterleaks binary '$BL_BIN' not on PATH"

"$BL_BIN" "${args[@]}"
rc=$?

# betterleaks exits non-zero for a finding and for a scan it could not complete. Neither
# is a pass, and the log above says which one happened.
[ "$rc" -eq 0 ] || fail "betterleaks exited $rc: a finding, or a scan that did not complete"
