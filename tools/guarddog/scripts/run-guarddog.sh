#!/usr/bin/env bash
# Run guarddog over this repo. Two gates, both defaulting on:
#
#   local   offline YARA over the tracked tree, per ecosystem whose manifest exists
#   actions `github_action verify` over each workflow, which fetches the JavaScript
#           of the actions it references
#
# Registry `verify` of declared dependencies is off by default: Socket and the
# update bots already cover that surface, and it downloads every package.
set -uo pipefail

GD_BIN="${GD_BIN:-guarddog}"
GD_ROOT="${GD_ROOT:-${GITHUB_WORKSPACE:-$PWD}}"
GD_ECOSYSTEMS="${GD_ECOSYSTEMS:-auto}"
GD_LOCAL_SCAN="${GD_LOCAL_SCAN:-true}"
GD_ACTIONS="${GD_ACTIONS:-true}"
GD_REGISTRY_VERIFY="${GD_REGISTRY_VERIFY:-false}"
GD_SCAN_PATHS="${GD_SCAN_PATHS:-}"
GD_EXCLUDE_PATHS="${GD_EXCLUDE_PATHS:-}"
GD_EXCLUDE_RULES="${GD_EXCLUDE_RULES:-}"
GD_INCLUDE_DEV="${GD_INCLUDE_DEV:-false}"
GD_SANDBOX="${GD_SANDBOX:-true}"
GD_MINIMUM_RISK="${GD_MINIMUM_RISK:-suspicious}"
GD_STAGE="${GD_STAGE:-${RUNNER_TEMP:-}}"
GD_PLAN_ONLY="${GD_PLAN_ONLY:-false}"

# github_action is reached through its own toggle, not the ecosystem list.
ALL_ECOSYSTEMS=(npm pypi go crates rubygems)

fail() {
	printf '::error::%s\n' "$1" >&2
	exit 1
}

check_ecosystem() {
	case "$1" in
	npm | pypi | go | crates | rubygems) ;;
	*) fail "unknown ecosystem '$1' (one of: ${ALL_ECOSYSTEMS[*]})" ;;
	esac
}

# The candidate set is the tracked tree, so a workspace package at any depth counts
# and node_modules never does.
list_files() {
	if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git ls-files
	else
		# No index to read: prune what a tracked list would never have held.
		find . \( -name .git -o -name node_modules -o -name .venv \) -prune -o \
			-type f -print | sed 's|^\./||'
	fi
}

manifests() {
	case "$1" in
	npm) grep -E '(^|/)package\.json$' ;;
	pypi) grep -E '(^|/)(requirements(-[^/]*)?\.txt|pyproject\.toml|setup\.py)$' ;;
	go) grep -E '(^|/)go\.mod$' ;;
	crates) grep -E '(^|/)Cargo\.(lock|toml)$' ;;
	rubygems) grep -E '(^|/)Gemfile(\.lock)?$' ;;
	esac
}

workflows() {
	grep -E '(^|/)\.github/workflows/[^/]+\.ya?ml$'
}

