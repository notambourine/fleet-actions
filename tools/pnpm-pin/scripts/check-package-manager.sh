#!/bin/bash
# Assert the root package.json pins an exact package manager version.
#
# Root only: workspaces inherit the field, and corepack reads the root manifest.
# A repo with no package.json is not a JavaScript repo and passes silently, so
# consumers can leave the input on by default.
set -euo pipefail

ROOT="${1:-.}"
MANIFEST="$ROOT/package.json"

if [ ! -f "$MANIFEST" ]; then
	echo "no package.json at the root; nothing to assert"
	exit 0
fi

PM=$(jq -r '.packageManager // empty' "$MANIFEST")

if [ -z "$PM" ]; then
	echo "::error file=package.json::package.json declares no packageManager. Run \`corepack use pnpm@<version>\`."
	exit 1
fi

# A bare name lets corepack resolve whatever is newest, which defeats the pin.
# The trailing hash corepack writes is optional and anything after the version is fine.
if [[ ! "$PM" =~ ^[a-z][a-z0-9-]*@[0-9]+\.[0-9]+\.[0-9]+([-+].*)?$ ]]; then
	echo "::error file=package.json::packageManager must pin an exact version, got '${PM}'"
	exit 1
fi

echo "packageManager: ${PM}"
