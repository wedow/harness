#!/usr/bin/env bash
# web-watchdog-visible — the stream watchdog only reloads on foreground
# stalls: hidden tabs must not queue a reload for the moment of return.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup
source "${HARNESS_ROOT}/plugins/web/lib/http.sh"
source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"

out="$(_head "t" "t" </dev/null)"
echo "${out}" | grep -q "visibilitychange" || { echo "FAIL: no visibilitychange handler"; exit 1; }
echo "${out}" | grep -qF "!document.hidden && Date.now() - lastBeat > 45000" \
  || { echo "FAIL: watchdog not gated on visibility"; exit 1; }

# the session page ships details open-state preservation (morphs strip the
# open attribute from server HTML; the client records user toggles by id)
mkdir -p "${HARNESS_SESSIONS}/wv/messages"
page="$(_session_page wv "meta")"
echo "${page}" | grep -q 'open state survives morphs' \
  || { echo "FAIL: open-state script missing from session page"; exit 1; }
echo "${page}" | grep -qF "attributeFilter: ['open']" \
  || { echo "FAIL: open-attribute observer missing"; exit 1; }
