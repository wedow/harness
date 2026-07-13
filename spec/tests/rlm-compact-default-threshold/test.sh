#!/usr/bin/env bash
# Test: default compaction threshold leaves large-but-safe sessions alone.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/rlm/hooks.d/assemble/25-compact"
msg_dir="${HARNESS_SESSION}/messages"

big="$(head -c 1000000 /dev/zero | tr '\0' x)"

cat > "${msg_dir}/0001-user.md" <<EOF
---
role: user
seq: 0001
---
${big}
EOF

payload='{"messages":[{"role":"user","content":"large but below 2MB"}]}'

out="$(echo "${payload}" | "${hook}")"

assert_json '.messages[0].content' "${out}" "large but below 2MB"
[[ ! -d "${HARNESS_SESSION}/archives" ]] || { echo "FAIL: archives dir should not exist"; exit 1; }