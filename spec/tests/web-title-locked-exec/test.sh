#!/usr/bin/env bash
# A locked user title cannot be changed by invoking the tool directly.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

session="${_tmpdir}/session"
mkdir -p "${session}"
printf 'title=User title\ntitle_locked=1\n' > "${session}/session.conf"
export HARNESS_SESSION="${session}"

if printf '{"title":"Agent title"}' | "${HARNESS_ROOT}/plugins/web/tools/title" --exec > "${_tmpdir}/out"; then
  echo 'FAIL: locked title was changed'
  exit 1
fi
assert_eq 'locked title remains' "$(sed -n 's/^title=//p' "${session}/session.conf")" 'User title'
