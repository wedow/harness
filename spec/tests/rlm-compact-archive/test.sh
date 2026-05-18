#!/usr/bin/env bash
# Test: 25-compact archives messages and injects continuation when over threshold.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

hook="${HARNESS_ROOT}/plugins/rlm/hooks.d/assemble/25-compact"
msg_dir="${HARNESS_SESSION}/messages"

# Create message files that exceed a low threshold
big="$(printf 'x%.0s' $(seq 1 5000))"

cat > "${msg_dir}/0001-user.md" <<EOF
---
role: user
seq: 0001
---
${big}
EOF

cat > "${msg_dir}/0002-assistant.md" <<EOF
---
role: assistant
seq: 0002
---
${big}
EOF

payload='{"messages":[{"role":"user","content":"big"},{"role":"assistant","content":"big"}]}'

out="$(echo "${payload}" | RLM_COMPACT_TOTAL=1000 "${hook}")"

# Output should signal reassembly
assert_json '.next_state' "${out}" "assemble"

# Archives dir should exist with one timestamped subdir
archive_count="$(ls -1 "${HARNESS_SESSION}/archives/" | wc -l)"
assert_eq "one archive created" "${archive_count// /}" "1"

# Archived messages should be in the archive
archive_ts="$(ls -1 "${HARNESS_SESSION}/archives/")"
assert_file_exists "${HARNESS_SESSION}/archives/${archive_ts}/messages/0001-user.md"
assert_file_exists "${HARNESS_SESSION}/archives/${archive_ts}/messages/0002-assistant.md"

# Fresh messages dir should have continuation message
assert_file_exists "${msg_dir}/0001-user.md"
assert_file_contains "${msg_dir}/0001-user.md" "[Session continuation]"
assert_file_contains "${msg_dir}/0001-user.md" "archives/"
assert_file_contains "${msg_dir}/0001-user.md" "Resume the task in progress"

# Only one message in the fresh dir
fresh_count="$(ls -1 "${msg_dir}"/*.md | wc -l)"
assert_eq "one continuation message" "${fresh_count// /}" "1"
