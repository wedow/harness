#!/usr/bin/env bash
# POSTs from other web origins must not reach state-changing routes.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

handler="${HARNESS_ROOT}/plugins/web/lib/handler"
request() {
  printf '%s\r\n' 'POST /missing HTTP/1.1' "$@" 'Content-Length: 0' '' | "$handler"
}
status() { sed -n '1s/\r$//p' "${_tmpdir}/response"; }

request 'Host: 127.0.0.1:8080' 'Origin: http://127.0.0.1:8080' > "${_tmpdir}/response"
[[ "$(status)" == 'HTTP/1.1 404 Not Found' ]] || { echo 'FAIL: local form rejected'; exit 1; }

printf '%s\r\n' 'GET / HTTP/1.1' 'Host: 127.0.0.1:8080' '' | "$handler" > "${_tmpdir}/response"
[[ "$(status)" == 'HTTP/1.1 200 OK' ]] || { echo 'FAIL: local GET rejected'; exit 1; }

printf '%s\r\n' 'GET / HTTP/1.1' 'Host: attacker.example:8080' '' | "$handler" > "${_tmpdir}/response"
[[ "$(status)" == 'HTTP/1.1 403 Forbidden' ]] || { echo 'FAIL: foreign Host could read GET'; exit 1; }

request 'Host: localhost:8080' 'Origin: http://localhost:8080' > "${_tmpdir}/response"
[[ "$(status)" == 'HTTP/1.1 404 Not Found' ]] || { echo 'FAIL: localhost form rejected'; exit 1; }

request 'Host: 127.0.0.1:8080' 'Origin: https://evil.example' > "${_tmpdir}/response"
[[ "$(status)" == 'HTTP/1.1 403 Forbidden' ]] || { echo 'FAIL: foreign Origin accepted'; exit 1; }

request 'Host: attacker.example:8080' 'Origin: http://attacker.example:8080' > "${_tmpdir}/response"
[[ "$(status)" == 'HTTP/1.1 403 Forbidden' ]] || { echo 'FAIL: foreign Host accepted'; exit 1; }

request 'Host: 127.0.0.1.evil.example:8080' > "${_tmpdir}/response"
[[ "$(status)" == 'HTTP/1.1 403 Forbidden' ]] || { echo 'FAIL: loopback-like Host accepted'; exit 1; }

request 'Host: 127.0.0.1:8080' 'Sec-Fetch-Site: cross-site' > "${_tmpdir}/response"
[[ "$(status)" == 'HTTP/1.1 403 Forbidden' ]] || { echo 'FAIL: cross-site request without Origin accepted'; exit 1; }

request 'Host: 127.0.0.1:8080' > "${_tmpdir}/response"
[[ "$(status)" == 'HTTP/1.1 404 Not Found' ]] || { echo 'FAIL: local client without Origin rejected'; exit 1; }

# Exercise a real form route as well: accepted requests create one session,
# while a foreign origin must leave the session directory untouched.
export HARNESS_MODEL=mock
printf '%s\r\n' 'POST /new HTTP/1.1' 'Host: 127.0.0.1:8080' \
  'Origin: http://127.0.0.1:8080' 'Content-Length: 0' '' | "$handler" > "${_tmpdir}/response"
[[ "$(status)" == 'HTTP/1.1 303 See Other' ]] || { echo 'FAIL: local new-session form rejected'; exit 1; }
before="$(find "${HARNESS_SESSIONS}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
printf '%s\r\n' 'POST /new HTTP/1.1' 'Host: 127.0.0.1:8080' \
  'Origin: https://evil.example' 'Content-Length: 0' '' | "$handler" > "${_tmpdir}/response"
[[ "$(status)" == 'HTTP/1.1 403 Forbidden' ]] || { echo 'FAIL: foreign new-session form accepted'; exit 1; }
after="$(find "${HARNESS_SESSIONS}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
assert_eq 'no session created by foreign origin' "$after" "$before"

echo PASS
