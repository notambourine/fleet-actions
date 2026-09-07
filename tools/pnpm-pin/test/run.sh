#!/bin/bash
# Behavior tests for scripts/check-package-manager.sh. Each case writes a
# package.json into a throwaway directory and asserts the exit code plus one
# output substring. No git repo is needed: the check reads one file.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-package-manager.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
cases=0

# run_case <name> <manifest-or-NONE> <want-rc> <output-substring>
run_case() {
	local name="$1" manifest="$2" want_rc="$3" want_out="$4" dir out rc ok=1
	cases=$((cases + 1))
	dir="$TMP/case-$cases"
	mkdir -p "$dir"
	if [ "$manifest" != NONE ]; then
		printf '%s\n' "$manifest" >"$dir/package.json"
	fi
	out=$("$CHECK" "$dir" 2>&1)
	rc=$?
	[ "$rc" -eq "$want_rc" ] || ok=0
	case "$out" in *"$want_out"*) ;; *) ok=0 ;; esac
	if [ "$ok" -eq 1 ]; then
		echo "ok   ${name}"
	else
		fails=$((fails + 1))
		echo "FAIL ${name} (rc=${rc} want=${want_rc}, output must contain '${want_out}')"
		printf '%s\n' "$out" | sed 's/^/     /'
	fi
}

run_case "no package.json passes" NONE 0 "nothing to assert"
run_case "missing packageManager fails" '{"name":"x"}' 1 "declares no packageManager"
run_case "empty packageManager fails" '{"packageManager":""}' 1 "declares no packageManager"
run_case "bare name fails" '{"packageManager":"pnpm"}' 1 "must pin an exact version"
run_case "range fails" '{"packageManager":"pnpm@^10.0.0"}' 1 "must pin an exact version"
run_case "major only fails" '{"packageManager":"pnpm@10"}' 1 "must pin an exact version"
run_case "minor only fails" '{"packageManager":"pnpm@10.4"}' 1 "must pin an exact version"
run_case "latest tag fails" '{"packageManager":"pnpm@latest"}' 1 "must pin an exact version"
run_case "exact version passes" '{"packageManager":"pnpm@10.4.1"}' 0 "packageManager: pnpm@10.4.1"
run_case "corepack hash passes" \
	'{"packageManager":"pnpm@10.4.1+sha512.abc"}' 0 "packageManager: pnpm@10.4.1+sha512.abc"
run_case "prerelease passes" '{"packageManager":"pnpm@10.4.1-rc.1"}' 0 "packageManager: pnpm@10.4.1-rc.1"
run_case "npm passes" '{"packageManager":"npm@11.0.0"}' 0 "packageManager: npm@11.0.0"
run_case "yarn passes" '{"packageManager":"yarn@4.6.0"}' 0 "packageManager: yarn@4.6.0"

# A manifest jq cannot parse must not read as a pass.
cases=$((cases + 1))
dir="$TMP/broken"
mkdir -p "$dir"
printf '{"packageManager": \n' >"$dir/package.json"
if "$CHECK" "$dir" >/dev/null 2>&1; then
	fails=$((fails + 1))
	echo "FAIL unparseable package.json must not pass"
else
	echo "ok   unparseable package.json fails"
fi

echo
echo "${cases} cases, ${fails} failed"
[ "$fails" -eq 0 ]
