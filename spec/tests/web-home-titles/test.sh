#!/usr/bin/env bash
# web-home-titles — the home page lists sessions with their titles,
# same as the sidebar (title if set, else the id).
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

source "${HARNESS_ROOT}/plugins/web/lib/http.sh"
source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"

for sid in titled plain; do
  mkdir -p "${HARNESS_SESSIONS}/${sid}/messages"
  printf 'x\n' > "${HARNESS_SESSIONS}/${sid}/messages/0001-user.md"
done
printf 'title=My Great Session\n' > "${HARNESS_SESSIONS}/titled/session.conf"

HEADERS=()
handle_home

echo "${BODY}" | grep -qF '>My Great Session</a>' || {
  echo "FAIL: titled session shows raw id or no title"; echo "${BODY}"; exit 1
}
echo "${BODY}" | grep -qF '>plain</a>' || {
  echo "FAIL: untitled session should fall back to id"; echo "${BODY}"; exit 1
}
