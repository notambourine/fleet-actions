#!/bin/bash
# Behavior tests for scripts/run-vet.sh. Suite assembly and argument order run in plan
# mode, so no case reaches SafeDep's API. The pass and fail paths use a stub vet on PATH:
# the real one needs the network, and the planted finding has to be one this suite owns.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/scripts/run-vet.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
cases=0

# stub <exit-code> writes a vet that exits as upstream does on a --filter-fail match.
stub() {
	local rc="$1" dir="$TMP/stub-$1"
	mkdir -p "$dir"
	cat >"$dir/vet" <<EOF
#!/bin/bash
echo "stub vet: \$*"
exit $rc
EOF
	chmod +x "$dir/vet"
	printf '%s' "$dir"
}

# fixture <name> <file>... builds a git repo holding those files, so detection reads an
# index like it does in CI.
fixture() {
	local dir="$TMP/$1" f
	shift
	mkdir -p "$dir"
	for f in "$@"; do
		mkdir -p "$dir/$(dirname "$f")"
		printf 'x\n' >"$dir/$f"
	done
	git -C "$dir" init -q 2>/dev/null
	git -C "$dir" add -A 2>/dev/null
	printf '%s' "$dir"
}

# run_case <name> <root> <want-rc> <output-substring> [VAR=value ...]
run_case() {
	local name="$1" root="$2" want_rc="$3" want_out="$4" out rc ok=1
	shift 4
	cases=$((cases + 1))
	out=$(env VET_ROOT="$root" VET_PLAN_ONLY=true VET_STAGE="$TMP" "$@" bash "$RUN" 2>&1)
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
	out=$(env VET_ROOT="$root" VET_PLAN_ONLY=true VET_STAGE="$TMP" "$@" bash "$RUN" 2>&1)
	case "$out" in
	*"$reject"*)
		fails=$((fails + 1))
		echo "FAIL ${name} (output must not contain '${reject}')"
		printf '%s\n' "$out" | sed 's/^/     /'
		;;
	*) echo "ok   ${name}" ;;
	esac
}

empty=$(fixture empty README.md)
npm=$(fixture npm package.json index.js)
nested=$(fixture nested services/api/pyproject.toml)
poly=$(fixture poly go.mod Cargo.lock Gemfile.lock pom.xml composer.json)

run_case "no manifest is not a finding" "$empty" 0 "nothing to scan"
run_case "package.json is a scan" "$npm" 0 "plan: vet scan --no-banner -D ."
run_case "a nested manifest counts" "$nested" 0 "plan: vet scan"
run_case "go.mod counts" "$(fixture go go.mod)" 0 "plan: vet scan"
run_case "a lockfile alone counts" "$(fixture lock pnpm-lock.yaml)" 0 "plan: vet scan"
run_case "every ecosystem vet reads is detected" "$poly" 0 "plan: vet scan"

# --filter-fail is the whole gate: without it vet reports a match and exits 0.
run_case "the scan fails the job on a match" "$npm" 0 "--filter-fail"
run_case "the malware database is queried by default" "$npm" 0 "--malware-query"

# Severity is cumulative, so the threshold names the floor and nothing below it.
run_case "high covers critical" "$npm" 0 \
	"vulns.critical.exists(p, true) || vulns.high.exists(p, true)"
refute_case "high stays off medium" "$npm" "vulns.medium"
run_case "critical is critical alone" "$npm" 0 "vulns.critical.exists(p, true)" \
	VET_SEVERITY=critical
refute_case "critical stays off high" "$npm" "vulns.high" VET_SEVERITY=critical
run_case "medium reaches medium" "$npm" 0 "vulns.medium.exists(p, true)" VET_SEVERITY=medium
run_case "low reaches low" "$npm" 0 "vulns.low.exists(p, true)" VET_SEVERITY=low
run_case "an unknown severity fails" "$npm" 1 "unknown severity" VET_SEVERITY=moderate

run_case "malware is its own filter" "$npm" 0 'vulns.all.exists(v, v.id.startsWith("MAL-"))'
refute_case "malware can be turned off" "$npm" "MAL-" VET_MALWARE=false
refute_case "turning off malware drops the database query" "$npm" "--malware-query" \
	VET_MALWARE=false
run_case "severity none gates on malware alone" "$npm" 0 "MAL-" VET_SEVERITY=none
refute_case "severity none drops the vulnerability filter" "$npm" "vulns.critical" \
	VET_SEVERITY=none
run_case "severity none with malware off is an error, not a silent pass" "$npm" 1 \
	"nothing to gate on" VET_SEVERITY=none VET_MALWARE=false

# A caller's suite owns the whole decision, so the generated filters must not survive.
policy="$npm/.github/vet-policy.yml"
mkdir -p "$(dirname "$policy")"
printf 'name: caller\nfilters: []\n' >"$policy"
run_case "a caller policy replaces the suite" "$npm" 0 \
	"--filter-suite .github/vet-policy.yml" VET_POLICY=.github/vet-policy.yml
refute_case "a caller policy drops the generated filters" "$npm" "vulns.critical" \
	VET_POLICY=.github/vet-policy.yml
refute_case "a caller policy owns the malware decision too" "$npm" "--malware-query" \
	VET_POLICY=.github/vet-policy.yml
run_case "a policy pointing at nothing fails" "$npm" 1 "is not a file" \
	VET_POLICY=.github/missing.yml

run_case "an exclusion reaches vet" "$npm" 0 "--exclude test/*" VET_EXCLUDE="test/*"
run_case "every exclusion reaches vet" "$npm" 0 "--exclude vendor/*" VET_EXCLUDE="test/*
vendor/*"

# The two paths that matter.
clean=$(stub 0)
finding=$(stub 1)
run_case "a clean scan passes" "$npm" 0 "no dependency matched" \
	VET_PLAN_ONLY=false VET_BIN="$clean/vet" PATH="$clean:$PATH"
run_case "a planted finding fails the job" "$npm" 1 "vet exited 1" \
	VET_PLAN_ONLY=false VET_BIN="$finding/vet" PATH="$finding:$PATH"
run_case "a missing binary is an error, not a pass" "$npm" 1 "not on PATH" \
	VET_PLAN_ONLY=false VET_BIN="$TMP/nope/vet"

# Keyless insights access. Without it vet expects an API key and the scan errors.
cases=$((cases + 1))
probe="$TMP/probe"
mkdir -p "$probe"
cat >"$probe/vet" <<'EOF'
#!/bin/bash
echo "community=${VET_COMMUNITY_MODE:-unset}"
EOF
chmod +x "$probe/vet"
out=$(env VET_ROOT="$npm" VET_STAGE="$TMP" VET_BIN="$probe/vet" PATH="$probe:$PATH" \
	bash "$RUN" 2>&1)
case "$out" in
*"community=true"*) echo "ok   community mode reaches the scan" ;;
*)
	fails=$((fails + 1))
	echo "FAIL community mode must reach the scan"
	printf '%s\n' "$out" | sed 's/^/     /'
	;;
esac

echo
echo "${cases} cases, ${fails} failed"
[ "$fails" -eq 0 ]
