#!/bin/bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/scripts/run-vet.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
cases=0

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

run_case "accepts no manifest" "$empty" 0 "nothing to scan"
run_case "detects package.json" "$npm" 0 "plan: vet scan --no-banner -D ."
run_case "detects nested manifest" "$nested" 0 "plan: vet scan"
run_case "detects go.mod" "$(fixture go go.mod)" 0 "plan: vet scan"
run_case "detects lockfile" "$(fixture lock pnpm-lock.yaml)" 0 "plan: vet scan"
run_case "detects supported ecosystems" "$poly" 0 "plan: vet scan"

run_case "enables filter failure" "$npm" 0 "--filter-fail"
run_case "queries malware by default" "$npm" 0 "--malware-query"

run_case "high covers critical" "$npm" 0 \
	"vulns.critical.exists(p, true) || vulns.high.exists(p, true)"
refute_case "high stays off medium" "$npm" "vulns.medium"
run_case "limits critical threshold" "$npm" 0 "vulns.critical.exists(p, true)" \
	VET_SEVERITY=critical
refute_case "critical stays off high" "$npm" "vulns.high" VET_SEVERITY=critical
run_case "includes medium threshold" "$npm" 0 "vulns.medium.exists(p, true)" VET_SEVERITY=medium
run_case "includes low threshold" "$npm" 0 "vulns.low.exists(p, true)" VET_SEVERITY=low
run_case "rejects unknown severity" "$npm" 1 "unknown severity" VET_SEVERITY=moderate

run_case "adds malware filter" "$npm" 0 'vulns.all.exists(v, v.id.startsWith("MAL-"))'
refute_case "disables malware filter" "$npm" "MAL-" VET_MALWARE=false
refute_case "disables malware query" "$npm" "--malware-query" \
	VET_MALWARE=false
run_case "checks malware at none severity" "$npm" 0 "MAL-" VET_SEVERITY=none
refute_case "omits advisories at none severity" "$npm" "vulns.critical" \
	VET_SEVERITY=none
run_case "rejects disabled gates" "$npm" 1 \
	"nothing to gate on" VET_SEVERITY=none VET_MALWARE=false

policy="$npm/.github/vet-policy.yml"
mkdir -p "$(dirname "$policy")"
printf 'name: caller\nfilters: []\n' >"$policy"
run_case "uses custom policy" "$npm" 0 \
	"--filter-suite .github/vet-policy.yml" VET_POLICY=.github/vet-policy.yml
refute_case "omits generated advisory filter" "$npm" "vulns.critical" \
	VET_POLICY=.github/vet-policy.yml
refute_case "omits generated malware query" "$npm" "--malware-query" \
	VET_POLICY=.github/vet-policy.yml
run_case "rejects missing policy" "$npm" 1 "is not a file" \
	VET_POLICY=.github/missing.yml

run_case "sets exclusion" "$npm" 0 "--exclude test/*" VET_EXCLUDE="test/*"
run_case "sets every exclusion" "$npm" 0 "--exclude vendor/*" VET_EXCLUDE="test/*
vendor/*"

clean=$(stub 0)
finding=$(stub 1)
run_case "passes clean scan" "$npm" 0 "no dependency matched" \
	VET_PLAN_ONLY=false VET_BIN="$clean/vet" PATH="$clean:$PATH"
run_case "fails on finding" "$npm" 1 "vet failed (exit 1)" \
	VET_PLAN_ONLY=false VET_BIN="$finding/vet" PATH="$finding:$PATH"
run_case "rejects missing binary" "$npm" 1 "not on PATH" \
	VET_PLAN_ONLY=false VET_BIN="$TMP/nope/vet"

probe="$TMP/probe"
mkdir -p "$probe"
cat >"$probe/vet" <<'EOF'
#!/bin/bash
echo "community=${VET_COMMUNITY_MODE:-unset} key=${VET_API_KEY:-unset} tenant=${VET_CONTROL_TOWER_TENANT_ID:-unset}"
EOF
chmod +x "$probe/vet"

probe_case() {
	local name="$1" want="$2" out
	shift 2
	cases=$((cases + 1))
	out=$(env VET_ROOT="$npm" VET_STAGE="$TMP" VET_BIN="$probe/vet" PATH="$probe:$PATH" \
		"$@" bash "$RUN" 2>&1)
	case "$out" in
	*"$want"*) echo "ok   ${name}" ;;
	*)
		fails=$((fails + 1))
		echo "FAIL ${name} (output must contain '${want}')"
		printf '%s\n' "$out" | sed 's/^/     /'
		;;
	esac
}

probe_case "enables community mode" "community=true key=unset tenant=unset"
probe_case "authenticates with a cloud key" "community=false key=stub-key tenant=acme.example" \
	VET_CLOUD_KEY=stub-key VET_CLOUD_TENANT=acme.example
run_case "rejects a cloud key without a tenant" "$npm" 1 "needs cloud-tenant" \
	VET_CLOUD_KEY=stub-key
run_case "rejects a tenant without a cloud key" "$npm" 1 "needs a cloud key" \
	VET_CLOUD_TENANT=acme.example

echo
echo "${cases} cases, ${fails} failed"
[ "$fails" -eq 0 ]