# guarddog has no ignore file or path allowlist, so an excluded path is kept out of
# the staged tree the scan reads. `*` crosses `/`, so `dist/*` drops the subtree.
excluded() {
	local path="$1" pattern
	while IFS= read -r pattern; do
		pattern="${pattern#"${pattern%%[![:space:]]*}"}"
		pattern="${pattern%"${pattern##*[![:space:]]}"}"
		[ -n "$pattern" ] || continue
		# shellcheck disable=SC2053 # $pattern is a pattern, not a literal
		[[ "$path" == $pattern ]] && return 0
	done <<<"$GD_EXCLUDE_PATHS"
	return 1
}

# Bare rules apply to every ecosystem scanned. guarddog validates rule names per
# ecosystem, so scope a single-ecosystem rule as `pypi:repository_integrity_mismatch`.
exclude_args() {
	local ecosystem="$1" rule scope
	while IFS= read -r rule; do
		rule="${rule#"${rule%%[![:space:]]*}"}"
		rule="${rule%"${rule##*[![:space:]]}"}"
		[ -n "$rule" ] || continue
		case "$rule" in
		*:*)
			scope="${rule%%:*}"
			[ "$scope" = "$ecosystem" ] || continue
			rule="${rule#*:}"
			;;
		esac
		printf '%s\n%s\n' -x "$rule"
	done <<<"$GD_EXCLUDE_RULES"
}

cd "$GD_ROOT" || fail "root '$GD_ROOT' is not a directory"

case "$GD_MINIMUM_RISK" in
low) minimum_score=0.1 ;;
suspicious) minimum_score=5 ;;
high) minimum_score=7 ;;
*) fail "unknown minimum risk '$GD_MINIMUM_RISK' (one of: low suspicious high)" ;;
esac

selected=()
if [ "$GD_ECOSYSTEMS" = auto ]; then
	selected=("${ALL_ECOSYSTEMS[@]}")
else
	read -r -a selected <<<"${GD_ECOSYSTEMS//,/ }"
	for ecosystem in "${selected[@]}"; do
		check_ecosystem "$ecosystem"
	done
fi

tracked=$(list_files)
kept=""
while IFS= read -r path; do
	[ -n "$path" ] || continue
	excluded "$path" && continue
	kept+="$path"$'\n'
done <<<"$tracked"

# ecosystem<TAB>command<TAB>target
plan=""
add() {
	plan+=$(printf '%s\t%s\t%s' "$1" "$2" "$3")$'\n'
}

if [ "$GD_LOCAL_SCAN" = true ]; then
	for ecosystem in "${selected[@]}"; do
		if printf '%s' "$kept" | manifests "$ecosystem" >/dev/null; then
			# One scan of the whole tree per ecosystem: the rule set differs by
			# ecosystem, the tree does not.
			add "$ecosystem" scan .
		fi
	done
fi

if [ "$GD_ACTIONS" = true ]; then
	while IFS= read -r path; do
		[ -n "$path" ] && add github_action verify "$path"
	done < <(printf '%s' "$kept" | workflows)
fi

if [ "$GD_REGISTRY_VERIFY" = true ]; then
	for ecosystem in "${selected[@]}"; do
		while IFS= read -r path; do
			[ -n "$path" ] && add "$ecosystem" verify "$path"
		done < <(printf '%s' "$kept" | manifests "$ecosystem")
	done
fi

# Explicit paths are scanned in place, untracked included, which is how a post-install
# step reaches node_modules. Unstaged, so exclude-paths cannot reach inside one.
while IFS= read -r entry; do
	entry="${entry#"${entry%%[![:space:]]*}"}"
	entry="${entry%"${entry##*[![:space:]]}"}"
	[ -n "$entry" ] || continue
	case "$entry" in
	*:*)
		ecosystem="${entry%%:*}"
		path="${entry#*:}"
		check_ecosystem "$ecosystem"
		[ -e "$path" ] || fail "scan-paths entry '$entry' points at nothing"
		add "$ecosystem" scan "$path"
		;;
	*)
		[ -e "$entry" ] || fail "scan-paths entry '$entry' points at nothing"
		for ecosystem in "${selected[@]}"; do
			add "$ecosystem" scan "$entry"
		done
		;;
	esac
done <<<"$GD_SCAN_PATHS"

if [ -z "$plan" ]; then
	echo "guarddog: nothing to scan"
	exit 0
fi

if [ "$GD_PLAN_ONLY" != true ] && ! command -v "$GD_BIN" >/dev/null 2>&1; then
	fail "guarddog binary '$GD_BIN' not on PATH"
fi

