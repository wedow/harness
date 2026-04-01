#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/assemble/30-prompts"

# Create a mock source with prompts/*.md
src="${_tmpdir}/project/.harness"
make_sources "$src"
mkdir -p "${src}/prompts"
echo "You are a test agent." > "${src}/prompts/001-system.md"

# Test: prompt text appears in system field, next_state is send
out="$(echo '{}' | "$hook")"
assert_json '.next_state' "$out" "send"
assert_json '.system' "$out" "You are a test agent."

# Test: AGENTS.md at parent dir is also picked up
echo "# Project Agent" > "${_tmpdir}/project/AGENTS.md"
out="$(echo '{}' | "$hook")"
assert_json '.next_state' "$out" "send"
# system should contain both AGENTS.md and the prompt file
echo "$out" | jq -r '.system' | grep -q "Project Agent" || { echo "FAIL: AGENTS.md not in system"; exit 1; }
echo "$out" | jq -r '.system' | grep -q "test agent" || { echo "FAIL: prompt not in system"; exit 1; }
