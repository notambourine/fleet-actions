#!/bin/bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-runner-tier.sh"
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
cases=0

if ! command -v yq >/dev/null 2>&1; then
	echo "yq (mikefarah v4) is required; brew install yq"
	exit 2
fi

new_repo() {
	REPO="$TMP/$1"
	mkdir -p "$REPO/.github/workflows"
	git init -q -b main "$REPO"
	WF="$REPO/.github/workflows/ci.yml"
}

wf() { printf '%s\n' "$1" >"$WF"; }

run_case() {
	local name="$1" want_rc="$2" want_out="$3" out rc ok=1
	cases=$((cases + 1))
	out=$(cd "$REPO" && RUNNER_TIER_EXCLUDE="${EXCLUDE:-}" RUNNER_TIER_FILES="${FILES:-}" \
		bash "$CHECK" 2>&1)
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

new_repo planted
wf 'on: push
jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: echo hi'
run_case "flags eligible job" 1 "job 'lint' can use ubuntu-slim"
run_case "counts eligible job" 1 "1 of 1 ubuntu-latest job(s) could run on ubuntu-slim"

new_repo slim
wf 'on: push
jobs:
  lint:
    runs-on: ubuntu-slim
    timeout-minutes: 5
    steps:
      - run: echo hi
  mac:
    runs-on: macos-latest
    steps:
      - run: echo hi'
run_case "ignores other runners" 0 "no ubuntu-latest jobs"

new_repo container
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    container: node:22
    steps:
      - run: echo hi'
run_case "excludes container" 0 "1 ubuntu-latest job(s) require that runner"

new_repo services
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    services:
      pg:
        image: postgres
    steps:
      - run: echo hi'
run_case "excludes services" 0 "1 ubuntu-latest job(s) require that runner"

new_repo hardened
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: step-security/harden-runner@v2
      - run: echo hi'
run_case "excludes harden-runner" 0 "require that runner"

new_repo heavy
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: npm ci'
run_case "excludes install command" 0 "require that runner"

new_repo slimgap
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: envsubst < in > out'
run_case "excludes missing tool" 0 "require that runner"

new_repo uncapped
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'
run_case "excludes missing timeout" 0 "require that runner"

new_repo overcap
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - run: echo hi'
run_case "excludes timeout above 15" 0 "require that runner"

new_repo reusable
wf 'on: push
jobs:
  a:
    uses: ./.github/workflows/other.yml'
run_case "ignores reusable workflow" 0 "no ubuntu-latest jobs"

new_repo localdocker
mkdir -p "$REPO/tools/thing"
printf 'name: thing\nruns:\n  using: docker\n  image: Dockerfile\n' \
	>"$REPO/tools/thing/action.yml"
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: ./tools/thing'
run_case "excludes local docker action" 0 "require that runner"

wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: $/tools/thing'
run_case "excludes local docker action with \$/" 0 "require that runner"

printf 'name: thing\nruns:\n  using: composite\n  steps: []\n' >"$REPO/tools/thing/action.yml"
run_case "allows local composite action" 1 "job 'a' can use ubuntu-slim"

new_repo waived
wf 'on: push
jobs:
  a:
    # Uses a vendored binary.
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: echo hi'
run_case "requires waiver keyword" 1 "job 'a' can use ubuntu-slim"

wf 'on: push
jobs:
  a:
    # ubuntu-slim breaks the vendored binary.
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: echo hi'
run_case "accepts head-comment waiver" 0 "require that runner"

wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest # not ubuntu-slim: the vendored binary is glibc-linked
    timeout-minutes: 5
    steps:
      - run: echo hi'
run_case "accepts line-comment waiver" 0 "require that runner"

new_repo excluded
wf 'on: push
jobs:
  e2e-chrome:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: echo hi'
run_case "flags unexcluded job" 1 "job 'e2e-chrome' can use ubuntu-slim"
EXCLUDE='e2e-*' run_case "accepts exclude glob" 0 "require that runner"
EXCLUDE='other-*' run_case "ignores unmatched glob" 1 "job 'e2e-chrome' can use ubuntu-slim"

new_repo files
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: echo hi'
FILES='.github/workflows/nope.yml' run_case "rejects missing file" 2 "no such workflow file"
FILES='.github/workflows/ci.yml' run_case "scans named file" 1 "job 'a' can use ubuntu-slim"

new_repo unparsed
printf 'jobs: [\n' >"$WF"
run_case "rejects invalid workflow" 2 "could not parse"

new_repo empty
rm -rf "$REPO/.github"
run_case "accepts empty workflow set" 0 "no workflow files to read"

REPO="$REPO_ROOT" run_case "passes repository" 0 "require that runner"

echo
echo "${cases} cases, ${fails} failed"
[ "$fails" -eq 0 ]
