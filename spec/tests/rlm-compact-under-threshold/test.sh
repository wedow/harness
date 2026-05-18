#!/usr/bin/env bash
# Test: 25-compact passes through unchanged when total message size is under threshold.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/rlm/hooks.d/assemble/25-compact"
msg_dir="${HARNESS_SESSION}/messages"

# Create small message files
cat > "${msg_dir}/0001-user.md" <<'EOF'
---
role: user
seq: 0001
---
hello
EOF

cat > "${msg_dir}/0002-assistant.md" <<'EOF'
---
role: assistant
seq: 0002
---
hi there
EOF

payload='{"messages":[{"role":"user","content":"hello"},{"role":"assistant","content":"hi there"}]}'

out="$(echo "${payload}" | RLM_COMPACT_TOTAL=200000 "${hook}")"

# Payload passes through unchanged
assert_json '.messages[0].content' "${out}" "hello"
assert_json '.messages[1].content' "${out}" "hi there"

# No archives created
[[ ! -d "${HARNESS_SESSION}/archives" ]] || { echo "FAIL: archives dir should not exist"; exit 1; }
