#!/usr/bin/env bash
# Test: tool_done .stream events should use same field names as tool_start
# tool_start uses {id, name} — tool_done should match, and include error field.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/core/hooks.d/tool_done/10-save"

# Run hook with error=false
echo '{"call_id":"c1","name":"bash","input":{},"result":"ok","error":false,"tool_calls":[]}' \
  | "$hook" > /dev/null

# Run hook with error=true
echo '{"call_id":"c2","name":"read_file","input":{},"result":"not found","error":true,"tool_calls":[]}' \
  | "$hook" > /dev/null

stream="${HARNESS_SESSION}/.stream"
assert_file_exists "$stream"

line1="$(sed -n '1p' "$stream")"
line2="$(sed -n '2p' "$stream")"

# tool_done should use "id" (matching tool_start), not "call_id"
assert_json '.id' "$line1" "c1"
assert_json '.name' "$line1" "bash"

# tool_done should include error field
assert_json '.error' "$line1" "false"

# Second event: error=true case
assert_json '.id' "$line2" "c2"
assert_json '.name' "$line2" "read_file"
assert_json '.error' "$line2" "true"
