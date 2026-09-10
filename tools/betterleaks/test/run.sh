#!/bin/bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/scripts/run-betterleaks.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
cases=0

stub() {
	local rc="$1" dir="$TMP/stub-$1"
	mkdir -p "$dir"
	cat >"$dir/betterleaks" <<EOF
#!/bin/bash
echo "stub betterleaks: \$*"
exit $rc
EOF
	chmod +x "$dir/betterleaks"
	printf '%s' "$dir"
}

repo() {
	local dir="$TMP/$1"
	mkdir -p "$dir"
	git -C "$dir" init -q 2>/dev/null
	for n in 1 2; do
		printf 'x%s\n' "$n" >"$dir/README.md"
		git -C "$dir" add -A 2>/dev/null
		git -C "$dir" -c commit.gpgsign=false -c user.email=t@e -c user.name=t commit -qm "c$n" 2>/dev/null
	done
	printf '%s' "$dir"
}

run_case() {
	local name="$1" root="$2" want_rc="$3" want_out="$4" out rc ok=1
	shift 4
	cases=$((cases + 1))
	out=$(env -u GIT_CONFIG_COUNT BL_ROOT="$root" BL_PLAN_ONLY=true "$@" bash "$RUN" 2>&1)
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

refute_case() {
	local name="$1" root="$2" reject="$3" out
	shift 3
	cases=$((cases + 1))
	out=$(env -u GIT_CONFIG_COUNT BL_ROOT="$root" BL_PLAN_ONLY=true "$@" bash "$RUN" 2>&1)
	case "$out" in
	*"$reject"*)
		fails=$((fails + 1))
		echo "FAIL ${name} (output must not contain '${reject}')"
		printf '%s\n' "$out" | sed 's/^/     /'
		;;
	*) echo "ok   ${name}" ;;
	esac
}

full=$(repo full)
shallow="$TMP/shallow"
git clone -q --depth 1 "file://$full" "$shallow" 2>/dev/null

run_case "defaults to git scan" "$full" 0 "plan: betterleaks git $full"
run_case "scans directory" "$full" 0 "plan: betterleaks dir $full" BL_SCAN=dir
run_case "uses path override" "$full" 0 "plan: betterleaks git $full/.git" BL_PATH="$full/.git"
run_case "defaults to full redaction" "$full" 0 "--redact=100"
run_case "sets redaction" "$full" 0 "--redact=0" BL_REDACT=0
run_case "sets confidence" "$full" 0 "--confidence high" BL_CONFIDENCE=high

run_case "rejects unknown scan" "$full" 1 "scan must be 'git' or 'dir'" BL_SCAN=history
run_case "rejects unknown confidence" "$full" 1 "confidence must be low, medium, or high" BL_CONFIDENCE=paranoid
run_case "rejects invalid redaction" "$full" 1 "redact must be 0-100" BL_REDACT=420

run_case "sets log options" "$full" 0 "--log-opts=--no-merges a..b" BL_LOG_OPTS="--no-merges a..b"
run_case "builds pull-request range" "$full" 0 "--log-opts=--no-merges aaa..bbb" \
	BL_PR_RANGE=true BL_PR_BASE=aaa BL_PR_HEAD=bbb
run_case "prefers log options" "$full" 0 "--log-opts=--no-merges c..d" \
	BL_LOG_OPTS="--no-merges c..d" BL_PR_RANGE=true BL_PR_BASE=aaa BL_PR_HEAD=bbb
run_case "warns on directory log options" "$full" 0 "apply to scan: git only" \
	BL_SCAN=dir BL_LOG_OPTS="--no-merges a..b"
refute_case "drops directory log options" "$full" "--log-opts" \
	BL_SCAN=dir BL_LOG_OPTS="--no-merges a..b"

run_case "sets safe.directory" "$full" 0 \
	"git: safe.directory at GIT_CONFIG_KEY_0 of 1"
run_case "preserves git config entries" "$full" 0 \
	"git: safe.directory at GIT_CONFIG_KEY_2 of 3" GIT_CONFIG_COUNT=2

if [ -d "$shallow/.git" ]; then
	run_case "rejects shallow git scan" "$shallow" 1 "set fetch-depth: 0"
	run_case "allows shallow directory scan" "$shallow" 0 "plan: betterleaks dir" BL_SCAN=dir
else
	echo "skip shallow clone cases (clone unavailable)"
fi

cases=$((cases + 1))
if out=$(PATH="$(stub 0):$PATH" env BL_ROOT="$full" BL_SCAN=dir bash "$RUN" 2>&1); then
	echo "ok   clean scan passes"
else
	fails=$((fails + 1))
	echo "FAIL clean scan passes"
	printf '%s\n' "$out" | sed 's/^/     /'
fi

cases=$((cases + 1))
out=$(PATH="$(stub 1):$PATH" env BL_ROOT="$full" BL_SCAN=dir bash "$RUN" 2>&1)
rc=$?
case "$rc:$out" in
1:*"betterleaks failed (exit 1)"*) echo "ok   fails on finding" ;;
*)
	fails=$((fails + 1))
	echo "FAIL fails on finding (rc=$rc)"
	printf '%s\n' "$out" | sed 's/^/     /'
	;;
esac

cases=$((cases + 1))
out=$(env BL_ROOT="$full" BL_SCAN=dir BL_BIN=betterleaks-not-here bash "$RUN" 2>&1)
case "$?:$out" in
1:*"not on PATH"*) echo "ok   rejects missing binary" ;;
*)
	fails=$((fails + 1))
	echo "FAIL rejects missing binary"
	printf '%s\n' "$out" | sed 's/^/     /'
	;;
esac

if command -v shellcheck >/dev/null 2>&1; then
	cases=$((cases + 1))
	if shellcheck -s bash "$RUN"; then echo "ok   shellcheck clean"; else
		fails=$((fails + 1))
		echo "FAIL shellcheck clean"
	fi
fi

echo "${cases} cases, ${fails} failures"
[ "$fails" -eq 0 ]
