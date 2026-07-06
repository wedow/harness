#!/usr/bin/env bash
# Test: `harness resume` resumes the most recent session.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_HOME="${_tmpdir}/home"
export HARNESS_SESSIONS="${HARNESS_HOME}/sessions"
mkdir -p "${HARNESS_SESSIONS}"

# Anti-correlate ids vs. mtime so the test fails if `ls -1t` ever degrades
# to lexical (asc or desc) sort:
#   lex-asc:  alpha-old   <  middle-new  <  zulu-mid
#   lex-desc: zulu-mid    >  middle-new  >  alpha-old
#   mtime:    middle-new (newest) — only this matches new_id
old_a="20240101-000000-alpha-old"
new_id="20240101-000000-middle-new"
old_z="20240101-000000-zulu-mid"
mkdir -p "${HARNESS_SESSIONS}/${old_a}" "${HARNESS_SESSIONS}/${new_id}" "${HARNESS_SESSIONS}/${old_z}"
mkdir -p "${HARNESS_SESSIONS}/${new_id}/messages"
cat > "${HARNESS_SESSIONS}/${new_id}/messages/0001-user.md" <<'MSG'
---
role: user
seq: 0001
timestamp: 2024-01-01T01:01:00Z
---
previous question
MSG
cat > "${HARNESS_SESSIONS}/${new_id}/messages/0002-assistant.md" <<'MSG'
---
role: assistant
seq: 0002
timestamp: 2024-01-01T01:02:00Z
---
previous answer
MSG
cat > "${HARNESS_SESSIONS}/${new_id}/messages/0003-tool_result.md" <<'MSG'
---
role: tool_result
seq: 0003
timestamp: 2024-01-01T01:03:00Z
tool: bash
error: false
---
tool line 01
tool line 02
tool line 03
tool line 04
tool line 05
tool line 06
tool line 07
tool line 08
tool line 09
tool line 10
tool line 11
MSG

touch -t 202401010101 "${HARNESS_SESSIONS}/${old_a}"
touch -t 202401010103 "${HARNESS_SESSIONS}/${new_id}"
touch -t 202401010102 "${HARNESS_SESSIONS}/${old_z}"

resume="${HARNESS_ROOT}/plugins/core/commands/resume"
output="$(printf '/quit\n' | bash "${resume}" 2>&1)"

case "${output}" in
  *"session: ${new_id}"*) ;;
  *)
    echo "FAIL: resume did not open most recent session"
    echo "${output}"
    exit 1
    ;;
esac

if [[ "${output}" != *"previous question"* || "${output}" != *"previous answer"* ]]; then
  echo "FAIL: resume did not print previous history"
  echo "${output}"
  exit 1
fi

if [[ "${output}" != *"tool line 10"* || "${output}" == *"tool line 11"* || "${output}" != *"[... 1 lines omitted]"* ]]; then
  echo "FAIL: resume did not truncate tool result history"
  echo "${output}"
  exit 1
fi

echo "PASS"
