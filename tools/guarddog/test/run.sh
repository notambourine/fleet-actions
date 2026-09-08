#!/bin/bash
# Behavior tests for scripts/run-guarddog.sh. Detection and argument assembly run in
# plan mode, so no case reaches a registry. The pass and fail paths use a stub guarddog
# on PATH: the real one downloads packages, and the planted finding has to be a finding
# this suite controls.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/scripts/run-guarddog.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
cases=0

# stub <issues> [score] [label] writes a guarddog result, exiting as upstream does.
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

# refute_case <name> <root> <substring-that-must-be-absent> [VAR=value ...]
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

run_case "no manifest and no workflow is not a finding" "$empty" 0 "nothing to scan"

# Default posture: offline local scan plus the workflow gate, no registry traffic.
run_case "package.json selects a local npm scan" "$npm" 0 "plan: guarddog npm scan"
run_case "the local scan is offline, never verify" "$npm" 0 "npm scan --exit-non-zero-on-finding"
refute_case "registry verify is off by default" "$npm" "npm verify"
run_case "workflows are verified by default" "$wf" 0 \
	"github_action verify --exit-non-zero-on-finding --output-format json .github/workflows/ci.yml"
run_case "every workflow is a target" "$wf" 0 ".github/workflows/release.yaml"

# json is what makes --exit-non-zero-on-finding fire upstream.
run_case "every invocation asks for json" "$npm" 0 "--output-format json"

run_case "a nested manifest counts" "$nested" 0 "guarddog npm scan" GD_ECOSYSTEMS=npm
run_case "pyproject.toml selects pypi" "$nested" 0 "guarddog pypi scan" GD_ECOSYSTEMS=pypi
run_case "go.mod selects go" "$poly" 0 "guarddog go scan"
run_case "Cargo.lock selects crates" "$poly" 0 "guarddog crates scan"
run_case "Gemfile.lock selects rubygems" "$poly" 0 "guarddog rubygems scan"
run_case "one scan per ecosystem, not per manifest" "$nested" 0 "1 target(s)" \
	GD_ECOSYSTEMS=npm GD_ACTIONS=false
run_case "explicit ecosystem list narrows the scan" "$poly" 0 "guarddog npm scan" GD_ECOSYSTEMS=npm
refute_case "explicit ecosystem list excludes the rest" "$poly" "guarddog go scan" GD_ECOSYSTEMS=npm
run_case "comma-separated list is accepted" "$poly" 0 "guarddog crates scan" GD_ECOSYSTEMS=npm,crates
run_case "unknown ecosystem fails" "$poly" 1 "unknown ecosystem" GD_ECOSYSTEMS=cocoapods

run_case "local scan can be turned off" "$mixed" 0 "github_action verify" GD_LOCAL_SCAN=false
refute_case "turning off the local scan drops it" "$mixed" "npm scan" GD_LOCAL_SCAN=false
run_case "actions gate can be turned off" "$mixed" 0 "npm scan" GD_ACTIONS=false
refute_case "turning off the actions gate drops it" "$mixed" "github_action" GD_ACTIONS=false
run_case "registry verify is opt-in" "$poly" 0 \
	"guarddog npm verify --exit-non-zero-on-finding" GD_REGISTRY_VERIFY=true
run_case "registry verify reads every manifest" "$nested" 0 \
	"verify --exit-non-zero-on-finding --output-format json packages/web/package.json" \
	GD_REGISTRY_VERIFY=true GD_ECOSYSTEMS=npm
run_case "include-dev-dependencies reaches npm verify" "$npm" 0 \
	"--include-dev-dependencies" GD_REGISTRY_VERIFY=true GD_INCLUDE_DEV=true
refute_case "include-dev-dependencies stays off a local scan" "$npm" \
	"scan --exit-non-zero-on-finding --output-format json --include-dev-dependencies" \
	GD_INCLUDE_DEV=true

# scan-paths is the chained post-install case: node_modules is untracked, so nothing
# else in this script can see it.
installed=$(fixture installed package.json)
mkdir -p "$installed/node_modules/left-pad"
printf '{"name":"left-pad"}\n' >"$installed/node_modules/left-pad/package.json"

