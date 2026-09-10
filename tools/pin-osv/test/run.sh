#!/bin/bash
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

stub_router() {
	local dir="$TMP/router-$1"
	mkdir -p "$dir"
	cat >"$dir/curl" <<EOF
#!/bin/bash
case "\$*" in
*'"commit"'*)
	cat <<'JSON'
$2
JSON
	;;
*)
	cat <<'JSON'
$3
JSON
	;;
esac
EOF
	chmod +x "$dir/curl"
	printf '%s' "$dir/curl"
}

fixture_versioned() {
	local dir="$TMP/$1"
	mkdir -p "$dir/.github/workflows"
	cat >"$dir/.github/workflows/ci.yml" <<EOF
on: push
jobs:
  a:
    steps:
      - uses: acme/widget@${CLEAN_SHA} # v1.2.3
EOF
	git -C "$dir" init -q 2>/dev/null
	git -C "$dir" add -A 2>/dev/null
	printf '%s' "$dir"
}

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

run_case "discovers action SHA" 0 "plan: query ${CLEAN_SHA}" \
	PINOSV_PLAN_ONLY=true PINOSV_IMAGES=false
refute_case "skips local action" "tools/thing" \
	PINOSV_PLAN_ONLY=true PINOSV_IMAGES=false
run_case "resolves image attestation" 0 \
	"plan: query ${DIRTY_SHA}" \
	PINOSV_PLAN_ONLY=true PINOSV_ACTIONS=false PINOSV_GH="$GH_OK"
run_case "excludes matching pin" 0 "skipping" \
	PINOSV_PLAN_ONLY=true PINOSV_IMAGES=false PINOSV_EXCLUDE="acme/*"

run_case "passes clean commit" 0 "pin(s) clean at OSV" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl none "$osv_none")"
run_case "fails on advisory" 1 "GHSA-test-high" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl high "$osv_high")"
run_case "fails on malware" 1 "MAL-0000-9999" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl mal "$osv_malware")"

refute_case "ignores low at high threshold" "GHSA-test-low" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl low "$osv_low")"
run_case "fails low at low threshold" 1 "GHSA-test-low" \
	PINOSV_IMAGES=false PINOSV_SEVERITY=low PINOSV_CURL="$(stub_curl low "$osv_low")"
run_case "fails on unrated record" 1 "CVE-2025-00000" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl unrated "$osv_unrated")"
run_case "rejects unknown severity" 1 "unknown severity" \
	PINOSV_SEVERITY=moderate
run_case "checks malware at none severity" 1 "MAL-0000-9999" \
	PINOSV_IMAGES=false PINOSV_SEVERITY=none PINOSV_CURL="$(stub_curl mal "$osv_malware")"
refute_case "ignores advisories at none severity" "GHSA-test-high" \
	PINOSV_IMAGES=false PINOSV_SEVERITY=none PINOSV_CURL="$(stub_curl high "$osv_high")"
run_case "rejects disabled gates" 1 \
	"nothing to gate on" PINOSV_SEVERITY=none PINOSV_MALWARE=false
refute_case "disables malware check" "MAL-0000-9999" \
	PINOSV_IMAGES=false PINOSV_MALWARE=false PINOSV_CURL="$(stub_curl mal "$osv_malware")"
run_case "waives identifier" 0 "waived" \
	PINOSV_IMAGES=false PINOSV_ALLOW="GHSA-test-high" \
	PINOSV_CURL="$(stub_curl high "$osv_high")"

run_case "reports unresolved image" 0 "1 unresolved" \
	PINOSV_ACTIONS=false PINOSV_GH="$GH_NONE" \
	PINOSV_CURL="$(stub_curl none "$osv_none")"
run_case "requires attestation" 1 "build attestation unavailable" \
	PINOSV_ACTIONS=false PINOSV_REQUIRE_ATTESTATION=true PINOSV_GH="$GH_NONE" \
	PINOSV_CURL="$(stub_curl none "$osv_none")"

run_case "rejects empty response" 1 "returned nothing" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl empty "")"

VREPO=$(fixture_versioned versioned)
ROUTER=$(stub_router split "$osv_none" "$osv_high")

run_case "queries package from release comment" 1 "GHSA-test-high" \
	PINOSV_ROOT="$VREPO" PINOSV_IMAGES=false PINOSV_CURL="$ROUTER"
run_case "queries unversioned pin by commit" 0 "clean at OSV" \
	PINOSV_IMAGES=false PINOSV_CURL="$ROUTER"

cases=$((cases + 1))
both=$(stub_router both "$osv_high" "$osv_high")
out=$(env PINOSV_ROOT="$VREPO" PINOSV_IMAGES=false PINOSV_CURL="$both" bash "$RUN" 2>&1)
hits=$(printf '%s\n' "$out" | grep -c 'GHSA-test-high')
if [ "$hits" -eq 1 ]; then
	echo "ok   deduplicates identifier"
