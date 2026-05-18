#!/usr/bin/env bash
# Test: running compaction twice creates separate timestamped archive dirs.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/rlm/hooks.d/assemble/25-compact"
msg_dir="${HARNESS_SESSION}/messages"

big="$(printf 'x%.0s' $(seq 1 5000))"

# --- First compaction ---
cat > "${msg_dir}/0001-user.md" <<EOF
---
role: user
seq: 0001
---
${big}
EOF

echo '{}' | RLM_COMPACT_TOTAL=1000 "${hook}" > /dev/null

# Verify first archive
archive_count="$(ls -1 "${HARNESS_SESSION}/archives/" | wc -l)"
assert_eq "one archive after first compaction" "${archive_count// /}" "1"
first_ts="$(ls -1 "${HARNESS_SESSION}/archives/")"

# Ensure second archive gets a different timestamp
sleep 1

# --- Second compaction ---
# The continuation message is small, so add a large message to trigger again
cat > "${msg_dir}/0002-assistant.md" <<EOF
---
role: assistant
seq: 0002
---
${big}
EOF

echo '{}' | RLM_COMPACT_TOTAL=1000 "${hook}" > /dev/null

# Verify two separate archives
archive_count="$(ls -1 "${HARNESS_SESSION}/archives/" | wc -l)"
assert_eq "two archives after second compaction" "${archive_count// /}" "2"

# Both archives should contain messages
for ts_dir in "${HARNESS_SESSION}/archives/"*/; do
  [[ -d "${ts_dir}/messages" ]] || { echo "FAIL: archive ${ts_dir} missing messages/"; exit 1; }
  count="$(ls -1 "${ts_dir}/messages/"*.md 2>/dev/null | wc -l)"
  (( count > 0 )) || { echo "FAIL: archive ${ts_dir} has no message files"; exit 1; }
done

# Fresh messages dir should have only the latest continuation
fresh_count="$(ls -1 "${msg_dir}"/*.md | wc -l)"
assert_eq "one continuation message" "${fresh_count// /}" "1"
assert_file_contains "${msg_dir}/0001-user.md" "[Session continuation]"
