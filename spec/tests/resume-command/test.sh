#!/usr/bin/env bash
# Test: `harness resume` resumes the most recent session.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

export HARNESS_HOME="${_tmpdir}/home"
export HARNESS_SESSIONS="${HARNESS_HOME}/sessions"
mkdir -p "${HARNESS_SESSIONS}"

old_id="20240101-000000-111"
new_id="20240101-000000-222"
mkdir -p "${HARNESS_SESSIONS}/${old_id}/messages"
mkdir -p "${HARNESS_SESSIONS}/${new_id}/messages"

cat > "${HARNESS_SESSIONS}/${old_id}/session.conf" <<EOF
id=${old_id}
EOF
cat > "${HARNESS_SESSIONS}/${new_id}/session.conf" <<EOF
id=${new_id}
EOF

touch -t 202401010101 "${HARNESS_SESSIONS}/${old_id}"
touch -t 202401010102 "${HARNESS_SESSIONS}/${new_id}"

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