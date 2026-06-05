#!/usr/bin/env bash
# Test: installed commands/tools are executable by the harness.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

paths=(
  "${HARNESS_ROOT}/plugins/core/commands/stream"
  "${HARNESS_ROOT}/plugins/core/lib/stream-renderer.sh"
  "${HARNESS_ROOT}/plugins/subagents/tools/agent"
)

for path in "${paths[@]}"; do
  if [[ ! -x "${path}" ]]; then
    echo "FAIL: expected executable: ${path#${HARNESS_ROOT}/}"
    exit 1
  fi
done

echo "PASS"