# A local scan reads a staged copy holding only the kept files, which is how an
# excluded path is excluded and how .git and untracked build output stay out.
stage=""
stage_tree() {
	[ -n "$stage" ] && return 0
	local parent="${GD_STAGE:-$(dirname "$(mktemp -u)")}"
	stage=$(mktemp -d "${parent%/}/guarddog-tree-XXXXXX") ||
		fail "could not create a staging directory under '$parent'"
	printf '%s' "$kept" | tar -cf - -T - | tar -xf - -C "$stage" ||
		fail "could not stage the tracked tree"
}
cleanup() { [ -n "$stage" ] && rm -rf "$stage"; }
trap cleanup EXIT

scanned=0
failed=()
while IFS=$'\t' read -r ecosystem command target; do
	[ -n "$ecosystem" ] || continue

	# The staging path is opaque, so the log and the error name what was asked for.
	target_label="$target"
	if [ "$command" = scan ] && [ "$target" = . ]; then
		target_label="tracked tree"
		[ "$GD_PLAN_ONLY" = true ] || stage_tree
		target="${stage:-.}"
	fi

	# json is load-bearing: upstream honors --exit-non-zero-on-finding only in the
	# JSON reporter and exits 0 on a high-risk package without it.
	args=("$ecosystem" "$command" --exit-non-zero-on-finding --output-format json)
	[ "$GD_SANDBOX" = true ] || args+=(--no-sandbox)
	[ "$command" = verify ] && [ "$ecosystem" = npm ] && [ "$GD_INCLUDE_DEV" = true ] &&
		args+=(--include-dev-dependencies)
	while IFS= read -r arg; do
		[ -n "$arg" ] && args+=("$arg")
	done < <(exclude_args "$ecosystem")
	args+=("$target")

	scanned=$((scanned + 1))
	if [ "$GD_PLAN_ONLY" = true ]; then
		printf 'plan: %s %s\n' "$GD_BIN" "${args[*]}"
		continue
	fi

	printf '::group::guarddog %s %s %s\n' "$ecosystem" "$command" "$target_label"
	report=$("$GD_BIN" "${args[@]}")
	rc=$?
	summary=$(printf '%s' "$report" | jq -r '
		([.. | objects | .issues? // empty] | add // 0) as $issues |
		([.. | objects | .errors? | select(type == "object") | length] | add // 0) as $errors |
		([.. | objects | .risk_score? | select(type == "object")] |
			max_by(.score) // {score: 0, label: "no_risks_detected"}) as $risk |
		"\($issues)\t\($errors)\t\($risk.score)\t\($risk.label)"' 2>/dev/null)
	IFS=$'\t' read -r issues errors score risk_label <<<"$summary"
	printf 'issues: %s; risk: %s (%s)\n' \
		"${issues:-unparsed}" "${risk_label:-unparsed}" "${score:-unparsed}"
	risks=$(printf '%s' "$report" | jq -r '[.. | objects | select(has("risks")) | .risks[]?]
		| unique | .[]
		| "  \(.severity // "?")\t\(.threat_rule // .name // "?")\t\(.threat_location // .file_path // "?")\t\(.threat_description // "")"' 2>/dev/null)
	if [ -n "$risks" ]; then
		printf '%s\n' "$risks" | column -t -s $'\t' 2>/dev/null || printf '%s\n' "$risks"
	fi
	echo '::endgroup::'
	if [ -z "$summary" ] || [ "${errors:-0}" -gt 0 ] || [ "$rc" -gt 1 ] ||
		jq -en --argjson score "${score:-0}" --argjson minimum "$minimum_score" \
			'$score >= $minimum' >/dev/null; then
		failed+=("$ecosystem $command $target_label")
	fi
done <<<"$plan"

if [ "${#failed[@]}" -gt 0 ]; then
	printf '::error::guarddog flagged %s of %s target(s): %s\n' \
		"${#failed[@]}" "$scanned" "${failed[*]}"
	exit 1
fi

echo "guarddog: ${scanned} target(s) below the ${GD_MINIMUM_RISK} risk threshold"
