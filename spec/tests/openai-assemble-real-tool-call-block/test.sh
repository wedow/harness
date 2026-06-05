#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/openai/hooks.d/assemble/10-messages"
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
assert_json '.messages[0].role' "$out" "assistant"
assert_json '.messages[0].tool_calls[0].id' "$out" "call_123"
assert_json '.messages[0].tool_calls[0].function.name' "$out" "bash"
assert_json '.messages[0].tool_calls[0].function.arguments' "$out" '{"command":"pwd"}'
