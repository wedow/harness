#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/chatgpt/hooks.d/assemble/10-messages"
msg_dir="${HARNESS_SESSION}/messages"

cat > "${msg_dir}/0001-assistant.md" <<'MSGEOF'
---
role: assistant
stop: tool_calls
---
```tool_call id=call_123 name=bash
{"command":"pwd"}
```
MSGEOF

out="$(echo '{}' | "$hook")"

assert_json '.messages | length' "$out" "1"
assert_json '.messages[0].type' "$out" "function_call"
assert_json '.messages[0].call_id' "$out" "call_123"
assert_json '.messages[0].name' "$out" "bash"
assert_json '.messages[0].arguments' "$out" '{"command":"pwd"}'
