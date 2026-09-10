#!/usr/bin/env bash
# Query OSV at the source commit behind every pin this repo holds.
#
# A manifest scanner reads declared dependencies. Nothing reads the two surfaces a
# workflow actually executes: the actions it references and the base images its
# Dockerfiles build on. Both are pinned to an immutable artifact, and both resolve to
# a commit:
#
#   uses: owner/repo@<40-hex>   the pin is already the commit
#   FROM host/owner/repo@sha256 the build attestation names the commit
#
# OSV indexes GIT commit ranges, so one query per commit covers the repo whatever it
# ships. That is strictly wider than a package query: the tj-actions compromise is a
# hit by commit and a miss by GitHub Actions package coordinates.
set -uo pipefail

PINOSV_ROOT="${PINOSV_ROOT:-${GITHUB_WORKSPACE:-$PWD}}"
PINOSV_SEVERITY="${PINOSV_SEVERITY:-high}"
PINOSV_MALWARE="${PINOSV_MALWARE:-true}"
PINOSV_ACTIONS="${PINOSV_ACTIONS:-true}"
PINOSV_IMAGES="${PINOSV_IMAGES:-true}"
PINOSV_REQUIRE_ATTESTATION="${PINOSV_REQUIRE_ATTESTATION:-false}"
PINOSV_ALLOW="${PINOSV_ALLOW:-}"
PINOSV_EXCLUDE="${PINOSV_EXCLUDE:-}"
PINOSV_API="${PINOSV_API:-https://api.osv.dev/v1/query}"
PINOSV_GH="${PINOSV_GH:-gh}"
PINOSV_CURL="${PINOSV_CURL:-curl}"
PINOSV_PLAN_ONLY="${PINOSV_PLAN_ONLY:-false}"

fail() {
	printf '::error::%s\n' "$1" >&2
	exit 1
}

trim() {
	local s="$1"
	s="${s#"${s%%[![:space:]]*}"}"
	printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# Unknown outranks the threshold rather than dropping out of it: OSV leaves the label
# null on CVE- and GO- records, and the tj-actions compromise is one of them.
rank() {
	case "$1" in
	CRITICAL) printf 4 ;;
	HIGH) printf 3 ;;
	MODERATE | MEDIUM) printf 2 ;;
	LOW) printf 1 ;;
	*) printf 4 ;;
	esac
}

case "$PINOSV_SEVERITY" in
critical) THRESHOLD=4 ;;
high) THRESHOLD=3 ;;
medium) THRESHOLD=2 ;;
low) THRESHOLD=1 ;;
none) THRESHOLD=0 ;;
*) fail "unknown severity '$PINOSV_SEVERITY' (one of: none low medium high critical)" ;;
esac

[ "$THRESHOLD" -gt 0 ] || [ "$PINOSV_MALWARE" = true ] ||
	fail "severity none with malware off leaves nothing to gate on"

cd "$PINOSV_ROOT" || fail "root '$PINOSV_ROOT' is not a directory"

# The candidate set is the tracked tree, so a vendored copy never counts.
list_files() {
	if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git ls-files
	else
		find . \( -name .git -o -name node_modules -o -name .venv \) -prune -o \
			-type f -print | sed 's|^\./||'
	fi
}

excluded() {
	local ref="$1" pattern
	while IFS= read -r pattern; do
		pattern=$(trim "$pattern")
		[ -n "$pattern" ] || continue
		# shellcheck disable=SC2053 # $pattern is a pattern, not a literal
		[[ "$ref" == $pattern ]] && return 0
	done <<<"$PINOSV_EXCLUDE"
	return 1
}

waived() {
	local id="$1" entry
	while IFS= read -r entry; do
		entry=$(trim "$entry")
		[ -n "$entry" ] || continue
		[ "$entry" = "$id" ] && return 0
	done <<<"$PINOSV_ALLOW"
	return 1
}