run_case "scan-paths reaches an untracked directory" "$installed" 0 \
	"npm scan --exit-non-zero-on-finding --output-format json node_modules" \
	GD_ACTIONS=false GD_LOCAL_SCAN=false GD_SCAN_PATHS="npm:node_modules"
run_case "a bare scan-path runs every selected ecosystem" "$installed" 0 \
	"guarddog pypi scan --exit-non-zero-on-finding --output-format json node_modules" \
	GD_ACTIONS=false GD_LOCAL_SCAN=false GD_SCAN_PATHS="node_modules"
run_case "a scoped scan-path stays on its ecosystem" "$installed" 0 "1 target(s)" \
	GD_ACTIONS=false GD_LOCAL_SCAN=false GD_SCAN_PATHS="npm:node_modules" \
	GD_PLAN_ONLY=false GD_BIN="$(stub 0)/guarddog" PATH="$(stub 0):$PATH"
run_case "scan-paths pointing at nothing fails" "$installed" 1 "points at nothing" \
	GD_SCAN_PATHS="npm:vendor"
run_case "scan-paths with an unknown ecosystem fails" "$installed" 1 "unknown ecosystem" \
	GD_SCAN_PATHS="cocoapods:node_modules"
run_case "scan-paths adds to the tracked-tree scan" "$installed" 0 "2 target(s)" \
	GD_ACTIONS=false GD_ECOSYSTEMS=npm GD_SCAN_PATHS="npm:node_modules"

# The path allowlist upstream does not have.
run_case "excluding every manifest leaves nothing to scan" "$npm" 0 "nothing to scan" \
	GD_EXCLUDE_PATHS="package.json"
run_case "a subtree glob excludes the subtree" "$nested" 0 "nothing to scan" \
	GD_EXCLUDE_PATHS="packages/*
