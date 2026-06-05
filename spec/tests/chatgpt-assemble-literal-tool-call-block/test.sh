#!/usr/bin/env bash
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/chatgpt/hooks.d/assemble/10-messages"
msg_dir="${HARNESS_SESSION}/messages"

cat > "${msg_dir}/0001-assistant.md" <<'MSGEOF'
---
role: assistant
stop: end
---
Here is what the serialized form would look like:

```tool_call id=archive-recovery-1 name=write_file
{"path":".harness/tools/archive-recovery","content":"..."}
```

Do not run it; this is documentation.
MSGEOF

out="$(echo '{}' | "$hook")"

assert_json '.messages | length' "$out" "1"
assert_json '.messages[0].type' "$out" "message"
assert_json '.messages[0].role' "$out" "assistant"
assert_json '.messages[0].content[0].type' "$out" "output_text"
assert_json '.messages[0].content[0].text' "$out" $'Here is what the serialized form would look like:\n\n```tool_call id=archive-recovery-1 name=write_file\n{"path":".harness/tools/archive-recovery","content":"..."}\n```\n\nDo not run it; this is documentation.'