# Emits `<commit><TAB><ref><TAB><package><TAB><version>`. Package coordinates are the
# second place OSV may hold a record and are empty when the pin carries no version.
pins() {
	local files
	files=$(list_files)

	if [ "$PINOSV_ACTIONS" = true ]; then
		# A local action (./ or the $/ the release rewrites) has no upstream commit.
		# The version comes from the trailing release comment, costing no request.
		printf '%s\n' "$files" |
			grep -E '(^|/)(\.github/workflows/[^/]+\.ya?ml|action\.ya?ml)$' |
			while IFS= read -r file; do
				grep -hoE 'uses:[[:space:]]+[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+@[0-9a-f]{40}([[:space:]]*#[[:space:]]*v?[0-9][0-9A-Za-z.+-]*)?' \
					"$file" 2>/dev/null
			done |
			sed -E 's/^uses:[[:space:]]+//' | sort -u |
			while IFS= read -r line; do
				ref=$(trim "${line%%#*}")
				version=""
				case "$line" in *'#'*) version=$(trim "${line#*#}") ;; esac
				printf '%s\t%s\t%s\t%s\n' \
					"${ref##*@}" "$ref" "${ref%@*}" "${version#v}"
			done
	fi

	if [ "$PINOSV_IMAGES" = true ]; then
		# No OSV ecosystem holds container images, so an image is a commit query alone.
		printf '%s\n' "$files" |
			grep -E '(^|/)Dockerfile[^/]*$' |
			while IFS= read -r file; do
				grep -hoE '^FROM[[:space:]]+[^[:space:]]+@sha256:[0-9a-f]{64}' \
					"$file" 2>/dev/null
			done |
			sed -E 's/^FROM[[:space:]]+//' | sort -u |
			while IFS= read -r ref; do
				printf 'image\t%s\t\t\n' "$ref"
			done
	fi
}

# An image pin names a digest, not a commit. The build attestation is what carries the
# commit, so an image whose provenance cannot be read is unresolved, never clean.
resolve_image() {
	local ref="$1" path digest owner repo commit
	path="${ref%@*}"
	path="${path%%:*}"
	digest="${ref##*@}"
	repo="${path##*/}"
	owner="${path%/*}"
	owner="${owner##*/}"
	[ -n "$owner" ] && [ -n "$repo" ] || return 1

	commit=$("$PINOSV_GH" api "repos/$owner/$repo/attestations/$digest" \
		--jq '.attestations[0].bundle.dsseEnvelope.payload' 2>/dev/null |
		base64 -d 2>/dev/null |
		jq -r '.predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit // empty' 2>/dev/null)
	[ -n "$commit" ] || return 1
	printf '%s' "$commit"
}

query() {
	"$PINOSV_CURL" -sS --max-time 30 -X POST "$PINOSV_API" -d "$1" 2>/dev/null
}

findings=0
scanned=0
unresolved=0

while IFS=$'\t' read -r commit ref package version; do
	[ -n "$ref" ] || continue
	if excluded "$ref"; then
		echo "pin-osv: skipping $ref"
		continue
	fi

	if [ "$commit" = image ]; then
		if ! commit=$(resolve_image "$ref"); then
			unresolved=$((unresolved + 1))
			if [ "$PINOSV_REQUIRE_ATTESTATION" = true ]; then
				printf '::error::%s has no readable build attestation, so its source commit cannot be queried\n' "$ref"
				findings=$((findings + 1))
			else
				printf '::warning::%s has no readable build attestation; not queried\n' "$ref"
			fi
			continue
		fi
	fi

	if [ "$PINOSV_PLAN_ONLY" = true ]; then
		if [ -n "$package" ] && [ -n "$version" ]; then
			echo "plan: query $commit and $package@$version ($ref)"
		else
			echo "plan: query $commit ($ref)"
		fi
		continue
	fi

	scanned=$((scanned + 1))
	response=$(query "{\"commit\":\"$commit\"}")
	[ -n "$response" ] || fail "OSV query for $ref returned nothing"

	# OSV holds an advisory under a GIT range, under package coordinates, or under
	# one and not the other, so both are asked and the identifiers are merged.
	if [ -n "$package" ] && [ -n "$version" ]; then
		response+=$'\n'$(query "$(printf '{"package":{"name":"%s","ecosystem":"GitHub Actions"},"version":"%s"}' \
			"$package" "$version")")
	fi

	while IFS=$'\t' read -r id severity; do
		[ -n "$id" ] || continue
		waived "$id" && {
			echo "pin-osv: $id waived for $ref"
			continue
		}
		case "$id" in
		MAL-*)
			[ "$PINOSV_MALWARE" = true ] || continue
			printf '::error::%s is reported malicious at %s (%s)\n' "$ref" "$commit" "$id"
			findings=$((findings + 1))
			continue
			;;
		esac
		[ "$THRESHOLD" -gt 0 ] || continue
		[ "$(rank "$severity")" -ge "$THRESHOLD" ] || continue
		printf '::error::%s carries %s (%s) at %s\n' "$ref" "$id" "${severity:-unrated}" "$commit"
		findings=$((findings + 1))
	done < <(jq -rs '[.[] | (.vulns // [])[]] | unique_by(.id)[] |
		[.id, (.database_specific.severity // "")] | @tsv' <<<"$response" 2>/dev/null)
done < <(pins)

if [ "$PINOSV_PLAN_ONLY" = true ]; then
	exit 0
fi

if [ "$findings" -gt 0 ]; then
	fail "$findings finding(s) across $scanned pin(s)"
fi

echo "pin-osv: $scanned pin(s) clean at OSV, $unresolved unresolved"
