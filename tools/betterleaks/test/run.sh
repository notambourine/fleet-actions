#!/bin/bash
# Behavior tests for scripts/run-betterleaks.sh. Argument assembly and validation run in
# plan mode, so no case runs a real scan. The pass and fail paths use a stub betterleaks
# on PATH: the real binary lives only in the image.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/scripts/run-betterleaks.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
cases=0

# stub <exit-code> writes a betterleaks that exits as upstream does on a finding.
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

# repo <name> [--shallow] builds a git repo so the history checks read a real clone.
repo() {
	local dir="$TMP/$1"
	mkdir -p "$dir"
	git -C "$dir" init -q 2>/dev/null
	# Two commits, so a --depth 1 clone of it is genuinely shallow.
	for n in 1 2; do
		printf 'x%s\n' "$n" >"$dir/README.md"
		git -C "$dir" add -A 2>/dev/null
		git -C "$dir" -c commit.gpgsign=false -c user.email=t@e -c user.name=t commit -qm "c$n" 2>/dev/null
	done
	printf '%s' "$dir"
}

# run_case <name> <root> <want-rc> <output-substring> [VAR=value ...]
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

# refute_case <name> <root> <substring-that-must-be-absent> [VAR=value ...]
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

run_case "git scan is the default" "$full" 0 "plan: betterleaks git $full"
run_case "dir scan reaches the worktree" "$full" 0 "plan: betterleaks dir $full" BL_SCAN=dir
run_case "path overrides the root" "$full" 0 "plan: betterleaks git $full/.git" BL_PATH="$full/.git"
run_case "redact defaults to full" "$full" 0 "--redact=100"
run_case "redact reaches the args" "$full" 0 "--redact=0" BL_REDACT=0
run_case "confidence high reaches the args" "$full" 0 "--confidence high" BL_CONFIDENCE=high

run_case "unknown scan fails" "$full" 1 "scan must be 'git' or 'dir'" BL_SCAN=history
run_case "unknown confidence fails" "$full" 1 "confidence must be low, medium, or high" BL_CONFIDENCE=paranoid
run_case "out-of-range redact fails" "$full" 1 "redact must be 0-100" BL_REDACT=420

run_case "log-opts narrow a git scan" "$full" 0 "--log-opts=--no-merges a..b" BL_LOG_OPTS="--no-merges a..b"
run_case "pr-range becomes a commit range" "$full" 0 "--log-opts=--no-merges aaa..bbb" \
	BL_PR_RANGE=true BL_PR_BASE=aaa BL_PR_HEAD=bbb
run_case "log-opts beats pr-range" "$full" 0 "--log-opts=--no-merges c..d" \
	BL_LOG_OPTS="--no-merges c..d" BL_PR_RANGE=true BL_PR_BASE=aaa BL_PR_HEAD=bbb
run_case "dir warns and drops log-opts" "$full" 0 "apply to scan: git only" \
	BL_SCAN=dir BL_LOG_OPTS="--no-merges a..b"
refute_case "dir passes no log-opts" "$full" "--log-opts" \
	BL_SCAN=dir BL_LOG_OPTS="--no-merges a..b"

run_case "safe.directory reaches git without HOME" "$full" 0 \
	"git: safe.directory at GIT_CONFIG_KEY_0 of 1"
run_case "a caller's git config entries survive" "$full" 0 \
	"git: safe.directory at GIT_CONFIG_KEY_2 of 3" GIT_CONFIG_COUNT=2

if [ -d "$shallow/.git" ]; then
	run_case "shallow clone fails the git scan" "$shallow" 1 "set fetch-depth: 0"
	run_case "shallow clone still allows dir" "$shallow" 0 "plan: betterleaks dir" BL_SCAN=dir
else
	echo "skip shallow clone cases (clone unavailable)"
fi

# The real exit paths, with a stub standing in for the pinned binary.
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
1:*"betterleaks exited 1"*) echo "ok   a finding fails the job" ;;
*)
	fails=$((fails + 1))
	echo "FAIL a finding fails the job (rc=$rc)"
	printf '%s\n' "$out" | sed 's/^/     /'
	;;
esac

cases=$((cases + 1))
out=$(env BL_ROOT="$full" BL_SCAN=dir BL_BIN=betterleaks-not-here bash "$RUN" 2>&1)
case "$?:$out" in
1:*"not on PATH"*) echo "ok   a missing binary fails the job" ;;
*)
	fails=$((fails + 1))
	echo "FAIL a missing binary fails the job"
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
