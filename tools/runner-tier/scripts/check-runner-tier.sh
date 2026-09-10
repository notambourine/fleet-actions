#!/usr/bin/env bash
# Exit 0 clean, 1 findings, 2 scan error.
set -uo pipefail

FILES=${RUNNER_TIER_FILES:-}
EXCLUDE=${RUNNER_TIER_EXCLUDE:-}

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || TOP="${GITHUB_WORKSPACE:-$PWD}"

if ! command -v yq >/dev/null 2>&1; then
	echo "::error::runner-tier requires yq (mikefarah v4)"
	exit 2
fi

declare -a wf=()
if [ -n "$FILES" ]; then
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		if [ ! -f "$TOP/$f" ]; then
			echo "::error::runner-tier: no such workflow file: $f"
			exit 2
		fi
		wf+=("$TOP/$f")
	done <<<"$FILES"
else
	for f in "$TOP"/.github/workflows/*.y*ml; do
		[ -f "$f" ] && wf+=("$f")
	done
fi

if [ ${#wf[@]} -eq 0 ]; then
	echo "runner-tier: no workflow files to read"
	exit 0
fi

# steps MUST be tojson(0), never tostring: tostring emits multi-line YAML that @tsv leaves
# unescaped, so the read loop sees one truncated row per line.
QUERY='.jobs // {} | to_entries[] | [
	.key,
	(.value["runs-on"] // "-" | tostring),
	(.value | has("uses")),
	(.value | has("container")),
	(.value | has("services")),
	(.value["timeout-minutes"] // "-" | tostring),
	(.value["runs-on"] | key | line),
	((.value.steps // []) | tojson(0)),
	((.value["runs-on"] | key | head_comment) + " "
		+ (.value["runs-on"] | key | line_comment) + " "
		+ (.value["runs-on"] | line_comment) | tojson(0))
] | @tsv'
# Every column needs a non-empty fallback: IFS=$'\t' is whitespace, so bash collapses a run
# of tabs and an empty field shifts every later one left.

HEAVY='(npm|pnpm|yarn|bun) +(ci|install)|pip +install|uv +(sync|pip)|bundle +(install|exec)'
HEAVY="$HEAVY"'|cargo +(build|test|fetch)|go +(build|test)|(mvn|gradle|make|cmake) '
HEAVY="$HEAVY"'|setup-(ruby|java|python|go|dotnet|haskell)|corepack|playwright +install'

# No `\b`: BSD regex has no such escape, so each alternative carries its own trailing space
# where a bare substring would misfire.
SLIMGAP='envsubst|gettext|cosign-installer|build-essential|xmllint|pandoc|graphviz|dot -T'
SLIMGAP="$SLIMGAP"'|playwright|puppeteer|chromium|google-chrome|firefox|selenium|cypress'
SLIMGAP="$SLIMGAP"'|lighthouse|ffmpeg|imagemagick|convert |kubectl|helm |terraform|ansible'
SLIMGAP="$SLIMGAP"'|podman|skopeo|buildah|psql |mysql|mongosh|redis-cli|apt-get|apt install'

# excluded <job>: a caller-supplied glob over the JOB KEY, one per line or space-separated.
excluded() {
	local job="$1" pat
	for pat in $EXCLUDE; do
		[ -n "$pat" ] || continue
		# shellcheck disable=SC2254 # the pattern is a glob by contract
		case "$job" in $pat) return 0 ;; esac
	done
	return 1
}

total=0
found=0
for f in "${wf[@]}"; do
	rel="${f#"$TOP"/}"
	if ! rows=$(yq -r "$QUERY" "$f" 2>/dev/null); then
		echo "::error file=${rel}::runner-tier could not parse this workflow"
		exit 2
	fi

	# An in-tree `uses: ./x` (or `$/x`) keeps `using: docker` in the action's own file, so the
	# step text never says docker. Joined per job, because yq's `as $v` re-emits every binding.
	docker_jobs=""
	local_refs=$(yq -r '.jobs // {} | to_entries[] | .key + "\t"
		+ ([(.value.steps // [])[] | .uses // "" | select(test("^[.$]/"))] | join(" "))' \
		"$f" 2>/dev/null)
	while IFS=$'\t' read -r j refs; do
		[ -n "$refs" ] || continue
		for lref in $refs; do
			# `#*/` because the prefix is `./` or `$/` and both end at the first slash.
			for m in "$TOP/${lref#*/}/action.yml" "$TOP/${lref#*/}/action.yaml"; do
				[ -f "$m" ] || continue
				if [ "$(yq -r '.runs.using // ""' "$m" 2>/dev/null)" = docker ]; then
					docker_jobs="${docker_jobs} ${j} "
				fi
			done
		done
	done <<<"$local_refs"

	while IFS=$'\t' read -r job runson is_reusable has_container has_services tmo line steps note; do
		[ -n "$job" ] || continue
		[ "$is_reusable" = true ] && continue
		# Expressions and other runner labels are out of scope.
		[ "$runson" = ubuntu-latest ] || continue
		total=$((total + 1))
		[ "$has_container" = true ] || [ "$has_services" = true ] && continue
		case "$steps" in *step-security/harden-runner* | *docker*) continue ;; esac
		case "$docker_jobs" in *" ${job} "*) continue ;; esac
		[[ "$steps" =~ $HEAVY ]] && continue
		[[ "$steps" =~ $SLIMGAP ]] && continue
		case "$note" in *ubuntu-slim*) continue ;; esac
		case "$tmo" in '' | 0 | *[!0-9]*) continue ;; esac
		[ "$tmo" -gt 15 ] && continue
		excluded "$job" && continue

		found=$((found + 1))
		echo "::error file=${rel},line=${line}::job '${job}' can use ubuntu-slim; change runs-on or add an ubuntu-slim waiver comment"
	done <<<"$rows"
done

if [ "$total" -eq 0 ]; then
	echo "runner-tier: no ubuntu-latest jobs"
	exit 0
fi
if [ "$found" -eq 0 ]; then
	echo "runner-tier: ${total} ubuntu-latest job(s) require that runner"
	exit 0
fi
echo "runner-tier: ${found} of ${total} ubuntu-latest job(s) could run on ubuntu-slim"
exit 1
