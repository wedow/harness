#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_SESSIONS="${_tmpdir}/sessions"
export HARNESS_HOME="${_tmpdir}/home"
export HARNESS_MODEL=""
mkdir -p "${HARNESS_SESSIONS}" "${HARNESS_HOME}"

acp="${HARNESS_ROOT}/plugins/core/commands/acp"

# Send a notification (no id field) followed by a valid request.
# Per JSON-RPC 2.0, a message without "id" is a notification and should
# not crash the server. The valid message after it must still be processed.
out="$(printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  | "$acp" 2>/dev/null)" || true

# The adapter must survive the id-less message and respond to the valid one.
[[ -n "$out" ]] || { echo "FAIL: no output — adapter crashed on missing id"; exit 1; }

response="$(echo "$out" | head -1)"
assert_json '.id' "$response" "1"
assert_json '.result.agentInfo.name' "$response" "harness"

echo "PASS"