else
	fails=$((fails + 1))
	echo "FAIL deduplicates identifier (saw ${hits})"
	printf '%s\n' "$out" | sed 's/^/     /'
fi

run_case "accepts omitted vulns" 0 "clean at OSV" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl omitted '{}')"
run_case "accepts unknown field" 0 "clean at OSV" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl extra '{"vulns":[],"query_id":"abc"}')"
run_case "finds advisory with unknown field" 1 "GHSA-test-high" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl extra-high '{"vulns":[{"id":"GHSA-test-high","database_specific":{"severity":"HIGH"}}],"query_id":"abc"}')"
for body in '{"code":3,"message":"invalid hash"}' '{"error":"upstream"}' '<html>Bad Gateway</html>' \
	'{"vulns":null}' '{"vulns":[{}]}' '[]'; do
	run_case "rejects OSV body: $body" 1 "OSV commit query failed" \
		PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl invalid "$body")"
done
run_case "rejects invalid package response" 1 "OSV package query failed" \
	PINOSV_ROOT="$VREPO" PINOSV_IMAGES=false \
	PINOSV_CURL="$(stub_router invalid-package "$osv_high" '<html>Bad Gateway</html>')"
run_case "rejects empty package response" 1 "OSV package query failed" \
	PINOSV_ROOT="$VREPO" PINOSV_IMAGES=false \
	PINOSV_CURL="$(stub_router empty-package "$osv_none" '')"

cat >"$TMP/http-failure" <<'EOF'
#!/bin/bash
printf '%s\n' '{}'
exit 22
EOF
chmod +x "$TMP/http-failure"
run_case "rejects failed request with body" 1 "OSV commit query failed" \
	PINOSV_IMAGES=false PINOSV_CURL="$TMP/http-failure"

cat >"$TMP/paginated" <<'EOF'
#!/bin/bash
case "$*" in
*'"page_token":"next"'*)
	printf '%s\n' '{"vulns":[{"id":"GHSA-test-page","database_specific":{"severity":"HIGH"}}]}' ;;
*) printf '%s\n' '{"next_page_token":"next"}' ;;
esac
EOF
chmod +x "$TMP/paginated"
run_case "finds advisory on commit page two" 1 "GHSA-test-page" \
	PINOSV_IMAGES=false PINOSV_CURL="$TMP/paginated"
cat >"$TMP/package-paginated" <<EOF
#!/bin/bash
case "\$*" in
*'"commit"'*) printf '%s\n' '{}' ;;
*) exec "$TMP/paginated" "\$@" ;;
esac
EOF
chmod +x "$TMP/package-paginated"
run_case "finds advisory on package page two" 1 "GHSA-test-page" \
	PINOSV_ROOT="$VREPO" PINOSV_IMAGES=false PINOSV_CURL="$TMP/package-paginated"
run_case "rejects repeated page token" 1 "OSV commit query failed" \
	PINOSV_IMAGES=false PINOSV_CURL="$(stub_curl repeated '{"next_page_token":"next"}')"

run_case "rejects invalid attestation commit" 1 "build attestation unavailable" \
	PINOSV_ACTIONS=false PINOSV_REQUIRE_ATTESTATION=true \
	PINOSV_GH="$(stub_gh invalid 'not-a-commit')"

SREPO=$(fixture syntax)
cat >"$SREPO/.github/workflows/ci.yml" <<EOF
on: push
jobs:
  a:
    steps:
      - uses: 'acme/widget/sub@${CLEAN_SHA}' # v1.2.3
      - uses: "acme/second@${DIRTY_SHA}" # v2.3.4
EOF
printf '  from --platform=linux/amd64 ghcr.io/acme/widget:v1@%s\n' "$DIGEST" >"$SREPO/tools/thing/Dockerfile"
run_case "normalizes quoted subpath action" 0 "and acme/widget@1.2.3" \
	PINOSV_ROOT="$SREPO" PINOSV_IMAGES=false PINOSV_PLAN_ONLY=true
run_case "discovers double-quoted action" 0 "and acme/second@2.3.4" \
	PINOSV_ROOT="$SREPO" PINOSV_IMAGES=false PINOSV_PLAN_ONLY=true
run_case "resolves platform image attestation" 1 "build attestation unavailable" \
	PINOSV_ROOT="$SREPO" PINOSV_ACTIONS=false PINOSV_REQUIRE_ATTESTATION=true PINOSV_GH="$GH_NONE"

echo
echo "${cases} cases, ${fails} failed"
[ "$fails" -eq 0 ]
