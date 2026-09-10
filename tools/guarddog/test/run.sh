#!/bin/bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/scripts/run-guarddog.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
cases=0

stub() {
	local issues="$1" score="${2:-}" label="${3:-}" dir
	if [ -z "$score" ]; then
		if [ "$issues" -gt 0 ]; then score=8; else score=0; fi
	fi
	if [ -z "$label" ]; then
		if [ "$score" = 0 ]; then label=no_risks_detected; else label=high_risk; fi
	fi
	dir="$TMP/stub-${issues}-${score}"
	mkdir -p "$dir"
	cat >"$dir/guarddog" <<EOF
#!/bin/bash
[ "\$*" = --version ] && { echo 3.2.0; exit 0; }
printf '{"issues": $issues, "risk_score": {"score": $score, "label": "$label"}, "risks": ["planted"]}\n'
[ $issues -gt 0 ] && exit 1
exit 0
EOF
	chmod +x "$dir/guarddog"
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
	out=$(env GD_ROOT="$root" GD_PLAN_ONLY=true GD_STAGE="$TMP" "$@" bash "$RUN" 2>&1)
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
	out=$(env GD_ROOT="$root" GD_PLAN_ONLY=true GD_STAGE="$TMP" "$@" bash "$RUN" 2>&1)
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
wf=$(fixture wf .github/workflows/ci.yml .github/workflows/release.yaml)
poly=$(fixture poly package.json requirements.txt go.mod Cargo.lock Gemfile.lock)
nested=$(fixture nested packages/web/package.json services/api/pyproject.toml)
mixed=$(fixture mixed package.json .github/workflows/ci.yml dist/bundle.min.js)

run_case "accepts no targets" "$empty" 0 "nothing to scan"

run_case "detects npm" "$npm" 0 "plan: guarddog npm scan"
run_case "uses local scan" "$npm" 0 "npm scan --exit-non-zero-on-finding"
refute_case "disables registry verify by default" "$npm" "npm verify"
run_case "verifies workflows by default" "$wf" 0 \
	"github_action verify --exit-non-zero-on-finding --output-format json .github/workflows/ci.yml"
run_case "targets every workflow" "$wf" 0 ".github/workflows/release.yaml"

run_case "requests JSON" "$npm" 0 "--output-format json"

run_case "detects nested manifest" "$nested" 0 "guarddog npm scan" GD_ECOSYSTEMS=npm
run_case "detects pypi" "$nested" 0 "guarddog pypi scan" GD_ECOSYSTEMS=pypi
run_case "detects go" "$poly" 0 "guarddog go scan"
run_case "detects crates" "$poly" 0 "guarddog crates scan"
run_case "detects rubygems" "$poly" 0 "guarddog rubygems scan"
run_case "deduplicates ecosystem scans" "$nested" 0 "1 target(s)" \
	GD_ECOSYSTEMS=npm GD_ACTIONS=false
run_case "selects ecosystem" "$poly" 0 "guarddog npm scan" GD_ECOSYSTEMS=npm
refute_case "excludes unselected ecosystem" "$poly" "guarddog go scan" GD_ECOSYSTEMS=npm
run_case "accepts ecosystem list" "$poly" 0 "guarddog crates scan" GD_ECOSYSTEMS=npm,crates
run_case "rejects unknown ecosystem" "$poly" 1 "unknown ecosystem" GD_ECOSYSTEMS=cocoapods

run_case "disables local scan" "$mixed" 0 "github_action verify" GD_LOCAL_SCAN=false
refute_case "omits disabled local scan" "$mixed" "npm scan" GD_LOCAL_SCAN=false
run_case "disables action scan" "$mixed" 0 "npm scan" GD_ACTIONS=false
refute_case "omits disabled action scan" "$mixed" "github_action" GD_ACTIONS=false
run_case "enables registry verify" "$poly" 0 \
	"guarddog npm verify --exit-non-zero-on-finding" GD_REGISTRY_VERIFY=true
run_case "verifies every manifest" "$nested" 0 \
	"verify --exit-non-zero-on-finding --output-format json packages/web/package.json" \
	GD_REGISTRY_VERIFY=true GD_ECOSYSTEMS=npm
run_case "includes npm dev dependencies" "$npm" 0 \
	"--include-dev-dependencies" GD_REGISTRY_VERIFY=true GD_INCLUDE_DEV=true
refute_case "omits dev flag from local scan" "$npm" \
	"scan --exit-non-zero-on-finding --output-format json --include-dev-dependencies" \
	GD_INCLUDE_DEV=true

installed=$(fixture installed package.json)
mkdir -p "$installed/node_modules/left-pad"
printf '{"name":"left-pad"}\n' >"$installed/node_modules/left-pad/package.json"

run_case "scans untracked path" "$installed" 0 \
	"npm scan --exit-non-zero-on-finding --output-format json node_modules" \
	GD_ACTIONS=false GD_LOCAL_SCAN=false GD_SCAN_PATHS="npm:node_modules"
run_case "uses all ecosystems for bare path" "$installed" 0 \
	"guarddog pypi scan --exit-non-zero-on-finding --output-format json node_modules" \
	GD_ACTIONS=false GD_LOCAL_SCAN=false GD_SCAN_PATHS="node_modules"
run_case "scopes scan path" "$installed" 0 "1 target(s)" \
	GD_ACTIONS=false GD_LOCAL_SCAN=false GD_SCAN_PATHS="npm:node_modules" \
	GD_PLAN_ONLY=false GD_BIN="$(stub 0)/guarddog" PATH="$(stub 0):$PATH"
run_case "rejects missing scan path" "$installed" 1 "points at nothing" \
	GD_SCAN_PATHS="npm:vendor"
run_case "rejects unknown path ecosystem" "$installed" 1 "unknown ecosystem" \
	GD_SCAN_PATHS="cocoapods:node_modules"
run_case "adds scan path target" "$installed" 0 "2 target(s)" \
	GD_ACTIONS=false GD_ECOSYSTEMS=npm GD_SCAN_PATHS="npm:node_modules"

run_case "excludes every manifest" "$npm" 0 "nothing to scan" \
	GD_EXCLUDE_PATHS="package.json"
run_case "excludes subtree glob" "$nested" 0 "nothing to scan" \
	GD_EXCLUDE_PATHS="packages/*
services/*"
run_case "excludes workflow target" "$mixed" 0 "npm scan" \
	GD_EXCLUDE_PATHS=".github/workflows/*"
refute_case "omits excluded workflow" "$mixed" "github_action" \
	GD_EXCLUDE_PATHS=".github/workflows/*"

run_case "applies bare rule exclusion" "$poly" 0 \
	"guarddog npm scan --exit-non-zero-on-finding --output-format json -x typosquatting" \
	GD_EXCLUDE_RULES="typosquatting"
run_case "applies scoped rule exclusion" "$poly" 0 \
	"pypi scan --exit-non-zero-on-finding --output-format json -x repository_integrity_mismatch" \
	GD_EXCLUDE_RULES="pypi:repository_integrity_mismatch"
refute_case "limits scoped rule exclusion" "$poly" \
	"npm scan --exit-non-zero-on-finding --output-format json -x repository_integrity_mismatch" \
	GD_EXCLUDE_RULES="pypi:repository_integrity_mismatch"

verify_stub() {
	local dir="$TMP/verify-stub-$RANDOM" body="" entry name version score
	mkdir -p "$dir"
	for entry in "$@"; do
		IFS='|' read -r name version score <<<"$entry"
		body+="${body:+,}"
		body+="{\"dependency\": \"$name\", \"version\": \"$version\", \"result\":"
		body+=" {\"issues\": 1, \"errors\": {}, \"risk_score\":"
		body+=" {\"score\": $score, \"label\": \"high_risk\"}, \"risks\": [\"planted\"]}}"
	done
	cat >"$dir/guarddog" <<EOF
#!/bin/bash
[ "\$*" = --version ] && { echo 3.2.0; exit 0; }
printf '[$body]\n'
exit 1
EOF
	chmod +x "$dir/guarddog"
	printf '%s' "$dir"
}

one=$(verify_stub "left-pad|1.3.0|8")
two=$(verify_stub "left-pad|1.3.0|8" "colors|1.4.0|9")
scoped=$(verify_stub "@acme/tools|2.0.0|8")
actions=$(verify_stub "actions/checkout|v4|8")

verify_case() {
	local name="$1" stub="$2" want_rc="$3" want_out="$4"
	shift 4
	run_case "$name" "$npm" "$want_rc" "$want_out" GD_PLAN_ONLY=false GD_ACTIONS=false \
		GD_REGISTRY_VERIFY=true GD_LOCAL_SCAN=false GD_ECOSYSTEMS=npm \
		GD_BIN="$stub/guarddog" PATH="$stub:$PATH" "$@"
}

verify_case "fails unlisted package" "$one" 1 "guarddog flagged"
verify_case "allows listed package" "$one" 0 \
	"below the suspicious risk threshold" GD_EXCLUDE_PACKAGES="left-pad"
verify_case "logs package suppression" "$one" 0 "allowlisted: left-pad@1.3.0" \
	GD_EXCLUDE_PACKAGES="left-pad"
verify_case "retains other package findings" "$two" 1 \
	"guarddog flagged" GD_EXCLUDE_PACKAGES="left-pad"
verify_case "rejects unmatched package version" "$one" 1 "guarddog flagged" \
	GD_EXCLUDE_PACKAGES="left-pad@1.2.0"
verify_case "allows matching package version" "$one" 0 "below the suspicious" \
	GD_EXCLUDE_PACKAGES="left-pad@1.3.0"
verify_case "matches npm scope glob" "$scoped" 0 "below the suspicious" \
	GD_EXCLUDE_PACKAGES="@acme/*"
verify_case "parses npm scope" "$scoped" 0 \
	"allowlisted: @acme/tools@2.0.0" GD_EXCLUDE_PACKAGES="@acme/tools"
verify_case "applies package ecosystem" "$one" 0 "below the suspicious" \
	GD_EXCLUDE_PACKAGES="npm:left-pad"
verify_case "limits package ecosystem" "$one" 1 "guarddog flagged" \
	GD_EXCLUDE_PACKAGES="pypi:left-pad"
verify_case "rejects unknown package scope" "$one" 1 "unknown scope" \
	GD_EXCLUDE_PACKAGES="cocoapods:left-pad"

run_case "allows github_action scope" "$wf" 0 "allowlisted: actions/checkout@v4" \
	GD_PLAN_ONLY=false GD_LOCAL_SCAN=false GD_BIN="$actions/guarddog" \
	PATH="$actions:$PATH" GD_EXCLUDE_PACKAGES="github_action:actions/checkout"

local_finding=$(stub 3)
run_case "ignores package list for local scan" "$npm" 1 "guarddog flagged" \
	GD_PLAN_ONLY=false GD_ACTIONS=false GD_BIN="$local_finding/guarddog" \
	PATH="$local_finding:$PATH" GD_EXCLUDE_PACKAGES="left-pad"

run_case "enables sandbox by default" "$npm" 0 "scan --exit-non-zero-on-finding --output-format json"
run_case "disables sandbox" "$npm" 0 "--no-sandbox" GD_SANDBOX=false

clean=$(stub 0)
finding=$(stub 3)
low=$(stub 3 4.3 low)
run_case "clean scan passes" "$npm" 0 "below the suspicious risk threshold" \
	GD_PLAN_ONLY=false GD_ACTIONS=false GD_BIN="$clean/guarddog" PATH="$clean:$PATH"
run_case "fails on finding" "$npm" 1 "guarddog flagged 1 of 1 target(s)" \
	GD_PLAN_ONLY=false GD_ACTIONS=false GD_BIN="$finding/guarddog" PATH="$finding:$PATH"
run_case "logs finding count" "$npm" 1 "issues: 3" \
	GD_PLAN_ONLY=false GD_ACTIONS=false GD_BIN="$finding/guarddog" PATH="$finding:$PATH"
run_case "passes low risk by default" "$npm" 0 "risk: low (4.3)" \
	GD_PLAN_ONLY=false GD_ACTIONS=false GD_BIN="$low/guarddog" PATH="$low:$PATH"
run_case "fails low risk at low threshold" "$npm" 1 "guarddog flagged" \
	GD_PLAN_ONLY=false GD_ACTIONS=false GD_MINIMUM_RISK=low \
	GD_BIN="$low/guarddog" PATH="$low:$PATH"
run_case "rejects unknown risk threshold" "$npm" 1 "unknown minimum risk" \
	GD_MINIMUM_RISK=medium
run_case "rejects missing binary" "$npm" 1 "not on PATH" \
	GD_PLAN_ONLY=false GD_BIN="$TMP/nope/guarddog"

silent="$TMP/stub-silent"
mkdir -p "$silent"
cat >"$silent/guarddog" <<'EOF'
#!/bin/bash
[ "$*" = --version ] && { echo 3.2.0; exit 0; }
printf '{"issues": 7, "risk_score": {"score": 8, "label": "high_risk"}, "risks": ["planted"]}\n'
exit 0
EOF
chmod +x "$silent/guarddog"
run_case "fails report despite zero exit" "$npm" 1 "guarddog flagged" \
	GD_PLAN_ONLY=false GD_ACTIONS=false GD_BIN="$silent/guarddog" PATH="$silent:$PATH"

cases=$((cases + 1))
probe="$TMP/stub-probe"
mkdir -p "$probe"
cat >"$probe/guarddog" <<EOF
#!/bin/bash
[ "\$*" = --version ] && { echo 3.2.0; exit 0; }
for a; do :; done
find "\$a" -type f | sed "s|^\$a/||" | sort > $TMP/staged.txt
printf '{"issues": 0}\n'
EOF
chmod +x "$probe/guarddog"
env GD_ROOT="$mixed" GD_STAGE="$TMP" GD_ACTIONS=false GD_EXCLUDE_PATHS="dist/*" \
	GD_BIN="$probe/guarddog" PATH="$probe:$PATH" bash "$RUN" >/dev/null 2>&1
staged=$(tr '\n' ' ' <"$TMP/staged.txt" 2>/dev/null)
case "$staged" in
*"dist/bundle.min.js"*)
	fails=$((fails + 1))
	echo "FAIL excludes staged path (got: $staged)"
	;;
*"package.json"*) echo "ok   stages included paths" ;;
*)
	fails=$((fails + 1))
	echo "FAIL stages included paths (got: $staged)"
	;;
esac

echo
echo "${cases} cases, ${fails} failed"
[ "$fails" -eq 0 ]
