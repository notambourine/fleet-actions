#!/bin/bash
set -euo pipefail

STAGED=0
ZERO=0
BASE=""
for _arg in "$@"; do
	case "$_arg" in
	--staged) STAGED=1 ;;
	--force-zero) ZERO=1 ;;
	-*)
		echo "unknown flag: ${_arg}" >&2
		exit 1
		;;
	*) BASE="$_arg" ;;
	esac
done
unset _arg

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/dash-set.sh
source "$(dirname "$0")/lib/dash-set.sh"

export DASH_ROOT
DASH_ROOT=$(command git rev-parse --show-toplevel)
EMPTY_TREE=$(command git hash-object -t tree /dev/null)
git() { command git -C "$DASH_ROOT" "$@"; }

if [ "$ZERO" -eq 1 ]; then
	# One tree, so nothing to resolve: the index when staged, else the checkout.
	if [ "$STAGED" -eq 1 ]; then
		AFTER=:index
		AFTER_LABEL=index
	else
		AFTER=:worktree
		AFTER_LABEL="working tree"
	fi
elif [ "$STAGED" -eq 1 ]; then
	if git rev-parse --verify --quiet HEAD >/dev/null; then
		BEFORE=HEAD
		BEFORE_LABEL=HEAD
	else
		# Root commit: the empty tree stands in for the HEAD that does not exist yet.
		BEFORE="$EMPTY_TREE"
		BEFORE_LABEL="empty tree"
	fi
	AFTER=:index
	AFTER_LABEL=index
else
	if [ -z "$BASE" ]; then
		# GITHUB_REF, not a parent count: a PR whose own head commit is a merge also
		# has two parents, and there HEAD^1 is not the base.
		case "${GITHUB_REF:-}" in
		refs/pull/*/merge) BASE="HEAD^1" ;;
		*) BASE="origin/${GITHUB_BASE_REF:-main}" ;;
		esac
	fi
	git rev-parse --verify --quiet "$BASE" >/dev/null || {
		if [ "$BASE" = "HEAD^1" ]; then
			echo "::error::the merge ref has no first parent - checkout needs fetch-depth 2 or more"
		else
			echo "::error::base ref '${BASE}' is not fetched - check the workflow's fetch-depth"
		fi
		exit 1
	}
	BEFORE="$BASE"
	BEFORE_LABEL="$BASE"
	AFTER=HEAD
	AFTER_LABEL=HEAD
fi

list_tree() {
	local tree="$1"
	local list=(git diff --raw --no-abbrev --no-renames --no-ext-diff --no-textconv --no-relative -z)
	case "$tree" in
	:index|:worktree) list+=(--cached "$EMPTY_TREE") ;;
	*) list+=("$EMPTY_TREE" "$tree") ;;
	esac
	"${list[@]}" -- "${DASH_PATHSPEC[@]}"
}

scan_input() {
	case "$1" in
	zero) list_tree "$2" ;;
	count)
		list_tree "$BEFORE" || return $?
		printf '\0'
		list_tree "$AFTER"
		;;
	diff) shift 2; "$@" ;;
	esac
}

scan() {
	local mode="$1" target="$2" stages
	shift 2
	scan_input "$mode" "$target" "$@" | perl "$SCANNER" "$mode" "$target" || {
		stages=("${PIPESTATUS[@]}")
		if [ "${stages[0]}" -ne 0 ]; then
			echo "::error::git scan failed (exit ${stages[0]})" >&2
			return 2
		fi
		return "${stages[1]}"
	}
}

export DASH_STAGED="$STAGED"
SCANNER="$(dirname "$0")/lib/scan.pl"
status=0

if [ "$ZERO" -eq 1 ]; then
	after=$(scan zero "$AFTER") || status=$?
else
	diff_cmd=(git diff --text --word-diff=none --no-relative --no-color --no-ext-diff --no-textconv
		--src-prefix=a/ --dst-prefix=b/ --inter-hunk-context=0
		--output-indicator-new=+ --output-indicator-old=- --output-indicator-context=' ' -U0)
	if [ "$STAGED" -eq 1 ]; then
		diff_cmd+=(--cached "$BEFORE")
	else
		diff_cmd+=("${BASE}...HEAD")
	fi
	scan diff "$AFTER" "${diff_cmd[@]}" -- "${DASH_PATHSPEC[@]}" || status=$?
fi
if [ "$status" -gt 1 ]; then
	echo "::error::scan failed (exit ${status}) - the result is not trustworthy" >&2
	exit "$status"
fi

if [ "$ZERO" -eq 1 ]; then
	headline="${AFTER_LABEL} ${after}, and this gate requires 0"
	summary="\`${AFTER_LABEL}\` **${after}**, and this gate requires 0"
	[ "$after" -gt 0 ] && status=1
else
	counts=$(scan count :trees)
	read -r before after <<<"$counts"
	delta=$((after - before))
	sign=""
	[ "$delta" -gt 0 ] && sign="+"
	headline="${BEFORE_LABEL} ${before} -> ${AFTER_LABEL} ${after} (${sign}${delta})"
	summary="\`${BEFORE_LABEL}\` ${before} to \`${AFTER_LABEL}\` ${after} (**${sign}${delta}**)"
fi
echo
echo "unicode dashes: ${headline}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	{
		echo "### Unicode dashes"
		echo
		echo "$summary"
		if [ "$ZERO" -eq 0 ] && [ "$delta" -gt 0 ]; then
			echo
			echo "The total rose. This count only ever goes down."
		fi
	} >>"$GITHUB_STEP_SUMMARY"
fi

if [ "$ZERO" -eq 0 ] && [ "$delta" -gt 0 ]; then
	msg="the unicode-dash total rose by ${delta} - this count only ever goes down"
	if [ "$STAGED" -eq 1 ]; then
		echo "$msg" >&2
	else
		echo "::error::${msg}"
	fi
	status=1
fi

exit "$status"
