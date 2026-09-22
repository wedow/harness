#!/usr/bin/env bash
# Request lengths must be validated before Bash evaluates them as arithmetic.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

handler="${HARNESS_ROOT}/plugins/web/lib/handler"
marker="${_tmpdir}/arithmetic-ran"

request() { printf '%s\r\n' 'POST /missing HTTP/1.1' "$1" '' | "$handler"; }

# A Bash array subscript in arithmetic context can evaluate command
# substitutions. Keep the marker inside the test sandbox.
payload='BODY[$(touch '"${marker}"')]'
request "Content-Length: ${payload}" > "${_tmpdir}/response" 2> "${_tmpdir}/error" || true
[[ ! -e "${marker}" ]] || { echo 'FAIL: Content-Length executed shell code'; exit 1; }
grep -q '^HTTP/1.1 400 ' "${_tmpdir}/response" || { echo 'FAIL: malformed length was not rejected'; exit 1; }

request 'Content-Length: 1048577' > "${_tmpdir}/response"
grep -q '^HTTP/1.1 413 ' "${_tmpdir}/response" || { echo 'FAIL: oversized body was not rejected'; exit 1; }

request 'Content-Length: 0' > "${_tmpdir}/response"
grep -q '^HTTP/1.1 404 ' "${_tmpdir}/response" || { echo 'FAIL: valid length was rejected'; exit 1; }

echo PASS
