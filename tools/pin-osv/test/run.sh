#!/bin/bash
# Behavior tests for scripts/run-pin-osv.sh. Discovery runs in plan mode. The decision
# paths use a stub curl serving a canned OSV body and a stub gh serving a canned
# attestation, so no case reaches the network and the planted finding is one this
# gate owns.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/scripts/run-pin-osv.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
cases=0

CLEAN_SHA=1111111111111111111111111111111111111111
DIRTY_SHA=2222222222222222222222222222222222222222
DIGEST=sha256:3333333333333333333333333333333333333333333333333333333333333333

# stub_curl <name> <json> writes a curl that answers every query with that body.
stub_curl() {
	local dir="$TMP/curl-$1"
	mkdir -p "$dir"
	cat >"$dir/curl" <<EOF
#!/bin/bash
cat <<'JSON'
$2
JSON
EOF
	chmod +x "$dir/curl"
	printf '%s' "$dir/curl"
}

# stub_gh <name> <commit> writes a gh whose attestation resolves to that commit.
# Empty commit stands for an image with no readable provenance.
stub_gh() {
	local dir="$TMP/gh-$1" payload
	mkdir -p "$dir"
	if [ -n "$2" ]; then
		payload=$(printf '{"predicate":{"buildDefinition":{"resolvedDependencies":[{"digest":{"gitCommit":"%s"}}]}}}' "$2" | base64 | tr -d '\n')
		cat >"$dir/gh" <<EOF
#!/bin/bash
printf '%s' "$payload"
EOF
	else
		cat >"$dir/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
	fi
	chmod +x "$dir/gh"
	printf '%s' "$dir/gh"
}

osv_none='{"vulns":[]}'
osv_high='{"vulns":[{"id":"GHSA-test-high","database_specific":{"severity":"HIGH"}}]}'
osv_low='{"vulns":[{"id":"GHSA-test-low","database_specific":{"severity":"LOW"}}]}'
osv_unrated='{"vulns":[{"id":"CVE-2025-00000"}]}'
osv_malware='{"vulns":[{"id":"MAL-0000-9999"}]}'

# fixture <name> builds a git repo holding one action pin and one image pin, so
# discovery reads an index like it does in CI.
fixture() {
	local dir="$TMP/$1"
	mkdir -p "$dir/.github/workflows" "$dir/tools/thing"
	cat >"$dir/.github/workflows/ci.yml" <<EOF
on: push
jobs:
  a:
    steps:
      - uses: acme/widget@${CLEAN_SHA}
      - uses: ./tools/thing
      - uses: \$/tools/thing
EOF
	printf 'FROM ghcr.io/acme/widget:v1@%s\n' "$DIGEST" >"$dir/tools/thing/Dockerfile"
	git -C "$dir" init -q 2>/dev/null
	git -C "$dir" add -A 2>/dev/null
	printf '%s' "$dir"
}

# run_case <name> <want-rc> <output-substring> [VAR=value ...]
run_case() {
	local name="$1" want_rc="$2" want_out="$3" out rc ok=1
	shift 3
	cases=$((cases + 1))
	out=$(env PINOSV_ROOT="$REPO" "$@" bash "$RUN" 2>&1)
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

# refute_case <name> <substring-that-must-be-absent> [VAR=value ...]
refute_case() {
	local name="$1" reject="$2" out
	shift 2
	cases=$((cases + 1))
	out=$(env PINOSV_ROOT="$REPO" "$@" bash "$RUN" 2>&1)
	case "$out" in
	*"$reject"*)
		fails=$((fails + 1))
		echo "FAIL ${name} (output must not contain '${reject}')"
		printf '%s\n' "$out" | sed 's/^/     /'
		;;
	*) echo "ok   ${name}" ;;
	esac
}

REPO=$(fixture repo)
GH_OK=$(stub_gh ok "$DIRTY_SHA")
GH_NONE=$(stub_gh none "")

# Discovery. A pin is only worth querying if it resolves to a commit.
run_case "an action sha pin is discovered" 0 "plan: query ${CLEAN_SHA}" \
	PINOSV_PLAN_ONLY=true PINOSV_IMAGES=false
refute_case "a local action pin is not queried" "tools/thing" \
	PINOSV_PLAN_ONLY=true PINOSV_IMAGES=false
run_case "an image digest pin resolves through its attestation" 0 \
	"plan: query ${DIRTY_SHA}" \
	PINOSV_PLAN_ONLY=true PINOSV_ACTIONS=false PINOSV_GH="$GH_OK"
run_case "an exclusion skips a pin" 0 "skipping" \
	PINOSV_PLAN_ONLY=true PINOSV_IMAGES=false PINOSV_EXCLUDE="acme/*"

# The two paths that matter.
run_case "a clean commit passes" 0 "pin(s) clean at OSV" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl none "$osv_none")"
run_case "a planted advisory fails the job" 1 "GHSA-test-high" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl high "$osv_high")"
run_case "a planted malware report fails the job" 1 "MAL-0000-9999" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl mal "$osv_malware")"

# Severity is cumulative and unrated records outrank every threshold, because the
# advisory for a real action compromise carried no label.
refute_case "high stays off low" "GHSA-test-low" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl low "$osv_low")"
run_case "low reaches low" 1 "GHSA-test-low" \
	PINOSV_IMAGES=false PINOSV_SEVERITY=low PINOSV_CURL="$(stub_curl low "$osv_low")"
run_case "an unrated record is not dropped" 1 "CVE-2025-00000" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl unrated "$osv_unrated")"
run_case "an unknown severity fails" 1 "unknown severity" \
	PINOSV_SEVERITY=moderate
run_case "severity none gates on malware alone" 1 "MAL-0000-9999" \
	PINOSV_IMAGES=false PINOSV_SEVERITY=none PINOSV_CURL="$(stub_curl mal "$osv_malware")"
refute_case "severity none drops the advisory filter" "GHSA-test-high" \
	PINOSV_IMAGES=false PINOSV_SEVERITY=none PINOSV_CURL="$(stub_curl high "$osv_high")"
run_case "severity none with malware off is an error, not a silent pass" 1 \
	"nothing to gate on" PINOSV_SEVERITY=none PINOSV_MALWARE=false
refute_case "malware can be turned off" "MAL-0000-9999" \
	PINOSV_IMAGES=false PINOSV_MALWARE=false PINOSV_CURL="$(stub_curl mal "$osv_malware")"
run_case "an identifier can be waived" 0 "waived" \
	PINOSV_IMAGES=false PINOSV_ALLOW="GHSA-test-high" \
	PINOSV_CURL="$(stub_curl high "$osv_high")"

# An image nobody can trace is unresolved, never clean: it is reported either way, and
# the input decides whether an unqueried image also fails.
run_case "an unattested image is reported, not counted clean" 0 "1 unresolved" \
	PINOSV_ACTIONS=false PINOSV_GH="$GH_NONE" \
	PINOSV_CURL="$(stub_curl none "$osv_none")"
run_case "require-attestation true fails it" 1 "no readable build attestation" \
	PINOSV_ACTIONS=false PINOSV_REQUIRE_ATTESTATION=true PINOSV_GH="$GH_NONE" \
	PINOSV_CURL="$(stub_curl none "$osv_none")"

# An empty body is an outage, not a clean bill of health.
run_case "an empty OSV response is an error" 1 "returned nothing" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl empty "")"

echo
echo "${cases} cases, ${fails} failed"
[ "$fails" -eq 0 ]
