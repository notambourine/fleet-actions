#!/bin/bash
# Behavior tests for scripts/check-runner-tier.sh. Each case writes one fixture workflow into
# a throwaway tree and asserts the exit code plus one output substring, so both the code and
# one message are load-bearing.
#
# Hermetic: fixtures never land in this repo's own .github/workflows, and the last case runs
# the gate over the real tree, which must pass its own rule.
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

# new_repo <name>: a git repo with an empty workflows dir, and $REPO/$WF pointing into it.
new_repo() {
	REPO="$TMP/$1"
	mkdir -p "$REPO/.github/workflows"
	git init -q -b main "$REPO"
	WF="$REPO/.github/workflows/ci.yml"
}

# wf <body>: the fixture workflow for this case.
wf() { printf '%s\n' "$1" >"$WF"; }

# run_case <name> <want-rc> <output-substring>: runs the gate from $REPO.
# $EXCLUDE becomes RUNNER_TIER_EXCLUDE, $FILES becomes RUNNER_TIER_FILES.
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

# 1. the planted positive: nothing here needs the expensive tier.
new_repo planted
wf 'on: push
jobs:
  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: echo hi'
run_case "a bare ubuntu-latest job is a finding" 1 "job 'lint' needs nothing ubuntu-latest provides"
run_case "and the summary counts it" 1 "1 of 1 ubuntu-latest job(s) could run on ubuntu-slim"

# 2. already slim, or on a tier this gate does not judge.
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
run_case "another tier is out of scope" 0 "no ubuntu-latest jobs"

# 3. each disqualifier, one job at a time. Every one of these must come out clean.
new_repo container
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    container: node:22
    steps:
      - run: echo hi'
run_case "container: needs the tier" 0 "all 1 ubuntu-latest job(s) need that tier"

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
run_case "services: needs the tier" 0 "all 1 ubuntu-latest job(s) need that tier"

new_repo hardened
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: step-security/harden-runner@v2
      - run: echo hi'
run_case "harden-runner cannot load unprivileged" 0 "need that tier"

new_repo heavy
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: npm ci'
run_case "an install command is weight" 0 "need that tier"

new_repo slimgap
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: envsubst < in > out'
run_case "a tool slim does not ship" 0 "need that tier"

new_repo uncapped
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi'
run_case "no cap: slim would kill it at 15" 0 "need that tier"

new_repo overcap
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - run: echo hi'
run_case "a cap above slim's 15-minute kill" 0 "need that tier"

new_repo reusable
wf 'on: push
jobs:
  a:
    uses: ./.github/workflows/other.yml'
run_case "a reusable call has no runner of its own" 0 "no ubuntu-latest jobs"

# 4. the case this gate exists for: an in-tree action whose runtime is docker. The step text
#    never says docker, so only reading the action's own file catches it.
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
run_case "an in-tree docker action needs the tier" 0 "need that tier"

wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: $/tools/thing'
run_case "the same-repository \$/ form too" 0 "need that tier"

printf 'name: thing\nruns:\n  using: composite\n  steps: []\n' >"$REPO/tools/thing/action.yml"
run_case "a composite in-tree action does not" 1 "job 'a' needs nothing"

# 5. waivers, both paths, and both directions.
new_repo waived
wf 'on: push
jobs:
  a:
    # Reason lives here: this job is exceptional.
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: echo hi'
run_case "a comment with no keyword is not a waiver" 1 "job 'a' needs nothing"

wf 'on: push
jobs:
  a:
    # Held on the expensive tier deliberately; ubuntu-slim breaks the vendored binary.
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: echo hi'
run_case "a head comment naming ubuntu-slim waives it" 0 "need that tier"

wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest # not ubuntu-slim: the vendored binary is glibc-linked
    timeout-minutes: 5
    steps:
      - run: echo hi'
run_case "a line comment on the value waives it" 0 "need that tier"

new_repo excluded
wf 'on: push
jobs:
  e2e-chrome:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: echo hi'
run_case "an unexcluded job still fires" 1 "job 'e2e-chrome' needs nothing"
EXCLUDE='e2e-*' run_case "an exclude glob holds it out" 0 "need that tier"
EXCLUDE='other-*' run_case "a glob that misses does not" 1 "job 'e2e-chrome' needs nothing"

# 6. input handling.
new_repo files
wf 'on: push
jobs:
  a:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: echo hi'
FILES='.github/workflows/nope.yml' run_case "a named file that is missing is a scan failure" 2 "no such workflow file"
FILES='.github/workflows/ci.yml' run_case "a named file is read" 1 "job 'a' needs nothing"

new_repo unparsed
printf 'jobs: [\n' >"$WF"
run_case "an unparseable workflow is a scan failure, never a pass" 2 "could not parse"

new_repo empty
rm -rf "$REPO/.github"
run_case "no workflows at all" 0 "no workflow files to read"

# 7. this repo passes its own gate.
REPO="$REPO_ROOT" run_case "this repo passes its own gate" 0 "need that tier"

echo
echo "${cases} cases, ${fails} failed"
[ "$fails" -eq 0 ]
