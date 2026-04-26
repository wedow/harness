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

echo "PASS"