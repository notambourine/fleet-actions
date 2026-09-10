#!/usr/bin/env bash
set -uo pipefail

VET_BIN="${VET_BIN:-vet}"
VET_ROOT="${VET_ROOT:-${GITHUB_WORKSPACE:-$PWD}}"
VET_SEVERITY="${VET_SEVERITY:-high}"
VET_MALWARE="${VET_MALWARE:-true}"
VET_POLICY="${VET_POLICY:-}"
VET_EXCLUDE="${VET_EXCLUDE:-}"
VET_STAGE="${VET_STAGE:-${RUNNER_TEMP:-/tmp}}"
VET_PLAN_ONLY="${VET_PLAN_ONLY:-false}"
VET_CLOUD_KEY="${VET_CLOUD_KEY:-}"
VET_CLOUD_TENANT="${VET_CLOUD_TENANT:-}"

fail() {
	printf '::error::%s\n' "$1" >&2
	exit 1
}

if [ -n "$VET_CLOUD_KEY" ]; then
	# Community Insights enriches one package per request, so a large tree costs minutes.
	# An authenticated tenant lifts that ceiling and reaches private packages.
	[ -n "$VET_CLOUD_TENANT" ] || fail "a cloud key needs cloud-tenant, the SafeDep tenant domain"
	export VET_API_KEY="$VET_CLOUD_KEY"
	export VET_CONTROL_TOWER_TENANT_ID="$VET_CLOUD_TENANT"
	export VET_COMMUNITY_MODE=false
	echo "vet: authenticated Insights, tenant $VET_CLOUD_TENANT"
else
	[ -z "$VET_CLOUD_TENANT" ] || fail "cloud-tenant needs a cloud key"
	# Keyless access to https://api.safedep.io/insights-community/v1. Without it vet expects
	# a SafeDep API key and the scan errors instead of reporting.
	export VET_COMMUNITY_MODE="${VET_COMMUNITY_MODE:-true}"
fi

trim() {
	local s="$1"
	s="${s#"${s%%[![:space:]]*}"}"
	printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# The candidate set is the tracked tree, so a nested manifest counts and node_modules
# never does.
list_files() {
	if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git ls-files
	else
		find . \( -name .git -o -name node_modules -o -name .venv \) -prune -o \
			-type f -print | sed 's|^\./||'
	fi
}

# The ecosystems vet reads: npm, pypi, maven, go, rubygems, crates, packagist.
manifests() {
	grep -E '(^|/)(package\.json|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|requirements(-[^/]*)?\.txt|pyproject\.toml|Pipfile\.lock|poetry\.lock|uv\.lock|go\.mod|Cargo\.(toml|lock)|Gemfile(\.lock)?|pom\.xml|build\.gradle(\.kts)?|gradle\.lockfile|composer\.(json|lock))$'
}

cd "$VET_ROOT" || fail "root '$VET_ROOT' is not a directory"

if [ -n "$VET_POLICY" ]; then
	[ -f "$VET_POLICY" ] || fail "policy '$VET_POLICY' is not a file"
	suite="$VET_POLICY"
	echo "vet: filter suite $suite"
else
	# Cumulative: `high` is critical or high, and so on down.
	severities=()
	case "$VET_SEVERITY" in
	none) ;;
	critical) severities=(critical) ;;
	high) severities=(critical high) ;;
	medium) severities=(critical high medium) ;;
	low) severities=(critical high medium low) ;;
	*) fail "unknown severity '$VET_SEVERITY' (one of: none low medium high critical)" ;;
	esac

	[ "${#severities[@]}" -gt 0 ] || [ "$VET_MALWARE" = true ] ||
		fail "severity none with malware off leaves nothing to gate on"

	suite="${VET_STAGE%/}/vet-fleet-suite.yml"
	{
		echo "name: fleet-ci"
		echo "filters:"
		if [ "${#severities[@]}" -gt 0 ]; then
			expression=""
			for severity in "${severities[@]}"; do
				expression+="${expression:+ || }vulns.${severity}.exists(p, true)"
			done
			echo "  - name: vulnerability"
			echo "    check_type: CheckTypeVulnerability"
			echo "    summary: A dependency carries a ${VET_SEVERITY}-or-worse advisory"
			echo "    value: |"
			echo "      ${expression}"
		fi
		if [ "$VET_MALWARE" = true ]; then
			echo "  - name: malware"
			echo "    check_type: CheckTypeMalware"
			echo "    summary: A dependency is a known malicious package"
			echo "    value: |"
			echo '      vulns.all.exists(v, v.id.startsWith("MAL-"))'
		fi
	} >"$suite" || fail "could not write the filter suite to $suite"
fi

if ! printf '%s\n' "$(list_files)" | manifests >/dev/null; then
	echo "vet: no package manifest in the tracked tree, nothing to scan"
	exit 0
fi

# --filter-fail is what turns a match into a non-zero exit. Without it vet reports and
# passes.
args=(scan --no-banner -D . --filter-suite "$suite" --filter-fail)
[ "$VET_MALWARE" = true ] && [ -z "$VET_POLICY" ] && args+=(--malware-query)

while IFS= read -r pattern; do
	pattern=$(trim "$pattern")
	[ -n "$pattern" ] && args+=(--exclude "$pattern")
done <<<"$VET_EXCLUDE"

if [ "$VET_PLAN_ONLY" = true ]; then
	printf 'plan: %s %s\n' "$VET_BIN" "${args[*]}"
	printf '::group::filter suite\n'
	cat "$suite"
	printf '::endgroup::\n'
	exit 0
fi

command -v "$VET_BIN" >/dev/null 2>&1 || fail "vet binary '$VET_BIN' not on PATH"

printf '::group::vet scan\n'
"$VET_BIN" "${args[@]}"
rc=$?
printf '::endgroup::\n'

[ "$rc" -eq 0 ] || fail "vet failed (exit $rc)"

echo "vet: no dependency matched the ${VET_SEVERITY} threshold"