services/*"
run_case "excluding a workflow drops its target" "$mixed" 0 "npm scan" \
	GD_EXCLUDE_PATHS=".github/workflows/*"
refute_case "an excluded workflow is not verified" "$mixed" "github_action" \
	GD_EXCLUDE_PATHS=".github/workflows/*"

run_case "bare exclude-rule reaches every ecosystem" "$poly" 0 \
	"guarddog npm scan --exit-non-zero-on-finding --output-format json -x typosquatting" \
	GD_EXCLUDE_RULES="typosquatting"
run_case "scoped exclude-rule reaches its ecosystem" "$poly" 0 \
	"pypi scan --exit-non-zero-on-finding --output-format json -x repository_integrity_mismatch" \
	GD_EXCLUDE_RULES="pypi:repository_integrity_mismatch"
refute_case "scoped exclude-rule stays out of the others" "$poly" \
	"npm scan --exit-non-zero-on-finding --output-format json -x repository_integrity_mismatch" \
	GD_EXCLUDE_RULES="pypi:repository_integrity_mismatch"

# The package allowlist upstream does not have. verify_stub <entry>... emits a
# verify-shaped report, one array element per `name|version|score` triple.
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

verify_case "an unlisted package still fails" "$one" 1 "guarddog flagged"
verify_case "an allowlisted package stops failing the job" "$one" 0 \
	"below the suspicious risk threshold" GD_EXCLUDE_PACKAGES="left-pad"
verify_case "the suppression reaches the log" "$one" 0 "allowlisted: left-pad@1.3.0" \
	GD_EXCLUDE_PACKAGES="left-pad"
verify_case "an allowlist entry does not cover the rest of the report" "$two" 1 \
	"guarddog flagged" GD_EXCLUDE_PACKAGES="left-pad"
verify_case "a version pin allowlists only that version" "$one" 1 "guarddog flagged" \
	GD_EXCLUDE_PACKAGES="left-pad@1.2.0"
verify_case "a matching version pin holds" "$one" 0 "below the suspicious" \
	GD_EXCLUDE_PACKAGES="left-pad@1.3.0"
verify_case "a glob covers an npm scope" "$scoped" 0 "below the suspicious" \
	GD_EXCLUDE_PACKAGES="@acme/*"
verify_case "an npm scope is not read as a version" "$scoped" 0 \
	"allowlisted: @acme/tools@2.0.0" GD_EXCLUDE_PACKAGES="@acme/tools"
verify_case "a scoped entry reaches its ecosystem" "$one" 0 "below the suspicious" \
	GD_EXCLUDE_PACKAGES="npm:left-pad"
verify_case "a scoped entry stays off the others" "$one" 1 "guarddog flagged" \
	GD_EXCLUDE_PACKAGES="pypi:left-pad"
verify_case "an unknown scope fails" "$one" 1 "unknown scope" \
	GD_EXCLUDE_PACKAGES="cocoapods:left-pad"

run_case "github_action is an allowlist scope" "$wf" 0 "allowlisted: actions/checkout@v4" \
	GD_PLAN_ONLY=false GD_LOCAL_SCAN=false GD_BIN="$actions/guarddog" \
	PATH="$actions:$PATH" GD_EXCLUDE_PACKAGES="github_action:actions/checkout"

# A local scan reports a path, not a dependency, so the allowlist must not touch it.
local_finding=$(stub 3)
run_case "the allowlist leaves a local scan alone" "$npm" 1 "guarddog flagged" \
	GD_PLAN_ONLY=false GD_ACTIONS=false GD_BIN="$local_finding/guarddog" \
	PATH="$local_finding:$PATH" GD_EXCLUDE_PACKAGES="left-pad"

run_case "sandbox stays on by default" "$npm" 0 "scan --exit-non-zero-on-finding --output-format json"
run_case "sandbox false passes --no-sandbox" "$npm" 0 "--no-sandbox" GD_SANDBOX=false

# The two paths that matter, plus the trap that upstream's exit code alone would hide.
clean=$(stub 0)
finding=$(stub 3)
low=$(stub 3 4.3 low)
run_case "clean scan passes" "$npm" 0 "below the suspicious risk threshold" \
	GD_PLAN_ONLY=false GD_ACTIONS=false GD_BIN="$clean/guarddog" PATH="$clean:$PATH"
run_case "a planted finding fails the job" "$npm" 1 "guarddog flagged 1 of 1 target(s)" \
	GD_PLAN_ONLY=false GD_ACTIONS=false GD_BIN="$finding/guarddog" PATH="$finding:$PATH"
run_case "the finding count reaches the log" "$npm" 1 "issues: 3" \
	GD_PLAN_ONLY=false GD_ACTIONS=false GD_BIN="$finding/guarddog" PATH="$finding:$PATH"
run_case "low risk passes the default threshold" "$npm" 0 "risk: low (4.3)" \
	GD_PLAN_ONLY=false GD_ACTIONS=false GD_BIN="$low/guarddog" PATH="$low:$PATH"
run_case "the low threshold rejects low risk" "$npm" 1 "guarddog flagged" \
	GD_PLAN_ONLY=false GD_ACTIONS=false GD_MINIMUM_RISK=low \
	GD_BIN="$low/guarddog" PATH="$low:$PATH"
run_case "an unknown risk threshold fails" "$npm" 1 "unknown minimum risk" \
	GD_MINIMUM_RISK=medium
run_case "a missing binary is an error, not a pass" "$npm" 1 "not on PATH" \
	GD_PLAN_ONLY=false GD_BIN="$TMP/nope/guarddog"

# Issues in the report fail the job even when upstream exits 0, which is what the
# missing --output-format json does to --exit-non-zero-on-finding.
silent="$TMP/stub-silent"
mkdir -p "$silent"
cat >"$silent/guarddog" <<'EOF'
#!/bin/bash
[ "$*" = --version ] && { echo 3.2.0; exit 0; }
printf '{"issues": 7, "risk_score": {"score": 8, "label": "high_risk"}, "risks": ["planted"]}\n'
exit 0
EOF
chmod +x "$silent/guarddog"
run_case "issues fail the job even on a zero exit code" "$npm" 1 "guarddog flagged" \
	GD_PLAN_ONLY=false GD_ACTIONS=false GD_BIN="$silent/guarddog" PATH="$silent:$PATH"

# The staged tree is what an exclusion acts on, so it must hold the kept files only.
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
	echo "FAIL an excluded path must not reach the staged tree (got: $staged)"
	;;
*"package.json"*) echo "ok   the staged tree holds the kept files without the excluded ones" ;;
*)
	fails=$((fails + 1))
	echo "FAIL the staged tree is missing tracked files (got: $staged)"
	;;
esac

echo
echo "${cases} cases, ${fails} failed"
[ "$fails" -eq 0 ]
