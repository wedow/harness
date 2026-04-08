#!/usr/bin/env bash
# Print top-level repo paths to bundle in release packages.
# bin/ is excluded — each packager installs it separately with path patching.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for path in AGENTS.md docs LICENSE plugins README.md vendor; do
    [[ -e "$REPO_ROOT/$path" ]] && printf '%s\n' "$path"
done
