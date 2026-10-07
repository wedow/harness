#!/usr/bin/env bash
# gzip is sent only when the Accept-Encoding quality permits it.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup
source "${HARNESS_ROOT}/plugins/web/lib/http.sh"

STATUS=200
HEADERS=()
BODY="$(head -c 1024 /dev/zero | tr '\0' x)"

check_encoding() { # $1 header value, $2 expected: gzip or identity
  HTTP_HEADERS[accept-encoding]="$1"
  respond_request > "${_tmpdir}/response"
  local actual=identity
  if grep -a -iq $'^Content-Encoding: gzip\r$' "${_tmpdir}/response"; then
    actual=gzip
  fi
  assert_eq "Accept-Encoding: $1" "$actual" "$2"
}

check_encoding 'gzip;q=0, identity' identity
check_encoding 'GZIP ; Q=0.000, br' identity
check_encoding 'xgzip, br' identity
check_encoding 'gzip;q=0, *;q=1' identity
check_encoding 'gzip;q=0.5, br' gzip
check_encoding 'GZIP ; Q=1' gzip
check_encoding 'gzip, br' gzip
check_encoding 'br, *;q=0.2' gzip

echo PASS
