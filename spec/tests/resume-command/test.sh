#!/usr/bin/env bash
# Test: `harness resume` resumes the most recent session.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup
export HARNESS_ROOT="$(cd "${HARNESS_ROOT}" && pwd)"

export HARNESS_HOME="${_tmpdir}/home"
export HARNESS_SESSIONS="${HARNESS_HOME}/sessions"
mkdir -p "${HARNESS_SESSIONS}"

# Anti-correlate ids vs. mtime so the test fails if `ls -1t` ever degrades
# to lexical (asc or desc) sort:
#   lex-asc:  alpha-old   <  middle-new  <  zulu-mid
#   lex-desc: zulu-mid    >  middle-new  >  alpha-old
#   mtime:    zulu-mid newer than middle-new, but wrong cwd
old_a="20240101-000000-alpha-old"
new_id="20240101-000000-middle-new"
old_z="20240101-000000-zulu-mid"
missing_cwd="20240101-000000-missing-cwd"
mkdir -p "${HARNESS_SESSIONS}/${old_a}" "${HARNESS_SESSIONS}/${new_id}" "${HARNESS_SESSIONS}/${old_z}" "${HARNESS_SESSIONS}/${missing_cwd}"
touch "${HARNESS_SESSIONS}/newer-non-session-file"
printf 'cwd=%s\n' "${PWD}" > "${HARNESS_SESSIONS}/${old_a}/session.conf"
printf 'cwd=%s\n' "${PWD}" > "${HARNESS_SESSIONS}/${new_id}/session.conf"
printf 'cwd=/other/project\n' > "${HARNESS_SESSIONS}/${old_z}/session.conf"
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

```tool_call id=call_123 name=bash
{"command":"pwd && printf '\\n--- files ---\\n'","timeout":120}
```

```tool_call id=call_456 name=write_file
{"path":"tests/test_questrade_tools.py","content":"very noisy generated test content that should not be printed in full because it represents a large generated file body rather than useful resume history"}
```
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
touch -t 202401010104 "${HARNESS_SESSIONS}/${old_z}"
touch -t 202401010105 "${HARNESS_SESSIONS}/${missing_cwd}"
touch -t 202401010106 "${HARNESS_SESSIONS}/newer-non-session-file"

resume="$(cd "${HARNESS_ROOT}" && pwd)/plugins/core/commands/resume"
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

if [[ "${output}" != *"[tool: bash]"*"pwd && printf"* || "${output}" == *"tool_call id=call_123"* ]]; then
  echo "FAIL: resume did not render assistant tool calls"
  echo "${output}"
  exit 1
fi

if [[ "${output}" != *"[tool: write_file]"*"path=tests/test_questrade_tools.py content=<"* || "${output}" == *"very noisy generated test content"* ]]; then
  echo "FAIL: resume did not summarize large tool call arguments"
  echo "${output}"
  exit 1
fi

if [[ "${output}" != *"tool line 10"* || "${output}" == *"tool line 11"* || "${output}" != *"[... 1 lines omitted]"* ]]; then
  echo "FAIL: resume did not truncate tool result history"
  echo "${output}"
  exit 1
fi

mkdir -p "${HARNESS_SESSIONS}/${old_a}/messages"
cat > "${HARNESS_SESSIONS}/${old_a}/messages/0001-user.md" <<'MSG'
---
role: user
seq: 0001
timestamp: 2024-01-01T01:01:00Z
---
explicit session history
MSG

output="$(printf '/quit\n' | bash "${resume}" "${old_a}" 2>&1)"
case "${output}" in
  *"session: ${old_a}"*) ;;
  *)
    echo "FAIL: resume did not open explicit session"
    echo "${output}"
    exit 1
    ;;
esac

if [[ "${output}" != *"explicit session history"* || "${output}" == *"previous question"* ]]; then
  echo "FAIL: resume did not print explicit session history"
  echo "${output}"
  exit 1
fi

no_match_dir="${_tmpdir}/no-match"
mkdir -p "${no_match_dir}"
rc=0
output="$(cd "${no_match_dir}" && printf '/quit\n' | bash "${resume}" 2>&1)" || rc=$?
if (( rc == 0 )) || [[ "${output}" != *"no sessions found for current directory: ${no_match_dir}"* || "${output}" != *"harness resume <session-id>"* ]]; then
  echo "FAIL: resume did not explain missing cwd match"
  echo "${output}"
  exit 1
fi

echo "PASS"
