#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/openai/hooks.d/assemble/10-messages"
msg_dir="${HARNESS_SESSION}/messages"

cat > "${msg_dir}/0001-tool_result.md" <<'EOF'
---
role: tool_result
call_id: call_new
tool: bash
error: false
---
tool output before nested dump
---
role: tool_result
call_id: call_old
tool: bash
error: false
---
tool output after nested dump
EOF

out="$(echo '{}' | "$hook")"

assert_json '.messages[0].role' "$out" "tool"
assert_json '.messages[0].tool_call_id' "$out" "call_new"
assert_json '.messages[0].content' "$out" $'tool output before nested dump\n---\nrole: tool_result\ncall_id: call_old\ntool: bash\nerror: false\n---\ntool output after nested dump'
