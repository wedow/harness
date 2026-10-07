#!/usr/bin/env bash
# A new SSE connection with saved messages must render and clean up its fifo
# under the handler's nounset mode.
set -euo pipefail
source "${SPEC_DIR}/helpers.sh"
setup

sid=initial-message
dir="${HARNESS_SESSIONS}/${sid}"
mkdir -p "${dir}/messages"
cat > "${dir}/messages/0001-user.md" <<'MSG'
---
role: user
seq: 0001
---
hello
MSG

if ! output="$(timeout 5 bash -uo pipefail -c '
  source "$HARNESS_ROOT/plugins/web/lib/http.sh"
  source "$HARNESS_ROOT/plugins/web/lib/pages.sh"
  respond_sse() { :; }
  sse_patch() {
    case "$1" in *"id=\"agent-status\""*) exit 0 ;; esac
  }
  handle_events initial-message
' 2>&1)"; then
  echo "FAIL: initial SSE render failed: ${output}" >&2
  exit 1
fi
if find "${dir}/.ui" -name '*.fifo' | grep -q .; then
  echo 'FAIL: SSE handler left a fifo after exit' >&2
  exit 1
fi
echo PASS
