#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_SESSIONS="${_tmpdir}/sessions"
export HARNESS_HOME="${_tmpdir}/home"
export HARNESS_MODEL=""
mkdir -p "${HARNESS_SESSIONS}" "${HARNESS_HOME}"

acp="${HARNESS_ROOT}/plugins/core/commands/acp"

# Feed initialize + session/new as two JSON-RPC lines
out="$(printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp"}}' \
  | "$acp" 2>/dev/null)"

line1="$(echo "$out" | sed -n '1p')"
line2="$(echo "$out" | sed -n '2p')"

# Validate initialize response
assert_json '.jsonrpc' "$line1" "2.0"
assert_json '.id' "$line1" "1"
assert_json '.result.protocolVersion' "$line1" "1"
assert_json '.result.agentInfo.name' "$line1" "harness"

# Validate session/new response
assert_json '.jsonrpc' "$line2" "2.0"
assert_json '.id' "$line2" "2"
sid="$(echo "$line2" | jq -r '.result.sessionId')"
[[ -n "$sid" ]] || { echo "FAIL: sessionId is empty"; exit 1; }

echo "PASS"
