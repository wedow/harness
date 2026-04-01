#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/anthropic/hooks.d/assemble/10-messages"
msg_dir="${HARNESS_SESSION}/messages"

# Create fixture message files
cat > "${msg_dir}/0001-user.md" <<'EOF'
---
role: user
---
List files
EOF

cat > "${msg_dir}/0002-assistant.md" <<'MSGEOF'
---
role: assistant
---
```tool_call id=toolu_456 name=bash
{"command":"ls"}
```
MSGEOF

cat > "${msg_dir}/0003-tool_result.md" <<'EOF'
---
role: tool_result
call_id: toolu_456
tool: bash
---
file1.txt
file2.txt
EOF

cat > "${msg_dir}/0004-assistant.md" <<'EOF'
---
role: assistant
---
Here are the files.
EOF

out="$(echo '{}' | "$hook")"

# Assert 4 messages (tool_result wrapped in user message)
assert_json '.messages | length' "$out" "4"

# messages[1] should have content array with tool_use block
assert_json '.messages[1].content | type' "$out" "array"
assert_json '.messages[1].content[0].type' "$out" "tool_use"
assert_json '.messages[1].content[0].id' "$out" "toolu_456"
assert_json '.messages[1].content[0].name' "$out" "bash"

# messages[2] should be the tool_result wrapped as user role
assert_json '.messages[2].role' "$out" "user"
assert_json '.messages[2].content[0].type' "$out" "tool_result"
assert_json '.messages[2].content[0].tool_use_id' "$out" "toolu_456"
