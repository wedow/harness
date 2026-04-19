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
echo "$out" | jq -r '.system' | grep -q "test agent" || { echo "FAIL: prompt not in system"; exit 1; }
# source annotation present
echo "$out" | jq -r '.system' | grep -q "<!-- source:.*001-system.md -->" || { echo "FAIL: source annotation missing"; exit 1; }

# Test: AGENTS.md at parent dir is also picked up
echo "# Project Agent" > "${_tmpdir}/project/AGENTS.md"
out="$(echo '{}' | "$hook")"
assert_json '.next_state' "$out" "send"
echo "$out" | jq -r '.system' | grep -q "Project Agent" || { echo "FAIL: AGENTS.md not in system"; exit 1; }
echo "$out" | jq -r '.system' | grep -q "test agent" || { echo "FAIL: prompt not in system"; exit 1; }
echo "$out" | jq -r '.system' | grep -q "<!-- source:.*AGENTS.md -->" || { echo "FAIL: AGENTS.md source annotation missing"; exit 1; }
