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
What is 2+2?
EOF

cat > "${msg_dir}/0002-assistant.md" <<'EOF'
---
role: assistant
---
The answer is 4.
EOF

cat > "${msg_dir}/0003-user.md" <<'EOF'
---
role: user
---
Thanks!
EOF

out="$(echo '{}' | "$hook")"

# Assert messages array
assert_json '.messages | length' "$out" "3"
assert_json '.messages[0].role' "$out" "user"
assert_json '.messages[1].role' "$out" "assistant"
assert_json '.messages[2].role' "$out" "user"

# Assert content
echo "$out" | jq -r '.messages[0].content' | grep -q "What is 2+2?" \
  || { echo "FAIL: messages[0] missing expected content"; exit 1; }
echo "$out" | jq -r '.messages[1].content' | grep -q "The answer is 4." \
  || { echo "FAIL: messages[1] missing expected content"; exit 1; }
echo "$out" | jq -r '.messages[2].content' | grep -q "Thanks!" \
  || { echo "FAIL: messages[2] missing expected content"; exit 1; }
