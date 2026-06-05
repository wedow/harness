#!/usr/bin/env bash
# Test: post-compaction prompt requires subagent-led archive recovery before resuming.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

msg_dir="${HARNESS_SESSION}/messages"
big="$(printf 'x%.0s' $(seq 1 5000))"

cat > "${msg_dir}/0001-user.md" <<EOF2
---
role: user
seq: 0001
---
${big}
EOF2

cat > "${msg_dir}/0002-assistant.md" <<EOF2
---
role: assistant
seq: 0002
---
${big}
EOF2

out="$(echo '{}' | RLM_COMPACT_TOTAL=1000 "${HARNESS_ROOT}/plugins/rlm/hooks.d/assemble/25-compact")"
assert_json '.next_state' "${out}" "assemble"

prompt="$(cat "${msg_dir}/0001-user.md")"

# Avoid asserting exact prose; enforce the recovery protocol concepts.
for required in \
  "subagent" \
  "archive" \
  "index" \
  "citation" \
  "notes/post-compaction-recovery.md" \
  "active skill" \
  "reinvoke" \
  "Do not continue"; do
  if ! grep -qi "${required}" <<< "${prompt}"; then
    echo "expected continuation prompt to include recovery concept: ${required}" >&2
    echo "${prompt}" >&2
    exit 1
  fi
done
