#!/usr/bin/env bash
# A session's title appears in both the browser tab and the visible page
# header. Untitled sessions continue to show their id in both places.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

source "${HARNESS_ROOT}/plugins/web/lib/http.sh"
source "${HARNESS_ROOT}/plugins/web/lib/pages.sh"

sid='named-session'
mkdir -p "${HARNESS_SESSIONS}/${sid}/messages"
title='Research <MCP> & "API"'
printf 'title=%s\nprovider=mock\n' "${title}" > "${HARNESS_SESSIONS}/${sid}/session.conf"

HEADERS=()
handle_session "${sid}"
escaped='Research &lt;MCP&gt; &amp; &quot;API&quot;'
[[ "${BODY}" == *"<title>${escaped}</title>"* ]] || {
  echo 'FAIL: browser tab does not show the escaped session title'
  exit 1
}
header="${BODY#*'<main id="main">'}"
header="${header%%'<div id="view"'*}"
[[ "${header}" == *"${escaped}"* ]] || {
  echo 'FAIL: visible page header does not show the escaped session title'
  exit 1
}

plain='untitled-session'
mkdir -p "${HARNESS_SESSIONS}/${plain}/messages"
HEADERS=()
handle_session "${plain}"
[[ "${BODY}" == *"<title>${plain}</title>"* ]] || {
  echo 'FAIL: untitled session browser tab does not fall back to its id'
  exit 1
}
header="${BODY#*'<main id="main">'}"
header="${header%%'<div id="view"'*}"
[[ "${header}" == *"${plain}"* ]] || {
  echo 'FAIL: untitled session page header does not fall back to its id'
  exit 1
}
