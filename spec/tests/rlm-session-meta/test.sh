#!/usr/bin/env bash
# Test: 32-session-meta appends session paths to system prompt.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/rlm/hooks.d/assemble/32-session-meta"

# Create a note file to verify listing
mkdir -p "${HARNESS_SESSION}/notes"
echo "some findings" > "${HARNESS_SESSION}/notes/research.md"

payload='{"system":"You are a helpful agent."}'
out="$(echo "${payload}" | "${hook}")"

sys="$(echo "${out}" | jq -r '.system')"

# Should contain session paths
echo "${sys}" | grep -q "messages/" || { echo "FAIL: messages path missing"; exit 1; }
echo "${sys}" | grep -q "notes/" || { echo "FAIL: notes path missing"; exit 1; }

# Should list existing notes
echo "${sys}" | grep -q "research.md" || { echo "FAIL: notes listing missing"; exit 1; }

# Original system prompt preserved
echo "${sys}" | grep -q "helpful agent" || { echo "FAIL: original system prompt lost"; exit 1; }
