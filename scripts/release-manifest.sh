#!/usr/bin/env bash
# Print top-level repo paths to bundle in release packages.
# bin/ is excluded — each packager installs it separately with path patching.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." >/dev/null && pwd)"

for path in AGENTS.md docs lib LICENSE plugins README.md vendor; do
    if [[ -e "$REPO_ROOT/$path" ]]; then
        printf '%s\n' "$path"
    fi
done
